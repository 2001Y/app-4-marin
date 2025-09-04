import Foundation
import CloudKit
import CoreMedia
#if canImport(WebRTC)
import WebRTC
#endif
import Combine
import SwiftUI

@MainActor
final class P2PController: NSObject, ObservableObject {
    // Singleton instance used across SwiftUI views
    static let shared: P2PController = .init()

    enum State { case idle, connecting, connected, failed }

    @Published private(set) var state: State = .idle
    @Published var localTrack: RTCVideoTrack?
    @Published var remoteTrack: RTCVideoTrack?

    private var pc: RTCPeerConnection?
    #if canImport(WebRTC)
    private var videoTransceiver: RTCRtpTransceiver?
    #endif
    private var capturer: RTCCameraVideoCapturer?
    private var presenceTimer: AnyCancellable?
    private var signalPoller: AnyCancellable?
    private var processedSignalIDs: Set<String> = []
    private var signalDB: CKDatabase?
    private var signalZoneID: CKRecordZone.ID?
    private var hasPublishedOffer: Bool = false
    private var hasSetRemoteDescription: Bool = false
    private var isOwnerRole: Bool = false
    private var processedCandidates: Set<String> = []
    // 1on1限定の安定キー（同一ルーム内の2者で一致するキー）
    private func computePairKey(roomID: String, myID: String) -> String {
        // 将来multiに拡張する場合は相手IDも含めてソート結合に変更する
        return "pair:" + roomID
    }
    
    // 現在のチャットルーム情報
    var currentRoomID: String = ""
    private var currentMyID: String = ""

    // Initialiser hidden
    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func startIfNeeded(roomID: String, myID: String) {
        guard state == .idle else { return }
        
        // ルーム情報を保存
        currentRoomID = roomID
        currentMyID = myID
        log("[P2P] startIfNeeded roomID=\(roomID) myID=\(String(myID.prefix(8))) state=\(state)", category: "P2P")
#if canImport(WebRTC)
        log("[P2P] WebRTC framework present", category: "P2P")
#else
        log("[P2P] WebRTC framework NOT present; using stubs", category: "P2P")
#endif
        
        state = .connecting
        setupPeer()
        // インカメラは相手がオンラインになった時に開始
        schedulePresence()
        maybeExchangeSDP()
    }
    
    // 相手がオンラインになった時に呼び出す
    func startLocalCameraWhenPartnerOnline() {
        guard state == .connecting && localTrack == nil else { return }
        startLocalCamera()
    }

    func close() {
        log("[P2P] close() called. Resetting peer + tracks", category: "P2P")
        presenceTimer?.cancel()
        signalPoller?.cancel()
        capturer?.stopCapture()
        pc?.close()
        pc = nil
        localTrack = nil
        remoteTrack = nil
        state = .idle
    }

    /// ゾーンの変更通知を受けたときにP2Pシグナルを即時確認（ポーリング廃止用フック）
    func onZoneChanged(roomID: String) {
        guard roomID == currentRoomID else { return }
        guard state != .idle else { return }
        Task { @MainActor in
            await self.pollSignalsOnce()
        }
    }

    // MARK: - Presence
    private func schedulePresence() {
        // Presence 機能は非推奨のため、タイマーのみ維持（将来のオンライン検知拡張用）
        presenceTimer = Timer.publish(every: 25, on: .main, in: .common)
            .autoconnect()
            .sink { _ in /* no-op */ }
        log("[P2P] presence timer scheduled (25s) — currently no CK writes", category: "P2P")
    }

    // MARK: - PeerConnection setup
    private func setupPeer() {
        let f = RTCPeerConnectionFactory()
#if canImport(WebRTC)
        var cfg = RTCConfiguration()
        cfg.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        // 公式推奨の Unified Plan を使用
        cfg.sdpSemantics = .unifiedPlan
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
            // CloudKit初期化待ち（所有者判定に必要）
            if CloudKitChatManager.shared.currentUserID == nil {
                while !CloudKitChatManager.shared.isInitialized { try? await Task.sleep(nanoseconds: 100_000_000) }
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
            let result = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: currentRoomID)
            self.signalDB = result.db
            self.signalZoneID = result.zoneID
            log("[P2P] Signal channel ready (zone=\(result.zoneID.zoneName))", category: "P2P")

            // ロール判定（オーナー=Offer側）
            let isOwner = await CloudKitChatManager.shared.isOwnerOfRoom(currentRoomID)
            self.isOwnerRole = (isOwner == true)
            if isOwner {
                await publishOfferIfNeeded()
            }
            // 初期の取りこぼし防止で単発フェッチ。以降はPush通知(onZoneChanged)で駆動
            await pollSignalsOnce()
        } catch {
            log("[P2P] Failed to prepare signal channel: \(error)", category: "P2P")
        }
    }

    private func startSignalPolling() { /* Push駆動へ移行（no-op） */ }

    private func pollSignalsOnce() async {
        guard let db = signalDB, let zoneID = signalZoneID else { return }
        // ダッシュボード設定不要: 既知の固定IDを直接取得
        let offerID = CKRecord.ID(recordName: "RTC_OFFER", zoneID: zoneID)
        let answerID = CKRecord.ID(recordName: "RTC_ANSWER", zoneID: zoneID)
        let remoteCandID = CKRecord.ID(recordName: isOwnerRole ? "RTC_CANDS_participant" : "RTC_CANDS_owner", zoneID: zoneID)
        if let offer = try? await db.record(for: offerID) { await applyOfferRecord(offer) }
        if let answer = try? await db.record(for: answerID) { await applyAnswerRecord(answer) }
        if let cands = try? await db.record(for: remoteCandID) { await applyCandidatesRecord(cands) }
    }

    private func handleSignalRecord(_ rec: CKRecord) async {
        // 旧クエリ経路の互換フック（現行は固定IDフェッチを使用）
        if let kind = rec["kind"] as? String { _ = kind }
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
            await self.saveSignal(kind: "offer", sdp: desc.sdp)
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
            await self.saveSignal(kind: "answer", sdp: desc.sdp)
            log("[P2P] Answer published (pairKey=\(computePairKey(roomID: currentRoomID, myID: currentMyID)))", category: "P2P")
        } catch {
            log("[P2P] createAnswer/setLocalDescription error: \(error)", category: "P2P")
        }
    }
#endif

    private func saveSignal(kind: String, sdp: String? = nil, candidate: RTCIceCandidate? = nil) async {
        guard let db = signalDB, let zoneID = signalZoneID else { return }
        do {
            switch kind {
            case "offer":
                let id = CKRecord.ID(recordName: "RTC_OFFER", zoneID: zoneID)
                let rec = (try? await db.record(for: id)) ?? CKRecord(recordType: "RTCSignal", recordID: id)
                rec["kind"] = "offer" as CKRecordValue
                rec["senderID"] = currentMyID as CKRecordValue
                rec["createdAt"] = Date() as CKRecordValue
                if let sdp { rec["sdp"] = sdp as CKRecordValue }
                _ = try await db.save(rec)
            case "answer":
                let id = CKRecord.ID(recordName: "RTC_ANSWER", zoneID: zoneID)
                let rec = (try? await db.record(for: id)) ?? CKRecord(recordType: "RTCSignal", recordID: id)
                rec["kind"] = "answer" as CKRecordValue
                rec["senderID"] = currentMyID as CKRecordValue
                rec["createdAt"] = Date() as CKRecordValue
                if let sdp { rec["sdp"] = sdp as CKRecordValue }
                _ = try await db.save(rec)
            case "candidate":
                let name = isOwnerRole ? "RTC_CANDS_owner" : "RTC_CANDS_participant"
                let id = CKRecord.ID(recordName: name, zoneID: zoneID)
#if canImport(WebRTC)
                let encoded = encodeCandidate(candidate)
#endif
                var attempt = 0
                while attempt < 3 {
                    do {
                        let rec = (try? await db.record(for: id)) ?? CKRecord(recordType: "RTCSignal", recordID: id)
                        rec["kind"] = "candidates" as CKRecordValue
                        rec["senderID"] = currentMyID as CKRecordValue
                        rec["createdAt"] = Date() as CKRecordValue
#if canImport(WebRTC)
                        var arr = rec["candidates"] as? [String] ?? []
                        if !encoded.isEmpty && !arr.contains(encoded) {
                            arr.append(encoded)
                        }
                        rec["candidates"] = arr as CKRecordValue
#endif
                        _ = try await db.save(rec)
                        break
                    } catch {
                        if let ck = error as? CKError, ck.code == .serverRecordChanged {
                            attempt += 1
                            log("[P2P] saveSignal retry \(attempt)/3 (serverRecordChanged)", category: "P2P")
                            // Exponential backoff: 0.1s, 0.2s, 0.4s
                            let delay = UInt64(pow(2.0, Double(attempt - 1)) * 100_000_000)
                            try? await Task.sleep(nanoseconds: delay)
                            continue
                        } else {
                            throw error
                        }
                    }
                }
            default:
                break
            }
        } catch {
            log("[P2P] saveSignal error: \(error)", category: "P2P")
        }
    }

    // MARK: - Fixed-ID records application
    private func applyOfferRecord(_ rec: CKRecord) async {
#if canImport(WebRTC)
        // 受信側のみ（参加者）
        guard !isOwnerRole else { return }
        if hasSetRemoteDescription { return }
        guard let sdp = rec["sdp"] as? String else { return }
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        do {
            try await self.pc?.setRemoteDescription(desc)
            self.hasSetRemoteDescription = true
            log("[P2P] Remote offer set. Creating answer...", category: "P2P")
            self.startLocalCameraWhenPartnerOnline()
            await self.createAndPublishAnswer()
        } catch {
            log("[P2P] setRemoteDescription(offer) error: \(error)", category: "P2P")
        }
#endif
    }

    private func applyAnswerRecord(_ rec: CKRecord) async {
#if canImport(WebRTC)
        // オーナー側のみ
        guard isOwnerRole else { return }
        if hasSetRemoteDescription { return }
        guard let sdp = rec["sdp"] as? String else { return }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await self.pc?.setRemoteDescription(desc)
            log("[P2P] Remote answer set", category: "P2P")
            self.hasSetRemoteDescription = true
            self.startLocalCameraWhenPartnerOnline()
        } catch {
            log("[P2P] setRemoteDescription(answer) error: \(error)", category: "P2P")
        }
#endif
    }

    private func applyCandidatesRecord(_ rec: CKRecord) async {
#if canImport(WebRTC)
        guard let arr = rec["candidates"] as? [String] else { return }
        for enc in arr {
            if processedCandidates.contains(enc) { continue }
            processedCandidates.insert(enc)
            let cand = decodeCandidate(enc)
            do {
                try await self.pc?.add(cand)
                log("[P2P] Remote ICE candidate added", category: "P2P")
            } catch {
                log("[P2P] add ICE candidate error: \(error)", category: "P2P")
            }
        }
#endif
    }

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
    func ingest(_ record: CKRecord) {
        // Handle ICE and SDP records here.
        log("[P2P] ingest(recordType=\(record.recordType))", category: "P2P")
        
        // 相手のPresenceを検知した時にインカメラを開始
        if record.recordType == "PresenceCK" {
            handlePresenceRecord(record)
        }
    }
    
    private func handlePresenceRecord(_ record: CKRecord) {
        guard let userID = record["userID"] as? String,
              let expires = record["expires"] as? Date else { return }
        
        // 自分のPresenceレコードは無視
        if userID == currentMyID { return }
        
        // 有効期限が切れていない場合、相手がオンライン
        if expires > Date() {
            log("Partner is online, starting local camera", category: "App")
            startLocalCameraWhenPartnerOnline()
        }
    }

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
            switch newState {
            case .connected:
                self.state = .connected
            case .disconnected, .failed, .closed:
                log("[P2P] ICE state changed: \(newState) — tearing down tracks", category: "P2P")
                self.localTrack = nil
                self.remoteTrack = nil
                self.state = (newState == .failed ? .failed : .idle)
            default:
                break
            }
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
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
                log("[P2P] Remote video track received (didAdd stream)", category: "P2P")
                if self.localTrack != nil {
                    FloatingVideoOverlayBridge.activate()
                }
            }
        }
    }
#if canImport(WebRTC)
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
            Task { @MainActor in
                self.remoteTrack = videoTrack
                log("[P2P] Remote video track received (didAdd rtpReceiver)", category: "P2P")
                if self.localTrack != nil {
                    FloatingVideoOverlayBridge.activate()
                }
            }
        }
    }
#endif
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        Task { @MainActor in
            log("[P2P] RTCPeerConnection state changed: \(state)", category: "P2P")
            switch state {
            case .connected:
                self.state = .connected
            case .failed:
                self.state = .failed
                self.localTrack = nil
                self.remoteTrack = nil
            case .disconnected, .closed:
                self.state = .idle
                self.localTrack = nil
                self.remoteTrack = nil
            default:
                break
            }
            if state == .connected {
                await self.cleanupSignalRecords()
            }
        }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            // ICE candidate をCloudKitへ保存（Unified Plan シグナリング）
            await self.saveSignal(kind: "candidate", candidate: candidate)
            log("[P2P] ICE candidate generated (published)", category: "P2P")
        }
    }

    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

// Placeholder bridge used by the overlay to trigger SwiftUI transitions.
enum FloatingVideoOverlayBridge {
    static func activate() {
        // No-op. In real app you might send Combine publisher or NotificationCenter event.
    }
}

extension P2PController {
    private func cleanupSignalRecords() async {
        guard let db = signalDB, let zoneID = signalZoneID else { return }
        let ids = ["RTC_OFFER", "RTC_ANSWER", "RTC_CANDS_owner", "RTC_CANDS_participant"].map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            _ = try await db.modifyRecords(saving: [], deleting: ids)
            log("[P2P] Cleaned up RTCSignal records after connect", category: "P2P")
        } catch {
            // 既に削除済み等は無視
        }
    }
}
