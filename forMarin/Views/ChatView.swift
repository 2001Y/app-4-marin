#if canImport(EmojisReactionKit)
import EmojisReactionKit
#endif
import SwiftUI
import UIKit
import SwiftData
import PhotosUI
import CloudKit
import AVKit



struct ChatView: View {
    let chatRoom: ChatRoom
    @Environment(\.dismiss) var dismiss
    
    // In a production app roomID should be deterministic hash of both users.
    var roomID: String { chatRoom.roomID }
    @State var myID: String = ""

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
    @State var editingText: String = ""
    @FocusState var editingFieldFocused: Bool
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
    
    // Context overlay for partner message actions
    @State var contextMessage: Message? = nil
    @State var editTextOverlay: String = ""
    
    // Partner profile
    @State var partnerName: String = ""
    @State var partnerAvatar: UIImage? = nil

    // Hero preview
    @Namespace var heroNS
    @State var heroImage: UIImage? = nil
    @State var heroImageID: String = ""
    @State var showHero: Bool = false
    
    @State var showProfileSheet: Bool = false
    
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

    @ViewBuilder
    func buildBody() -> some View {
        TabView {
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
        .tabViewStyle(.page(indexDisplayMode: .never))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .allowsHitTesting(true)
        .scrollDisabled(isTextFieldFocused || interactionBlocked) // テキストフィールドフォーカス時または編集モード時はスワイプ無効
        .navigationTitle(partnerName.isEmpty ? remoteUserID : partnerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(partnerName.isEmpty ? remoteUserID : partnerName)
                        .font(.headline)
                    Text("あと\(daysUntilAnniversary)日")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .onTapGesture {
                    showProfileSheet = true
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    #if DEBUG
                    Button(action: {
                        log("Manual database check requested", category: "DEBUG")
                        messageStore?.debugPrintEntireDatabase()
                        messageStore?.debugSearchForMessage(containing: "たああ")
                        messageStore?.debugSearchForMessage(containing: "たあああ")
                        messageStore?.refresh()
                    }) {
                        Image(systemName: "magnifyingglass.circle")
                            .foregroundColor(.blue)
                    }
                    #endif
                    
                    FaceTimeAudioButton(callee: remoteUserID)
                    FaceTimeButton(callee: remoteUserID)
                }
            }
        }
        .fullScreenCover(isPresented: $isVideoPlayerShown) {
            if let url = videoPlayerURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $isPreviewShown) {
            if !previewMediaItems.isEmpty {
                // 画像・動画混在プレビュー
                FullScreenPreviewView(
                    images: [], // 空配列（mediaItemsを使用）
                    startIndex: previewStartIndex,
                    onDismiss: { isPreviewShown = false },
                    namespace: heroNS,
                    geometryIDs: previewMediaItems.enumerated().map { index, _ in
                        "preview_\(index)"
                    },
                    mediaItems: previewMediaItems
                )
            } else {
                // 従来の画像のみプレビュー
                FullScreenPreviewView(
                    images: previewImages,
                    startIndex: previewStartIndex,
                    onDismiss: { isPreviewShown = false },
                    namespace: heroNS,
                    geometryIDs: previewImages.enumerated().map { index, _ in
                        // 単一画像の場合はassetPath、複数画像の場合はindexベースのID
                        previewImages.count == 1 ? heroImageID : "preview_\(index)"
                    }
                )
            }
        }
        .overlay {
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
        .sheet(isPresented: $isEmojiPickerShown) {
            MCEmojiPickerSheet(selectedEmoji: $pickedEmoji)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showDualCameraRecorder) {
            DualCamRecorderView()
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileDetailView(chatRoom: chatRoom, partnerAvatar: partnerAvatar)
        }
        .onChange(of: pickedEmoji) { newValue, _ in
            handleEmojiSelection(newValue)
        }
        .onAppear {
            // Initialize MessageStore with Environment's modelContext if not already initialized
            if messageStore == nil {
                messageStore = MessageStore(modelContext: modelContext, roomID: roomID)
                log("ChatView: Initialized MessageStore with Environment modelContext", category: "DEBUG")
                log("ChatView: MessageStore ModelContext: \(ObjectIdentifier(modelContext))", category: "DEBUG")
                
                // Force refresh to ensure UI-DB sync
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    messageStore?.refresh()
                    log("ChatView: Auto-refresh triggered after MessageStore initialization", category: "DEBUG")
                }
            } else {
                // MessageStore already exists, just refresh
                messageStore?.refresh()
                log("ChatView: Refreshing existing MessageStore", category: "DEBUG")
                log("ChatView: MessageStore ModelContainer: \(ObjectIdentifier(modelContext.container))", category: "DEBUG")
            }
            
            handleViewAppearance()
            requestChatPermissions()
            
            // CloudKit UserIDを取得してmyIDに設定
            Task {
                if let userID = CloudKitChatManager.shared.currentUserID {
                    myID = userID
                    log("ChatView: myID set to CloudKit userID: \(userID)", category: "DEBUG")
                } else {
                    // CloudKitChatManagerが初期化中の場合は待つ
                    while !CloudKitChatManager.shared.isInitialized {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒待機
                    }
                    if let userID = CloudKitChatManager.shared.currentUserID {
                        myID = userID
                        log("ChatView: myID set to CloudKit userID (after init): \(userID)", category: "DEBUG")
                    } else {
                        // フォールバック: デバイスIDを使用
                        myID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
                        log("ChatView: myID fallback to device ID: \(myID)", category: "DEBUG")
                    }
                }
            }
        }
        .onChange(of: messages.count) { _, newCount in
            // 統合されたメッセージ数変更処理
            if chatRoom.autoDownloadImages {
                autoDownloadNewImages()
            }
            handleMessagesCountChange(newCount)
        }
        .onDisappear {
            P2PController.shared.close()
        }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RequestDatabaseDump"))) { notif in
            log("ChatView: Received RequestDatabaseDump notification", category: "DEBUG")
            if let source = notif.userInfo?["source"] as? String {
                log("ChatView: Database dump requested by: \(source)", category: "DEBUG")
            }
            
            // MessageStoreのデバッグ機能を実行
            messageStore?.debugPrintEntireDatabase()
            messageStore?.debugSearchForMessage(containing: "たああ")
            messageStore?.debugSearchForMessage(containing: "たあああ")
            messageStore?.debugSearchForMessage(containing: "メインからサブ")
            messageStore?.debugSearchForMessage(containing: "サブからメイン")
            messageStore?.debugSearchForMessage(containing: "サブからのテスト")
            messageStore?.debugSearchForMessage(containing: "メインからのテスト")
        }
        // 動画プレイヤー解除時に他アプリのオーディオを止めない
        .onChange(of: isVideoPlayerShown) { _, newVal in
            if newVal == false {
                AudioSessionManager.configureForAmbient()
            }
        }
    }
    
    // MARK: - Chat Content View
    @ViewBuilder
    private func chatContentView() -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                messagesView()
                
                Divider()
                
                composeBarView()
            }
            .background(Color(UIColor.systemBackground))
            .allowsHitTesting(true)
            .contentShape(Rectangle())
            .overlay { contextOverlayView() }
        }
        .overlay { interactionBlockerView() }
        .overlay(alignment: .bottomTrailing) { editingOverlayView() }
    }
    

    
    @ViewBuilder
    private func contextOverlayView() -> some View {
        if let ctx = contextMessage {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
                .onTapGesture { contextMessage = nil }

            contextModalContent(ctx: ctx)
        }
    }
    
    @ViewBuilder
    private func contextModalContent(ctx: Message) -> some View {
        GeometryReader { g in
            let msgWidth: CGFloat = min(g.size.width * 0.72, 320)
            let horizontalOffset = ctx.senderID == myID ? (g.size.width/2 - msgWidth*0.6) : -(g.size.width/2 - msgWidth*0.4)

            VStack(spacing: 24) {
                Spacer().frame(height: 60)
                bubble(for: ctx)
                    .frame(width: msgWidth, alignment: ctx.senderID == myID ? .trailing : .leading)
                    .offset(x: horizontalOffset)
                    .allowsHitTesting(false)

                contextActionButtons(ctx: ctx)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func contextActionButtons(ctx: Message) -> some View {
                            if ctx.senderID == myID {
                                VStack(spacing: 16) {
                                TextEditor(text: $editTextOverlay)
                                    .frame(height: 120)
                                    .padding(8)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(12)
                                    .onAppear { editTextOverlay = ctx.body ?? "" }
                                    .onChange(of: editTextOverlay) { _, newVal in
                                        ctx.body = newVal
                                    }
                                    
                                    HStack {
                                        Spacer()
                                Button("完了") { contextMessage = nil }
                                            .buttonStyle(.borderedProminent)
                                    }
                                }
                            } else {
                                HStack(spacing: 32) {
                                    Button {
                                        text = "> " + (ctx.body ?? "") + "\n"
                                        isTextFieldFocused = true
                                        contextMessage = nil
                                    } label: {
                                        VStack { Image(systemName: "arrowshape.turn.up.left"); Text("返信") }
                                    }

                                    Button {
                                        if let body = ctx.body { UIPasteboard.general.string = body }
                                        contextMessage = nil
                                    } label: {
                                        VStack { Image(systemName: "doc.on.doc"); Text("コピー") }
                                    }
                                }
                                .foregroundColor(.primary)
                                .font(.body)
                            }
                        }
    
    @ViewBuilder
    private func interactionBlockerView() -> some View {
        if interactionBlocked {
            Color.clear.contentShape(Rectangle()).allowsHitTesting(true)
        }
    }
    
    @ViewBuilder
    private func editingOverlayView() -> some View {
        if let editing = editingMessage {
            EditingOverlay(message: editing)
        }
    }
    
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