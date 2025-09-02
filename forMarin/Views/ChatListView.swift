import SwiftUI
import SwiftData
import AVKit
import AVFoundation
import CloudKit

struct ChatListView: View {
    @Query(sort: \ChatRoom.lastMessageDate, order: .reverse) private var chatRooms: [ChatRoom]
    @Environment(\.modelContext) private var modelContext
    @State private var showInviteModal = false
    @State private var showQRInvite = false
    var onChatSelected: (ChatRoom) -> Void
    @State private(set) var showingSettings = false
    @State private(set) var selectedChatRoom: ChatRoom?
    
    init(onChatSelected: @escaping (ChatRoom) -> Void) {
        self.onChatSelected = onChatSelected
    }
    // パフォーマンス最適化: 未読数計算をmemoizeで最適化
    private var totalUnreadCount: Int {
        chatRooms.lazy.reduce(0) { $0 + $1.unreadCount }
    }
    
    var body: some View {
        VStack(spacing: 0) {
                
                // カスタムヘッダー
                HStack(alignment: .center) {
                    // 左側：アイコンとアプリ名
                    HStack(alignment: .center, spacing: 12) {
                        ChatListVideoLogoView(size: 72)
                        
                        Text("4-Marin")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                        
                        // アニメーション付き未読バッジ
                        if totalUnreadCount > 0 {
                            Text("<\(totalUnreadCount)")
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                                .transition(.scale.combined(with: .opacity))
                                .animation(.easeInOut(duration: 0.2), value: totalUnreadCount)
                        }
                    }
                    
                    Spacer()
                    
                    // 右側：新規追加と設定ボタン
                    HStack(alignment: .center, spacing: 16) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInviteModal = true
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 26, weight: .bold))
                                .symbolRenderingMode(.hierarchical)
                                .symbolEffect(.bounce, value: showInviteModal)
                        }
                        
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingSettings = true
                            }
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 26, weight: .bold))
                                .symbolRenderingMode(.hierarchical)
                                .symbolEffect(.bounce, value: showingSettings)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                
                Divider()
                
                // チャットリストの表示
                chatListContent
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showInviteModal) {
                InviteModalView { newRoom in
                    onChatSelected(newRoom)
                }
            }
            .sheet(isPresented: $showQRInvite) {
                InviteModalView { newRoom in
                    onChatSelected(newRoom)
                }
            }
    }
    
    private var chatListContent: some View {
        Group {
            if chatRooms.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(chatRooms, id: \.id) { chatRoom in
                        Button {
                            // セルタップ時にコールバック（アニメーション付き）
                            withAnimation(.easeInOut(duration: 0.2)) {
                                onChatSelected(chatRoom)
                                // 未読数リセット
                                chatRoom.unreadCount = 0
                            }
                        } label: {
                            ChatRowView(
                                chatRoom: chatRoom,
                                avatarView: avatarView(for: chatRoom.remoteUserID, displayText: chatRoom.displayName?.prefix(1) ?? chatRoom.remoteUserID.prefix(1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteChatRooms)
                }
                .listStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: chatRooms.count)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("チャットを始めましょう")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("右上の「+」ボタンから招待URLをシェアできます")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showQRInvite = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                    Text("招待する")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .padding(.top, 16)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
    
    
    
    private func deleteChatRooms(at offsets: IndexSet) {
        withAnimation(.easeInOut(duration: 0.3)) {
            for index in offsets {
                let room = chatRooms[index]
                // 共有の無効化（オーナーならゾーン削除、参加者なら離脱）
                Task { await CloudKitChatManager.shared.revokeShareAndDeleteIfNeeded(roomID: room.roomID) }
                modelContext.delete(room)
            }
        }
    }

    // 共有導線は InviteModalView 経由の共通モーダルに統一
    
    // アバター形状をシャッフル（ユーザーIDに基づいて一貫性を保つ）
    @ViewBuilder
    private func avatarView(for userID: String, displayText: Substring) -> some View {
        let hash = abs(userID.hashValue)
        let shapeIndex = hash % 5
        
        Group {
            switch shapeIndex {
            case 0:
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(displayText)
                            .font(.title2)
                    )
            case 1:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 54, height: 54)
                    .overlay(
                        Text(displayText)
                            .font(.title2)
                    )
            case 2:
                PentagonShape()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 58, height: 58)
                    .overlay(
                        Text(displayText)
                            .font(.title2)
                    )
            case 3:
                HexagonShape()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 58, height: 58)
                    .overlay(
                        Text(displayText)
                            .font(.title2)
                    )
            case 4:
                OctagonShape()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 58, height: 58)
                    .overlay(
                        Text(displayText)
                            .font(.title2)
                    )
            default:
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(displayText)
                            .font(.title2)
                    )
            }
        }
        .frame(width: 60, height: 60)
    }
    
}

// MARK: - パフォーマンス最適化のための個別チャット行コンポーネント
struct ChatRowView: View {
    let chatRoom: ChatRoom
    let avatarView: AnyView
    
    init(chatRoom: ChatRoom, avatarView: some View) {
        self.chatRoom = chatRoom
        self.avatarView = AnyView(avatarView)
    }
    
    var body: some View {
        HStack {
            // アバター
            avatarView
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chatRoom.displayName ?? chatRoom.remoteUserID)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if let date = chatRoom.lastMessageDate {
                        Text(date, style: .time)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                if let last = chatRoom.lastMessageText {
                    Text(last)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // アニメーション付き未読バッジ
            if chatRoom.unreadCount > 0 {
                Text("\(chatRoom.unreadCount)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.red)
                    .clipShape(Circle())
                    .transition(.scale.combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: chatRoom.unreadCount)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ChatListVideoLogoView: View {
    @State private(set) var player: AVPlayer?
    @State private(set) var videoAspectRatio: CGFloat = 1.0
    @State private(set) var hasPlayedOnce = false
    let size: CGFloat
    
    init(size: CGFloat = 52) {
        self.size = size
    }
    
    var body: some View {
        Group {
            if let player = player {
                ChatListVideoPlayerView(player: player, aspectRatio: videoAspectRatio)
                    .aspectRatio(1.0, contentMode: .fill)
            } else {
                Image("AppLogo")
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear {
            // ページ遷移時に一度だけ再生（パフォーマンス最適化）
            if !hasPlayedOnce {
                setupPlayer()
                startPlayback()
                hasPlayedOnce = true
            } else if let player = player {
                // 既に初期化済みの場合は単に再生のみ
                player.seek(to: .zero)
                player.play()
            }
        }
        .onDisappear {
            // メモリ最適化: 非表示時は一時停止
            player?.pause()
        }
    }
    
    private func setupPlayer() {
        guard player == nil else { return }
        
        guard let videoURL = Bundle.main.url(forResource: "logo", withExtension: "mov") else {
            log("logo.mov not found in bundle", category: "App")
            return
        }
        
        let asset = AVAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .pause // 終了時は停止
        
        // メモリ最適化：バックグラウンド時は自動停止
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        player = newPlayer
        
        // Get video aspect ratio (バックグラウンドで実行)
        Task.detached(priority: .background) {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let videoTrack = tracks.first {
                    let size = try await videoTrack.load(.naturalSize)
                    let transform = try await videoTrack.load(.preferredTransform)
                    
                    let videoSize = size.applying(transform)
                    let width = abs(videoSize.width)
                    let height = abs(videoSize.height)
                    
                    // NaNを防ぐための安全チェック
                    let aspectRatio: CGFloat
                    if width > 0 && height > 0 && width.isFinite && height.isFinite {
                        aspectRatio = width / height
                    } else {
                        aspectRatio = 1.0 // デフォルト値
                        log("⚠️ Invalid video dimensions, using default aspect ratio", category: "ChatListVideoLogoView")
                    }
                    
                    await MainActor.run {
                        self.videoAspectRatio = aspectRatio.isFinite ? aspectRatio : 1.0
                    }
                }
            } catch {
                log("Error loading video properties: \(error)", category: "App")
            }
        }
    }
    
    private func startPlayback() {
        guard let player = player else { 
            setupPlayer()
            // パフォーマンス最適化：非同期で再試行
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒待機
                await MainActor.run {
                    startPlayback()
                }
            }
            return 
        }
        
        player.seek(to: .zero)
        player.play()
    }
}

struct ChatListVideoPlayerView: UIViewRepresentable {
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

struct NewChatSheet: View {
    @Binding var partnerID: String
    @Binding var isValidatingUser: Bool
    let onComplete: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFieldFocused: Bool
    
    // パフォーマンス最適化：フォーム状態の計算をprivateに
    private var isFormValid: Bool {
        !partnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom header
            HStack {
                Button("キャンセル") {
                    onCancel()
                }
                .foregroundColor(.primary)
                
                Spacer()
                
                Text("新しいチャット")
                    .font(.system(size: 17, weight: .semibold))
                
                Spacer()
                
                Button {
                    let trimmedID = partnerID.trimmingCharacters(in: .whitespacesAndNewlines)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onComplete(trimmedID)
                    }
                } label: {
                    HStack {
                        if isValidatingUser {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                                .scaleEffect(0.8)
                            Text("確認中...")
                        } else {
                            Text("追加")
                        }
                    }
                }
                .disabled(!isFormValid || isValidatingUser)
                .foregroundColor((isFormValid && !isValidatingUser) ? .accentColor : .secondary)
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            
            Divider()
            
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("相手の連絡先")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text("相手のCloudKitユーザーIDを入力してください")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    
                    TextField("_abc123... (CloudKitユーザーID)", text: $partnerID)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 16))
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            if isFormValid {
                                let trimmedID = partnerID.trimmingCharacters(in: .whitespacesAndNewlines)
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    onComplete(trimmedID)
                                }
                            }
                        }
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
}

// 五角形のShapeを定義
struct PentagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let centerX = rect.midX
        let centerY = rect.midY
        let radius = min(rect.width, rect.height) / 2
        
        // 五角形の5つの頂点を定義（上から開始）
        for i in 0..<5 {
            let angle = Double(i) * 2.0 * .pi / 5.0 - .pi / 2.0 // 上から開始するため-π/2
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        
        return path
    }
}

// 六角形のShapeを定義
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let centerX = rect.midX
        let centerY = rect.midY
        let radius = min(rect.width, rect.height) / 2
        
        // 六角形の6つの頂点を定義（上から開始）
        for i in 0..<6 {
            let angle = Double(i) * 2.0 * .pi / 6.0 - .pi / 2.0 // 上から開始するため-π/2
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        
        return path
    }
}

// 八角形のShapeを定義
struct OctagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let centerX = rect.midX
        let centerY = rect.midY
        let radius = min(rect.width, rect.height) / 2
        
        // 八角形の8つの頂点を定義（上から開始）
        for i in 0..<8 {
            let angle = Double(i) * 2.0 * .pi / 8.0 - .pi / 2.0 // 上から開始するため-π/2
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        
        return path
    }
}
