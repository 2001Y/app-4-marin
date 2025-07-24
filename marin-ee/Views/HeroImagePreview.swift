import SwiftUI

/// 単一画像用ヒーロープレビュー。サムネイルと同じ `matchedGeometryEffect` id を共有して全画面化し、
/// 下方向 Drag でインタラクティブに閉じられる。
struct HeroImagePreview: View {
    let image: UIImage
    let geometryID: String
    var namespace: Namespace.ID
    var onDismiss: () -> Void

    // Drag
    @GestureState private var dragState: CGSize = .zero
    private let dismissThreshold: CGFloat = 120

    // アクションボタン表示
    @State private var showActions: Bool = false
    @State private var toast: String? = nil

    private var dragProgress: CGFloat {
        let dy = abs(dragState.height)
        return min(dy / dismissThreshold, 1)
    }

    var body: some View {
        ZStack {
            // 背景 (黒+薄ブラー) - ドラッグで薄く
            Rectangle()
                .fill(Color.black.opacity(Double(0.15 * (1 - dragProgress))))
                .background(.thinMaterial)
                .ignoresSafeArea()
                .onTapGesture { close() }

            // 画像本体
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .matchedGeometryEffect(id: geometryID, in: namespace)
                .offset(dragState)
                .scaleEffect(1 - 0.2 * dragProgress)
                .gesture(
                    DragGesture()
                        .updating($dragState) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            if abs(value.translation.height) > dismissThreshold {
                                close()
                            }
                        }
                )

            // アクション (遅延フェードイン)
            if showActions {
                VStack {
                    HStack {
                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.regularMaterial)
                        }
                        Spacer()
                        Button {
                            saveImage()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title)
                                .foregroundStyle(.regularMaterial)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                    Spacer()
                }
                .transition(.opacity)
            }

            // Toast
            if let msg = toast {
                Text(msg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { toast = nil }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 60)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            // 少し遅らせてボタンをフェードイン
            withAnimation(.easeInOut.delay(0.3)) { showActions = true }
        }
    }

    private func close() {
        withAnimation(.spring()) {
            showActions = false
        }
        // 少し遅らせないとボタンが一瞬残る場合がある
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDismiss()
        }
    }

    private func saveImage() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { toast = "ダウンロードしました" }
    }
}