// MARK: - ImagePreviewComponents.swift
// 役割: 画像ギャラリーの横スライダーとフルスクリーンプレビューを提供する。
//       iOS17+ の新しい SwiftUI API (NavigationStack, navigationTransition, scrollTargetBehavior など) を活用し、
//       ライブラリ不要でヒーローアニメーション・ズーム・一括ダウンロードを実現する。
// 責任範囲: UI レイヤーのみ。画像のデータソースは呼び出し側で解決済み `UIImage` 配列を渡す。
//           写真保存は Photos 権限に依存 (Info.plist に NSPhotoLibraryAddUsageDescription が必要)。
//           他レイヤーへの副作用は saveImages(_:) 経由の写真保存のみ。

import SwiftUI
import AVKit
import PhotosUI

// MARK: - ルート (呼び出し用)
/// 使用例: `ImageSliderRoot(images: uiImagesArray)`
/// NavigationStackが必要な場合にのみ使用。fullScreenCoverなどでは直接FullScreenPreviewViewを使用。
public struct ImageSliderRoot: View {
    private let images: [UIImage]
    @State private var path = NavigationPath()

    public init(images: [UIImage] = []) {
        self.images = images
    }

    public var body: some View {
        NavigationStack(path: $path) {
            HorizontalSliderView(images: images)
                .navigationTitle("Gallery")
                // FIXME: 一時的にコメントアウト - navigationDestinationエラーのデバッグ用
                /*
                .navigationDestination(for: Int.self) { index in
                    FullScreenPreviewView(images: images, startIndex: index)
                        .navigationBarBackButtonHidden(true)
                        /* カスタム遷移を使う場合は以下を有効化 (要 @Namespace)
                         .navigationTransition(.scale)
                        */
                }
                */
        }
    }
}

// MARK: - 横スライダー (Filmstrip)
struct HorizontalSliderView: View {
    let images: [UIImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(images.indices, id: \.self) { i in
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

// MARK: - フルスクリーンプレビュー (NavigationStack不要の独立コンポーネント)
public struct FullScreenPreviewView: View {
    let images: [UIImage]
    let mediaItems: [MediaItem]? // 画像・動画混在配列（オプション）
    @State private var page: Int
    @Environment(\.dismiss) private var dismissEnv
    @State private var showConfirm = false
    @State private var showActionSheet = false
    @State private var toastMessage: String? = nil
    // 縦ドラッグによるインタラクティブディスミス
    @State private var dragTranslation: CGSize = .zero // gesture translation
    @State private var currentIndex: Int
    @State private var shouldAutoPlayVideo: Bool = true
    private let dismissThreshold: CGFloat = 120
    // overlay 表示時用の手動ディスミスクロージャ（fullScreenCover では nil）
    var onDismiss: (() -> Void)? = nil

    // ヒーローアニメーション用
    var namespace: Namespace.ID? = nil
    var geometryIDs: [String]? = nil

    public init(images: [UIImage] = [], startIndex: Int, onDismiss: (() -> Void)? = nil, namespace: Namespace.ID? = nil, geometryIDs: [String]? = nil, mediaItems: [MediaItem]? = nil) {
        self.images = images
        self.mediaItems = mediaItems
        _currentIndex = State(initialValue: startIndex)
        _page = State(initialValue: startIndex)
        self.onDismiss = onDismiss
        self.namespace = namespace
        self.geometryIDs = geometryIDs
    }

    public var body: some View {
        GeometryReader { geo in
            // 背景: 黒 + 軽いブラー
            Rectangle()
                .background(.thinMaterial)
                .overlay(Color.black.opacity(backgroundOpacity()))
                .ignoresSafeArea(.all, edges: .all)

            // ---- カスタム横ページング ----
            let width = geo.size.width
            HStack(spacing: 0) {
                if let mediaItems = mediaItems {
                    // 画像・動画混在プレビュー
                    ForEach(Array(mediaItems.indices), id: \.self) { idx in
                        switch mediaItems[idx] {
                        case .image(let image):
                            ZoomableImage(
                                image: image,
                                namespace: namespace,
                                geometryID: geometryIDs?[idx]
                            )
                            .frame(width: width, height: geo.size.height)
                        case .video(let videoURL):
                            ZoomableVideo(
                                videoURL: videoURL,
                                namespace: namespace,
                                geometryID: geometryIDs?[idx],
                                autoPlay: shouldAutoPlayVideo && idx == currentIndex
                            )
                            .frame(width: width, height: geo.size.height)
                        }
                    }
                } else {
                    // 従来の画像プレビュー
                    ForEach(images.indices, id: \.self) { idx in
                        ZoomableImage(
                            image: images[idx],
                            namespace: namespace,
                            geometryID: geometryIDs?[idx]
                        )
                        .frame(width: width, height: geo.size.height)
                    }
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
                            if dx < -threshold { newIndex = min(newIndex + 1, (mediaItems?.count ?? images.count) - 1) }
                            if dx >  threshold { newIndex = max(newIndex - 1, 0) }
                            withAnimation(.spring()) {
                                currentIndex = newIndex
                                dragTranslation = .zero
                            }
                            // ページ切り替え時に動画の再生状態を管理
                            handlePageChange(to: newIndex)
                        } else {
                            // 縦スワイプ
                            if abs(dy) > dismissThreshold {
                                dismissAction()
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
                        dismissAction()
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

            // Toast overlay
            if let msg = toastMessage {
                Text(msg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { toastMessage = nil }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 60)
            }
        }
        // 保存確認アラート / ActionSheet
        .confirmationDialog("表示してるメディアのみ\n\(mediaItems?.count ?? images.count)件をダウンロード", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("ダウンロード") { saveAll() }
            Button("キャンセル", role: .cancel) { }
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled()
    }

    // MARK: - 保存処理
    private func downloadTapped() {
        if let mediaItems = mediaItems {
            // 画像・動画混在の場合
            if mediaItems.count == 1 {
                saveMediaItem(mediaItems[0])
            } else {
                showConfirm = true
            }
        } else {
            // 従来の画像のみの場合
            if images.count == 1 {
                save(images[0])
            } else {
                showConfirm = true
            }
        }
    }
    private func saveAll() { 
        if let mediaItems = mediaItems {
            // 画像・動画混在の場合
            mediaItems.forEach(saveMediaItem)
        } else {
            // 従来の画像のみの場合
            for image in images {
                save(image)
            }
        }
    }
    private func save(_ img: UIImage) {
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        withAnimation { toastMessage = "ダウンロードしました" }
    }
    private func saveMediaItem(_ item: MediaItem) {
        switch item {
        case .image(let image):
            save(image)
        case .video(let url):
            saveVideo(url)
        }
    }
    
    private func saveVideo(_ url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    withAnimation { toastMessage = "動画をダウンロードしました" }
                } else {
                    withAnimation { toastMessage = "動画のダウンロードに失敗しました" }
                }
            }
        }
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
        // 0.15 → 0 へフェード (以前より軽め)
        let progress = min(abs(dragTranslation.height) / dismissThreshold, 1)
        return 0.15 * (1 - Double(progress))
    }
}

// MARK: - ズーム可能画像
struct ZoomableImage: View {
    let image: UIImage
    var namespace: Namespace.ID? = nil
    var geometryID: String? = nil
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .matchedGeometryEffect(id: geometryID ?? "", in: namespace ?? Namespace().wrappedValue)
            .modifier(ZoomGestureModifier(scale: $scale, offset: $offset))
            .phaseAnimator([1, 2]) { content, _ in
                content
                    .animation(.bouncy, value: scale)
            }
            .ignoresSafeArea(.all, edges: .all)
    }
}

// MARK: - ズーム可能動画
struct ZoomableVideo: View {
    let videoURL: URL
    var namespace: Namespace.ID? = nil
    var geometryID: String? = nil
    var autoPlay: Bool = true
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var isLooping: Bool = true

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .matchedGeometryEffect(id: geometryID ?? "", in: namespace ?? Namespace().wrappedValue)
                .modifier(ZoomGestureModifier(scale: $scale, offset: $offset))
                .phaseAnimator([1, 2]) { content, _ in
                    content
                        .animation(.bouncy, value: scale)
                }
                .ignoresSafeArea(.all, edges: .all)
                .onTapGesture {
                    // タップで再生/一時停止を切り替え
                    togglePlayback()
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    // 長押しでループ再生のON/OFFを切り替え
                    toggleLoopPlayback()
                }
            
            // 再生/一時停止ボタン（オーバーレイ）
            if !isPlaying {
                Button(action: togglePlayback) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.3)))
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
        .onChange(of: autoPlay) { _, newValue in
            if newValue && !isPlaying {
                player?.play()
                isPlaying = true
            } else if !newValue && isPlaying {
                player?.pause()
                isPlaying = false
            }
        }
    }
    
    private func setupPlayer() {
        player = AVPlayer(url: videoURL)
        
        // ループ再生を設定
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            if isLooping {
                player?.seek(to: .zero)
                player?.play()
            }
        }
        
        // 音量を0に設定（無音再生）
        player?.volume = 0.0
        
        // 自動再生開始（autoPlayがtrueの場合のみ）
        if autoPlay {
            player?.play()
            isPlaying = true
        }
    }
    
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        isPlaying = false
        NotificationCenter.default.removeObserver(self)
    }
    
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
    }
    
    private func toggleLoopPlayback() {
        isLooping.toggle()
        // ループ設定の変更をユーザーに通知
        // ここでトーストメッセージを表示する場合は、親ビューに通知
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

// MARK: - 内部ユーティリティ
extension FullScreenPreviewView {
    private func dismissAction() {
        if let manual = onDismiss {
            manual()
        } else {
            dismissEnv()
        }
    }
    
    private func handlePageChange(to newIndex: Int) {
        // ページ切り替え時に動画の自動再生状態を更新
        shouldAutoPlayVideo = true
        
        // 新しいページが動画の場合、少し遅延してから再生開始
        if let mediaItems = mediaItems, newIndex < mediaItems.count {
            if case .video = mediaItems[newIndex] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    shouldAutoPlayVideo = true
                }
            }
        }
    }
}