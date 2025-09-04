import SwiftUI
import SwiftData
import AVKit
import AVFoundation

// 特徴ページ（旧: ウェルカム画面）
struct FeaturesPage: View {
    @AppStorage("hasSeenFeatures") private var hasSeenFeatures: Bool = false
    @AppStorage("myDisplayName") private var myDisplayName: String = ""
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
            let bgHeight = width * (375.0/1177.0)
            ZStack {
                // 背景画像（アセットのbg.pdf）。アスペクト比を固定して上部に配置
                Image("bg")
                    .resizable()
                    .frame(width: width, height: bgHeight)
                    .ignoresSafeArea(edges: .top)
                    .frame(maxWidth: .infinity, alignment: .top)

                ScrollView {
                    VStack(spacing: 16) {
                        VideoLogoView()
                            .frame(width: width * 0.8)
                            .offset(y: -15) // 少し上に詰める
                            .frame(maxWidth: .infinity)

                        Spacer().frame(height: 1)

                        VStack(spacing: 6) {
                            // タイトル画像（アセットのAny/Darkバリアントで自動切替）
                            if UIImage(named: "Title") != nil {
                                Image("Title")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: width * 0.45)
                                    .frame(maxWidth: .infinity)
                            } else {
                                // フォールバック: テキスト
                                Text("4-Marin")
                                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                                    .frame(maxWidth: .infinity)
                            }

                            Text("はなれていても、\nいっしょに開くと顔が見える特別なメッセージ")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal)
                        }

                        FeatureCardsView()
                            .padding(.top, 8)
                        
                        // Bottom spacing for fixed button
                        Spacer()
                            .frame(height: 100)
                    }
                    .padding(.horizontal)
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
                            // 名前が未設定なら名前入力、設定済みなら統合シート
                            let name = myDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if name.isEmpty {
                                showNameSheet = true
                            } else {
                                showInviteSheet = true
                            }
                        } label: { startButtonLabel(width: width) }
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
            }, onJoined: {
                // 参加完了後のUI更新が必要ならここで
            }, onOpenQR: {
                // 排他のため一旦閉じてからQRを開く
                showInviteSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    showQRScanner = true
                }
            })
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet(isPresented: $showQRScanner) {
                // 受諾後にアップデートし、ルートへ遷移（チャットリスト/チャットへ）
                MessageSyncService.shared.checkForUpdates()
                onDismiss?()
            }
        }
        .onAppear { }
    }
}

// 下部のぼかし・ホワイトグラデ背景だけを独立させて型チェック負荷を軽減
private struct BottomFadeBackground: View {
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
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.white.opacity(0), location: 0),
                        .init(color: Color.white.opacity(0.3), location: 0.15),
                        .init(color: Color.white.opacity(0.7), location: 0.5),
                        .init(color: Color.white.opacity(0.9), location: 0.85),
                        .init(color: Color.white, location: 1)
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
    AnyView(
    Text("はじめる")
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: width * 0.7, height: 52)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 1.0, green: 0.2196, blue: 0.4863), // #FF387C
                    Color(red: 1.0, green: 0.4, blue: 0.2)       // #FF6633 (#F63)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        .shadow(color: Color(red: 1.0, green: 0.4, blue: 0.6).opacity(0.3), radius: 12, x: 0, y: 6)
        .overlay(alignment: .topTrailing) {
            if UIImage(named: "button-highlight-line-topright") != nil {
                Image("button-highlight-line-topright")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .allowsHitTesting(false)
                    .offset(x: -5, y: 5)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if UIImage(named: "button-highlight-line-bottomleft") != nil {
                Image("button-highlight-line-bottomleft")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .allowsHitTesting(false)
                    .offset(x: -5, y: 5)
            }
        }
    )
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
