import SwiftUI
import UIKit
import SwiftData
import PhotosUI
import AVKit



struct ChatView: View {
    let chatRoom: ChatRoom
    @Environment(\.dismiss) var dismiss
    
    // In a production app roomID should be deterministic hash of both users.
    var roomID: String { chatRoom.roomID }
    @State var myID: String = ""
    @State private var selectedTab: Int = 0
    // CloudKitユーザーIDの変化を購読して常に最新を用いる
    @StateObject private var chatManager = CloudKitChatManager.shared

    // 相手ユーザー ID をヘッダーに表示
    var remoteUserID: String { chatRoom.remoteUserID }

    // 最近使った絵文字を保存（最大3件）
    // デフォルトで 3 つの絵文字をプリセット（初回起動時のみ表示用）
    @AppStorage("recentEmojis") var recentEmojisString: String = "😀,👍,🎉"

    // MCEmojiPicker 表示フラグ
    @State var isEmojiPickerShown: Bool = false

    // ピッカーで選択された絵文字
    @State var pickedEmoji: String = ""

    // 直近 3 件を配列に変換
    var recentEmojis: [String] {
        recentEmojisString.split(separator: ",").map(String.init)
    }

    // MessageStore for real-time sync
    @State var messageStore: MessageStore?
    
    // Anniversary countdown (dynamic)  
    @Query var anniversaries: [Anniversary]
    
    // Messages from MessageStore
    var messages: [Message] {
        messageStore?.messages ?? []
    }
    
    init(chatRoom: ChatRoom) {
        self.chatRoom = chatRoom
        
        // Use a simple query without predicate to avoid macro issues
        self._anniversaries = Query(sort: \.date)
    }
    
    @Environment(\.modelContext) var modelContext

    @State var text: String = ""
    // 編集中のメッセージ（nil なら通常送信モード）
    @State var editingMessage: Message? = nil
    // 旧編集UI（インライン/オーバーレイ）用のStateを撤去
    @State var photosPickerItems: [PhotosPickerItem] = []
    @State var showSettings: Bool = false
    @State var showDualCameraRecorder: Bool = false

    // --- Image preview ---
    @State var previewImages: [UIImage] = []
    @State var previewVideos: [URL]? = nil
    @State var previewMediaItems: [MediaItem] = []
    @State var previewStartIndex: Int = 0
    @State var isPreviewShown: Bool = false

    // Compose bar states
    @FocusState var isTextFieldFocused: Bool
    @State var attachmentsExpanded: Bool = true
    
    // ハーフモーダル（メッセージアクション）
    @State var actionSheetMessage: Message? = nil
    // 画像グループへの一括リアクション適用用（nilなら単一メッセージ）
    @State var actionSheetTargetGroup: [Message]? = nil
    
    // Partner profile
    @State var partnerName: String = ""
    @State var partnerAvatar: UIImage? = nil

    // Hero preview
    @Namespace var heroNS
    @State var heroImage: UIImage? = nil
    @State var heroImageID: String = ""
    @State var showHero: Bool = false
    
    @State var showProfileSheet: Bool = false
    
    // 長押し中のメッセージID（押している間だけ拡大表現）
    @State var pressingMessageID: UUID? = nil

    // リアクションピッカー表示用（テキストバブルのワンタップ）
    // ChatViewMessageBubble.swift（別ファイルの拡張）から参照するためprivateを外す
    @State var reactionPickerMessage: Message? = nil
    @AppStorage("myDisplayName") var myDisplayName: String = ""
    // 入力バーの実高さ（safeAreaInsetで配置したコンポーザの高さ）
    @State var composerHeight: CGFloat = 0
    
    // Filtered anniversaries for current room
    var roomAnniversaries: [Anniversary] {
        anniversaries.filter { $0.roomID == roomID }
    }
    
    var nextAnniversary: (anniversary: Anniversary, nextDate: Date)? {
        let today = Date()
        let sortedByNextOccurrence = roomAnniversaries.compactMap { anniversary in
            (anniversary: anniversary, nextDate: anniversary.nextOccurrence(from: today))
        }.sorted { $0.nextDate < $1.nextDate }
        
        return sortedByNextOccurrence.first
    }
    
    var daysUntilAnniversary: Int {
        guard let next = nextAnniversary else { return 0 }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: next.nextDate)
        return max(0, components.day ?? 0)
    }

    // --- Video player ---
    @State var videoPlayerURL: URL? = nil
    @State var isVideoPlayerShown: Bool = false

    // リストスクロール・ページ遷移ブロック用
    var interactionBlocked: Bool {
        editingMessage != nil
    }

    var body: some View {
        buildBody()
    }

    func buildBody() -> some View {
        // 1) タブ + ナビゲーション基本設定（AnyViewで型を単純化）
        let base = AnyView(
            tabsView()
                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .allowsHitTesting(true)
                .navigationTitle(partnerName.isEmpty ? remoteUserID : partnerName)
                .navigationBarTitleDisplayMode(.inline)
        )

        // 2) ツールバーを段階的に適用
        let withTitle = AnyView(
            base.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(partnerName.isEmpty ? remoteUserID : partnerName)
                            .font(.headline)
                        Text("あと\(daysUntilAnniversary)日")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .onTapGesture { showProfileSheet = true }
                }
            }
        )

        let withActions = AnyView(
            withTitle.toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        FaceTimeAudioButton(callee: remoteUserID, roomID: roomID)
                        FaceTimeButton(callee: remoteUserID, roomID: roomID)
                    }
                }
            }
        )

        // 3) 各種シート/オーバーレイ/通知ハンドラを適用
        let finalView = AnyView(
            withActions
                .onChange(of: selectedTab) { _, _ in
                    // タブ移動時にフォーカス解除（キーボードを閉じる）
                    isTextFieldFocused = false
                }
                .fullScreenCover(isPresented: $isVideoPlayerShown) {
                    if let url = videoPlayerURL {
                        VideoPlayer(player: AVPlayer(url: url))
                            .ignoresSafeArea()
                    }
                }
                .fullScreenCover(isPresented: $isPreviewShown) {
                    if !previewMediaItems.isEmpty {
                        FullScreenPreviewView(
                            images: [],
                            startIndex: previewStartIndex,
                            onDismiss: { isPreviewShown = false },
                            namespace: heroNS,
                            geometryIDs: previewMediaItems.enumerated().map { index, _ in "preview_\(index)" },
                            mediaItems: previewMediaItems
                        )
                    } else {
                        FullScreenPreviewView(
                            images: previewImages,
                            startIndex: previewStartIndex,
                            onDismiss: { isPreviewShown = false },
                            namespace: heroNS,
                            geometryIDs: previewImages.enumerated().map { index, _ in previewImages.count == 1 ? heroImageID : "preview_\(index)" }
                        )
                    }
                }
                .overlay {
                    if showHero, let img = heroImage {
                        FullScreenPreviewView(
                            images: [img],
                            startIndex: 0,
                            onDismiss: { withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { showHero = false } },
                            namespace: heroNS,
                            geometryIDs: [heroImageID]
                        )
                        .transition(.opacity)
                    }
                }
                .sheet(isPresented: $isEmojiPickerShown) {
                    MCEmojiPickerSheet(selectedEmoji: $pickedEmoji)
                        .presentationDetents([.medium, .large])
                }
                .fullScreenCover(isPresented: $showDualCameraRecorder) { DualCamRecorderView() }
                .sheet(isPresented: $showProfileSheet) { ProfileDetailView(chatRoom: chatRoom, partnerAvatar: partnerAvatar) }
                .sheet(isPresented: Binding(
                    get: { actionSheetMessage != nil },
                    set: { newVal in
                        if newVal == false {
                            actionSheetMessage = nil
                            actionSheetTargetGroup = nil
                            log("ActionSheet: dismissed by user", category: "ChatView")
                        }
                    }
                )) {
                    if let target = actionSheetMessage {
                        MessageActionSheet(
                            message: target,
                            isMine: target.senderID == myID,
                            onReact: { emoji in
                                let targets = actionSheetTargetGroup ?? [target]
                                for msg in targets {
                                    Task { _ = await ReactionManager.shared.addReaction(emoji, to: msg) }
                                }
                                log("ActionSheet: Added reaction(CloudKit) \(emoji) to \(targets.count) message(s)", category: "ChatView")
                                updateRecentEmoji(emoji)
                                actionSheetMessage = nil
                                actionSheetTargetGroup = nil
                            },
                            onEdit: {
                                guard target.senderID == myID else { return }
                                editingMessage = target
                                text = target.body ?? ""
                                isTextFieldFocused = true
                                log("Edit: enter edit mode id=\(target.id)", category: "ChatView")
                                actionSheetMessage = nil
                                actionSheetTargetGroup = nil
                            },
                            onCopy: {
                                if let body = target.body { UIPasteboard.general.string = body }
                                log("ActionSheet: Copied text from message id=\(target.id)", category: "ChatView")
                                actionSheetMessage = nil
                                actionSheetTargetGroup = nil
                            },
                            onDelete: {
                                deleteMessage(target)
                                log("ActionSheet: Deleted message id=\(target.id)", category: "ChatView")
                                actionSheetMessage = nil
                                actionSheetTargetGroup = nil
                            },
                            onDismiss: {
                                actionSheetMessage = nil
                                actionSheetTargetGroup = nil
                            }
                        )
                        .presentationDetents([.fraction(0.33)])
                    }
                }
                .sheet(item: $reactionPickerMessage) { msg in
                    ReactionListSheet(message: msg, roomID: roomID, currentUserID: myID)
                        .onAppear { log("ReactionList: open for id=\(msg.id)", category: "ChatView") }
                        .presentationDetents([.medium])
                }
                .onChange(of: pickedEmoji) { newValue, _ in handleEmojiSelection(newValue) }
                .onAppear {
                    if messageStore == nil {
                        messageStore = MessageStore(modelContext: modelContext, roomID: roomID)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { messageStore?.refresh() }
                    }
                    handleViewAppearance()
                    requestChatPermissions()
                    Task {
                        if let userID = CloudKitChatManager.shared.currentUserID {
                            myID = userID
                            log("[ChatView] myID set onAppear (immediate): \(String(myID.prefix(8)))", category: "DEBUG")
                        } else {
                            while !CloudKitChatManager.shared.isInitialized { try? await Task.sleep(nanoseconds: 100_000_000) }
                            if let userID = CloudKitChatManager.shared.currentUserID {
                                myID = userID
                                log("[ChatView] myID set onAppear (after init): \(String(myID.prefix(8)))", category: "DEBUG")
                            }
                        }
                    }
                }
                .onReceive(chatManager.$currentUserID) { uid in
                    if let uid, uid != myID {
                        myID = uid
                        log("[ChatView] myID updated via publisher: \(String(uid.prefix(8)))", category: "DEBUG")
                    }
                }
                .onChange(of: messages.count) { _, newCount in
                    if chatRoom.autoDownloadImages { autoDownloadNewImages() }
                    handleMessagesCountChange(newCount)
                }
                .onDisappear { P2PController.shared.close() }
                .onReceive(NotificationCenter.default.publisher(for: .didFinishDualCamRecording)) { notif in
                    log("ChatView: Received .didFinishDualCamRecording notification", category: "DEBUG")
                    if let url = notif.userInfo?["videoURL"] as? URL {
                        log("ChatView: Video URL from notification: \(url)", category: "DEBUG")
                        log("ChatView: Video file exists: \(FileManager.default.fileExists(atPath: url.path))", category: "DEBUG")
                        insertVideoMessage(url)
                    } else {
                        log("ChatView: No video URL found in notification userInfo", category: "DEBUG")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .didFinishDualCamPhoto)) { notif in
                    log("ChatView: Received .didFinishDualCamPhoto notification", category: "DEBUG")
                    if let url = notif.userInfo?["photoURL"] as? URL {
                        log("ChatView: Photo URL from notification: \(url)", category: "DEBUG")
                        log("ChatView: Photo file exists: \(FileManager.default.fileExists(atPath: url.path))", category: "DEBUG")
                        insertPhotoMessage(url)
                    } else {
                        log("ChatView: No photo URL found in notification userInfo", category: "DEBUG")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .faceTimeIDRegistered)) { notif in
                    if let info = notif.userInfo as? [String: Any],
                       let faceTimeID = info["faceTimeID"] as? String {
                        let name = myDisplayName.isEmpty ? "あなた" : myDisplayName
                        let body = Message.makeFaceTimeRegisteredBody(name: name, faceTimeID: faceTimeID)
                        log("📞 [SYS] Sending FaceTime registration system message", category: "ChatView")
                        messageStore?.sendMessage(body)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RequestDatabaseDump"))) { notif in
                    log("ChatView: Received RequestDatabaseDump notification", category: "DEBUG")
                    if let source = notif.userInfo?["source"] as? String { log("ChatView: Database dump requested by: \(source)", category: "DEBUG") }
                    messageStore?.debugPrintEntireDatabase()
                    messageStore?.debugSearchForMessage(containing: "たああ")
                    messageStore?.debugSearchForMessage(containing: "たあああ")
                    messageStore?.debugSearchForMessage(containing: "メインからサブ")
                    messageStore?.debugSearchForMessage(containing: "サブからメイン")
                    messageStore?.debugSearchForMessage(containing: "サブからのテスト")
                    messageStore?.debugSearchForMessage(containing: "メインからのテスト")
                }
                .onChange(of: isVideoPlayerShown) { _, newVal in if newVal == false { AudioSessionManager.configureForAmbient() } }
        )

        return finalView
    }

    // 複雑なTabView部分を分割して型推論負荷を軽減
    @ViewBuilder
    private func tabsView() -> some View {
        TabView(selection: $selectedTab) {
            chatContentView()
                .tag(0)
                .tabItem {
                    Label("チャット", systemImage: "bubble.left.and.bubble.right")
                }

            unifiedCalendarAlbumView()
                .tag(1)
                .tabItem {
                    Label("カレンダー", systemImage: "calendar")
                }
        }
    }
    
    // MARK: - Chat Content View
    @ViewBuilder
    private func chatContentView() -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                messagesView()
            }
            .background(Color(UIColor.systemBackground))
            .allowsHitTesting(true)
            .contentShape(Rectangle())
            // 旧・返信/コピー用のオーバーレイは廃止（ハーフモーダルへ統合）
            // P2Pビデオオーバーレイ（条件は内部で判定）
            FloatingVideoOverlay()
        }
        // 入力欄はセーフエリア下端に常設（キーボード追従はOS任せ）
        .safeAreaInset(edge: .bottom) {
            composeBarView()
                .readHeight($composerHeight)
                .background(Color(UIColor.systemBackground))
        }
    }
    

    
    // 旧・contextOverlayView/返信・コピーUIは削除
    @ViewBuilder private func interactionBlockerView() -> some View {
        if interactionBlocked {
            Color.clear.contentShape(Rectangle()).allowsHitTesting(true)
        }
    }
    
    // 旧編集オーバーレイUIは廃止（通常の入力欄編集へ統合済み）
    
    @ViewBuilder
    private func heroPreviewOverlay() -> some View {
        if showHero, let img = heroImage {
            // HeroImagePreviewは削除されたため、FullScreenPreviewViewを使用
            FullScreenPreviewView(
                images: [img],
                startIndex: 0,
                onDismiss: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                        showHero = false
                    }
                },
                namespace: heroNS,
                geometryIDs: [heroImageID]
            )
            .transition(.opacity)
        }
    }
    
    // MARK: - User Calendar View
    @ViewBuilder 
    private func userCalendarView() -> some View {
        let imageMessages = getImageMessages()
        let imagesByDate = groupImagesByDate(imageMessages)
        
        CalendarWithImagesView(
            imagesByDate: imagesByDate,
            anniversaries: roomAnniversaries,
            onImageTap: { images, startIndex in
                previewImages = images
                previewStartIndex = startIndex
                isPreviewShown = true
            }
        )
        .allowsHitTesting(true)
        .contentShape(Rectangle())
    }
    
    // MARK: - Unified Calendar & Album View
    @ViewBuilder
    private func unifiedCalendarAlbumView() -> some View {
        let imageMessages = getImageMessages()
        let imagesByDate = groupImagesByDate(imageMessages)
        let shouldShowYearView = imagesByDate.keys.count >= 60
        
        Group {
            if shouldShowYearView {
                yearCalendarView(imagesByDate: imagesByDate)
            } else {
                monthCalendarView(imagesByDate: imagesByDate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(true)
            .contentShape(Rectangle())
    }
    
    // MARK: - Helper Methods
    private func groupImagesByDate(_ messages: [Message]) -> [Date: [Message]] {
        let calendar = Calendar.current
        var grouped: [Date: [Message]] = [:]
        
        for message in messages {
            let dayKey = calendar.startOfDay(for: message.createdAt)
            if grouped[dayKey] == nil {
                grouped[dayKey] = []
            }
            grouped[dayKey]?.append(message)
        }
        
        return grouped
    }
    
    @ViewBuilder
    private func monthCalendarView(imagesByDate: [Date: [Message]]) -> some View {
        CalendarWithImagesView(
            imagesByDate: imagesByDate,
            anniversaries: roomAnniversaries,
            onImageTap: { images, startIndex in
                previewImages = images
                previewStartIndex = startIndex
                isPreviewShown = true
            }
        )
    }
    
    @ViewBuilder
    private func yearCalendarView(imagesByDate: [Date: [Message]]) -> some View {
        YearCalendarView(
            imagesByDate: imagesByDate,
            anniversaries: roomAnniversaries,
            onImageTap: { images, startIndex in
                previewImages = images
                previewStartIndex = startIndex
                isPreviewShown = true
            }
        )
    }
    
    // MARK: - User Album View (deprecated)
    @ViewBuilder
    private func userAlbumView() -> some View {
        albumContent()
            .allowsHitTesting(true)
            .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private func albumContent() -> some View {
        let imageMessages = getImageMessages()
        
        ScrollView {
            albumGrid(imageMessages: imageMessages)
                .padding(.horizontal, 16)
        }
    }
    
    private func getImageMessages() -> [Message] {
        return messages.filter { message in
            guard let assetPath = message.assetPath else { return false }
            // 拡張子で画像のみをフィルタ
            let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext)
        }
    }
    
    @ViewBuilder
    private func albumGrid(imageMessages: [Message]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(imageMessages) { message in
                albumImageCell(message: message, imageMessages: imageMessages)
            }
        }
    }
    
    @ViewBuilder
    private func albumImageCell(message: Message, imageMessages: [Message]) -> some View {
            let cellSize = (UIScreen.main.bounds.width - 40) / 3
            
        if let assetPath = message.assetPath {
            let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
            // 画像ファイルのみを処理
            if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext),
               FileManager.default.fileExists(atPath: assetPath),
               let image = UIImage(contentsOfFile: assetPath) {
                // 正常な画像表示
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cellSize, height: cellSize)
                .clipped()
                .cornerRadius(8)
                .onTapGesture {
                    handleAlbumImageTap(message: message, imageMessages: imageMessages)
                }
            } else {
                // ファイルが存在しないまたは読み込み失敗
                albumMissingImagePlaceholder(size: cellSize)
            }
        } else {
            // assetPathがnil
            albumMissingImagePlaceholder(size: cellSize)
        }
    }
    
    @ViewBuilder
    private func albumMissingImagePlaceholder(size: CGFloat) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.system(size: size * 0.25))
                .foregroundColor(.secondary)
            
            Text("画像なし")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private func handleAlbumImageTap(message: Message, imageMessages: [Message]) {
        let images = imageMessages.compactMap { msg -> UIImage? in
            guard let path = msg.assetPath else { return nil }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            // 画像ファイルのみを処理
            if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext) {
            return UIImage(contentsOfFile: path)
            }
            return nil
        }
        previewImages = images.compactMap { $0 }
        previewStartIndex = imageMessages.firstIndex(of: message) ?? 0
        isPreviewShown = true
    }
    
    // MARK: - Permission Requests
    
    private func requestChatPermissions() {
        Task {
            do {
                try await PermissionManager.shared.requestChatPermissions()
                log("Chat permissions granted successfully", category: "DEBUG")
            } catch {
                log("Chat permissions denied: \(error.localizedDescription)", category: "DEBUG")
                // 権限が拒否されても、チャット画面は表示を継続
                // 必要な機能が制限されることをユーザーに後で通知
            }
        }
    }
    
}
