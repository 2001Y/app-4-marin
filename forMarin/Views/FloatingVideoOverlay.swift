import SwiftUI
import Combine

struct FloatingVideoOverlay: View {
    @ObservedObject private var p2p = P2PController.shared
    @State private var offset: CGSize = .zero
    @State private var isExpanded: Bool = false

    var body: some View {
        // 仕様変更: リモートが未着でもローカルがあればプレビューを表示
        if let remote = p2p.remoteTrack ?? p2p.localTrack {
            ZStack(alignment: .topTrailing) {
                RTCVideoView(track: remote)
                    .aspectRatio(9/16, contentMode: .fill)

                // リモートが主画面のときのみローカルPiPを重ねる
                if p2p.remoteTrack != nil, let local = p2p.localTrack {
                    RTCVideoView(track: local)
                        .frame(width: 96, height: 128)
                        .mask {
                            RoundedRectangle(cornerRadius: 8).fill(style: .init(eoFill: true))
                        }
                        .padding(8)
                }

                // システムPiPは不採用。ボタン表示なし（要件）
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
