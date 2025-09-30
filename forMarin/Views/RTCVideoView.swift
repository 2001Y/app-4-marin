import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif

struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    final class Coordinator {
        var currentTrack: RTCVideoTrack?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        // 初期割り当て
        context.coordinator.currentTrack = track
        track.add(v)
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // トラックが差し替わった場合は古いレンダラを解除してから新規追加
        if let prev = context.coordinator.currentTrack, prev != track {
            prev.remove(uiView)
        }
        track.add(uiView)
        context.coordinator.currentTrack = track
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        // SwiftUI 破棄時にレンダラを確実に解除
        coordinator.currentTrack?.remove(uiView)
        coordinator.currentTrack = nil
    }
}
