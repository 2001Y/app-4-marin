import Foundation
import CloudKit
import CoreMedia
#if canImport(WebRTC)
import WebRTC
#endif
import Combine
import SwiftUI
import SwiftData
import Network

@MainActor
final class P2PController: NSObject, ObservableObject {
    // Singleton instance used across SwiftUI views
    static let shared: P2PController = .init()

    enum State { case idle, connecting, connected, failed }

    @Published private(set) var state: State = .idle {
        didSet {
            log("[P2P] state changed: \(oldValue) -> \(state)", category: "P2P")
        }
    }
    @Published var localTrack: RTCVideoTrack?
    @Published var remoteTrack: RTCVideoTrack?

    private var pc: RTCPeerConnection?
    #if canImport(WebRTC)
    private var videoTransceiver: RTCRtpTransceiver?
    #endif
    private var capturer: RTCCameraVideoCapturer?
    private var hasPublishedOffer: Bool = false
    private var hasSetRemoteDescription: Bool = false
    // Connection timeout and retry
    private var connectionTimer: Timer?
    private var connectionAttempts = 0
    private let maxConnectionAttempts = 3
    private let connectionTimeout: TimeInterval = 10.0
    // Perfect Negotiation用の簡易状態
    private var isPolite: Bool = false
    private var isMakingOffer: Bool = false
    
    // Offer作成者を決定する固定ロジック
    private var isOfferCreator: Bool = false
    // --- 固定Offer作成ロジック ---
    // - UserID比較でOffer作成者を決定（辞書順で小さい方）
    // - Offer作成者のみがOfferを送信し、相手からAnswerを受信
    // - Offer作成者でない端末はOfferを受信してAnswerを送信
    // - この方式によりGlareを完全に回避し、メッシュ接続にも拡張可能
    private var needsNegotiation: Bool = false
    private var negotiationDebounceTask: Task<Void, Never>?
    private var ensureOfferTask: Task<Void, Never>?
    private var signalInfraRetryTask: Task<Void, Never>?
    private static var globalOffersInFlight: Int = 0
    private static let globalOfferLimit: Int = 2
    private var pendingRemoteCandidates: [String] = [] // remoteDescription未設定時に一時保持
    private var publishedCandidateCount: Int = 0 {
        didSet {
            if publishedCandidateCount > 0, publishedCandidateCount % 10 == 0 {
                log("[P2P] Local ICE candidates published total=\(publishedCandidateCount)", category: "P2P")
            }
        }
    }
    private var addedRemoteCandidateCount: Int = 0
    private var publishedCandidateTypeCounts: [String: Int] = [:]
    private let pathMonitor = NWPathMonitor()
    private var path: NWPath?
    private var resolvedRemoteUserID: String?
    private var signalSession: CloudKitChatManager.SignalSessionSnapshot?
    private var activeCallEpoch: Int = 0
    private var lastAppliedOfferEpoch: Int = -1
    private var lastAppliedAnswerEpoch: Int = -1
    private var publishedCandidateFingerprints: Set<String> = []
    private var appliedEnvelopeRecordIDs: Set<String> = []
    private var appliedIceRecordIDs: Set<String> = []

    private func resetSignalState(resetRoomContext: Bool) {
        negotiationDebounceTask?.cancel(); negotiationDebounceTask = nil
        ensureOfferTask?.cancel(); ensureOfferTask = nil
        signalInfraRetryTask?.cancel(); signalInfraRetryTask = nil
        needsNegotiation = false
        hasPublishedOffer = false
        hasSetRemoteDescription = false
        isMakingOffer = false
        isOfferCreator = false
        pendingRemoteCandidates.removeAll()
        publishedCandidateCount = 0
        addedRemoteCandidateCount = 0
        publishedCandidateTypeCounts.removeAll()
#if canImport(WebRTC)
        videoTransceiver = nil
#endif
        resolvedRemoteUserID = nil
        signalSession = nil
        activeCallEpoch = 0
        lastAppliedOfferEpoch = -1
        lastAppliedAnswerEpoch = -1
        publishedCandidateFingerprints.removeAll()
        appliedEnvelopeRecordIDs.removeAll()
        appliedIceRecordIDs.removeAll()
        if resetRoomContext {
            currentRoomID = ""
            currentMyID = ""
            currentRemoteID = ""
        }
        log("[P2P] Signal state cleared (resetRoomContext=\(resetRoomContext))", category: "P2P")
    }
    // 1on1限定の安定キー（同一ルーム内の2者で一致するキー）
    private func computePairKey(roomID: String, myID: String) -> String {
        let trimmedRoom = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = myID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = currentRemoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let (lo, hi) = me <= remote ? (me, remote) : (remote, me)
        return "\(trimmedRoom)#\(lo)#\(hi)"
    }

    // 現在のチャットルーム情報
    var currentRoomID: String = ""
    private var currentMyID: String = ""
    private var currentRemoteID: String = ""
    
    // MARK: - Offer Creation Logic
    
    /// Offer作成者を決定（UserID比較方式）
    /// - Parameters:
    ///   - myID: 自分のUserID
    ///   - remoteID: 相手のUserID
    /// - Returns: 自分がOffer作成者の場合true
    private func shouldCreateOffer(myID: String, remoteID: String) -> Bool {
        // UserIDを辞書順で比較し、小さい方がOfferを作成
        // これにより両端末で必ず同じ結果となる
        return myID < remoteID
    }
    
    /// メッシュ接続用：複数参加者での接続ペアごとのOffer作成者を決定
    /// - Parameter participants: 参加者のUserIDリスト
    /// - Returns: 接続ペアとOffer作成者のマッピング
    private func calculateMeshOfferMatrix(participants: [String]) -> [String: String] {
        var matrix: [String: String] = [:]
        let sorted = participants.sorted() // 辞書順でソート
        
        // 全ての接続ペアを計算
        for i in 0..<sorted.count {
            for j in (i+1)..<sorted.count {
                let pairKey = computePairKey(id1: sorted[i], id2: sorted[j])
                matrix[pairKey] = sorted[i] // 小さい方がOffer作成者
            }
        }
        
        return matrix
    }
    
    /// 接続ペアのキーを生成（順序に依存しない）
    private func computePairKey(id1: String, id2: String) -> String {
        let (smaller, larger) = id1 < id2 ? (id1, id2) : (id2, id1)
        return "\(smaller)#\(larger)"
    }

    // Initialiser hidden
    private override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] p in
            // NWPathMonitor のハンドラは @Sendable でメインアクタ外から呼ばれる。
            // MainActor 隔離のプロパティを更新するために明示的にメインへ切り替える。
            Task { @MainActor in
                self?.path = p
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "p2p.path"))
    }

    // MARK: - Connection Management
    
    private func startConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                log("[P2P] ⏰ Connection timeout after \(self.connectionTimeout)s", category: "P2P")
                self.handleConnectionTimeout()
            }
        }
        log("[P2P] Connection timer started (\(connectionTimeout)s)", category: "P2P")
    }
    
    private func handleConnectionTimeout() {
        if connectionAttempts < maxConnectionAttempts {
            connectionAttempts += 1
            log("[P2P] 🔄 Retrying connection (attempt \(connectionAttempts)/\(maxConnectionAttempts))", category: "P2P")
            
            // 既存の接続をリセット
            resetSignalState(resetRoomContext: false)
            close()
            
            // 再試行
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機
                if !currentRoomID.isEmpty && !currentMyID.isEmpty {
                    startIfNeeded(roomID: currentRoomID, myID: currentMyID, remoteID: currentRemoteID)
                }
            }
        } else {
            log("[P2P] ❌ Max connection attempts reached. Giving up.", category: "P2P")
            handleConnectionFailure()
        }
    }
    
    private func handleConnectionFailure() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        localTrack = nil
        remoteTrack = nil
        state = .failed
        
        // 診断情報を出力
        diagnoseVideoState()
        
        // UIに通知（必要に応じて）
        log("[P2P] Connection failed. Please try again later.", category: "P2P")
    }

    // MARK: - Lifecycle

    func startIfNeeded(roomID: String, myID: String, remoteID: String? = nil) {
        let normalizedRoom = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMyID = myID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedMyID.isEmpty else {
            log("[P2P] Skip start: myID unavailable room=\(normalizedRoom)", category: "P2P")
            return
        }

        if state != .idle {
            if currentRoomID != normalizedRoom {
                log("[P2P] Switching room: closing previous peer (from=\(currentRoomID) to=\(normalizedRoom))", category: "P2P")
                close()
            } else {
                log("[P2P] Skip start: already active for room=\(normalizedRoom) state=\(state)", category: "P2P")
                
                // 既にアクティブな場合でも現在の状態をログ出力
                if let context = try? ModelContainerBroker.shared.mainContext() {
                    var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == normalizedRoom })
                    descriptor.fetchLimit = 1
                    if let room = (try? context.fetch(descriptor))?.first {
                        log("[P2P] Current participants in room=\(normalizedRoom): \(room.participants.count)", category: "P2P")
                        for participant in room.participants {
                            log("[P2P]   - userID=\(String(participant.userID.prefix(8))) isLocal=\(participant.isLocal) displayName=\(participant.displayName ?? "nil")", category: "P2P")
                        }
                    }
                }
                return
            }
        }

        currentRoomID = normalizedRoom
        currentMyID = normalizedMyID
        resetSignalState(resetRoomContext: false)

        let initialRemote = remoteID?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentRemoteID = initialRemote ?? ""
        resolvedRemoteUserID = initialRemote

        state = .connecting
        publishedCandidateCount = 0
        addedRemoteCandidateCount = 0
        publishedCandidateTypeCounts.removeAll()
        
        // Start connection timer
        startConnectionTimer()
        if let p = path {
            let ifType: String = p.usesInterfaceType(.wifi) ? "wifi" : (p.usesInterfaceType(.cellular) ? "cellular" : (p.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other") )
            log("[P2P] Network path type=\(ifType) constrained=\(p.isConstrained)", category: "P2P")
        }

        setupPeer()
        log("[P2P] startIfNeeded roomID=\(normalizedRoom) myID=\(String(normalizedMyID.prefix(8))) initialRemote=\(String((initialRemote ?? "").prefix(8)))", category: "P2P")
#if canImport(WebRTC)
        log("[P2P] WebRTC framework present", category: "P2P")
#else
        log("[P2P] WebRTC framework NOT present; using stubs", category: "P2P")
#endif
        log("[P2P] init flags: hasPublishedOffer=\(hasPublishedOffer) hasSetRD=\(hasSetRemoteDescription) pendingCandidates=\(pendingRemoteCandidates.count)", category: "P2P")

        maybeExchangeSDP()
    }
    
    // 相手がオンラインになった時に呼び出す
    func startLocalCameraWhenPartnerOnline() {
        guard state == .connecting && localTrack == nil else { return }
        startLocalCamera()
    }

    func close() {
        if state == .idle && currentRoomID.isEmpty {
            return
        }
        log("[P2P] close() called. Resetting peer + tracks", category: "P2P")

        // Cancel all timers and tasks
        connectionTimer?.invalidate()
        connectionTimer = nil
        connectionAttempts = 0
        negotiationDebounceTask?.cancel(); negotiationDebounceTask = nil
        ensureOfferTask?.cancel(); ensureOfferTask = nil

        pc?.delegate = nil
#if canImport(WebRTC)
        videoTransceiver?.sender.track = nil
#endif
        capturer?.stopCapture()
        capturer = nil
        localTrack = nil
        remoteTrack = nil
        pc?.close()
        pc = nil

        resetSignalState(resetRoomContext: true)
        state = .idle
    }

    func closeIfCurrent(roomID: String?, reason: String) {
        let expected = roomID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expected.isEmpty && expected != currentRoomID {
            log("[P2P] closeIfCurrent skipped (reason=\(reason)) current=\(currentRoomID) expected=\(expected)", category: "P2P")
            return
        }
        if reason.hasPrefix("navigation") && state == .connecting {
            log("[P2P] closeIfCurrent deferred (reason=\(reason)) while connecting room=\(currentRoomID)", category: "P2P")
            return
        }
        log("[P2P] closeIfCurrent invoked (reason=\(reason)) room=\(currentRoomID) state=\(state)", category: "P2P")
        close()
    }

    /// ゾーンの変更通知を受けたときのフック（差分駆動のため、ここでは診断ログのみ）
    func onZoneChanged(roomID: String) {
        guard roomID == currentRoomID else { return }
        guard state != .idle else { return }
        log("[P2P] onZoneChanged(roomID=\(roomID)) — push/delta driven flow active", category: "P2P")
    }

    // MARK: - PeerConnection setup
    private func setupPeer() {
        let f = RTCPeerConnectionFactory()
#if canImport(WebRTC)
        var cfg = RTCConfiguration()
        // ICEサーバ設定: 既定はGoogle STUN。Info.plist に TURN 設定がある場合は併用。
        var servers: [RTCIceServer] = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        /*
         TURN疎通検証結果（実施: 2025-09-11）
         実行コマンド例:
           - turnutils_uclient -y -u "$USER" -w "$PASS" -p 3478 relay1.expressturn.com  → 成功（ALLOCATE/relay addr/channel bind）
           - turnutils_uclient -y -u "$USER" -w "$PASS" -p 3480 relay1.expressturn.com  → 失敗（ERROR: Cannot complete Allocation）
           - turnutils_uclient -S -y -u "$USER" -w "$PASS" -p 443 relay1.expressturn.com → TLS接続は成功、ALLOCATE失敗
           - turnutils_uclient -S -y -u "$USER" -w "$PASS" -p 5349 relay1.expressturn.com → 接続不可
         結論:
           - 当該プロバイダでは UDP:3478 のみTURNとして有効。Info.plistは 3478/udp のみ設定。
           - TLSフォールバック（WEBRTC_TURN_URL_TLS）は現状未使用。将来対応時は Info.plist に turns:... を追加すれば自動的に併用される。
         */
        let turnURL = Bundle.main.object(forInfoDictionaryKey: "WEBRTC_TURN_URL") as? String
        let turnURLTLS = Bundle.main.object(forInfoDictionaryKey: "WEBRTC_TURN_URL_TLS") as? String
        let turnUser = Bundle.main.object(forInfoDictionaryKey: "WEBRTC_TURN_USERNAME") as? String
        let turnPass = Bundle.main.object(forInfoDictionaryKey: "WEBRTC_TURN_PASSWORD") as? String
        if let user = turnUser, let pass = turnPass, !user.isEmpty, !pass.isEmpty {
            if let url = turnURL, !url.trimmingCharacters(in: .whitespaces).isEmpty {
                servers.append(RTCIceServer(urlStrings: [url], username: user, credential: pass))
            }
            if let urlTLS = turnURLTLS, !urlTLS.trimmingCharacters(in: .whitespaces).isEmpty {
                servers.append(RTCIceServer(urlStrings: [urlTLS], username: user, credential: pass))
            }
        }
        cfg.iceServers = servers
        // 公式推奨の Unified Plan を使用
        cfg.sdpSemantics = .unifiedPlan
        // 接続性の初期レイテンシ改善に軽いプリギャザ
        cfg.iceCandidatePoolSize = 1
        // デバッグ: 使用ICEサーバ情報（URLのみ）
        let urls = servers.flatMap { $0.urlStrings }
        log("[P2P] ICE servers used: \(urls.joined(separator: ", "))", category: "P2P")
#else
        var cfg = RTCConfiguration()
        cfg.iceServers = []
#endif
        pc = f.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        log("[P2P] RTCPeerConnection created (Unified Plan)", category: "P2P")
#if canImport(WebRTC)
        // 公式推奨: Unified Plan + sendRecv の単一トランシーバを用意
        let txInit = RTCRtpTransceiverInit()
        txInit.direction = .sendRecv
        self.videoTransceiver = pc?.addTransceiver(of: .video, init: txInit)
        log("[P2P] Added video transceiver (.sendRecv)", category: "P2P")
#endif
    }

    private func startLocalCamera() {
#if targetEnvironment(simulator)
        // Simulator にはカメラデバイスが無く WebRTC が abort するためスキップ
        log("[P2P] startLocalCamera skipped on Simulator", category: "P2P")
        return
#else
        guard let pc else { return }
        let f = RTCPeerConnectionFactory()
        let source = f.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: source)
        localTrack = f.videoTrack(with: source, trackId: "local0")
        #if canImport(WebRTC)
            if let track = localTrack {
                if let tx = self.videoTransceiver {
                    tx.sender.track = track
                    log("[P2P] Local video track attached to transceiver sender", category: "P2P")
                } else {
                    _ = pc.add(track, streamIds: ["stream0"]) // フォールバック（このスコープではpcは非Optional）
                    log("[P2P] Local video track added via addTrack (fallback)", category: "P2P")
                }
            }
        #else
        let stream = f.mediaStream(withStreamId: "stream0")
        if let track = localTrack {
            stream.addVideoTrack(track)
        }
        pc.add(stream)
        log("[P2P] Local video track created and added to stream (stub)", category: "P2P")
        #endif

        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device)
                .first(where: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 640 }),
              let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate else {
            log("[P2P] No suitable camera/format/fps found", category: "P2P")
            return
        }
        capturer?.startCapture(with: device, format: format, fps: Int(fps/2))
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        log("[P2P] startCapture device=front format=\(dims.width)x\(dims.height) fps=\(Int(fps/2))", category: "P2P")
        log("[P2P] Local video capture started successfully", category: "P2P")
#endif
    }

    // MARK: - SDP Negotiation
    private func maybeExchangeSDP() {
        Task { @MainActor in
            await prepareSignalChannel(initial: true)
        }
    }

    @MainActor
    private func prepareSignalChannel(initial: Bool) async {
        guard state == .connecting else { return }
        let myID = currentMyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !myID.isEmpty else {
            log("[P2P] Mailbox prep skipped: myID unavailable", category: "P2P")
            return
        }

        let zoneReady = await CloudKitChatManager.shared.isSignalZoneReady(roomID: currentRoomID)
        if !zoneReady {
            if signalInfraRetryTask == nil {
                log("[P2P] Signal prep deferred: zone not yet available room=\(currentRoomID)", category: "P2P")
            }
            scheduleSignalInfraRetry(afterMilliseconds: initial ? 1500 : 2500)
            return
        }

        signalInfraRetryTask?.cancel()
        signalInfraRetryTask = nil

        do {
            let remoteHint = currentRemoteID.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedRemoteUserID == nil {
                if let hinted = (!remoteHint.isEmpty ? remoteHint : nil) {
                    resolvedRemoteUserID = hinted
                    log("[P2P] Using hinted remote ID: \(String(hinted.prefix(8)))", category: "P2P")
                } else if let counterpart = CloudKitChatManager.shared.primaryCounterpartUserID(roomID: currentRoomID) {
                    resolvedRemoteUserID = counterpart
                    log("[P2P] Using counterpart from CloudKit: \(String(counterpart.prefix(8)))", category: "P2P")
                } else {
                    log("[P2P] No remote ID available yet, will retry", category: "P2P")
                }
            }

            guard let remoteID = resolvedRemoteUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteID.isEmpty else {
                log("[P2P] Signal prep: remote user unresolved - scheduling retry", category: "P2P")
                // 初回は短い間隔でリトライ
                let retryDelay: UInt64 = initial ? 500 : 2000
                scheduleSignalInfraRetry(afterMilliseconds: retryDelay)
                return
            }

            if remoteID == myID {
                log("[P2P] Signal prep resolved to self — closing peer", category: "P2P")
                close()
                return
            }

            if currentRemoteID != remoteID {
                currentRemoteID = remoteID
            }
            // Perfect Negotiationのロールを決定
            isPolite = (myID > remoteID)
            
            // Offer作成者を決定（UserID比較で固定）
            isOfferCreator = shouldCreateOffer(myID: myID, remoteID: remoteID)
            
            log("[P2P] Role resolved: isPolite=\(isPolite) isOfferCreator=\(isOfferCreator) remote=\(String(remoteID.prefix(8)))", category: "P2P")
            persistRemoteParticipant(userID: remoteID)

            signalSession = try await CloudKitChatManager.shared.ensureSignalSession(roomID: currentRoomID,
                                                                                    localUserID: myID,
                                                                                    remoteUserID: remoteID)
            await markActiveAndMaybeInitialOffer()
        } catch let error as CloudKitChatManager.CloudKitChatError where error == .signalingZoneUnavailable {
            log("[P2P] Signal zone unavailable — scheduling retry room=\(currentRoomID)", category: "P2P")
            scheduleSignalInfraRetry(afterMilliseconds: 2500)
        } catch {
            log("[P2P] Failed to prepare signal session: \(error)", category: "P2P")
        }
    }

    private func scheduleSignalInfraRetry(afterMilliseconds ms: UInt64) {
        signalInfraRetryTask?.cancel()
        let delay = max(ms, 500)
        signalInfraRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard let self else { return }
            await self.prepareSignalChannel(initial: false)
        }
    }

    private func persistRemoteParticipant(userID: String) {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log("[P2P] Remote participant resolved userID=\(String(trimmed.prefix(8)))", category: "P2P")
    }

    private func freshCallEpoch() -> Int {
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        if now <= activeCallEpoch {
            activeCallEpoch += 1
            return activeCallEpoch
        }
        activeCallEpoch = now
        return activeCallEpoch
    }

    @MainActor
    private func markActiveAndMaybeInitialOffer() async {
        guard state == .connecting else { return }
        guard resolvedRemoteUserID != nil else {
            log("[P2P] Offer scheduling deferred: remote unresolved", category: "P2P")
            return
        }
        ensureOfferTask?.cancel()
        let jitterMs: UInt64 = isPolite ? UInt64.random(in: 120...300) : UInt64.random(in: 0...80)
        ensureOfferTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: jitterMs * 1_000_000)
#if canImport(WebRTC)
            guard self.state == .connecting, let pc = self.pc, pc.connectionState != .closed else { return }
            guard pc.localDescription == nil, pc.remoteDescription == nil else { return }
            guard pc.signalingState == .stable else { return }
#endif
            guard !self.isMakingOffer else { return }
            self.scheduleNegotiationDebounced()
        }
    }

    // negotiationneededをPC単位でデバウンス・直列化
    private func scheduleNegotiationDebounced() {
        self.needsNegotiation = true
        self.negotiationDebounceTask?.cancel()
        // 50–150msの短いデバウンス＋軽いジッタ
        let delayMs = UInt64.random(in: 50...150)
        self.negotiationDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard self.needsNegotiation else { return }
            self.needsNegotiation = false
            await self.createAndPublishOfferInternal()
        }
    }

#if canImport(WebRTC)
    private func createAndPublishAnswer() async {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            guard let desc = try await pc?.answer(for: constraints) else { return }
            try await pc?.setLocalDescription(desc)
            let epoch = activeCallEpoch > 0 ? activeCallEpoch : freshCallEpoch()
            await publishAnswerSDP(desc.sdp, callEpoch: epoch)
            log("[P2P] Answer published (epoch=\(epoch))", category: "P2P")
        } catch {
            log("[P2P] createAnswer/setLocalDescription error: \(error)", category: "P2P")
        }
    }
#endif

    private func publishOfferSDP(_ sdp: String, callEpoch: Int) async {
        guard !currentMyID.isEmpty, let remote = resolvedRemoteUserID else { return }
        do {
            let envelope = try await CloudKitChatManager.shared.publishOffer(roomID: currentRoomID,
                                                                             localUserID: currentMyID,
                                                                             remoteUserID: remote,
                                                                             callEpoch: callEpoch,
                                                                             sdp: sdp)
            hasPublishedOffer = true
            publishedCandidateFingerprints.removeAll()
            activeCallEpoch = max(activeCallEpoch, envelope.callEpoch)
            if var session = signalSession {
                session.activeCallEpoch = max(session.activeCallEpoch, envelope.callEpoch)
                session.updatedAt = envelope.createdAt
                signalSession = session
            }
            log("[P2P] Offer published (callEpoch=\(envelope.callEpoch))", category: "P2P")
        } catch {
            log("[P2P] Failed to publish offer: \(error)", category: "P2P")
        }
    }

    private func publishAnswerSDP(_ sdp: String, callEpoch: Int) async {
        guard !currentMyID.isEmpty, let remote = resolvedRemoteUserID else { return }
        do {
            let envelope = try await CloudKitChatManager.shared.publishAnswer(roomID: currentRoomID,
                                                                              localUserID: currentMyID,
                                                                              remoteUserID: remote,
                                                                              callEpoch: callEpoch,
                                                                              sdp: sdp)
            activeCallEpoch = max(activeCallEpoch, envelope.callEpoch)
            if var session = signalSession {
                session.activeCallEpoch = max(session.activeCallEpoch, envelope.callEpoch)
                session.updatedAt = envelope.createdAt
                signalSession = session
            }
            log("[P2P] Answer published (callEpoch=\(envelope.callEpoch))", category: "P2P")
        } catch {
            log("[P2P] Failed to publish answer: \(error)", category: "P2P")
        }
    }

    private func publishCandidateEncoded(_ encoded: String, callEpoch: Int) async {
        guard !currentMyID.isEmpty, let remote = resolvedRemoteUserID else { return }
        guard !publishedCandidateFingerprints.contains(encoded) else { return }
        publishedCandidateFingerprints.insert(encoded)
        do {
            let chunk = try await CloudKitChatManager.shared.publishIceCandidate(roomID: currentRoomID,
                                                                                 localUserID: currentMyID,
                                                                                 remoteUserID: remote,
                                                                                 callEpoch: callEpoch,
                                                                                 encodedCandidate: encoded,
                                                                                 candidateType: nil)
            activeCallEpoch = max(activeCallEpoch, chunk.callEpoch)
            log("[P2P] Published ICE chunk record=\(chunk.recordID.recordName)", level: "DEBUG", category: "P2P")
        } catch {
            log("[P2P] Failed to publish ICE candidate: \(error)", category: "P2P")
        }
    }

    // MARK: - Signal ingestion
    func applySignalRecord(_ record: CKRecord) async -> Bool {
        guard record.recordID.zoneID.zoneName == currentRoomID else { return false }
        if let envelope = CloudKitChatManager.shared.decodeSignalRecord(record) {
            return await applySignalEnvelope(envelope)
        }
        if let chunk = CloudKitChatManager.shared.decodeSignalIceRecord(record) {
            return await applySignalIceChunk(chunk)
        }
        return false
    }

    private func matchesCurrentSession(_ sessionKey: String) -> Bool {
        guard !currentRoomID.isEmpty, !currentMyID.isEmpty else { return false }
        let expected = computePairKey(roomID: currentRoomID, myID: currentMyID)
        return sessionKey == expected
    }

    private func ensureSessionForRemote(_ owner: String) {
        if resolvedRemoteUserID == nil {
            resolvedRemoteUserID = owner
            currentRemoteID = owner
            // Perfect Negotiationのロールを決定
            isPolite = (currentMyID > owner)
            
            // Offer作成者を決定（UserID比較で固定）
            isOfferCreator = shouldCreateOffer(myID: currentMyID, remoteID: owner)
            
            log("[P2P] Remote resolved via signal: isPolite=\(isPolite) isOfferCreator=\(isOfferCreator) owner=\(String(owner.prefix(8)))", category: "P2P")
        }
    }

    @MainActor
    private func applySignalEnvelope(_ envelope: CloudKitChatManager.SignalEnvelopeSnapshot) async -> Bool {
        guard !currentMyID.isEmpty else { return false }
        ensureSessionForRemote(envelope.ownerUserID)
        guard envelope.ownerUserID != currentMyID else { return false }
        guard matchesCurrentSession(envelope.sessionKey) else {
            log("[P2P] Skip envelope (session mismatch) record=\(envelope.recordID.recordName)", level: "DEBUG", category: "P2P")
            return false
        }
        let isNewEpoch = envelope.callEpoch > activeCallEpoch
        if isNewEpoch {
            hasSetRemoteDescription = false
            hasPublishedOffer = false
            pendingRemoteCandidates.removeAll()
            appliedIceRecordIDs.removeAll()
            appliedEnvelopeRecordIDs.removeAll()
            publishedCandidateFingerprints.removeAll()
            addedRemoteCandidateCount = 0
        }
        let recordKey = envelope.recordID.recordName
        guard !appliedEnvelopeRecordIDs.contains(recordKey) else { return false }
        appliedEnvelopeRecordIDs.insert(recordKey)

        activeCallEpoch = max(activeCallEpoch, envelope.callEpoch)
        var applied = false
        switch envelope.type {
        case .offer:
            if envelope.callEpoch >= lastAppliedOfferEpoch {
                lastAppliedOfferEpoch = envelope.callEpoch
                applied = await applyOfferPayload(callId: recordKey, sdp: envelope.sdp)
            }
        case .answer:
            if envelope.callEpoch >= lastAppliedAnswerEpoch {
                lastAppliedAnswerEpoch = envelope.callEpoch
                applied = await applyAnswerPayload(callId: recordKey, sdp: envelope.sdp)
            }
        }
        return applied
    }

    @MainActor
    private func applySignalIceChunk(_ chunk: CloudKitChatManager.SignalIceChunkSnapshot) async -> Bool {
        guard !currentMyID.isEmpty else { return false }
        ensureSessionForRemote(chunk.ownerUserID)
        guard chunk.ownerUserID != currentMyID else { return false }
        guard matchesCurrentSession(chunk.sessionKey) else {
            log("[P2P] Skip ICE chunk (session mismatch) record=\(chunk.recordID.recordName)", level: "DEBUG", category: "P2P")
            return false
        }
        if chunk.callEpoch < activeCallEpoch {
            log("[P2P] Skip ICE chunk (stale epoch) record=\(chunk.recordID.recordName)", level: "DEBUG", category: "P2P")
            return false
        }
        let recordKey = chunk.recordID.recordName
        guard !appliedIceRecordIDs.contains(recordKey) else { return false }
        appliedIceRecordIDs.insert(recordKey)
        activeCallEpoch = max(activeCallEpoch, chunk.callEpoch)
        if hasSetRemoteDescription {
            return await applyCandidatePayload(callId: recordKey, encodedCandidate: chunk.candidate)
        } else {
            pendingRemoteCandidates.append(chunk.candidate)
            log("[P2P] Buffered ICE chunk (pending RD) record=\(recordKey)", level: "DEBUG", category: "P2P")
            return true
        }
    }

#if canImport(WebRTC)
    // negotiationneeded時のOffer生成（Perfect Negotiation）
    private func createAndPublishOfferInternal() async {
        guard !self.isMakingOffer else { return }
        guard self.state != .idle, let pc = self.pc, pc.connectionState != .closed else { return }
#if canImport(WebRTC)
        // stableでない間はOffer生成しない（デバウンスから再試行）
        guard pc.signalingState == .stable else { return }
#endif
        // 端末全体の同時Offer生成上限（CloudKitの書込みバースト抑制）
        guard Self.globalOffersInFlight < Self.globalOfferLimit else {
            log("[P2P] Offer postponed: in-flight limit (\(Self.globalOffersInFlight)/\(Self.globalOfferLimit))", category: "P2P")
            return
        }
        Self.globalOffersInFlight += 1
        defer { Self.globalOffersInFlight = max(0, Self.globalOffersInFlight - 1) }
        self.isMakingOffer = true
        defer { self.isMakingOffer = false }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "OfferToReceiveAudio": "false",
            "OfferToReceiveVideo": "true"
        ])
        do {
            // trackを反映させてからOffer生成
            self.startLocalCameraWhenPartnerOnline()
            let desc = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(desc)
            self.ensureOfferTask?.cancel()
            let epoch = freshCallEpoch()
            await publishOfferSDP(desc.sdp, callEpoch: epoch)
            log("[P2P] Offer published (epoch=\(epoch))", category: "P2P")
        } catch {
            log("[P2P] negotiationneeded offer error: \(error)", category: "P2P")
        }
    }
#endif


#if canImport(WebRTC)
    private func applyOfferPayload(callId: String, sdp: String) async -> Bool {
        // 固定ロジック: Offer作成者でない端末のみがOfferを受信して処理
        if isOfferCreator {
            log("[P2P] ⚠️ Unexpected: Offer creator received offer. Ignoring. callId=\(callId)", category: "P2P")
            return false
        }
        
        if hasSetRemoteDescription {
            scheduleRestartAfterDelay(reason: "stale offer after RD", cooldownMs: 300)
            return true
        }
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        do {
            // Glareは発生しないはず（固定ロジックのため）
            if let peer = self.pc, peer.signalingState == .haveLocalOffer {
                log("[P2P] ⚠️ Unexpected state: haveLocalOffer when receiving offer. Restarting.", category: "P2P")
                scheduleRestartAfterDelay(reason: "unexpected glare", cooldownMs: 300)
                return false
            }
            guard let peer = self.pc else {
                log("[P2P] No peer connection when applying offer callId=\(callId)", category: "P2P")
                return false
            }
            try await peer.setRemoteDescription(desc)
            self.hasSetRemoteDescription = true
            self.ensureOfferTask?.cancel()
            log("[P2P] Remote offer set callId=\(callId) pendingICE=\(self.pendingRemoteCandidates.count)", category: "P2P")
            self.startLocalCameraWhenPartnerOnline()
            await flushPendingRemoteCandidates()
            await self.createAndPublishAnswer()
            return true
        } catch {
            log("[P2P] setRemoteDescription(offer) error callId=\(callId): \(error)", category: "P2P")
            return false
        }
    }

    private func applyAnswerPayload(callId: String, sdp: String) async -> Bool {
        // 固定ロジック: Offer作成者のみがAnswerを受信して処理
        if !isOfferCreator {
            log("[P2P] ⚠️ Unexpected: Non-offer creator received answer. Ignoring. callId=\(callId)", category: "P2P")
            return false
        }
        
        if hasSetRemoteDescription {
            scheduleRestartAfterDelay(reason: "stale answer after RD", cooldownMs: 300)
            return true
        }
        guard let peer = self.pc else { return false }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await peer.setRemoteDescription(desc)
            log("[P2P] Remote answer set callId=\(callId)", category: "P2P")
            self.hasSetRemoteDescription = true
            self.ensureOfferTask?.cancel()
            log("[P2P] RD set (answer) pendingICE=\(self.pendingRemoteCandidates.count)", category: "P2P")
            self.startLocalCameraWhenPartnerOnline()
            await flushPendingRemoteCandidates()
            return true
        } catch {
            log("[P2P] setRemoteDescription(answer) error callId=\(callId): \(error)", category: "P2P")
            return false
        }
    }

    private func applyCandidatePayload(callId: String, encodedCandidate: String) async -> Bool {
        let cand = decodeCandidate(encodedCandidate)
        do {
            if let peer = self.pc, peer.remoteDescription != nil {
                try await peer.add(cand)
                self.addedRemoteCandidateCount += 1
                if self.addedRemoteCandidateCount % 10 == 0 {
                    log("[P2P] Remote ICE candidates added total=\(self.addedRemoteCandidateCount) callId=\(callId)", level: "DEBUG", category: "P2P")
                }
            } else {
                pendingRemoteCandidates.append(encodedCandidate)
            }
            return true
        } catch {
            log("[P2P] add ICE candidate error callId=\(callId): \(error). Scheduling full reset.", category: "P2P")
            scheduleRestartAfterDelay(reason: "addIce failed", cooldownMs: 300)
            return false
        }
    }
#endif

#if canImport(WebRTC)
    private func flushPendingRemoteCandidates() async {
        guard let pc = self.pc, pc.remoteDescription != nil else { return }
        if pendingRemoteCandidates.isEmpty { return }
        for enc in pendingRemoteCandidates {
            let c = decodeCandidate(enc)
            do { try await pc.add(c) } catch {
                log("[P2P] add ICE candidate (flush) error: \(error). Scheduling full reset.", category: "P2P")
                scheduleRestartAfterDelay(reason: "flush addIce failed", cooldownMs: 300)
            }
        }
        log("[P2P] Flushed \(pendingRemoteCandidates.count) buffered ICE candidates", category: "P2P")
        pendingRemoteCandidates.removeAll()
    }
#endif

#if canImport(WebRTC)
    private func encodeCandidate(_ cand: RTCIceCandidate?) -> String {
        guard let cand else { return "" }
        let mid = cand.sdpMid ?? ""
        let idx = Int(cand.sdpMLineIndex)
        let sep = "\u{1F}"
        return [cand.sdp, mid, String(idx)].joined(separator: sep)
    }
    private func decodeCandidate(_ s: String) -> RTCIceCandidate {
        let sep = "\u{1F}"
        let parts = s.components(separatedBy: sep)
        let sdp = parts.indices.contains(0) ? parts[0] : ""
        let mid = parts.indices.contains(1) ? parts[1] : nil
        let idx = parts.indices.contains(2) ? Int32(parts[2]) ?? 0 : 0
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: idx, sdpMid: mid)
    }
#endif

    // MARK: - Record ingestion from CloudKit
    // PresenceCK 経由の起動は廃止。SignalEnvelope / SignalIceChunk の差分通知のみで駆動する。

    // MARK: - Diagnostics
    func debugDump() {
        log("[P2P] diag state=\(state) roomID=\(currentRoomID) myID=\(String(currentMyID.prefix(8))) pcExists=\(pc != nil) localTrack=\(localTrack != nil) remoteTrack=\(remoteTrack != nil)", category: "P2P")
    }
    
    /// P2Pビデオの状態を診断して詳細ログを出力
    func diagnoseVideoState() {
        log("[P2P] === VIDEO DIAGNOSTICS ===", category: "P2P")
        log("[P2P] Connection state: \(state)", category: "P2P")
        
        if let pc = pc {
            log("[P2P] PeerConnection: state=\(pc.connectionState) iceState=\(pc.iceConnectionState)", category: "P2P")
            
            #if canImport(WebRTC)
            // トランシーバーの状態
            for (index, transceiver) in pc.transceivers.enumerated() {
                let mediaType = transceiver.mediaType == .video ? "video" : "audio"
                log("[P2P] Transceiver[\(index)] type=\(mediaType) direction=\(transceiver.direction) stopped=\(transceiver.isStopped)", category: "P2P")
                
                if transceiver.mediaType == .video {
                    if let senderTrack = transceiver.sender.track as? RTCVideoTrack {
                        log("[P2P]   Sender: trackId=\(senderTrack.trackId) enabled=\(senderTrack.isEnabled)", category: "P2P")
                    } else {
                        log("[P2P]   Sender: no track", category: "P2P")
                    }
                    
                    if let receiverTrack = transceiver.receiver.track as? RTCVideoTrack {
                        log("[P2P]   Receiver: trackId=\(receiverTrack.trackId) enabled=\(receiverTrack.isEnabled)", category: "P2P")
                    } else {
                        log("[P2P]   Receiver: no track", category: "P2P")
                    }
                }
            }
            #endif
        } else {
            log("[P2P] PeerConnection: nil", category: "P2P")
        }
        
        log("[P2P] Local video track: \(localTrack != nil ? "present" : "nil")", category: "P2P")
        if let local = localTrack {
            log("[P2P]   trackId=\(local.trackId) enabled=\(local.isEnabled)", category: "P2P")
        }
        
        log("[P2P] Remote video track: \(remoteTrack != nil ? "present" : "nil")", category: "P2P")
        if let remote = remoteTrack {
            log("[P2P]   trackId=\(remote.trackId) enabled=\(remote.isEnabled)", category: "P2P")
        }
        
        // シグナリング状態の診断
        log("[P2P] Signaling diagnostics:", category: "P2P")
        log("[P2P]   - hasPublishedOffer: \(hasPublishedOffer)", category: "P2P")
        log("[P2P]   - hasSetRemoteDescription: \(hasSetRemoteDescription)", category: "P2P")
        log("[P2P]   - isOfferCreator: \(isOfferCreator)", category: "P2P")
        log("[P2P]   - isPolite: \(isPolite)", category: "P2P")
        log("[P2P]   - isMakingOffer: \(isMakingOffer)", category: "P2P")
        log("[P2P]   - needsNegotiation: \(needsNegotiation)", category: "P2P")
        log("[P2P]   - pendingRemoteCandidates: \(pendingRemoteCandidates.count)", category: "P2P")
        
        log("[P2P] Expected behavior:", category: "P2P")
        log("[P2P]   - Both local and remote tracks should be present", category: "P2P")
        log("[P2P]   - Both tracks should be enabled=true", category: "P2P")
        log("[P2P]   - Connection state should be 'connected'", category: "P2P")
        log("[P2P]   - At least one video transceiver with direction=sendRecv", category: "P2P")
        
        // UI側の状態も診断
        log("[P2P] UI State:", category: "P2P")
        log("[P2P]   - Local track: \(localTrack != nil ? "present" : "nil")", category: "P2P")
        log("[P2P]   - Remote track: \(remoteTrack != nil ? "present" : "nil")", category: "P2P")
        
        if remoteTrack != nil {
            log("[P2P] ⚠️ Remote track exists - ensure VideoCallView or P2PVideoView is properly connected", category: "P2P")
            log("[P2P] ⚠️ Check that remoteTrack is added to the renderer in your UI layer", category: "P2P")
        }
        
        log("[P2P] === END DIAGNOSTICS ===", category: "P2P")
    }
}

extension P2PController: RTCPeerConnectionDelegate {
    // MARK: - Required delegate stubs (empty implementations)
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            let callId = (!self.currentRoomID.isEmpty && !self.currentMyID.isEmpty) ? self.computePairKey(roomID: self.currentRoomID, myID: self.currentMyID) : ""
            log("[P2P] ICE connection state changed: \(newState)", category: "P2P")
            
            switch newState {
            case .connected, .completed:
                self.state = .connected
                self.connectionTimer?.invalidate()
                self.connectionTimer = nil
                self.connectionAttempts = 0
                log("[P2P] ✅ Connection established!", category: "P2P")
                // 診断情報を出力
                self.diagnoseVideoState()
                
            case .disconnected:
                // 一時切断はトラックを保持して再接続を待つ
                log("[P2P] ICE state changed: disconnected — keep tracks and wait", category: "P2P")
                if self.state != .failed { 
                    self.state = .connecting
                    self.startConnectionTimer()
                }
                
            case .failed:
                log("[P2P] ❌ ICE connection failed", category: "P2P")
                self.handleConnectionFailure()
                
            case .closed:
                log("[P2P] ICE connection closed", category: "P2P")
                self.connectionTimer?.invalidate()
                self.connectionTimer = nil
                self.localTrack = nil
                self.remoteTrack = nil
                self.state = .idle
                
            case .checking:
                if self.state != .failed { 
                    self.state = .connecting
                    if self.connectionTimer == nil {
                        self.startConnectionTimer()
                    }
                }
                
            case .new:
                if self.state != .failed { self.state = .connecting }
                
            case .count:
                break
            @unknown default:
                break
            }
            _ = callId
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in
            log("[P2P] ICE gathering state changed: \(newState)", category: "P2P")
            switch newState {
            case .new, .gathering, .complete:
                break
            @unknown default:
                log("[P2P] ICE gathering state changed: unknown state \(newState)", category: "P2P")
            }
            if newState == .complete {
                log("[P2P] ICE gathering complete", category: "P2P")
            }
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            self.remoteTrack = nil
            if self.localTrack == nil { self.state = .idle }
            log("[P2P] Remote media stream removed — hiding overlay", category: "P2P")
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: - Implemented logic we actually care about
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            Task { @MainActor in
                self.remoteTrack = track
                _ = OverlaySupport.checkAndLog()
                log("[P2P] Remote video track received (didAdd stream)", category: "P2P")
                log("[P2P] Remote track enabled=\(track.isEnabled) trackId=\(track.trackId)", category: "P2P")
                log("[P2P] Stream has \(stream.videoTracks.count) video tracks, \(stream.audioTracks.count) audio tracks", category: "P2P")
                
                if self.localTrack != nil {
                    log("[P2P] Both local and remote tracks are now available - video should be visible", category: "P2P")
                    self.state = .connected
                    // 接続後に診断を実行
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.diagnoseVideoState()
                    }
                }
            }
        } else {
            Task { @MainActor in
                log("[P2P] ⚠️ Stream received but no video tracks found", category: "P2P")
            }
        }
    }
#if canImport(WebRTC)
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
            Task { @MainActor in
                self.remoteTrack = videoTrack
                _ = OverlaySupport.checkAndLog()
                log("[P2P] Remote video track received (didAdd rtpReceiver)", category: "P2P")
                log("[P2P] Remote track enabled=\(videoTrack.isEnabled) trackId=\(videoTrack.trackId)", category: "P2P")
                log("[P2P] RTP receiver mediaType=\(rtpReceiver.track?.kind ?? "nil")", category: "P2P")
                
                if self.localTrack != nil {
                    log("[P2P] Both local and remote tracks are now available - video should be visible", category: "P2P")
                    self.state = .connected
                    
                    // 接続成功時の参加者情報を詳細にログ
                    let roomID = self.currentRoomID
                    let myID = self.currentMyID
                    let remoteID = self.currentRemoteID
                    log("🎥 [P2P] === VIDEO CONNECTION ESTABLISHED ===", category: "P2P")
                    log("🎥 [P2P] Room: \(roomID)", category: "P2P")
                    log("🎥 [P2P] My ID: \(String(myID.prefix(8)))", category: "P2P")
                    log("🎥 [P2P] Remote ID: \(String(remoteID.prefix(8)))", category: "P2P")
                    
                    // 参加者の詳細情報
                    if let context = try? ModelContainerBroker.shared.mainContext() {
                        var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
                        descriptor.fetchLimit = 1
                        if let room = (try? context.fetch(descriptor))?.first {
                            log("🎥 [P2P] Total participants: \(room.participants.count)", category: "P2P")
                            for (index, participant) in room.participants.enumerated() {
                                let role = participant.role == .owner ? "owner" : "participant"
                                let isMe = participant.userID == myID
                                log("🎥 [P2P] Participant[\(index)]: \(participant.displayName ?? "NoName") (ID: \(String(participant.userID.prefix(8)))) - role:\(role) isMe:\(isMe)", category: "P2P")
                            }
                        }
                    }
                    log("🎥 [P2P] === END CONNECTION INFO ===", category: "P2P")
                    
                    // 接続後に診断を実行
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.diagnoseVideoState()
                    }
                }
                
                // トランシーバーの状態も確認
                if let transceiver = peerConnection.transceivers.first(where: { $0.receiver == rtpReceiver }) {
                    log("[P2P] Transceiver direction=\(transceiver.direction) stopped=\(transceiver.isStopped)", category: "P2P")
                }
            }
        } else {
            Task { @MainActor in
                log("[P2P] ⚠️ RTP receiver added but not a video track: \(rtpReceiver.track?.kind ?? "nil")", category: "P2P")
            }
        }
    }
#endif
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        Task { @MainActor in
            log("[P2P] RTCPeerConnection state changed: \(state)", category: "P2P")
            if state == .connected {
#if canImport(WebRTC)
                let dir = self.videoTransceiver?.direction
                let dirStr: String
                switch dir {
                case .some(.sendRecv): dirStr = "sendRecv"
                case .some(.sendOnly): dirStr = "sendOnly"
                case .some(.recvOnly): dirStr = "recvOnly"
                case .some(.inactive): dirStr = "inactive"
                case .some(.stopped): dirStr = "stopped"
                case .none: dirStr = "nil"
                @unknown default: dirStr = "unknown"
                }
                
                // より詳細な状態ログ
                log("[P2P] === VIDEO STATE SUMMARY ===", category: "P2P")
                log("[P2P] Local track: \(self.localTrack != nil ? "present" : "nil") enabled=\(self.localTrack?.isEnabled ?? false)", category: "P2P")
                log("[P2P] Remote track: \(self.remoteTrack != nil ? "present" : "nil") enabled=\(self.remoteTrack?.isEnabled ?? false)", category: "P2P")
                log("[P2P] Transceiver direction=\(dirStr) stopped=\(self.videoTransceiver?.isStopped ?? true)", category: "P2P")
                
                // 接続統計を取得（非同期）
                peerConnection.statistics { stats in
                    Task { @MainActor in
                        var hasInboundVideo = false
                        var hasOutboundVideo = false
                        for (_, report) in stats.statistics {
                            if report.type == "inbound-rtp" && report.values["mediaType"] as? String == "video" {
                                hasInboundVideo = true
                                if let bytesReceived = report.values["bytesReceived"] as? Int {
                                    log("[P2P] Inbound video: \(bytesReceived) bytes received", category: "P2P")
                                }
                            }
                            if report.type == "outbound-rtp" && report.values["mediaType"] as? String == "video" {
                                hasOutboundVideo = true
                                if let bytesSent = report.values["bytesSent"] as? Int {
                                    log("[P2P] Outbound video: \(bytesSent) bytes sent", category: "P2P")
                                }
                            }
                        }
                        log("[P2P] Video streams: inbound=\(hasInboundVideo) outbound=\(hasOutboundVideo)", category: "P2P")
                        log("[P2P] === END VIDEO STATE ===", category: "P2P")
                        
                        // ビデオが流れていない場合の診断
                        if !hasInboundVideo || !hasOutboundVideo {
                            log("[P2P] ⚠️ VIDEO ISSUE DETECTED: No video data flowing", category: "P2P")
                            self.diagnoseVideoState()
                        }
                    }
                }
#else
                let dirStr = "n/a"
#endif
                let hasLocal = (self.localTrack != nil)
                let hasRemote = (self.remoteTrack != nil)
                log("[P2P] connected: localTrack=\(hasLocal) remoteTrack=\(hasRemote) transceiver=\(dirStr)", category: "P2P")
                // remoteTrackが遅延/未到達の場合の最小リカバリ（体感ギャップ解消）
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                    if self.state == .connected && self.remoteTrack == nil {
                        log("[P2P] connected but remoteTrack==nil. Triggering renegotiation (impolite only)", category: "P2P")
#if canImport(WebRTC)
                        if !self.isPolite {
                            await self.createAndPublishOfferInternal()
                        }
#endif
                    }
                }
            }
            let callId = (!self.currentRoomID.isEmpty && !self.currentMyID.isEmpty) ? self.computePairKey(roomID: self.currentRoomID, myID: self.currentMyID) : ""

            switch state {
            case .connected:
                self.state = .connected
            case .failed:
                self.state = .failed
                self.localTrack = nil
                self.remoteTrack = nil
                // 共通の完全リセットロジックで健全化（0.8sクールダウン）
                scheduleRestartAfterDelay(reason: "peerConnection state failed", cooldownMs: 800)
            case .disconnected:
                // 一時切断は維持（UIが消えるのを防止）
                if self.state != .failed { self.state = .connecting }
            case .closed:
                self.state = .idle
                self.localTrack = nil
                self.remoteTrack = nil
            case .new, .connecting:
                if self.state != .failed { self.state = .connecting }
            @unknown default:
                break
            }
            if state == .connected, !self.publishedCandidateTypeCounts.isEmpty {
                let summary = self.publishedCandidateTypeCounts.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                log("[P2P] connected with ICE summary {\(summary)}", category: "P2P")
            }
            _ = callId
        }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            // クローズや未接続状態ではPublishしない（クラッシュ/重複抑止）
            guard self.state != .idle, let pc = self.pc, pc.connectionState != .closed else { return }
            let encoded = self.encodeCandidate(candidate)
            let epoch = self.activeCallEpoch > 0 ? self.activeCallEpoch : self.freshCallEpoch()
            await self.publishCandidateEncoded(encoded, callEpoch: epoch)
            self.publishedCandidateCount += 1
            // SDPから候補タイプを抽出して集計（typ host/srflx/relay）
            let parts = candidate.sdp.components(separatedBy: " ")
            if let idx = parts.firstIndex(of: "typ"), parts.count > idx + 1 {
                let typ = parts[idx + 1]
                self.publishedCandidateTypeCounts[typ, default: 0] += 1
            }
            // ログ冗長性を抑制：10件ごとに集約ログ
            if self.publishedCandidateCount % 10 == 0 {
                let summary = self.publishedCandidateTypeCounts.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                log("[P2P] ICE candidates published total=\(self.publishedCandidateCount) {\(summary)}", level: "DEBUG", category: "P2P")
            }
        }
    }

    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            log("[P2P] peerConnectionShouldNegotiate fired (isPolite=\(self.isPolite) isOfferCreator=\(self.isOfferCreator))", category: "P2P")
#if canImport(WebRTC)
            // 固定ロジック: Offer作成者のみがOfferを作成
            if self.isOfferCreator {
                self.scheduleNegotiationDebounced()
            } else {
                log("[P2P] Skip negotiation - not the offer creator", category: "P2P")
            }
#endif
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

// 共通の完全リセットロジック（検討過程メモ）
// - sdpRevisionや複雑な分岐で“古い/順序違い”を捨てるのではなく、
//   異常/衝突/適用失敗など“健全性が疑わしい状態”は小さなクールダウン後に完全リセットして再交渉に戻す。
// - 理由: ロジックの簡素化・可観測性の向上（ログの一貫性）、CloudKitの最終的整合性に対して頑強。
private extension P2PController {
    func scheduleRestartAfterDelay(reason: String, cooldownMs: Int) {
        let room = self.currentRoomID
        let me = self.currentMyID
        log("[P2P] Scheduling full reset due to: \(reason)", category: "P2P")
        Task { @MainActor in
            // 遅延後に“まだ同じroomに居る”ことを確認してからリセットを実行
            let ns = UInt64(max(0, cooldownMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard room == self.currentRoomID else {
                log("[P2P] Skip reset: room switched (scheduled=\(room) current=\(self.currentRoomID))", category: "P2P")
                return
            }
            _ = self.computePairKey(roomID: room, myID: me)
            self.close()
            if !room.isEmpty, !me.isEmpty {
                let remote = self.currentRemoteID.isEmpty ? nil : self.currentRemoteID
                self.startIfNeeded(roomID: room, myID: me, remoteID: remote)
            }
        }
    }
}

// Placeholder bridge used by the overlay to trigger SwiftUI transitions.
// FloatingVideoOverlayBridge は不要（システムPiP不採用）
