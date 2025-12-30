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

/// 役割:
/// - WebRTC PeerConnection のライフサイクル管理
/// - CloudKit シグナリング（SignalSession / Envelope / IceChunk）の適用
/// - UI向けに `localTrack` / `remoteTrack` を公開
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
    /// Simulator用: バンドル動画を「疑似カメラ」として送出するためのcapturer
    private var fileCapturer: RTCFileVideoCapturer?
    #endif
    private var capturer: RTCCameraVideoCapturer?
    private var hasPublishedOffer: Bool = false
    private var hasPublishedAnswer: Bool = false
    private var hasSetRemoteDescription: Bool = false
    /// `setRemoteDescription` 済みのSDPが属するepoch（ICEのstale判定に使用）
    /// - `activeCallEpoch` は publish(Offer/ICE) で先に進みうるため、ICE側のstale判定には不適切なケースがある（H13）。
    private var remoteDescriptionCallEpoch: Int = 0
    // Connection timeout and retry
    private var connectionTimer: Timer?
    private var connectionAttempts = 0
    private let maxConnectionAttempts = 3
    // シグナルポーリング: CloudKit変更を定期的にfetchしてOffer/Answerを検出
    private var signalPollingTimer: Timer?
    private let signalPollingInterval: TimeInterval = 2.0
    // CloudKitシグナリング（offer/answer/ice + session update）は実環境で10秒を超えることがある。
    // 10秒で切ると offer が保存される前に close → 文脈リセットが走り、永遠に接続できなくなる。
    private let connectionTimeout: TimeInterval = 25.0
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
    private var pendingLocalCandidates: [String] = []  // offer/answer未公開時に一時保持（CloudKit書込みバースト抑制）
    
    // CloudKitのICE書き込みをレート制限(503/ZoneBusy)から守るため、候補を短時間でバッチ化して送信する。
    // - 0.4秒デバウンス / 最大12件で即フラッシュ
    // - epochが切り替わったら（再交渉/リトライ）旧epochは先に送る
    private var outgoingIceBatchEpoch: Int?
    private var outgoingIceBatchCandidates: [String] = []
    private var outgoingIceBatchTask: Task<Void, Never>?
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
        hasPublishedAnswer = false
        hasSetRemoteDescription = false
        remoteDescriptionCallEpoch = 0
        isMakingOffer = false
        isOfferCreator = false
        pendingRemoteCandidates.removeAll()
        pendingLocalCandidates.removeAll()
        outgoingIceBatchEpoch = nil
        outgoingIceBatchCandidates.removeAll()
        outgoingIceBatchTask?.cancel()
        outgoingIceBatchTask = nil
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
                await self.handleConnectionTimeout()
            }
        }
        log("[P2P] Connection timer started (\(connectionTimeout)s)", category: "P2P")
    }
    
    /// シグナルポーリング開始: CloudKit変更を定期的にfetchしてOffer/Answerを検出
    /// Push通知が届かない環境（シミュレータ等）でもシグナリングを機能させるため
    private func startSignalPolling() {
        stopSignalPolling()
        signalPollingTimer = Timer.scheduledTimer(withTimeInterval: signalPollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.state == .connecting else { return }
                await self.pollSignalChanges()
            }
        }
        log("[P2P] Signal polling started (interval=\(signalPollingInterval)s)", category: "P2P")
    }
    
    private func stopSignalPolling() {
        signalPollingTimer?.invalidate()
        signalPollingTimer = nil
    }
    
    /// CloudKitからゾーン変更を直接取得してOffer/Answerを検出
    private func pollSignalChanges() async {
        guard state == .connecting else { return }
        let roomID = currentRoomID
        guard !roomID.isEmpty else { return }
        
        do {
            let (database, zoneID) = try await CloudKitChatManager.shared.resolveZone(for: roomID, purpose: .signal)
            
            // recordZoneChanges を使ってゾーン内の全変更を取得
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: nil)
            
            var appliedCount = 0
            for modification in changes.modificationResultsByID {
                if let record = try? modification.value.get().record {
                    let recordType = record.recordType
                    if recordType == CKSchema.SharedType.signalEnvelope || recordType == CKSchema.SharedType.signalIceChunk {
                        let applied = await applySignalRecord(record)
                        if applied { appliedCount += 1 }
                    }
                }
            }
            
            if appliedCount > 0 {
                log("[P2P] Signal polling: applied \(appliedCount) records", category: "P2P")
            }
        } catch {
            // エラーは無視（ゾーン未発見などの場合）
        }
    }
    
    /// タイムアウト時の処理。
    /// NOTE: Simulator/Push通知なし環境ではSignalの取り込みが遅れることがあるため、
    /// Offer作成者側は「CloudKitにAnswerが存在するのに適用できていない」ケースを救済する。
    @MainActor
    private func handleConnectionTimeout() async {
        // --- Timeout救済: Offer作成者で、AnswerがCloudKit上に既に存在するなら直fetch→適用して延命 ---
        if isOfferCreator,
           hasPublishedOffer,
           !hasSetRemoteDescription,
           !currentRoomID.isEmpty,
           !currentMyID.isEmpty,
           !currentRemoteID.isEmpty,
           activeCallEpoch > 0 {
            let room = currentRoomID
            let me = currentMyID
            let remote = currentRemoteID
            let epoch = activeCallEpoch

            // #region agent log
            AgentNDJSONLogger.post(runId: "post-fix-1",
                                   hypothesisId: "H12",
                                   location: "P2PController.swift:handleConnectionTimeout",
                                   message: "timeout rescue: try fetch+apply answer",
                                   data: [
                                    "roomID": room,
                                    "my": String(me.prefix(8)),
                                    "remote": String(remote.prefix(8)),
                                    "epoch": epoch,
                                    "hasPublishedOffer": hasPublishedOffer,
                                    "hasSetRD": hasSetRemoteDescription
                                   ])
            // #endregion

            do {
                let (db, zoneID) = try await CloudKitChatManager.shared.resolveZone(for: room, purpose: .signal)
                let (lo, hi) = me <= remote ? (me, remote) : (remote, me)
                let sessionKey = "\(room)#\(lo)#\(hi)"
                let answerRecordName = "SE_\(sessionKey)_\(epoch)_answer"
                let recordID = CKRecord.ID(recordName: answerRecordName, zoneID: zoneID)

                let record = try await db.record(for: recordID)
                let applied = await applySignalRecord(record)

                // #region agent log
                AgentNDJSONLogger.post(runId: "post-fix-1",
                                       hypothesisId: "H12",
                                       location: "P2PController.swift:handleConnectionTimeout",
                                       message: "timeout rescue: fetched answer",
                                       data: [
                                        "roomID": room,
                                        "epoch": epoch,
                                        "dbScope": db.databaseScope.rawValue,
                                        "recordSuffix": String(record.recordID.recordName.suffix(12)),
                                        "applied": applied,
                                        "hasSetRD": hasSetRemoteDescription
                                       ])
                // #endregion

                if applied || hasSetRemoteDescription {
                    // ここで接続が進む可能性があるので、タイムアウトを延長して様子を見る
                    startConnectionTimer()
                    return
                }
            } catch {
                // #region agent log
                AgentNDJSONLogger.post(runId: "post-fix-1",
                                       hypothesisId: "H12",
                                       location: "P2PController.swift:handleConnectionTimeout",
                                       message: "timeout rescue: fetch failed",
                                       data: [
                                        "roomID": room,
                                        "epoch": epoch,
                                        "err": String(describing: error)
                                       ])
                // #endregion
            }
        }

        if connectionAttempts < maxConnectionAttempts {
            connectionAttempts += 1
            log("[P2P] 🔄 Retrying connection (attempt \(connectionAttempts)/\(maxConnectionAttempts))", category: "P2P")
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix-2",
                                   hypothesisId: "H1",
                                   location: "P2PController.swift:handleConnectionTimeout",
                                   message: "connection timeout -> will close",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remoteHint": String(currentRemoteID.prefix(8)),
                                    "resolvedRemote": String((resolvedRemoteUserID ?? "").prefix(8)),
                                    "hasPublishedOffer": hasPublishedOffer,
                                    "hasSetRD": hasSetRemoteDescription,
                                    "activeCallEpoch": activeCallEpoch,
                                    "state": String(describing: state)
                                   ])
            // #endregion

            // #region agent log
            // Offer作成者側で「AnswerがCloudKit上で見えているのに適用できていない」vs「そもそも見えていない」を切り分ける。
            let diagRoomID = currentRoomID
            let diagMyID = currentMyID
            let diagRemoteID = (resolvedRemoteUserID ?? currentRemoteID)
            let diagEpoch = activeCallEpoch
            let diagIsOfferCreator = isOfferCreator
            Task { @MainActor in
                await self.debugProbeAnswerVisibilityOnTimeout(roomID: diagRoomID,
                                                              myID: diagMyID,
                                                              remoteID: diagRemoteID,
                                                              activeCallEpoch: diagEpoch,
                                                              isOfferCreator: diagIsOfferCreator)
            }
            // #endregion
            
            // 既存の接続をリセット（room文脈は維持して再試行する）
            let room = currentRoomID
            let me = currentMyID
            let remote = currentRemoteID
            teardownPeer(resetRoomContext: false, resetRetryAttempts: false)

            // 再試行（room文脈を保持しているので startIfNeeded に渡せる）
            if !room.isEmpty, !me.isEmpty {
                startIfNeeded(roomID: room, myID: me, remoteID: remote.isEmpty ? nil : remote)
            }
        } else {
            log("[P2P] ❌ Max connection attempts reached. Giving up.", category: "P2P")
            handleConnectionFailure()
        }
    }

    // #region agent log
    /// DEBUG MODE用: Offer作成者がAnswerを受け取れていないときに、CloudKit上の可視性（存在/最新epoch）を診断する。
    /// - NOTE: userID等はprefixに丸めてログへ出す（PIIを避ける）。
    @MainActor
    private func debugProbeAnswerVisibilityOnTimeout(roomID: String,
                                                    myID: String,
                                                    remoteID: String,
                                                    activeCallEpoch: Int,
                                                    isOfferCreator: Bool) async {
        guard isOfferCreator else { return }
        let room = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = myID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty, !me.isEmpty, !remote.isEmpty else { return }
        guard activeCallEpoch > 0 else { return }

        do {
            // 現在端末の視点で「シグナルはどのDB/zoneで見えるべきか」を採用
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveZone(for: room, purpose: .signal)
            let (lo, hi) = me <= remote ? (me, remote) : (remote, me)
            let sessionKey = "\(room)#\(lo)#\(hi)"

            // 1) 「このepochのAnswer」が見えるか（直接fetch）
            let expectedAnswerRecordName = "SE_\(sessionKey)_\(activeCallEpoch)_answer"
            let expectedAnswerID = CKRecord.ID(recordName: expectedAnswerRecordName, zoneID: zoneID)
            var expectedFound = false
            var expectedError: String = ""
            do {
                _ = try await db.record(for: expectedAnswerID)
                expectedFound = true
            } catch {
                expectedError = String(describing: error)
            }

            // 2) 見えているAnswerのうち「最新callEpoch」を探す（query）
            var latestEpoch: Int = -1
            var latestSuffix: String = ""
            var queryError: String = ""
            do {
                let predicate = NSPredicate(format: "%K == %@ AND %K == %@",
                                            CKSchema.FieldKey.sessionKey, sessionKey,
                                            CKSchema.FieldKey.envelopeType, CloudKitChatManager.SignalEnvelopeType.answer.rawValue)
                let query = CKQuery(recordType: CKSchema.SharedType.signalEnvelope, predicate: predicate)
                let (results, _) = try await db.records(matching: query, inZoneWith: zoneID)
                for (_, res) in results {
                    if let rec = try? res.get() {
                        let epoch = rec[CKSchema.FieldKey.callEpoch] as? Int ?? -1
                        if epoch > latestEpoch {
                            latestEpoch = epoch
                            latestSuffix = String(rec.recordID.recordName.suffix(8))
                        }
                    }
                }
            } catch {
                queryError = String(describing: error)
            }

            AgentNDJSONLogger.post(runId: "diag-1",
                                   hypothesisId: "H7",
                                   location: "P2PController.swift:debugProbeAnswerVisibilityOnTimeout",
                                   message: "answer visibility probe",
                                   data: [
                                    "roomID": room,
                                    "my": String(me.prefix(8)),
                                    "remote": String(remote.prefix(8)),
                                    "dbScope": db.databaseScope.rawValue,
                                    "zoneOwner": String(zoneID.ownerName.prefix(8)),
                                    "epoch": activeCallEpoch,
                                    "expectedAnswerSuffix": String(expectedAnswerRecordName.suffix(8)),
                                    "expectedAnswerFound": expectedFound,
                                    "expectedAnswerErr": expectedError,
                                    "latestAnswerEpoch": latestEpoch,
                                    "latestAnswerSuffix": latestSuffix,
                                    "queryErr": queryError
                                   ])
        } catch {
            AgentNDJSONLogger.post(runId: "diag-1",
                                   hypothesisId: "H7",
                                   location: "P2PController.swift:debugProbeAnswerVisibilityOnTimeout",
                                   message: "answer visibility probe error",
                                   data: [
                                    "roomID": room,
                                    "my": String(me.prefix(8)),
                                    "remote": String(remote.prefix(8)),
                                    "epoch": activeCallEpoch,
                                    "err": String(describing: error)
                                   ])
        }
    }
    // #endregion
    
    private func handleConnectionFailure() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        stopSignalPolling()
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
        
        // Start connection timer and signal polling
        startConnectionTimer()
        startSignalPolling()
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
        teardownPeer(resetRoomContext: true, resetRetryAttempts: true)
    }

    /// close() の実体。timeoutリトライ等では room 文脈や retry 回数を保持したいので引数で制御する。
    private func teardownPeer(resetRoomContext: Bool, resetRetryAttempts: Bool) {
        if state == .idle && currentRoomID.isEmpty {
            return
        }
        log("[P2P] close() called. Resetting peer + tracks", category: "P2P")

        // Cancel all timers and tasks
        connectionTimer?.invalidate()
        connectionTimer = nil
        stopSignalPolling()
        if resetRetryAttempts {
            connectionAttempts = 0
        }
        negotiationDebounceTask?.cancel(); negotiationDebounceTask = nil
        ensureOfferTask?.cancel(); ensureOfferTask = nil

        pc?.delegate = nil
#if canImport(WebRTC)
        videoTransceiver?.sender.track = nil
#endif
        capturer?.stopCapture()
        capturer = nil
        #if canImport(WebRTC)
        fileCapturer?.stopCapture()
        fileCapturer = nil
        #endif
        localTrack = nil
        remoteTrack = nil
        pc?.close()
        pc = nil

        resetSignalState(resetRoomContext: resetRoomContext)
        state = .idle
    }

    func closeIfCurrent(roomID: String?, reason: String) {
        let expected = roomID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expected.isEmpty && expected != currentRoomID {
            log("[P2P] closeIfCurrent skipped (reason=\(reason)) current=\(currentRoomID) expected=\(expected)", category: "P2P")
            return
        }
        // post-fix-2: RoomMember更新などの「リモート解決」による自動リスタートが、
        // ちょうどOffer適用直後に走ると self-close して交渉を破壊する（実ログで発生）。
        // 接続中は defer して、シグナリングを優先する。
        if reason.contains("remote-participant-resolved") && state == .connecting {
            log("[P2P] closeIfCurrent deferred (reason=\(reason)) while connecting room=\(currentRoomID)", category: "P2P")
            AgentNDJSONLogger.post(runId: "post-fix-2",
                                   hypothesisId: "H16",
                                   location: "P2PController.swift:closeIfCurrent",
                                   message: "defer closeIfCurrent (remote-participant-resolved) while connecting",
                                   data: [
                                    "roomID": currentRoomID,
                                    "state": String(describing: state),
                                    "hasSetRD": hasSetRemoteDescription,
                                    "activeCallEpoch": activeCallEpoch
                                   ])
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
        // Simulator にはカメラデバイスが無いので、バンドル動画を疑似カメラとして送出する。
        // A/Bで別動画になるよう、myID と remoteID の辞書順でファイルを選ぶ（両端末で必ず反転する）。
        guard let pc else { return }
        let f = RTCPeerConnectionFactory()
        let source = f.videoSource()

        let my = currentMyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = (resolvedRemoteUserID ?? currentRemoteID).trimmingCharacters(in: .whitespacesAndNewlines)

        let fileName: String
        if my.isEmpty || remote.isEmpty {
            // remote未解決でもクラッシュしないよう固定値にフォールバック
            fileName = "logo2.mp4"
        } else {
            // 片側がlogo2、もう片側がlogo3になる
            fileName = (my < remote) ? "logo2.mp4" : "logo3.mp4"
        }

        if Bundle.main.url(forResource: fileName, withExtension: nil) == nil {
            log("[P2P] ⚠️ Simulator file camera missing in bundle: \(fileName)", category: "P2P")
        } else {
            log("[P2P] Simulator file camera selected: \(fileName)", category: "P2P")
        }

        #if canImport(WebRTC)
        fileCapturer?.stopCapture()
        fileCapturer = RTCFileVideoCapturer(delegate: source)
        #endif

        localTrack = f.videoTrack(with: source, trackId: "local0")
        #if canImport(WebRTC)
        if let track = localTrack {
            if let tx = self.videoTransceiver {
                tx.sender.track = track
                log("[P2P] Local video track attached to transceiver sender (simulator file)", category: "P2P")
            } else {
                _ = pc.add(track, streamIds: ["stream0"])
                log("[P2P] Local video track added via addTrack (simulator file fallback)", category: "P2P")
            }
        }
        #endif

        // RTCFileVideoCapturerは「ファイル名（拡張子込み）」で読み取る
        #if canImport(WebRTC)
        fileCapturer?.startCapturing(fromFileNamed: fileName, onError: { error in
            log("[P2P] ⚠️ Simulator file camera start failed: \(error)", category: "P2P")
        })
        #endif

        log("[P2P] startLocalCamera using bundled video (simulator)", category: "P2P")
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
        // #region agent log
        AgentNDJSONLogger.post(runId: "pre-fix",
                               hypothesisId: "H2",
                               location: "P2PController.swift:prepareSignalChannel",
                               message: "signal zone ready check",
                               data: [
                                "roomID": currentRoomID,
                                "zoneReady": zoneReady,
                                "initial": initial
                               ])
        // #endregion
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
            var resolveSource: String = "existing"
            if resolvedRemoteUserID == nil {
                resolveSource = "none"
                if let hinted = (!remoteHint.isEmpty ? remoteHint : nil) {
                    resolvedRemoteUserID = hinted
                    resolveSource = "hint"
                    log("[P2P] Using hinted remote ID: \(String(hinted.prefix(8)))", category: "P2P")
                } else if let counterpart = CloudKitChatManager.shared.primaryCounterpartUserID(roomID: currentRoomID) {
                    resolvedRemoteUserID = counterpart
                    resolveSource = "counterpart"
                    log("[P2P] Using counterpart from CloudKit: \(String(counterpart.prefix(8)))", category: "P2P")
                } else {
                    log("[P2P] No remote ID available yet, will retry", category: "P2P")
                }
            }
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H1",
                                   location: "P2PController.swift:prepareSignalChannel",
                                   message: "remote resolve attempt",
                                   data: [
                                    "roomID": currentRoomID,
                                    "remoteHint": String(remoteHint.prefix(8)),
                                    "source": resolveSource,
                                    "resolved": String((resolvedRemoteUserID ?? "").prefix(8))
                                   ])
            // #endregion

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
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H3",
                                   location: "P2PController.swift:prepareSignalChannel",
                                   message: "ensureSignalSession ok",
                                   data: [
                                    "roomID": currentRoomID,
                                    "remote": String(remoteID.prefix(8)),
                                    "activeCallEpoch": signalSession?.activeCallEpoch ?? 0
                                   ])
            // #endregion
            await markActiveAndMaybeInitialOffer()
        } catch let error as CloudKitChatManager.CloudKitChatError where error == .signalingZoneUnavailable {
            log("[P2P] Signal zone unavailable — scheduling retry room=\(currentRoomID)", category: "P2P")
            scheduleSignalInfraRetry(afterMilliseconds: 2500)
        } catch {
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H3",
                                   location: "P2PController.swift:prepareSignalChannel",
                                   message: "prepareSignalChannel failed",
                                   data: [
                                    "roomID": currentRoomID,
                                    "err": String(describing: error)
                                   ])
            // #endregion
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
        // 固定ロジック: Offer作成者のみがOfferを作成する
        guard isOfferCreator else { return }
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
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix-3",
                                   hypothesisId: "H8",
                                   location: "P2PController.swift:publishOfferSDP",
                                   message: "publishOffer ok",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(remote.prefix(8)),
                                    "callEpoch": envelope.callEpoch,
                                    "record": String(envelope.recordID.recordName.suffix(12)),
                                    "sessionKeySuffix": String(envelope.sessionKey.suffix(20))
                                   ])
            // #endregion
            log("[P2P] Offer published (callEpoch=\(envelope.callEpoch))", category: "P2P")
            await flushPendingLocalCandidates(callEpoch: envelope.callEpoch)
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
            hasPublishedAnswer = true
            activeCallEpoch = max(activeCallEpoch, envelope.callEpoch)
            if var session = signalSession {
                session.activeCallEpoch = max(session.activeCallEpoch, envelope.callEpoch)
                session.updatedAt = envelope.createdAt
                signalSession = session
            }
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix-3",
                                   hypothesisId: "H8",
                                   location: "P2PController.swift:publishAnswerSDP",
                                   message: "publishAnswer ok",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(remote.prefix(8)),
                                    "callEpoch": envelope.callEpoch,
                                    "record": String(envelope.recordID.recordName.suffix(12)),
                                    "sessionKeySuffix": String(envelope.sessionKey.suffix(20))
                                   ])
            // #endregion
            log("[P2P] Answer published (callEpoch=\(envelope.callEpoch))", category: "P2P")
            await flushPendingLocalCandidates(callEpoch: envelope.callEpoch)
        } catch {
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix-3",
                                   hypothesisId: "H11",
                                   location: "P2PController.swift:publishAnswerSDP",
                                   message: "publishAnswer error",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String((resolvedRemoteUserID ?? "").prefix(8)),
                                    "callEpoch": callEpoch,
                                    "err": String(describing: error)
                                   ])
            // #endregion
            log("[P2P] Failed to publish answer: \(error)", category: "P2P")
        }
    }

    private func publishCandidateEncoded(_ encoded: String, callEpoch: Int) async {
        guard !currentMyID.isEmpty, let remote = resolvedRemoteUserID else { return }
        guard !publishedCandidateFingerprints.contains(encoded) else { return }
        publishedCandidateFingerprints.insert(encoded)
        _ = remote
        await enqueueIceCandidateForBatchPublish(encoded, callEpoch: callEpoch)
    }

    /// offer/answer が CloudKit に保存される前に ICE を大量送信すると、SignalSession更新がバーストしてCAS lockエラー/遅延を誘発しやすい。
    /// そのため、SDPが公開されるまではローカル候補をバッファし、公開後にまとめて送る。
    private func flushPendingLocalCandidates(callEpoch: Int) async {
        guard !pendingLocalCandidates.isEmpty else { return }
        let buffered = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        log("[P2P] Flushing \(buffered.count) buffered local ICE candidates (callEpoch=\(callEpoch))", level: "DEBUG", category: "P2P")
        for enc in buffered {
            await publishCandidateEncoded(enc, callEpoch: callEpoch)
            publishedCandidateCount += 1
            let sep = "\u{1F}"
            let sdp = enc.components(separatedBy: sep).first ?? ""
            let parts = sdp.components(separatedBy: " ")
            if let idx = parts.firstIndex(of: "typ"), parts.count > idx + 1 {
                let typ = parts[idx + 1]
                publishedCandidateTypeCounts[typ, default: 0] += 1
            }
        }
        // まとめてキューに積んだら即フラッシュして書込み回数を圧縮する
        await flushOutgoingIceBatchIfNeeded()
    }

    // MARK: - ICE batch publish (CloudKit rate-limit mitigation)
    @MainActor
    private func enqueueIceCandidateForBatchPublish(_ encoded: String, callEpoch: Int) async {
        guard !encoded.isEmpty else { return }
        guard state != .idle, let pc, pc.connectionState != .closed else { return }
        guard !currentRoomID.isEmpty, !currentMyID.isEmpty, resolvedRemoteUserID != nil else { return }
        guard hasPublishedOffer || hasPublishedAnswer else { return }

        // epochが変わったら旧epochを先に送る（混ぜない）
        if let e = outgoingIceBatchEpoch, e != callEpoch, !outgoingIceBatchCandidates.isEmpty {
            let oldEpoch = e
            let oldBatch = outgoingIceBatchCandidates
            outgoingIceBatchCandidates.removeAll()
            outgoingIceBatchTask?.cancel()
            outgoingIceBatchTask = nil

            outgoingIceBatchEpoch = callEpoch
            outgoingIceBatchCandidates.append(encoded)

            Task { @MainActor in
                await self.publishIceBatchNow(encodedCandidates: oldBatch, callEpoch: oldEpoch)
                await self.flushOutgoingIceBatchIfNeeded()
            }
            return
        }

        outgoingIceBatchEpoch = callEpoch
        outgoingIceBatchCandidates.append(encoded)

        // 量が多い場合は即フラッシュ
        if outgoingIceBatchCandidates.count >= 12 {
            outgoingIceBatchTask?.cancel()
            outgoingIceBatchTask = nil
            await flushOutgoingIceBatchIfNeeded()
            return
        }

        if outgoingIceBatchTask == nil {
            outgoingIceBatchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
                await self.flushOutgoingIceBatchIfNeeded()
            }
        }
    }

    @MainActor
    private func flushOutgoingIceBatchIfNeeded() async {
        guard let epoch = outgoingIceBatchEpoch else { return }
        guard !outgoingIceBatchCandidates.isEmpty else { return }
        let batch = outgoingIceBatchCandidates
        outgoingIceBatchCandidates.removeAll()
        outgoingIceBatchTask?.cancel()
        outgoingIceBatchTask = nil
        await publishIceBatchNow(encodedCandidates: batch, callEpoch: epoch)
    }

    @MainActor
    private func publishIceBatchNow(encodedCandidates: [String], callEpoch: Int) async {
        guard !currentMyID.isEmpty, let remote = resolvedRemoteUserID else { return }
        guard !currentRoomID.isEmpty else { return }
        do {
            let chunk = try await CloudKitChatManager.shared.publishIceCandidatesBatch(roomID: currentRoomID,
                                                                                      localUserID: currentMyID,
                                                                                      remoteUserID: remote,
                                                                                      callEpoch: callEpoch,
                                                                                      encodedCandidates: encodedCandidates)
            activeCallEpoch = max(activeCallEpoch, chunk.callEpoch)
            log("[P2P] Published ICE batch record=\(chunk.recordID.recordName) count=\(encodedCandidates.count)", level: "DEBUG", category: "P2P")
            AgentNDJSONLogger.post(runId: "post-fix-3",
                                   hypothesisId: "H17",
                                   location: "P2PController.swift:publishIceBatchNow",
                                   message: "publish ICE batch ok",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(remote.prefix(8)),
                                    "callEpoch": callEpoch,
                                    "count": encodedCandidates.count,
                                    "recordSuffix": String(chunk.recordID.recordName.suffix(24))
                                   ])
        } catch {
            log("[P2P] Failed to publish ICE batch: \(error)", category: "P2P")
            AgentNDJSONLogger.post(runId: "post-fix-3",
                                   hypothesisId: "H18",
                                   location: "P2PController.swift:publishIceBatchNow",
                                   message: "publish ICE batch error",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String((resolvedRemoteUserID ?? "").prefix(8)),
                                    "callEpoch": callEpoch,
                                    "count": encodedCandidates.count,
                                    "err": String(describing: error)
                                   ])
        }
    }

    // MARK: - Signal ingestion
    func applySignalRecord(_ record: CKRecord) async -> Bool {
        let recordZoneName = record.recordID.zoneID.zoneName
        if recordZoneName != currentRoomID {
            // currentRoomID が空の状態でシグナルが到達している場合、タイムアウト/closeで文脈が消えて適用できていない可能性が高い。
            // #region agent log
            if currentRoomID.isEmpty && (record.recordType == "SignalEnvelope" || record.recordType == "SignalIceChunk") {
                AgentNDJSONLogger.post(runId: "pre-fix-2",
                                       hypothesisId: "H1",
                                       location: "P2PController.swift:applySignalRecord",
                                       message: "skip signal record (currentRoomID empty)",
                                       data: [
                                        "recordZone": recordZoneName,
                                        "recordType": record.recordType,
                                        "my": String(currentMyID.prefix(8)),
                                        "state": String(describing: state)
                                       ])
            }
            // #endregion
            return false
        }
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
            // #region agent log
            let expected = computePairKey(roomID: currentRoomID, myID: currentMyID)
            AgentNDJSONLogger.post(runId: "pre-fix-3",
                                   hypothesisId: "H8",
                                   location: "P2PController.swift:applySignalEnvelope",
                                   message: "skip envelope (session mismatch)",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "currentRemote": String(currentRemoteID.prefix(8)),
                                    "resolvedRemote": String((resolvedRemoteUserID ?? "").prefix(8)),
                                    "envelopeOwner": String(envelope.ownerUserID.prefix(8)),
                                    "type": envelope.type.rawValue,
                                    "callEpoch": envelope.callEpoch,
                                    "expectedKeySuffix": String(expected.suffix(20)),
                                    "gotKeySuffix": String(envelope.sessionKey.suffix(20)),
                                    "state": String(describing: state),
                                    "isOfferCreator": isOfferCreator
                                   ])
            // #endregion
            return false
        }
        let recordKey = envelope.recordID.recordName
        guard !appliedEnvelopeRecordIDs.contains(recordKey) else { return false }
        appliedEnvelopeRecordIDs.insert(recordKey)

        // post-fix-2: ロール不一致のEnvelopeは、epoch更新/状態リセットの前に弾く。
        // そうしないと「処理しないOffer/Answerが到達→activeCallEpochが進む or stateが初期化」
        // となり、接続の文脈が壊れてタイムアウトしうる。
        switch envelope.type {
        case .offer where isOfferCreator:
            log("[P2P] ⚠️ Ignoring offer (isOfferCreator=true) record=\(recordKey)", level: "DEBUG", category: "P2P")
            AgentNDJSONLogger.post(runId: "post-fix-2",
                                   hypothesisId: "H15",
                                   location: "P2PController.swift:applySignalEnvelope",
                                   message: "ignored offer before epoch/state mutation",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(currentRemoteID.prefix(8)),
                                    "callEpoch": envelope.callEpoch,
                                    "recordSuffix": String(recordKey.suffix(24)),
                                    "activeCallEpoch": activeCallEpoch
                                   ])
            return false
        case .answer where !isOfferCreator:
            log("[P2P] ⚠️ Ignoring answer (isOfferCreator=false) record=\(recordKey)", level: "DEBUG", category: "P2P")
            AgentNDJSONLogger.post(runId: "post-fix-2",
                                   hypothesisId: "H15",
                                   location: "P2PController.swift:applySignalEnvelope",
                                   message: "ignored answer before epoch/state mutation",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(currentRemoteID.prefix(8)),
                                    "callEpoch": envelope.callEpoch,
                                    "recordSuffix": String(recordKey.suffix(24)),
                                    "activeCallEpoch": activeCallEpoch
                                   ])
            return false
        default:
            break
        }

        let isNewEpoch = envelope.callEpoch > activeCallEpoch
        if isNewEpoch {
            hasSetRemoteDescription = false
            remoteDescriptionCallEpoch = 0
            hasPublishedOffer = false
            pendingRemoteCandidates.removeAll()
            appliedIceRecordIDs.removeAll()
            appliedEnvelopeRecordIDs.removeAll()
            publishedCandidateFingerprints.removeAll()
            addedRemoteCandidateCount = 0
        }

        activeCallEpoch = max(activeCallEpoch, envelope.callEpoch)
        var applied = false
        switch envelope.type {
        case .offer:
            if envelope.callEpoch >= lastAppliedOfferEpoch {
                lastAppliedOfferEpoch = envelope.callEpoch
                applied = await applyOfferPayload(callId: recordKey, sdp: envelope.sdp, callEpoch: envelope.callEpoch)
            }
        case .answer:
            if envelope.callEpoch >= lastAppliedAnswerEpoch {
                lastAppliedAnswerEpoch = envelope.callEpoch
                applied = await applyAnswerPayload(callId: recordKey, sdp: envelope.sdp, callEpoch: envelope.callEpoch)
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
        // ICEのstale判定は「いま適用しているremoteDescriptionのepoch」を優先する。
        // まだRD未設定なら、stale判定で弾かずにバッファしておき、RD確定後にflushする。
        let floorEpoch = hasSetRemoteDescription ? remoteDescriptionCallEpoch : 0
        if floorEpoch > 0, chunk.callEpoch < floorEpoch {
            log("[P2P] Skip ICE chunk (stale epoch) record=\(chunk.recordID.recordName)", level: "DEBUG", category: "P2P")
            // #region agent log
            AgentNDJSONLogger.post(runId: "post-fix-2",
                                   hypothesisId: "H13",
                                   location: "P2PController.swift:applySignalIceChunk",
                                   message: "skip ICE chunk (stale epoch; floorEpoch=remoteDescriptionCallEpoch)",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(currentRemoteID.prefix(8)),
                                    "chunkEpoch": chunk.callEpoch,
                                    "floorEpoch": floorEpoch,
                                    "activeCallEpoch": activeCallEpoch,
                                    "lastAppliedOfferEpoch": lastAppliedOfferEpoch,
                                    "lastAppliedAnswerEpoch": lastAppliedAnswerEpoch,
                                    "hasSetRD": hasSetRemoteDescription,
                                    "isOfferCreator": isOfferCreator,
                                    "recordSuffix": String(chunk.recordID.recordName.suffix(24))
                                   ])
            // #endregion
            return false
        }
        let recordKey = chunk.recordID.recordName
        guard !appliedIceRecordIDs.contains(recordKey) else { return false }
        appliedIceRecordIDs.insert(recordKey)
        activeCallEpoch = max(activeCallEpoch, chunk.callEpoch)
        if hasSetRemoteDescription {
            // batch-v1はJSONで複数候補を1レコードに詰めて送る（Schema変更なし）
            let candidates = decodeIceCandidatesFromChunk(chunk)
            var anyApplied = false
            for (idx, enc) in candidates.enumerated() {
                let ok = await applyCandidatePayload(callId: "\(recordKey)#\(idx)", encodedCandidate: enc)
                anyApplied = anyApplied || ok
            }
            return anyApplied
        } else {
            let candidates = decodeIceCandidatesFromChunk(chunk)
            for enc in candidates {
                if pendingRemoteCandidates.count < 200 {
                    pendingRemoteCandidates.append(enc)
                }
            }
            log("[P2P] Buffered ICE chunk (pending RD) record=\(recordKey)", level: "DEBUG", category: "P2P")
            return true
        }
    }

    // batch-v1互換: candidateTypeで判定し、JSON payloadなら候補配列を返す
    private func decodeIceCandidatesFromChunk(_ chunk: CloudKitChatManager.SignalIceChunkSnapshot) -> [String] {
        guard let t = chunk.candidateType, t == "batch-v1" else {
            return [chunk.candidate]
        }
        struct IceBatchV1Payload: Decodable { let v: Int; let candidates: [String] }
        guard let data = chunk.candidate.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IceBatchV1Payload.self, from: data),
              payload.v == 1 else {
            // 壊れていたら単一として扱って落ちないようにする
            return [chunk.candidate]
        }
        AgentNDJSONLogger.post(runId: "post-fix-3",
                               hypothesisId: "H19",
                               location: "P2PController.swift:decodeIceCandidatesFromChunk",
                               message: "decoded ICE batch",
                               data: [
                                "roomID": currentRoomID,
                                "my": String(currentMyID.prefix(8)),
                                "remote": String(currentRemoteID.prefix(8)),
                                "chunkEpoch": chunk.callEpoch,
                                "count": payload.candidates.count
                               ])
        return payload.candidates
    }

#if canImport(WebRTC)
    // negotiationneeded時のOffer生成（Perfect Negotiation）
    private func createAndPublishOfferInternal() async {
        // 固定ロジック: Offer作成者のみがOfferを作成する
        guard self.isOfferCreator else { return }
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
    private func applyOfferPayload(callId: String, sdp: String, callEpoch: Int) async -> Bool {
        // 固定ロジック: Offer作成者でない端末のみがOfferを受信して処理
        if isOfferCreator {
            log("[P2P] ⚠️ Unexpected: Offer creator received offer. Ignoring. callId=\(callId)", category: "P2P")
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix-3",
                                   hypothesisId: "H9",
                                   location: "P2PController.swift:applyOfferPayload",
                                   message: "ignored offer (isOfferCreator=true)",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(currentRemoteID.prefix(8)),
                                    "callId": String(callId.suffix(8)),
                                    "state": String(describing: state),
                                    "isOfferCreator": isOfferCreator
                                   ])
            // #endregion
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
            self.remoteDescriptionCallEpoch = callEpoch
            self.ensureOfferTask?.cancel()
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H5",
                                   location: "P2PController.swift:applyOfferPayload",
                                   message: "setRemoteDescription(offer) ok",
                                   data: [
                                    "callId": String(callId.suffix(8)),
                                    "signalingState": String(describing: peer.signalingState),
                                    "pendingICE": self.pendingRemoteCandidates.count
                                   ])
            // #endregion
            log("[P2P] Remote offer set callId=\(callId) pendingICE=\(self.pendingRemoteCandidates.count)", category: "P2P")
            self.startLocalCameraWhenPartnerOnline()
            await flushPendingRemoteCandidates()
            await self.createAndPublishAnswer()
            return true
        } catch {
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H5",
                                   location: "P2PController.swift:applyOfferPayload",
                                   message: "setRemoteDescription(offer) error",
                                   data: [
                                    "callId": String(callId.suffix(8)),
                                    "err": String(describing: error)
                                   ])
            // #endregion
            log("[P2P] setRemoteDescription(offer) error callId=\(callId): \(error)", category: "P2P")
            return false
        }
    }

    private func applyAnswerPayload(callId: String, sdp: String, callEpoch: Int) async -> Bool {
        // 固定ロジック: Offer作成者のみがAnswerを受信して処理
        if !isOfferCreator {
            log("[P2P] ⚠️ Unexpected: Non-offer creator received answer. Ignoring. callId=\(callId)", category: "P2P")
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix-3",
                                   hypothesisId: "H9",
                                   location: "P2PController.swift:applyAnswerPayload",
                                   message: "ignored answer (isOfferCreator=false)",
                                   data: [
                                    "roomID": currentRoomID,
                                    "my": String(currentMyID.prefix(8)),
                                    "remote": String(currentRemoteID.prefix(8)),
                                    "callId": String(callId.suffix(8)),
                                    "state": String(describing: state),
                                    "isOfferCreator": isOfferCreator
                                   ])
            // #endregion
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
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H5",
                                   location: "P2PController.swift:applyAnswerPayload",
                                   message: "setRemoteDescription(answer) ok",
                                   data: [
                                    "callId": String(callId.suffix(8)),
                                    "signalingState": String(describing: peer.signalingState),
                                    "pendingICE": self.pendingRemoteCandidates.count
                                   ])
            // #endregion
            log("[P2P] Remote answer set callId=\(callId)", category: "P2P")
            self.hasSetRemoteDescription = true
            self.remoteDescriptionCallEpoch = callEpoch
            self.ensureOfferTask?.cancel()
            log("[P2P] RD set (answer) pendingICE=\(self.pendingRemoteCandidates.count)", category: "P2P")
            self.startLocalCameraWhenPartnerOnline()
            await flushPendingRemoteCandidates()
            return true
        } catch {
            // #region agent log
            AgentNDJSONLogger.post(runId: "pre-fix",
                                   hypothesisId: "H5",
                                   location: "P2PController.swift:applyAnswerPayload",
                                   message: "setRemoteDescription(answer) error",
                                   data: [
                                    "callId": String(callId.suffix(8)),
                                    "err": String(describing: error)
                                   ])
            // #endregion
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
                if self.addedRemoteCandidateCount == 1 {
                    AgentNDJSONLogger.post(runId: "post-fix-2",
                                           hypothesisId: "H14",
                                           location: "P2PController.swift:applyCandidatePayload",
                                           message: "addIce ok (first)",
                                           data: [
                                            "roomID": currentRoomID,
                                            "my": String(currentMyID.prefix(8)),
                                            "remote": String(currentRemoteID.prefix(8)),
                                            "epoch": remoteDescriptionCallEpoch,
                                            "callIdSuffix": String(callId.suffix(12))
                                           ])
                }
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
            self.addedRemoteCandidateCount += 1
            if self.addedRemoteCandidateCount == 1 || self.addedRemoteCandidateCount % 10 == 0 {
                log("[P2P] Remote ICE candidates added total=\(self.addedRemoteCandidateCount) (flush)", level: "DEBUG", category: "P2P")
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
                self.stopSignalPolling()
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
                // #region agent log
                AgentNDJSONLogger.post(runId: "pre-fix",
                                       hypothesisId: "H6",
                                       location: "P2PController.swift:didAddRtpReceiver",
                                       message: "remoteTrack received",
                                       data: [
                                        "roomID": self.currentRoomID,
                                        "trackId": videoTrack.trackId,
                                        "hasLocalTrack": (self.localTrack != nil)
                                       ])
                // #endregion
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
            if !self.hasPublishedOffer && !self.hasPublishedAnswer {
                if !encoded.isEmpty, self.pendingLocalCandidates.count < 50 {
                    self.pendingLocalCandidates.append(encoded)
                    if self.pendingLocalCandidates.count == 1 || self.pendingLocalCandidates.count % 10 == 0 {
                        log("[P2P] Buffered local ICE candidates count=\(self.pendingLocalCandidates.count) (waiting for SDP publish)", level: "DEBUG", category: "P2P")
                    }
                }
                _ = pc
                return
            }
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
