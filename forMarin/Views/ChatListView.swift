import SwiftUI
import SwiftData
import AVKit
import AVFoundation
import CloudKit
import UIKit

struct ChatListView: View {
    @Query(sort: \ChatRoom.lastMessageDate, order: .reverse) private var chatRooms: [ChatRoom]
    @Environment(\.modelContext) private var modelContext
    @State private var showInviteModal = false
    var onChatSelected: (ChatRoom) -> Void
    @State private(set) var showingSettings = false
    @State private(set) var selectedChatRoom: ChatRoom?
    @AppStorage("myAvatarData") private var myAvatarData: Data = Data()
    // プロフィール一括プリフェッチ制御
    @State private var isPrefetchingProfiles = false
    // モーダル排他: 招待とQRは同時に出さない
    @State private var showQRScanner = false
    
    init(onChatSelected: @escaping (ChatRoom) -> Void) {
        self.onChatSelected = onChatSelected
    }
    // パフォーマンス最適化: 未読数計算をmemoizeで最適化
    private var totalUnreadCount: Int {
        chatRooms.lazy.reduce(0) { $0 + $1.unreadCount }
    }
    
    // 表示用にroomID単位で一意化（最新の更新を優先）
    private var uniqueChatRooms: [ChatRoom] {
        let grouped = Dictionary(grouping: chatRooms, by: { $0.roomID })
        var collapsed: [ChatRoom] = []
        var removed = 0
        for (_, rooms) in grouped {
            if rooms.count > 1 { removed += (rooms.count - 1) }
            let picked = rooms.max(by: { (lhs, rhs) in
                let l = lhs.lastMessageDate ?? lhs.createdAt
                let r = rhs.lastMessageDate ?? rhs.createdAt
                return l < r
            }) ?? rooms[0]
            collapsed.append(picked)
        }
        let sorted = collapsed.sorted { (lhs, rhs) in
            let l = lhs.lastMessageDate ?? lhs.createdAt
            let r = rhs.lastMessageDate ?? rhs.createdAt
            return l > r
        }
        if removed > 0 {
            let ids = grouped.filter { $0.value.count > 1 }.keys.joined(separator: ", ")
            log("♻️ Collapsed duplicate ChatRooms for roomIDs: [\(ids)] (removed=\(removed))", category: "ChatListView")
        }
        return sorted
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
                    
                    // 右側：新規追加と設定ボタン（設定はプロフィール画像に）
                    HStack(alignment: .center, spacing: 16) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showInviteModal = true }
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
                            Group {
                                if !myAvatarData.isEmpty, let image = UIImage(data: myAvatarData) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 28, height: 28)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 1))
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 28, height: 28)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .onAppear {
                    // 重複の可能性をログに出力（UIには影響させない）
                    debugLogDuplicateChatRooms(chatRooms)
                }
                
                Divider()
                
                // チャットリストの表示
                chatListContent
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showInviteModal) {
                InviteUnifiedSheet(
                    onChatCreated: { newRoom in onChatSelected(newRoom) },
                    onJoined: nil,
                    existingRoomID: nil,
                    allowCreatingNewChat: true
                )
            }
            // 招待UIはChatView側で表示（メンバー不在時）
            .sheet(isPresented: $showQRScanner) {
                QRScannerSheet(isPresented: $showQRScanner) {
                    // 受諾後にアップデート
                    MessageSyncPipeline.shared.checkForUpdates()
                }
            }
            .task(id: uniqueChatRooms.map(\.roomID).joined(separator: ",")) {
                await prefetchMissingDisplayNames()
            }
    }

    // MARK: - Actions
    @MainActor
    private func createNewChatAndOpen() async {
        do {
            let roomID = CKSchema.makeZoneName()
            let descriptor = try await CloudKitChatManager.shared.createSharedChatRoom(roomID: roomID, invitedUserID: nil)
            _ = descriptor // 生成・URLはChatView側で表示
            let newRoom = ChatRoom(roomID: roomID, remoteUserID: "", displayName: nil)
            modelContext.insert(newRoom)
            try? modelContext.save()
            onChatSelected(newRoom)
        } catch {
            log("❌ [ChatList] Failed to create chat: \(error)", category: "share")
        }
    }
    
    private var chatListContent: some View {
        Group {
            if chatRooms.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(uniqueChatRooms, id: \.roomID) { chatRoom in
                        Button {
                            // セルタップ時にコールバック（アニメーション付き）
                            withAnimation(.easeInOut(duration: 0.2)) {
                                onChatSelected(chatRoom)
                            }
                        } label: {
                            ChatRowView(
                                chatRoom: chatRoom,
                                avatarView: avatarView(for: chatRoom)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteChatRooms)
                }
                .listStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: uniqueChatRooms.count)
            }
        }
        // 招待シートの表示は showInviteModal に統一
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
                showInviteModal = true
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

    // MARK: - Profile Prefetch
    private func roomsMissingDisplayName() -> [ChatRoom] {
        uniqueChatRooms.filter { room in
            let name = room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty
        }
    }

    private func prefetchMissingDisplayNames() async {
        if isPrefetchingProfiles { return }
        isPrefetchingProfiles = true
        defer { isPrefetchingProfiles = false }

        let targets = roomsMissingDisplayName()
        guard targets.isEmpty == false else { return }
        log("ChatList: prefetch profiles start missing=\(targets.count)", category: "ChatListView")

        for room in targets {
            let uid = room.remoteUserID
            // 空UID: 一度だけ補完を試みる（成功すれば以降のフェッチが有効化）
            if uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await CloudKitChatManager.shared.inferRemoteParticipantAndUpdateRoom(roomID: room.roomID, modelContext: modelContext)
            }
            let effectiveUID = room.remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveUID.isEmpty {
                log("ChatList: still empty uid after inference room=\(room.roomID)", category: "ChatListView")
                continue
            }
            do {
                // 共有ゾーンの参加者プロフィールを優先
                let shared = try await CloudKitChatManager.shared.fetchParticipantProfile(userID: effectiveUID, roomID: room.roomID)
                var nameToUse: String? = shared.name
                var avatarToUse: Data? = shared.avatarData
                if (nameToUse == nil || nameToUse!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    // フォールバック：従来のprivateプロフィール
                    if let priv = await CloudKitChatManager.shared.fetchProfile(userID: effectiveUID) {
                        nameToUse = priv.name
                        if avatarToUse == nil { avatarToUse = priv.avatarData }
                    }
                }
                await MainActor.run {
                    if let name = nameToUse, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        room.displayName = name
                    }
                    if let data = avatarToUse, !data.isEmpty {
                        room.avatarData = data
                    }
                }
                let nm = nameToUse?.trimmingCharacters(in: .whitespacesAndNewlines)
                log("ChatList: profile ok uid=\(uid) name=\(nm?.isEmpty == false ? nm! : "nil")", category: "ChatListView")
            } catch {
                log("ChatList: profile failed uid=\(uid) err=\(error)", category: "ChatListView")
            }
        }

        log("ChatList: prefetch profiles done", category: "ChatListView")
    }

    private func deleteChatRooms(at offsets: IndexSet) {
        withAnimation(.easeInOut(duration: 0.3)) {
            let targets = offsets.map { uniqueChatRooms[$0] }
            for room in targets {
                // 共有の無効化（オーナーならゾーン削除、参加者なら離脱）
                Task { await CloudKitChatManager.shared.revokeShareAndDeleteIfNeeded(roomID: room.roomID) }
                modelContext.delete(room)
                log("ChatList: deleted room locally and requested CloudKit revoke room=\(room.roomID)", category: "ChatListView")
            }
        }
    }

    // 共有導線は InviteUnifiedSheet に統一
    
    // アバター形状をシャッフル（ユーザーIDに基づいて一貫性を保つ）
    @ViewBuilder
    private func avatarView(for userID: String, displayText: Substring) -> some View {
        let shapeIndex = CloudKitChatManager.shared.getCachedAvatarShapeIndex(for: userID)
            ?? CloudKitChatManager.shared.stableShapeIndex(for: userID)
        
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

    // 画像アバター優先版（表示名/IDからのイニシャルにフォールバック）
    @ViewBuilder
    private func avatarView(for room: ChatRoom) -> some View {
        if let data = room.avatarData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 1))
        } else {
            let displayText: Substring = room.displayName?.prefix(1) ?? room.remoteUserID.prefix(1)
            avatarView(for: room.remoteUserID, displayText: displayText)
        }
    }
    
}

// MARK: - 重複検出ログ（診断用）
extension ChatListView {
    fileprivate func debugLogDuplicateChatRooms(_ rooms: [ChatRoom]) {
        // roomID単位の重複（本来はありえない想定）
        let byRoomID = Dictionary(grouping: rooms, by: { $0.roomID })
        let dupRoomIDs = byRoomID.filter { $0.value.count > 1 }
        if !dupRoomIDs.isEmpty {
            let ids = dupRoomIDs.keys.joined(separator: ", ")
            log("⚠️ Duplicate ChatRoom entries detected for roomID(s): [\(ids)]", category: "ChatListView")
        }

        // 同じ相手(remoteUserID)に対する複数ルーム（仕様上は起こり得るが診断用に出力）
        let byRemote = Dictionary(grouping: rooms, by: { $0.remoteUserID })
        let dupRemote = byRemote.filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !dupRemote.isEmpty {
            let list = dupRemote.map { "\($0.key): \($0.value.count) rooms" }.joined(separator: ", ")
            log("ℹ️ Multiple ChatRooms found for same remoteUserID(s): [\(list)]", category: "ChatListView")
        }
    }
}

// MARK: - パフォーマンス最適化のための個別チャット行コンポーネント
struct ChatRowView: View {
    let chatRoom: ChatRoom
    let avatarView: AnyView
    @Environment(\.modelContext) private var modelContext
    @State private var resolvedTitle: String = ""
    
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
                    Text({
                        let local = (chatRoom.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !local.isEmpty { return local }
                        if !resolvedTitle.isEmpty { return resolvedTitle }
                        let rid = chatRoom.remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
                        return rid.isEmpty ? "新規チャット" : rid
                    }())
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
        .onAppear {
            Task { @MainActor in
                let opener = CloudKitChatManager.shared.currentUserID ?? ""
                await LocalRoomNameResolver.evaluateOnOpen(room: chatRoom, openerUserID: opener, modelContext: modelContext)
                resolvedTitle = await LocalRoomNameResolver.effectiveTitle(room: chatRoom, openerUserID: opener, modelContext: modelContext)
            }
        }
    }
}

struct ChatListVideoLogoView: View {
    @State private(set) var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
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
            // ページ遷移時に一度だけ初期化（再生はレイヤー準備後に自動）
            if !hasPlayedOnce {
                setupPlayer()
                hasPlayedOnce = true
            } else if let player = player {
                player.seek(to: .zero)
            }
        }
        .onDisappear {
            // メモリ最適化: 非表示時は一時停止
            player?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // 復帰時の再表示
            if let player = player {
                player.seek(to: .zero)
            } else {
                setupPlayer()
            }
        }
    }
    
    private func setupPlayer() {
        guard player == nil else { return }
        
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
        // メモリ最適化：バックグラウンド時は自動停止
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        self.player = queue
        self.looper = looper
        
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
    }
}

struct ChatListVideoPlayerView: UIViewRepresentable {
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
        // 背景プレースホルダで完全透明フレーム時の視認性を確保
        playerLayer.backgroundColor = UIColor.clear.cgColor
        view.layer.addSublayer(playerLayer)

        // 初回フレームが描画可能になってから再生
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
