import SwiftUI
import SwiftData
import AVKit
import AVFoundation

// 特徴ページ（旧: ウェルカム画面）
struct FeaturesPage: View {
    @AppStorage("myDisplayName") private var myDisplayName: String = ""
    // CloudKitから取得した表示名（RootViewと同じ判定基準を使用）
    @State private var myDisplayNameCloud: String? = nil
    @State private var showWelcomeModal = false
    @State private var showNameSheet = false
    @State private var showQRScanner = false
    @State private var showInviteSheet = false
    @Environment(\.modelContext) private var modelContext
    var onChatCreated: (ChatRoom) -> Void
    var onDismiss: (() -> Void)?
    private let showWelcomeModalOnAppear: Bool
    
    init(showWelcomeModalOnAppear: Bool = false, onChatCreated: @escaping (ChatRoom) -> Void, onDismiss: (() -> Void)? = nil) {
        self.showWelcomeModalOnAppear = showWelcomeModalOnAppear
        self.onChatCreated = onChatCreated
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .top) {
                // 背景：セーフエリアを無視してtop0・全幅固定
                Image("bg")
                    .resizable()
                    .aspectRatio(1177.0/375.0, contentMode: .fit)
                    .frame(width: width)
                    .ignoresSafeArea(edges: .top)
                ScrollView {
                    VStack(spacing: 8) {
                        // 背景はZStack背面に常設済み
                        VideoLogoView()
                            .frame(width: width * 0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 20)

                        // タイトル〜カードをまとめたPDF（Any/Darkバリアント）
                        if UIImage(named: "featuresCard") != nil {
                            Image("featuresCard")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: width)
                                .frame(maxWidth: .infinity)
                        }
                        
                        // Bottom spacing for fixed button
                        Spacer().frame(height: 100)
                    }
                    .padding(.top, -20)
                }
                
                // Fixed bottom button with blur background
                ZStack {
                    BottomFadeBackground()
                    
                    // Buttons (前面)
                    VStack {
                        Spacer()
                        
                        Button {
                            // 触覚フィードバック
                            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                            impactFeedback.impactOccurred()
                            // CloudKitの表示名で判定（RootViewと同じ基準、フォールバックなし）
                            let name = myDisplayNameCloud?.trimmingCharacters(in: .whitespacesAndNewlines)
                            if name?.isEmpty ?? true {
                                showNameSheet = true
                            } else {
                                showInviteSheet = true
                            }
                        } label: { startButtonLabel(width: width) }
                        .keyboardShortcut("n", modifiers: .command)
                        .padding(.bottom, 21)
                        
                        // 「招待を受ける」ボタンは削除。名前入力後に統合シートで選択させる
                    }
                }
            }
            // RootView 側でウェルカムモーダルを重ねるため、ここでは表示しない
        }
        .background(Color(UIColor.systemBackground))
        .sheet(isPresented: $showNameSheet) {
            // 名前登録完了後は統合シートへ誘導（機能ページは維持）
            NameInputSheet(isPresented: $showNameSheet, onSaved: { showInviteSheet = true })
        }
        .sheet(isPresented: $showInviteSheet) {
            InviteUnifiedSheet(onChatCreated: { room in
                // 作成時は親に通知（RootViewが遷移を担当）
                onChatCreated(room)
            }, onJoined: nil)
        }
        .task(id: myDisplayNameCloud == nil) {
            // CloudKitから表示名を取得（RootViewと同じ処理）
            if myDisplayNameCloud == nil {
                let name = await CloudKitChatManager.shared.fetchMyDisplayNameFromCloud()
                await MainActor.run { self.myDisplayNameCloud = name }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .displayNameUpdated)) { notif in
            // 表示名更新の通知を受けて、即座に判定を更新
            if let name = notif.userInfo?["name"] as? String {
                myDisplayNameCloud = name
            } else {
                // name未添付ならクラウド再フェッチ
                Task {
                    let name = await CloudKitChatManager.shared.fetchMyDisplayNameFromCloud()
                    await MainActor.run { self.myDisplayNameCloud = name }
                }
            }
        }
        .onAppear { }
    }
}

// 下部のぼかし・ホワイトグラデ背景だけを独立させて型チェック負荷を軽減
private struct BottomFadeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack {
            Spacer()
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.clear, location: 0),
                                .init(color: Color.black.opacity(0.1), location: 0.1),
                                .init(color: Color.black.opacity(0.3), location: 0.35),
                                .init(color: Color.black.opacity(0.8), location: 0.75),
                                .init(color: Color.black.opacity(0.9), location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                let base = (colorScheme == .dark) ? Color.black : Color.white
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: base.opacity(0), location: 0),
                        .init(color: base.opacity(0.3), location: 0.15),
                        .init(color: base.opacity(0.7), location: 0.5),
                        .init(color: base.opacity(0.9), location: 0.85),
                        .init(color: base, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 200)
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }
}

// ボタンラベルを関数分割
private func startButtonLabel(width: CGFloat) -> AnyView {
    if UIImage(named: "startButton") != nil {
        return AnyView(
            Image("startButton")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width * 0.75)
                // 以前のグラデボタンと同等の影を付与
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                .shadow(color: Color(red: 1.0, green: 0.4, blue: 0.6).opacity(0.3), radius: 12, x: 0, y: 6)
                .accessibilityLabel(Text("はじめる"))
                .contentShape(Rectangle())
        )
    } else {
        return AnyView(
            Text("はじめる")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: width * 0.75, height: 52)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                .shadow(color: Color(red: 1.0, green: 0.4, blue: 0.6).opacity(0.3), radius: 12, x: 0, y: 6)
        )
    }
}

struct VideoLogoView: View {
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var videoAspectRatio: CGFloat = 1.0
    
    var body: some View {
        Group {
            if let player = player {
                VideoPlayerView(player: player, aspectRatio: videoAspectRatio)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
            } else {
                Image("AppLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .onAppear {
            setupPlayer()
            startPlayback()
        }
        .onDisappear {
            player?.pause()
    }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            startPlayback()
        }
    }
    
    private func setupPlayer() {
        guard player == nil else { return } // Prevent recreating player

        guard let videoURL = Bundle.main.url(forResource: "logo", withExtension: "mov") else {
            log("logo.mov not found in bundle", category: "App")
            return
        }

        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["playable", "tracks", "duration"]
        )
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .none
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        self.player = queue
        self.looper = looper
        
        // Get video aspect ratio
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let videoTrack = tracks.first {
                    let size = try await videoTrack.load(.naturalSize)
                    let transform = try await videoTrack.load(.preferredTransform)
                    
                    // Apply transform to get correct dimensions
                    let videoSize = size.applying(transform)
                    let aspectRatio = abs(videoSize.width) / abs(videoSize.height)
                    
                    await MainActor.run {
                        self.videoAspectRatio = aspectRatio
                    }
                }
            } catch {
                log("Error loading video properties: \(error)", category: "App")
            }
        }
        
        // Setup looping with 3-second delay
        // ループは AVPlayerLooper に任せる（公式推奨）
    }
    
    private func startPlayback() {
        guard let player = player else { return }
        // 再生はレイヤーの描画準備完了時に自動開始（VideoPlayerView側で実行）
        // ここでは先頭へシークのみ（冪等）
        player.seek(to: .zero)
    }
}

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let aspectRatio: CGFloat

    class Coordinator {
        var readyObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.backgroundColor = UIColor.clear.cgColor
        view.layer.addSublayer(playerLayer)

        // 描画準備が整ったら再生開始
        context.coordinator.readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            if layer.isReadyForDisplay {
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let playerLayer = uiView.layer.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = uiView.bounds
        }
    }
}


struct FeatureCardsView: View {
    let features = [
        FeatureItem(number: "1.", title: "一緒に開いてる時ぐらい\n顔をみて話そうよ。"),
        FeatureItem(number: "2.", title: "景色だけじゃだめ！\nあなたも映らなきゃ"),
        FeatureItem(number: "3.", title: "\"キドク\"じゃない\n\"おもい\"をリアクション"),
        FeatureItem(number: "4.", title: "ふたりで待ち望んで、\nふたりでふりかえる。")
    ]
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ], spacing: 6) {
            ForEach(features.indices, id: \.self) { index in
                FeatureCardView(feature: features[index], index: index)
            }
        }
    }
}

struct FeatureCardView: View {
    let feature: FeatureItem
    let index: Int
    
    var body: some View {
        VStack(spacing: 0) {
            // Number and title section
            HStack(alignment: .top, spacing: 8) {
                Text(feature.number)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.972, green: 0.369, blue: 0.145))
                
                Text(feature.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 5)
            .padding(.top, 10)
            
            Spacer()
                .frame(height: 4)
            
            // Feature image section
            VStack {
                if let image = UIImage(named: "feature-\(index + 1).jpg") {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 250)
                        .overlay(
                            Text("feature-\(index + 1).jpg")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        )
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 8)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(red: 0.898, green: 0.898, blue: 0.898), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.systemBackground))
                )
        )
    }
}

struct FeatureItem {
    let number: String
    let title: String
}
