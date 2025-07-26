import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif

struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        RTCMTLVideoView()
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        track.add(uiView)
    }
} 