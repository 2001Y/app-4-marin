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
    private var capturer: RTCCameraVideoCapturer?
    private var presenceTimer: AnyCancellable?

    // Initialiser hidden
    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func startIfNeeded() {
        guard state == .idle else { return }
        state = .connecting
        setupPeer()
        startLocalCamera()
        schedulePresence()
        maybeExchangeSDP()
    }

    func close() {
        presenceTimer?.cancel()
        capturer?.stopCapture()
        pc?.close()
        localTrack = nil
        remoteTrack = nil
        state = .idle
    }

    // MARK: - Presence
    private func schedulePresence() {
        // Placeholder: replace with real IDs
        let roomID = "room-placeholder"
        let myID = "my-placeholder"
        presenceTimer = Timer.publish(every: 25, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                CKSync.refreshPresence(roomID, myID)
            }
    }

    // MARK: - PeerConnection setup
    private func setupPeer() {
        let f = RTCPeerConnectionFactory()
#if canImport(WebRTC)
        var cfg = RTCConfiguration()
        cfg.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        // Unified Plan だと addStream が使えないため Plan B へ変更
        cfg.sdpSemantics = .planB
#else
        var cfg = RTCConfiguration()
        cfg.iceServers = []
#endif
        pc = f.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    private func startLocalCamera() {
#if targetEnvironment(simulator)
        // Simulator にはカメラデバイスが無く WebRTC が abort するためスキップ
        return
#else
        guard let pc else { return }
        let f = RTCPeerConnectionFactory()
        let source = f.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: source)
        localTrack = f.videoTrack(with: source, trackId: "local0")
        let stream = f.mediaStream(withStreamId: "stream0")
        if let track = localTrack {
            stream.addVideoTrack(track)
        }
        pc.add(stream)

        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device)
                .first(where: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 640 }),
              let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate else {
            return
        }
        capturer?.startCapture(with: device, format: format, fps: Int(fps/2))
#endif
    }

    // MARK: - SDP Negotiation
    private func maybeExchangeSDP() {
        // Full SDP exchange via CloudKit is out of scope for this sample.
        // Implement your host/guest logic here.
    }

    // MARK: - Record ingestion from CloudKit
    func ingest(_ record: CKRecord) {
        // Handle ICE and SDP records here.
    }
}

extension P2PController: RTCPeerConnectionDelegate {
    // MARK: - Required delegate stubs (empty implementations)
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: - Implemented logic we actually care about
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            Task { @MainActor in
                self.remoteTrack = track
                if self.localTrack != nil {
                    FloatingVideoOverlayBridge.activate()
                }
            }
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        Task { @MainActor in
            self.state = (state == .connected) ? .connected : (state == .failed ? .failed : self.state)
        }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task {
            try? await CKSync.saveCandidate(candidate, roomID: "room-placeholder")
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