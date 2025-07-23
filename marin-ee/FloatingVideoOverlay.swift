import SwiftUI
import Combine

struct FloatingVideoOverlay: View {
    @ObservedObject private var p2p = P2PController.shared
    @State private var offset: CGSize = .zero
    @State private var isExpanded: Bool = false

    var body: some View {
        if let remote = p2p.remoteTrack,
           let local = p2p.localTrack,
           p2p.state == .connected {
            ZStack(alignment: .topTrailing) {
                RTCVideoView(track: remote)
                    .aspectRatio(9/16, contentMode: .fill)

                RTCVideoView(track: local)
                    .frame(width: 96, height: 128)
                    .mask {
                        RoundedRectangle(cornerRadius: 8).fill(style: .init(eoFill: true))
                    }
                    .padding(8)
            }
            .frame(width: isExpanded ? 240 : 140,
                   height: isExpanded ? 320 : 200)
            .background(Color.black.opacity(0.6))
            .shadow(radius: 4)
            .offset(offset)
            .gesture(DragGesture().onChanged { value in
                offset = value.translation
            })
            .onTapGesture {
                withAnimation(.spring()) {
                    isExpanded.toggle()
                }
            }
            .padding(16)
            .transition(.scale.combined(with: .opacity))
        }
    }
} 