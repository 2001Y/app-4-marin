import Foundation
import CloudKit
import CoreMedia
#if canImport(WebRTC)
import WebRTC
#endif
import Combine
import SwiftUI
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
    private var signalDB: CKDatabase?
    private var signalZoneID: CKRecordZone.ID?
    private var hasPublishedOffer: Bool = false
    private var hasSetRemoteDescription: Bool = false
    private var isOwnerRole: Bool = false
    // Perfect Negotiation用の簡易状態
    private var isPolite: Bool = false
    private var isMakingOffer: Bool = false
    // --- PN設計の検討と決定（コメント） ---
    // - 以前は「impoliteのみOffer作成」だったが、polite側でローカル変更が起こると交渉が進まない欠点があった。
    // - o3の推奨に基づき、どちら側でもOffer作成可とし、衝突はisPoliteで解決（polite: rollback受け入れ、impolite: 無視）。
    // - 嵐（storm）回避のため、PC単位で交渉をデバウンス・直列化し、端末全体の同時Offer生成数にも上限を設ける。
    private var needsNegotiation: Bool = false
    private var negotiationDebounceTask: Task<Void, Never>?
    private var ensureOfferTask: Task<Void, Never>?
    private static var globalOffersInFlight: Int = 0
    private static let globalOfferLimit: Int = 2
    private var processedCandidates: Set<String> = []
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
    private struct SignalBatch {
        var offer: String?
        var answer: String?
        var candidates: [String] = []
        var retryAttempt: Int = 0

        var isEmpty: Bool {
            return offer == nil && answer == nil && candidates.isEmpty
        }

        mutating func clearAfterFlush() {
            offer = nil
            answer = nil
            candidates.removeAll()
        }
    }

    private func resetSignalState(resetRoomContext: Bool) {
        negotiationDebounceTask?.cancel(); negotiationDebounceTask = nil
        ensureOfferTask?.cancel(); ensureOfferTask = nil
        needsNegotiation = false
        hasPublishedOffer = false
        hasSetRemoteDescription = false
        isOwnerRole = false
        isMakingOffer = false
        processedCandidates.removeAll()
        pendingRemoteCandidates.removeAll()
        publishedCandidateCount = 0
        addedRemoteCandidateCount = 0
        publishedCandidateTypeCounts.removeAll()
        signalDB = nil
        signalZoneID = nil
#if canImport(WebRTC)
        videoTransceiver = nil
#endif
        for task in signalFlushTasks.values { task.cancel() }
        signalFlushTasks.removeAll()
        signalBatches.removeAll()
        signalRecordCache.removeAll()
        if resetRoomContext {
            currentRoomID = ""
            currentMyID = ""
            currentRemoteID = ""
        }
        log("[P2P] Signal state cleared (resetRoomContext=\(resetRoomContext))", category: "P2P")
    }
    private var signalBatches: [String: SignalBatch] = [:]
    private var signalFlushTasks: [String: Task<Void, Never>] = [:]
    private var signalRecordCache: [String: CKRecord] = [:]
    private let signalFlushInterval: TimeInterval = 1.0
    private let signalBaseRetry: TimeInterval = 0.5
    private let signalMaxRetry: TimeInterval = 8.0
    private func logSignalMetrics(prefix: String, callId: String) {
        let buffered = signalBatches[callId]?.candidates.count ?? 0
        let hasBatchOffer = signalBatches[callId]?.offer != nil
        let hasBatchAnswer = signalBatches[callId]?.answer != nil
        let flushScheduled = signalFlushTasks[callId] != nil
        log("[P2P][diag] \(prefix) callId=\(callId) state=\(state) pendingRemote=\(pendingRemoteCandidates.count) bufferedICE=\(buffered) hasOffer=\(hasPublishedOffer) hasRD=\(hasSetRemoteDescription) flushScheduled=\(flushScheduled) batchOffer=\(hasBatchOffer) batchAnswer=\(hasBatchAnswer)", category: "P2P")
    }
    // 1on1限定の安定キー（同一ルーム内の2者で一致するキー）
    private func computePairKey(roomID: String, myID: String) -> String {
        // 2者間の衝突回避のため、参加者2名のユーザーIDを決定的順序で含める
        // 例: pair:<roomID>:<idLow>-<idHigh>
        let a = myID
        let b = currentRemoteID
        let (lo, hi) = (a <= b) ? (a, b) : (b, a)
        return "pair:\(roomID):\(lo)-\(hi)"
    }
    
    // 現在のチャットルーム情報
    var currentRoomID: String = ""
    private var currentMyID: String = ""
    private var currentRemoteID: String = ""

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

    // MARK: - Lifecycle

    func startIfNeeded(roomID: String, myID: String, remoteID: String) {
        if state != .idle {
            if currentRoomID != roomID {
                log("[P2P] Switching room: closing previous peer (from=\(currentRoomID) to=\(roomID))", category: "P2P")
                close()
            } else {
                let idsReady = (!currentMyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && (!currentRemoteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                log("[P2P] Skip start: state=\(state) sameRoom=true idsReady=\(idsReady) room=\(roomID)", category: "P2P")
                return
            }
        }

        currentRoomID = roomID
        currentMyID = myID
        currentRemoteID = remoteID

        if !currentMyID.isEmpty && !currentRemoteID.isEmpty {
            self.isPolite = (currentMyID > currentRemoteID)
            log("[P2P] PerfectNegotiation role: isPolite=\(self.isPolite)", category: "P2P")
        } else {
            self.isPolite = false
        }
        log("[P2P] startIfNeeded roomID=\(roomID) myID=\(String(myID.prefix(8))) remoteID=\(String(remoteID.prefix(8))) state=\(state)", category: "P2P")
#if canImport(WebRTC)
        log("[P2P] WebRTC framework present", category: "P2P")
#else
        log("[P2P] WebRTC framework NOT present; using stubs", category: "P2P")
#endif

        state = .connecting
        publishedCandidateCount = 0
        addedRemoteCandidateCount = 0
        publishedCandidateTypeCounts.removeAll()
        if let p = path {
            let ifType: String = p.usesInterfaceType(.wifi) ? "wifi" : (p.usesInterfaceType(.cellular) ? "cellular" : (p.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"))
            log("[P2P] Network path type=\(ifType) constrained=\(p.isConstrained)", category: "P2P")
        }

        setupPeer()
        log("[P2P] init flags: hasPublishedOffer=\(hasPublishedOffer) hasSetRD=\(hasSetRemoteDescription) processedCandidates=\(processedCandidates.count) pendingCandidates=\(pendingRemoteCandidates.count)", category: "P2P")

        resetSignalState(resetRoomContext: false)
        maybeExchangeSDP()
    }
    
    // 相手がオンラインになった時に呼び出す
    func startLocalCameraWhenPartnerOnline() {
        guard state == .connecting && localTrack == nil else { return }
        startLocalCamera()
    }

    func close() {
        if state == .idle && currentRoomID.isEmpty && signalFlushTasks.isEmpty {
            return
        }
        log("[P2P] close() called. Resetting peer + tracks", category: "P2P")

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
#endif
    }

    // MARK: - SDP Negotiation
    private func maybeExchangeSDP() {
        Task { @MainActor in
            await setupSignalChannelAndNegotiate()
        }
    }

    private func setupSignalChannelAndNegotiate() async {
        do {
            if CloudKitChatManager.shared.currentUserID == nil {
                let pcExists = (self.pc != nil)
                log("[P2P] Skip negotiate: currentUserID not ready (room=\(currentRoomID) state=\(state) pcExists=\(pcExists))", category: "P2P")
                return
            }
            // クローズ済み/未接続なら交渉をスキップ
            guard self.state == .connecting, let pc = self.pc, pc.connectionState != .closed else {
                log("[P2P] Skip negotiate: state=\(self.state) pcExists=\(self.pc != nil)", category: "P2P")
                return
            }
            // myID 未確定で開始した場合の後追い補正
            if self.currentMyID.isEmpty, let uid = CloudKitChatManager.shared.currentUserID {
                self.currentMyID = uid
            }
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveSignalingDatabase(for: currentRoomID)
            self.signalDB = db
            self.signalZoneID = zoneID
            log("[P2P] Signal channel ready (scope=\(db.databaseScope.rawValue) zone=\(zoneID.zoneName))", category: "P2P")

            let pendingCallIds = signalBatches.filter { !$0.value.isEmpty }.map { $0.key }
            if !pendingCallIds.isEmpty {
                let joined = pendingCallIds.joined(separator: ",")
                log("[P2P] Signal channel ready with pending batches callIds=[\(joined)] total=\(pendingCallIds.count)", category: "P2P")
                pendingCallIds.forEach { logSignalMetrics(prefix: "flush.pending", callId: $0) }
                drainPendingSignalBatches(reason: "channel-ready")
            }

            // 参考: 既存ロール（オーナー/参加者）判定は保持するが、初期OfferはPNに委譲（どちら側でも可）。
            let isOwner = await CloudKitChatManager.shared.isOwnerOfRoom(currentRoomID)
            self.isOwnerRole = (isOwner == true)
            log("[P2P] Role resolved: isOwner=\(self.isOwnerRole)", category: "P2P")
            // 初期Offer方針: negotiationneededにより発火。万一の取りこぼし対策としてensure-offerを一回だけ仕込む。
            await markActiveAndMaybeInitialOffer()
        // 差分駆動に移行（Push+delta fetchで駆動）
        } catch {
            log("[P2P] Failed to prepare signal channel: \(error)", category: "P2P")
        }
    }

    /// オーナーが不在でも初期Offerが存在しない場合は、決定的なタイブレークで参加者側がOfferを作成
    private func attemptOfferAsNeededFallback() async {
        guard let db = signalDB, let zoneID = signalZoneID else { return }
#if canImport(WebRTC)
        // 既存の未消費Offerがあるか確認（重複生成を避けるための軽いチェック）
        let callKey = computePairKey(roomID: currentRoomID, myID: currentMyID)
        let pred = NSPredicate(format: "type == %@ AND consumed == %@ AND callId == %@", "offer", NSNumber(value: false), callKey)
        let q = CKQuery(recordType: CKSchema.SharedType.rtcSignal, predicate: pred)
        do {
            let (results, _) = try await db.records(matching: q, inZoneWith: zoneID)
            let hasOutstandingOffer = !results.isEmpty
            if hasOutstandingOffer {
                log("[P2P] Detected existing outstanding offer in zone. Waiting (PN flow)", category: "P2P")
                return
            }
        } catch {
            log("[P2P] Offer existence check failed: \(error) zoneOwner=\(zoneID.ownerName) zoneName=\(zoneID.zoneName)", category: "P2P")
        }
        log("[P2P] Initial offer not present. Relying on PN + ensure-offer (one-shot)", category: "P2P")
#endif
    }

    /// 現状の初期交渉は Perfect Negotiation の `negotiationneeded` に委譲する。
    /// 明示的な初期Offer生成は行わず、ゾーンに未消費Offerが存在する場合は待機するだけに留める。
    @MainActor
    private func markActiveAndMaybeInitialOffer() async {
        // まずは既存の未消費Offerが無いかだけ軽く確認
        await attemptOfferAsNeededFallback()
        // ensure-offerは両側で許可（o3推奨）。ただしimpoliteは短め、politeは長めのジッタで衝突緩和。
        self.ensureOfferTask?.cancel()
        let jitterMs: UInt64 = self.isPolite ? UInt64.random(in: 120...300) : UInt64.random(in: 0...80)
        self.ensureOfferTask = Task { @MainActor in
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

    // 差分駆動（Push）への完全移行によりポーリングは廃止

    /// 差分取得で受け取ったRTCSignalを適用（成功時のみ true）
    func onSignalDelta(roomID: String, record: CKRecord) async -> Bool {
        guard roomID == currentRoomID else { return false }
        return await applySignalRecord(record)
    }

    private func applySignalRecord(_ rec: CKRecord) async -> Bool {
        guard rec.recordType == CKSchema.SharedType.rtcSignal else { return false }
        guard let typ = rec[CKSchema.FieldKey.signalType] as? String else { return false }
        switch typ {
        case "offer":
            return await applyOfferRecord(rec)
        case "answer":
            return await applyAnswerRecord(rec)
        case "ice":
            return await applyCandidatesRecord(rec)
        default:
            return false
        }
    }

    @MainActor
    private func publishOfferIfNeeded() async {
        guard !hasPublishedOffer else { return }
#if canImport(WebRTC)
        // クローズ済みなら生成しない
        guard self.state == .connecting, let pc = self.pc, pc.connectionState != .closed else {
            log("[P2P] Skip offer: pc is closed or state not connecting", category: "P2P")
            return
        }
        // 先にローカル映像をトランシーバへ割り当てて、Offerにmsid等を含める
        startLocalCameraWhenPartnerOnline()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "OfferToReceiveAudio": "false",
            "OfferToReceiveVideo": "true"
        ])
        do {
            let desc = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(desc)
            self.bufferSignal(.offer(desc.sdp))
            self.hasPublishedOffer = true
            log("[P2P] Offer published (pairKey=\(computePairKey(roomID: currentRoomID, myID: currentMyID)))", category: "P2P")
        } catch {
            log("[P2P] createOffer/setLocalDescription error: \(error)", category: "P2P")
        }
#endif
    }

#if canImport(WebRTC)
    private func createAndPublishAnswer() async {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            guard let desc = try await pc?.answer(for: constraints) else { return }
            try await pc?.setLocalDescription(desc)
            self.bufferSignal(.answer(desc.sdp))
            log("[P2P] Answer published (pairKey=\(computePairKey(roomID: currentRoomID, myID: currentMyID)))", category: "P2P")
        } catch {
            log("[P2P] createAnswer/setLocalDescription error: \(error)", category: "P2P")
        }
    }
#endif

    private enum OutgoingSignal {
        case offer(String)
        case answer(String)
        case candidate(String)
    }

    private struct SignalEnvelope: Codable {
        var offers: [String] = []
        var answers: [String] = []
        var candidates: [String] = []
        var updatedAt: Date = Date()
    }

    private func bufferSignal(_ signal: OutgoingSignal) {
        let callId = computePairKey(roomID: currentRoomID, myID: currentMyID)
        var batch = signalBatches[callId] ?? SignalBatch()
        let delay: TimeInterval
        let reason: String

        switch signal {
        case .offer(let sdp):
            batch.offer = sdp
            delay = 0
            reason = "buffer-offer"
        case .answer(let sdp):
            batch.answer = sdp
            delay = 0
            reason = "buffer-answer"
        case .candidate(let payload):
            batch.candidates.append(payload)
            delay = signalFlushInterval
            reason = "buffer-ice"
        }

        batch.retryAttempt = 0
        signalBatches[callId] = batch
        scheduleSignalFlush(for: callId, after: delay, reason: reason)
        logSignalMetrics(prefix: "buffer.signal", callId: callId)
    }

    private func scheduleSignalFlush(for callId: String, after delay: TimeInterval, reason: String? = nil) {
        signalFlushTasks[callId]?.cancel()
        if state == .idle {
            log("[P2P] Skip signal flush scheduling: state=idle callId=\(callId)", category: "P2P")
            signalFlushTasks.removeValue(forKey: callId)
            signalBatches.removeValue(forKey: callId)
            return
        }

        let reasonLabel = reason ?? "unspecified"
        signalFlushTasks[callId] = Task { @MainActor [weak self] in
            if delay > 0 {
                let ns = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
            await self?.flushSignalBatch(for: callId)
        }
        if let batch = signalBatches[callId] {
            let delayMs = Int((delay * 1_000).rounded())
            let offer = batch.offer != nil
            let answer = batch.answer != nil
            let iceCount = batch.candidates.count
            log("[P2P] Schedule signal flush (reason=\(reasonLabel)) callId=\(callId) delayMs=\(delayMs) pendingOffer=\(offer) pendingAnswer=\(answer) pendingICE=\(iceCount)", category: "P2P")
            logSignalMetrics(prefix: "flush.scheduled", callId: callId)
        } else {
            let delayMs = Int((delay * 1_000).rounded())
            log("[P2P] Schedule signal flush (reason=\(reasonLabel)) callId=\(callId) delayMs=\(delayMs) batch=missing", category: "P2P")
        }
    }

    @MainActor
    private func drainPendingSignalBatches(reason: String) {
        let pending = signalBatches.filter { !$0.value.isEmpty }
        guard !pending.isEmpty else { return }
        for (callId, batch) in pending {
            log("[P2P] Force flush pending batch (reason=\(reason)) callId=\(callId) pendingOffer=\(batch.offer != nil) pendingAnswer=\(batch.answer != nil) pendingICE=\(batch.candidates.count)", category: "P2P")
            scheduleSignalFlush(for: callId, after: 0, reason: "drain-\(reason)")
        }
    }

    @MainActor
    private func flushSignalBatch(for callId: String) async {
        guard var batch = signalBatches[callId], !batch.isEmpty else { return }
        guard let db = signalDB, let zoneID = signalZoneID else {
            let reasons = [signalDB == nil ? "db=nil" : nil,
                           signalZoneID == nil ? "zone=nil" : nil]
                .compactMap { $0 }
                .joined(separator: ",")
            log("[P2P] Skip flush: signal channel not ready (callId=\(callId) reasons=\(reasons.isEmpty ? "unknown" : reasons) pendingOffer=\(batch.offer != nil) pendingAnswer=\(batch.answer != nil) pendingICE=\(batch.candidates.count))", category: "P2P")
            logSignalMetrics(prefix: "flush.wait", callId: callId)
            let retryDelay = max(signalFlushInterval, 0.3)
            scheduleSignalFlush(for: callId, after: retryDelay, reason: "channel-not-ready")
            return
        }

        logSignalMetrics(prefix: "flush.start", callId: callId)

        signalFlushTasks[callId]?.cancel()
        signalFlushTasks[callId] = nil

        let recordID = CKRecord.ID(recordName: "RTC_\(callId)", zoneID: zoneID)
        var record: CKRecord
        var envelope: SignalEnvelope

        if let cached = signalRecordCache[callId] {
            record = cached
            envelope = decodeEnvelope(from: cached)
            if (cached[CKSchema.FieldKey.consumed] as? Bool) == true {
                envelope = SignalEnvelope()
            }
        } else if let existing = try? await db.record(for: recordID) {
            record = existing
            envelope = decodeEnvelope(from: existing)
            if (existing[CKSchema.FieldKey.consumed] as? Bool) == true {
                envelope = SignalEnvelope()
            }
        } else {
            record = CKRecord(recordType: CKSchema.SharedType.rtcSignal, recordID: recordID)
            envelope = SignalEnvelope()
            record[CKSchema.FieldKey.signalType] = "bundle" as CKRecordValue
            record[CKSchema.FieldKey.callId] = callId as CKRecordValue
            record[CKSchema.FieldKey.ttlSeconds] = 600 as CKRecordValue
            record[CKSchema.FieldKey.consumed] = false as CKRecordValue
            let meRef = CKRecord.Reference(recordID: CKSchema.roomMemberRecordID(userId: currentMyID, zoneID: zoneID), action: .none)
            let toRef = CKRecord.Reference(recordID: CKSchema.roomMemberRecordID(userId: currentRemoteID, zoneID: zoneID), action: .none)
            record[CKSchema.FieldKey.fromMemberRef] = meRef
            record[CKSchema.FieldKey.toMemberRef] = toRef
        }

        if let offer = batch.offer {
            if !envelope.offers.contains(offer) { envelope.offers.append(offer) }
        }
        if let answer = batch.answer {
            if !envelope.answers.contains(answer) { envelope.answers.append(answer) }
        }
        if !batch.candidates.isEmpty {
            let unique = batch.candidates.filter { !envelope.candidates.contains($0) }
            envelope.candidates.append(contentsOf: unique)
        }
        envelope.updatedAt = Date()

        if let payload = encodeEnvelope(envelope) {
            record[CKSchema.FieldKey.signalPayload] = payload as CKRecordValue
            record[CKSchema.FieldKey.payload] = payload as CKRecordValue
        }
        record[CKSchema.FieldKey.signalType] = "bundle" as CKRecordValue
        record[CKSchema.FieldKey.updatedAt] = envelope.updatedAt as CKRecordValue
        record[CKSchema.FieldKey.ttlSeconds] = 600 as CKRecordValue
        record[CKSchema.FieldKey.consumed] = false as CKRecordValue

        let offerCount = envelope.offers.count
        let answerCount = envelope.answers.count
        let iceCount = envelope.candidates.count
        let scopeLabel: String
        switch db.databaseScope {
        case .private: scopeLabel = "private"
        case .shared: scopeLabel = "shared"
        case .public: scopeLabel = "public"
        @unknown default: scopeLabel = "unknown"
        }
        log("[P2P] Signal envelope prepared callId=\(callId) scope=\(scopeLabel) zone=\(zoneID.zoneName) offers=\(offerCount) answers=\(answerCount) ice=\(iceCount)", category: "P2P")

        do {
            try await saveSignalRecord(record, database: db, callId: callId)
            batch.clearAfterFlush()
            batch.retryAttempt = 0
            if batch.isEmpty {
                signalBatches.removeValue(forKey: callId)
            } else {
                signalBatches[callId] = batch
            }
            logSignalMetrics(prefix: "flush.success", callId: callId)
            log("[P2P] Signal envelope saved callId=\(callId) record=\(recordID.recordName) scope=\(scopeLabel) offers=\(offerCount) answers=\(answerCount) ice=\(iceCount)", category: "P2P")
            await CloudKitChatManager.shared.cleanupExpiredSignals(roomID: currentRoomID)
        } catch let ckError as CKError {
            handleSignalSaveError(callId: callId, batch: batch, error: ckError)
        } catch {
            log("[P2P] Signal flush failed (callId=\(callId)): \(error)", category: "P2P")
            handleSignalSaveRetry(callId: callId, batch: batch, retryAfter: nil)
        }
    }

    private func saveSignalRecord(_ record: CKRecord, database: CKDatabase, callId: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.isAtomic = false

            op.modifyRecordsResultBlock = { [weak self] result in
                switch result {
                case .success:
                    Task { @MainActor in
                        self?.signalRecordCache[callId] = record
                    }
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(op)
        }
    }

    private func handleSignalSaveError(callId: String, batch: SignalBatch, error: CKError) {
        if error.code == .zoneNotFound {
            log("[P2P] Signal zone missing callId=\(callId). Closing peer.", category: "P2P")
            self.signalDB = nil
            self.signalZoneID = nil
            close()
            return
        }
        let retryAfter = error.userInfo[CKErrorRetryAfterKey] as? Double
        log("[P2P] Signal save throttled (callId=\(callId)): code=\(error.code.rawValue) retryAfter=\(retryAfter ?? 0)", category: "P2P")
        handleSignalSaveRetry(callId: callId, batch: batch, retryAfter: retryAfter)
    }

    private func handleSignalSaveRetry(callId: String, batch: SignalBatch, retryAfter: Double?) {
        var updated = batch
        updated.retryAttempt += 1
        signalBatches[callId] = updated
        let exponential = min(signalMaxRetry, pow(2.0, Double(updated.retryAttempt - 1)) * signalBaseRetry)
        let wait = max(retryAfter ?? 0, exponential)
        state = .failed
        let waitMs = Int((wait * 1_000).rounded())
        let retryReason = retryAfter != nil ? "ck-retry-after" : "exponential"
        log("[P2P] Signal flush retry scheduled callId=\(callId) attempt=\(updated.retryAttempt) waitMs=\(waitMs) reason=\(retryReason)", category: "P2P")
        scheduleSignalFlush(for: callId, after: wait, reason: "retry-\(retryReason)")
        logSignalMetrics(prefix: "flush.retry", callId: callId)
    }

    private func encodeEnvelope(_ envelope: SignalEnvelope) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeEnvelope(from record: CKRecord) -> SignalEnvelope {
        guard let payload = record[CKSchema.FieldKey.signalPayload] as? String,
              let data = payload.data(using: .utf8) else {
            return SignalEnvelope()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SignalEnvelope.self, from: data)) ?? SignalEnvelope()
    }


    // MARK: - Fixed-ID records application
    func applyOfferRecord(_ rec: CKRecord) async -> Bool {
#if canImport(WebRTC)
        guard let callId = rec[CKSchema.FieldKey.callId] as? String,
              let sdp = rec[CKSchema.FieldKey.payload] as? String else { return false }
        return await applyOfferPayload(callId: callId, sdp: sdp)
#else
        return false
#endif
    }

    func applyAnswerRecord(_ rec: CKRecord) async -> Bool {
#if canImport(WebRTC)
        guard let callId = rec[CKSchema.FieldKey.callId] as? String,
              let sdp = rec[CKSchema.FieldKey.payload] as? String else { return false }
        return await applyAnswerPayload(callId: callId, sdp: sdp)
#else
        return false
#endif
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
            // 初回ensure-offerフォールバックは以後不要
            self.ensureOfferTask?.cancel()
            self.bufferSignal(.offer(desc.sdp))
            log("[P2P] Offer published (PN debounced) pairKey=\(computePairKey(roomID: currentRoomID, myID: currentMyID))", category: "P2P")
        } catch {
            log("[P2P] negotiationneeded offer error: \(error)", category: "P2P")
        }
    }
#endif


    func applyCandidatesRecord(_ rec: CKRecord) async -> Bool {
#if canImport(WebRTC)
        guard let callId = rec[CKSchema.FieldKey.callId] as? String,
              let payload = rec[CKSchema.FieldKey.payload] as? String else { return false }
        return await applyCandidatePayload(callId: callId, encodedCandidate: payload)
#else
        return false
#endif
    }

    func applySignalBundle(_ rec: CKRecord) async -> Bool {
#if canImport(WebRTC)
        guard let callId = rec[CKSchema.FieldKey.callId] as? String else { return false }
        let envelope = decodeEnvelope(from: rec)
        var applied = false
        for offer in envelope.offers {
            if await applyOfferPayload(callId: callId, sdp: offer) { applied = true }
        }
        for answer in envelope.answers {
            if await applyAnswerPayload(callId: callId, sdp: answer) { applied = true }
        }
        for candidate in envelope.candidates {
            if await applyCandidatePayload(callId: callId, encodedCandidate: candidate) { applied = true }
        }
        return applied
#else
        return false
#endif
    }

#if canImport(WebRTC)
    private func applyOfferPayload(callId: String, sdp: String) async -> Bool {
        if hasSetRemoteDescription {
            scheduleRestartAfterDelay(reason: "stale offer after RD", cooldownMs: 300)
            return true
        }
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        do {
            if let peer = self.pc, peer.signalingState == .haveLocalOffer {
                if !self.isPolite {
                    log("[P2P] Glare detected (impolite). Ignoring remote offer callId=\(callId)", category: "P2P")
                    return false
                } else {
                    scheduleRestartAfterDelay(reason: "glare (polite)", cooldownMs: 300)
                    return false
                }
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
        if processedCandidates.contains(encodedCandidate) {
            log("[P2P] Duplicate ICE candidate ignored callId=\(callId)", level: "DEBUG", category: "P2P")
            return true
        }
        processedCandidates.insert(encodedCandidate)
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
                logSignalMetrics(prefix: "buffer", callId: callId)
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
    // PresenceCK 経由の起動は廃止。RTCSignalは MessageSyncPipeline から onSignalDelta で適用。

    // MARK: - Diagnostics
    func debugDump() {
        log("[P2P] diag state=\(state) roomID=\(currentRoomID) myID=\(String(currentMyID.prefix(8))) pcExists=\(pc != nil) localTrack=\(localTrack != nil) remoteTrack=\(remoteTrack != nil)", category: "P2P")
    }
}

extension P2PController: RTCPeerConnectionDelegate {
    // MARK: - Required delegate stubs (empty implementations)
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            let callId = (!self.currentRoomID.isEmpty && !self.currentMyID.isEmpty) ? self.computePairKey(roomID: self.currentRoomID, myID: self.currentMyID) : ""
            switch newState {
            case .connected, .completed:
                self.state = .connected
            case .disconnected:
                // 一時切断はトラックを保持して再接続を待つ
                log("[P2P] ICE state changed: disconnected — keep tracks and wait", category: "P2P")
                if self.state != .failed { self.state = .connecting }
            case .failed, .closed:
                log("[P2P] ICE state changed: \(newState) — tearing down tracks", category: "P2P")
                self.localTrack = nil
                self.remoteTrack = nil
                self.state = (newState == .failed ? .failed : .idle)
            case .checking, .new:
                if self.state != .failed { self.state = .connecting }
            case .count:
                break
            @unknown default:
                break
            }
            if !callId.isEmpty {
                self.logSignalMetrics(prefix: "iceConnection.\(String(describing: newState))", callId: callId)
            }
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
                if self.localTrack != nil {
                    // overlay auto-shown by SwiftUI
                }
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
                if self.localTrack != nil {
                    // overlay auto-shown by SwiftUI
                }
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
            if state == .connected {
                await self.cleanupSignalRecords()
                if !self.publishedCandidateTypeCounts.isEmpty {
                    let summary = self.publishedCandidateTypeCounts.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                    log("[P2P] connected with ICE summary {\(summary)}", category: "P2P")
                }
            }
            if !callId.isEmpty {
                let stateLabel = String(describing: state)
                logSignalMetrics(prefix: "ice.\(stateLabel)", callId: callId)
            }
        }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            // クローズや未接続状態ではPublishしない（クラッシュ/重複抑止）
            guard self.state != .idle, let pc = self.pc, pc.connectionState != .closed else { return }
            let encoded = self.encodeCandidate(candidate)
            self.bufferSignal(.candidate(encoded))
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
            log("[P2P] peerConnectionShouldNegotiate fired (isPolite=\(self.isPolite))", category: "P2P")
#if canImport(WebRTC)
            // o3推奨: 両側で交渉を許可し、glareはisPoliteで解決（polite: rollback受け入れ / impolite: 無視）
            // 嵐防止はPC単位のデバウンス＋in-flight上限で担保
            self.scheduleNegotiationDebounced()
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
        let remote = self.currentRemoteID
        log("[P2P] Scheduling full reset due to: \(reason)", category: "P2P")
        Task { @MainActor in
            // 遅延後に“まだ同じroomに居る”ことを確認してからリセットを実行
            let ns = UInt64(max(0, cooldownMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard room == self.currentRoomID else {
                log("[P2P] Skip reset: room switched (scheduled=\(room) current=\(self.currentRoomID))", category: "P2P")
                return
            }
            let callId = self.computePairKey(roomID: room, myID: me)
            logSignalMetrics(prefix: "reset", callId: callId)
            self.close()
            if !room.isEmpty, !me.isEmpty, !remote.isEmpty {
                self.startIfNeeded(roomID: room, myID: me, remoteID: remote)
            }
        }
    }
}

// Placeholder bridge used by the overlay to trigger SwiftUI transitions.
// FloatingVideoOverlayBridge は不要（システムPiP不採用）

extension P2PController {
    private func cleanupSignalRecords() async {
        guard !currentRoomID.isEmpty else { return }
        await CloudKitChatManager.shared.cleanupExpiredSignals(roomID: currentRoomID)
    }
}
