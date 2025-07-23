// MARK: - ImagePreviewComponents.swift
// 役割: 画像ギャラリーの横スライダーとフルスクリーンプレビューを提供する。
//       iOS17+ の新しい SwiftUI API (NavigationStack, navigationTransition, scrollTargetBehavior など) を活用し、
//       ライブラリ不要でヒーローアニメーション・ズーム・一括ダウンロードを実現する。
// 責任範囲: UI レイヤーのみ。画像のデータソースは呼び出し側で解決済み `UIImage` 配列を渡す。
//           写真保存は Photos 権限に依存 (Info.plist に NSPhotoLibraryAddUsageDescription が必要)。
//           他レイヤーへの副作用は saveImages(_:) 経由の写真保存のみ。

import SwiftUI

// MARK: - ルート (呼び出し用)
/// 使用例: `ImageSliderRoot(images: uiImagesArray)`
public struct ImageSliderRoot: View {
    private let images: [UIImage]
    @State private var path = NavigationPath()

    public init(images: [UIImage]) {
        self.images = images
    }

    public var body: some View {
        NavigationStack(path: $path) {
            HorizontalSliderView(images: images)
                .navigationTitle("Gallery")
                .navigationDestination(for: Int.self) { index in
                    FullScreenPreviewView(images: images, startIndex: index)
                        .navigationBarBackButtonHidden(true)
                        /* カスタム遷移を使う場合は以下を有効化 (要 @Namespace)
                         .navigationTransition(.scale)
                        */
                }
        }
    }
}

// MARK: - 横スライダー (Filmstrip)
struct HorizontalSliderView: View {
    let images: [UIImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(Array(images.indices), id: \.self) { i in
                    NavigationLink(value: i) {
                        Image(uiImage: images[i])
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }
            }
            .padding()
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - フルスクリーンプレビュー
struct FullScreenPreviewView: View {
    let images: [UIImage]
    @State private var page: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirm = false
    // 縦ドラッグによるインタラクティブディスミス
    @State private var dragTranslation: CGSize = .zero // gesture translation
    @State private var currentIndex: Int
    private let dismissThreshold: CGFloat = 120

    init(images: [UIImage], startIndex: Int) {
        self.images = images
        _currentIndex = State(initialValue: startIndex)
        _page = State(initialValue: startIndex)
    }

    var body: some View {
        GeometryReader { geo in
            // 背景ブラー
            Rectangle()
                .background(.ultraThinMaterial)
                .overlay(Color.black.opacity( backgroundOpacity()))
                .ignoresSafeArea()

            // ---- カスタム横ページング ----
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(Array(images.indices), id: \ .self) { idx in
                    ZoomableImage(image: images[idx])
                        .frame(width: width, height: geo.size.height)
                }
            }
            .offset(x: -CGFloat(currentIndex) * width + dragTranslation.width,
                    y: dragTranslation.height)
            .scaleEffect(scaleForDrag())
            .highPriorityGesture(
                DragGesture()
                    .onChanged { value in
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height

                        if abs(dx) > abs(dy) {
                            // 横スワイプ
                            let threshold = width * 0.25
                            var newIndex = currentIndex
                            if dx < -threshold { newIndex = min(newIndex + 1, images.count - 1) }
                            if dx >  threshold { newIndex = max(newIndex - 1, 0) }
                            withAnimation(.spring()) {
                                currentIndex = newIndex
                                dragTranslation = .zero
                            }
                        } else {
                            // 縦スワイプ
                            if abs(dy) > dismissThreshold {
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    dragTranslation = .zero
                                }
                            }
                        }
                    }
            )

            // 閉じる・保存ボタン
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.regularMaterial)
                    }
                    Spacer()
                    Button(action: downloadTapped) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title)
                            .foregroundStyle(.regularMaterial)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                Spacer()
            }

            // 保存確認アラート
            .alert("すべてダウンロードしますか？", isPresented: $showConfirm) {
                Button("ダウンロード", role: .destructive) { saveAll() }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("\(images.count) 件の画像を保存")
            }
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled()
    }

    // MARK: - 保存処理
    private func downloadTapped() {
        images.count == 1 ? save(images[0]) : (showConfirm = true)
    }
    private func saveAll() { images.forEach(save) }
    private func save(_ img: UIImage) {
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
    }

    // MARK: - Helpers
    private func scaleForDrag() -> CGFloat {
        // 横より縦移動が優勢の時のみスケールダウン
        let dx = abs(dragTranslation.width)
        let dy = abs(dragTranslation.height)
        guard dy > dx else { return 1 }
        return max(0.80, 1 - dy / 900)
    }

    private func backgroundOpacity() -> Double {
        // 0.25 → 0 にフェード
        let progress = min(abs(dragTranslation.height) / dismissThreshold, 1)
        return 0.25 * (1 - Double(progress))
    }
}

// MARK: - ズーム可能画像
struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .modifier(ZoomGestureModifier(scale: $scale, offset: $offset))
            .phaseAnimator([1, 2]) { content, _ in
                content
                    .animation(.bouncy, value: scale)
            }
            .ignoresSafeArea()
    }
}

// MARK: - ズーム & ドラッグ Gesture
private struct ZoomGestureModifier: ViewModifier {
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    func body(content: Content) -> some View {
        content
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale = max($0, 1) }
                        .onEnded { _ in if scale < 1 { scale = 1 } },
                    DragGesture()
                        .onChanged { g in
                            if scale > 1.01 {
                                offset = g.translation
                            }
                        }
                        .onEnded { _ in
                            if scale <= 1.01 {
                                offset = .zero // reset
                            }
                        }
                )
            )
    }
} 