import SwiftUI
import SwiftData
import AVKit
import AVFoundation

struct PairingView: View {
    @State private var showWelcomeModal = false
    @State private var showInviteModal = false
    @State private var showNameSheet = false
    @State private var showQRScanner = false
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
            ZStack {
                // Top blur background
                VStack {
                    ZStack {
                        // Progressive background blur for top
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: Color.black, location: 0),
                                        .init(color: Color.black.opacity(0.8), location: 0.3),
                                        .init(color: Color.black.opacity(0.3), location: 0.7),
                                        .init(color: Color.clear, location: 1)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        // White overlay gradient for top
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.white, location: 0),
                                .init(color: Color.white.opacity(0.95), location: 0.3),
                                .init(color: Color.white.opacity(0.7), location: 0.7),
                                .init(color: Color.white.opacity(0), location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(height: 120)
                    .ignoresSafeArea(.all, edges: .top)
                    
                    Spacer()
                }
                
                ScrollView {
                    VStack(spacing: 24) {
                        VideoLogoView()
                            .frame(width: geometry.size.width * 0.8)
                            .frame(maxWidth: .infinity)
                        
                        Spacer()
                            .frame(height: 10)

                        VStack(spacing: 12) {
                            Text("4-Marin")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .frame(maxWidth: .infinity)
                            
                            Text("はなれていても、\nいっしょに開くと顔が見える特別なメッセージ")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal)
                        }

                        FeatureCardsView()
                            .padding(.top, 24)
                        
                        // Bottom spacing for fixed button
                        Spacer()
                            .frame(height: 100)
                    }
                    .padding(.horizontal)
                    .padding(.top, -20)
                }
                
                // Fixed bottom button with blur background
                ZStack {
                    // Background gradient (最背面)
                    VStack {
                        Spacer()
                        
                        ZStack {
                            // Progressive background blur - height doubled
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
                            
                            // White overlay gradient - height doubled
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
                    
                    // Buttons (前面)
                    VStack {
                        Spacer()
                        
                        Button {
                            // 触覚フィードバック
                            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                            impactFeedback.impactOccurred()
                            // 名前入力のハーフモーダルを表示
                            showNameSheet = true
                        } label: {
                            Text("はじめる")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: geometry.size.width * 0.8, height: 52)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color(red: 1.0, green: 0.4, blue: 0.6),
                                            Color(red: 1.0, green: 0.5, blue: 0.7),
                                            Color(red: 0.9, green: 0.4, blue: 0.8)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                                .shadow(color: Color(red: 1.0, green: 0.4, blue: 0.6).opacity(0.3), radius: 12, x: 0, y: 6)
                        }
                        .padding(.bottom, 20)
                        
                        // 招待をされる（QR読取）
                        Button {
                            // 触覚フィードバック
                            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                            impactFeedback.impactOccurred()
                            showQRScanner = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 16))
                                Text("招待をされる")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            
            // ウェルカムモーダルオーバーレイ
            WelcomeModalOverlay(isPresented: $showWelcomeModal) {
                // 「つづける」ボタンが押された時の処理（モーダルを閉じるだけ）
            }
        }
        .background(Color.white)
        .colorScheme(.light)
        .sheet(isPresented: $showInviteModal) {
            InviteModalView(onChatCreated: onChatCreated)
        }
        .sheet(isPresented: $showNameSheet) {
            NameInputSheet(isPresented: $showNameSheet)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet(isPresented: $showQRScanner) {
                // 受諾後にアップデート
                MessageSyncService.shared.checkForUpdates()
            }
        }
        .onAppear {
            if showWelcomeModalOnAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showWelcomeModal = true
                }
            }
        }
    }
}

struct VideoLogoView: View {
    @State private var player: AVPlayer?
    @State private var videoAspectRatio: CGFloat = 1.0
    @State private var loopTimer: Timer?
    
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
            loopTimer?.invalidate()
            loopTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            startPlayback()
        }
    }
    
    private func setupPlayer() {
        guard player == nil else { return } // Prevent recreating player
        
        guard let videoURL = Bundle.main.url(forResource: "logo", withExtension: "mov") else {
            log("logo.mp4 not found in bundle", category: "App")
            return
        }
        
        let asset = AVAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = true // Mute to allow autoplay
        newPlayer.actionAtItemEnd = .none
        player = newPlayer
        
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
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            // 3秒後に再開
            loopTimer?.invalidate()
            loopTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                newPlayer.seek(to: .zero)
                newPlayer.play()
            }
        }
    }
    
    private func startPlayback() {
        guard let player = player else { return }
        
        // Start playback immediately and let AVPlayer handle readiness
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            player.seek(to: .zero)
            player.play()
        }
    }
}

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let aspectRatio: CGFloat
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
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
                    .foregroundColor(.orange)
                
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
                        .frame(height: 300)
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
        .background(Color.clear)
    }
}

struct FeatureItem {
    let number: String
    let title: String
}
