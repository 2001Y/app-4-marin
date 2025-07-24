import SwiftUI
import UIKit
import SwiftData
import PhotosUI
import CloudKit
import AVKit

struct ChatView: View {
    let chatRoom: ChatRoom
    @Environment(\.dismiss) private var dismiss
    
    // In a production app roomID should be deterministic hash of both users.
    private var roomID: String { chatRoom.roomID }
    private let myID: String = UIDevice.current.identifierForVendor?.uuidString ?? "me"

    // 相手ユーザー ID をヘッダーに表示
    private var remoteUserID: String { chatRoom.remoteUserID }

    // 最近使った絵文字を保存（最大3件）
    // デフォルトで 3 つの絵文字をプリセット（初回起動時のみ表示用）
    @AppStorage("recentEmojis") private var recentEmojisString: String = "😀,👍,🎉"

    // MCEmojiPicker 表示フラグ
    @State private var isEmojiPickerShown: Bool = false

    // ピッカーで選択された絵文字
    @State private var pickedEmoji: String = ""

    // リアクションストア
    @Environment(ReactionStore.self) private var reactionStore

    // 直近 3 件を配列に変換
    private var recentEmojis: [String] {
        recentEmojisString.split(separator: ",").map(String.init)
    }

    private func updateRecentEmoji(_ emoji: String) {
        var arr = recentEmojis
        if let idx = arr.firstIndex(of: emoji) {
            arr.remove(at: idx)
        }
        arr.insert(emoji, at: 0)
        if arr.count > 3 { arr = Array(arr.prefix(3)) }
        recentEmojisString = arr.joined(separator: ",")
    }

    @Query private var messages: [Message]
    
    init(chatRoom: ChatRoom) {
        self.chatRoom = chatRoom
        let roomID = chatRoom.roomID
        self._messages = Query(filter: #Predicate<Message> { message in
            message.roomID == roomID
        }, sort: \.createdAt)
    }
    @Environment(\.modelContext) private var modelContext

    @State private var text: String = ""
    // 編集中のメッセージ（nil なら通常送信モード）
    @State private var editingMessage: Message? = nil
    @State private var editingText: String = ""
    @FocusState private var editingFieldFocused: Bool
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showSettings: Bool = false
    @State private var showDualCameraRecorder: Bool = false

    // --- Image preview ---
    @State private var previewImages: [UIImage] = []
    @State private var previewStartIndex: Int = 0
    @State private var isPreviewShown: Bool = false

    // Compose bar states
    @FocusState private var isTextFieldFocused: Bool
    @State private var attachmentsExpanded: Bool = true
    @State private var plusReactionTarget: Message? = nil

    // Context overlay for partner message actions
    @State private var contextMessage: Message? = nil
    @State private var editTextOverlay: String = ""
    
    // Partner profile
    @State private var partnerName: String = ""
    @State private var partnerAvatar: UIImage? = nil

    // Hero preview
    @Namespace private var heroNS
    @State private var heroImage: UIImage? = nil
    @State private var heroImageID: String = ""
    @State private var showHero: Bool = false
    
    @State private var showProfileSheet: Bool = false
    
    // Anniversary countdown (temporary fixed date)
    private let anniversaryDate = Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 14))!
    
    private var daysUntilAnniversary: Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: anniversaryDate)
        return max(0, components.day ?? 0)
    }

    // --- Video player ---
    @State private var videoPlayerURL: URL? = nil
    @State private var isVideoPlayerShown: Bool = false

    // リストスクロール・ページ遷移ブロック用
    private var interactionBlocked: Bool {
        reactionStore.reactingMessageID != nil || editingMessage != nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Header (tap to open profile)
                HStack {
                    // Left: back button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    
                    // Center: avatar + name & countdown (Stack)
                    HStack(spacing: 12) {
                        // Avatar
                        if let avatar = partnerAvatar {
                            Image(uiImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                        } else {
                            Circle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.gray)
                                )
                        }

                        Button {
                            showProfileSheet = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(partnerName.isEmpty ? remoteUserID : partnerName)
                                    .foregroundColor(.primary)
                                    .font(.headline)
                                Text("あと\(daysUntilAnniversary)日")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)

                    Spacer()

                    // Right: FaceTime video & audio buttons
                    HStack(spacing: 12) {
                        FaceTimeAudioButton(callee: remoteUserID)
                        FaceTimeButton(callee: remoteUserID)
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))

                Divider()

                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { message in
                                bubble(for: message)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .dismissKeyboardOnDrag()
                    .scrollDisabled(interactionBlocked)
                    .onChange(of: messages.last?.id) { id in
                        if let id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }

                Divider()

                // Compose area
                HStack(spacing: 6) {
                    if attachmentsExpanded {
                        PhotosPicker(selection: $photosPickerItems,
                                     maxSelectionCount: 10,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)

                        // Dual camera recording button
                        CameraDualButton()
                    } else {
                        // collapsed indicator
                        Button {
                            withAnimation { attachmentsExpanded = true }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20))
                                .rotationEffect(.degrees(attachmentsExpanded ? 90 : 0))
                        }
                    }

                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(18)
                        .lineLimit(1...5)
                        .focused($isTextFieldFocused)
                        .onChange(of: isTextFieldFocused) { focused in
                            if focused {
                                withAnimation { attachmentsExpanded = false }
                            } else {
                                // キーボードが閉じたら左側ツールバーを元に戻す
                                withAnimation { attachmentsExpanded = true }
                            }
                        }

                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // テキストが無い場合は常に同一の絵文字ボタンを表示
                        Button {
                            isEmojiPickerShown = true
                        } label: {
                            Image(systemName: "smiley")
                                .font(.system(size: 24))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: {
                            commitSend(with: text)
                            text = ""
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemBackground))
                // ------ Overlay when long-pressing partner message ------
                .overlay {
                    if let ctx = contextMessage {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .background(.ultraThinMaterial)
                            .onTapGesture { contextMessage = nil }

                        GeometryReader { g in
                            let msgWidth: CGFloat = min(g.size.width * 0.72, 320)
                            let horizontalOffset = ctx.senderID == myID ? (g.size.width/2 - msgWidth*0.4) : -(g.size.width/2 - msgWidth*0.4)

                            VStack(spacing: 24) {
                                // Reaction bar
                                QuickEmojiBar(recentEmojis: Array(recentEmojis.prefix(3))) { emoji in
                                    ctx.reactionEmoji = emoji
                                    updateRecentEmoji(emoji)
                                    contextMessage = nil
                                } onShowPicker: {
                                    plusReactionTarget = ctx
                                    isEmojiPickerShown = true
                                    contextMessage = nil
                                }

                                // Message bubble positioned left/right 20%
                                bubble(for: ctx)
                                    .frame(width: msgWidth, alignment: ctx.senderID == myID ? .trailing : .leading)
                                    .offset(x: horizontalOffset)
                                    .allowsHitTesting(false)

                                // If own message → inline editor
                                if ctx.senderID == myID {
                                    TextEditor(text: $editTextOverlay)
                                        .frame(height: 120)
                                        .padding(8)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .cornerRadius(12)
                                        .onAppear { editTextOverlay = ctx.body ?? "" }
                                        .onChange(of: editTextOverlay) { newVal in
                                            ctx.body = newVal
                                        }
                                    Button("完了") { contextMessage = nil }
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        // --- Interaction block overlay ---
        .overlay {
            if interactionBlocked {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
            }
        }
        // 画像フルスクリーンプレビュー (オーバーレイ)
        .overlay {
            // Hero single image preview
            if showHero, let img = heroImage {
                let targetMessage = messages.first { $0.assetPath == heroImageID || $0.imageLocalURLs.contains { $0.path == heroImageID } }
                HeroImagePreview(image: img,
                                  geometryID: heroImageID,
                                  namespace: heroNS,
                                  onDismiss: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                        showHero = false
                    }
                }, message: targetMessage)
                .environment(reactionStore)
                .transition(.opacity)
            }
        }
        // Fallback multi-image preview (if ever used)
        .overlay {
            if isPreviewShown {
                FullScreenPreviewView(images: previewImages,
                                      startIndex: previewStartIndex,
                                      onDismiss: { isPreviewShown = false })
                .transition(.opacity)
            }
        }
        // 動画プレイヤー
        .fullScreenCover(isPresented: $isVideoPlayerShown) {
            if let url = videoPlayerURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            }
        }
        // MCEmojiPicker シート
        .sheet(isPresented: $isEmojiPickerShown) {
            MCEmojiPickerSheet(selectedEmoji: $pickedEmoji)
                .presentationDetents([.medium, .large])
        }
        // Dual camera recorder
        .fullScreenCover(isPresented: $showDualCameraRecorder) {
            DualCamRecorderView()
        }
        .onChange(of: pickedEmoji) { newValue, _ in
            guard !newValue.isEmpty else { return }
            // 通常送信はシートの dismiss 後、メインアクターで確実に実行
            Task { @MainActor in
                commitSend(with: newValue)
            }
            updateRecentEmoji(newValue)
            pickedEmoji = "" // 連続同一選択に備えてクリア
            isEmojiPickerShown = false
        }
        .onAppear {
            // 通知許可要求（初回のみ）
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                if settings.authorizationStatus == .notDetermined {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        print("[DEBUG] notification permission granted = \(granted)")
                    }
                }
            }

            // recentEmojis が空の場合はデフォルト値を設定（AppStorage に保存済みでも上書きしない）
            if recentEmojisString.isEmpty {
                recentEmojisString = "😀,👍,🎉"
            }
            P2PController.shared.startIfNeeded()
            CKSync.modelContext = modelContext

            print("[DEBUG] ChatView appeared. messages = \(messages.count)")
            
            // Auto-download images if enabled
            if autoDownloadImages {
                autoDownloadNewImages()
            }
            // Load partner profile
            Task {
                let (name, avatarData) = await CKSync.fetchProfile(for: remoteUserID)
                if let name = name {
                    partnerName = name
                }
                if let avatarData = avatarData {
                    partnerAvatar = UIImage(data: avatarData)
                }
            }
            
            // チュートリアルメッセージを初回のみ自動挿入
            if messages.isEmpty && !UserDefaults.standard.bool(forKey: "didSeedTutorial") {
                let partner = remoteUserID.isEmpty ? "Partner" : remoteUserID
                TutorialDataSeeder.seed(into: modelContext,
                                        roomID: roomID,
                                        myID: myID,
                                        partnerID: partner)
            }
        }
        .onChange(of: messages.count) { _, _ in
            // Check for new images to auto-download
            if autoDownloadImages {
                autoDownloadNewImages()
            }
        }
        .onDisappear {
            P2PController.shared.close()
        }
        // メッセージが全削除されたらチュートリアルを再挿入
        .onChange(of: messages.count) { newCount in
            guard newCount == 0 else { return }
            // View 更新サイクル内での State 変更を避けるため次の RunLoop で実行
            DispatchQueue.main.async {
                UserDefaults.standard.set(false, forKey: "didSeedTutorial")
                let partner = remoteUserID.isEmpty ? "Partner" : remoteUserID
                TutorialDataSeeder.seed(into: modelContext,
                                        roomID: roomID,
                                        myID: myID,
                                        partnerID: partner)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveRemoteMessage)) { notif in
            let (partner, _) = notif.userInfo?["message"] as? (String, Message) ?? ("", nil)
            if partner == remoteUserID {
                ckListener.checkNewMessages(roomID: roomID,
                                          partnerID: partner)
            }
        }
        // 録画終了通知
        .onReceive(NotificationCenter.default.publisher(for: .didFinishDualCamRecording)) { notif in
            if let url = notif.userInfo?["videoURL"] as? URL {
                insertVideoMessage(url)
            }
        }
        // Profile sheet
        .sheet(isPresented: $showProfileSheet) {
            ProfileDetailView(partnerName: partnerName.isEmpty ? remoteUserID : partnerName, partnerAvatar: partnerAvatar, roomID: roomID)
        }
    }

    // MARK: - UI Helpers
    @ViewBuilder private func bubble(for message: Message) -> some View {
        if message.assetPath != nil || message.imageLocalURLs.isEmpty == false {
            imageBubble(for: message)
        } else if let body = message.body, body.hasPrefix("video://") {
            videoBubble(for: message)
        } else {
            textBubble(for: message)
        }
    }

    // Video message view
    @ViewBuilder private func videoBubble(for message: Message) -> some View {
        let path = String(message.body!.dropFirst("video://".count))
        let url = URL(fileURLWithPath: path)
        HStack {
            if message.senderID != myID { Spacer(minLength: 0) }
            VideoThumbnailView(videoURL: url)
                .frame(width: 160, height: 284)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture {
                    videoPlayerURL = url
                    isVideoPlayerShown = true
                }
            if message.senderID == myID { Spacer(minLength: 0) }
        }
        .overlay(alignment: message.senderID == myID ? .leading : .trailing) {
            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .id(message.id)
    }

    // Text / reaction bubble
    @ViewBuilder private func textBubble(for message: Message) -> some View {
        let reactionStr = reactionStore.reactions[message.id] ?? message.reactionEmoji
        let isEmojiOnly = message.body?.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy { $0.unicodeScalars.allSatisfy { $0.properties.isEmoji } } ?? false
        let emojiCount = message.body?.count ?? 0
        
        Group {
            VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: 6) {
                    if message.senderID != myID {
                        // Left side message
                        if isEmojiOnly && emojiCount <= 3 {
                            Text(message.body ?? "")
                                .font(.system(size: 60))
                        } else {
                            Text(message.body ?? "")
                                .padding(10)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .font(.system(size: 15))
                        }
                        Text(message.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        // Right side (my) message
                        Text(message.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if editingMessage?.id == message.id {
                            TextField("", text: $editingText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.accentColor.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .font(.system(size: 15))
                                .focused($editingFieldFocused)
                                .onSubmit { commitInlineEdit() }
                                .onAppear { editingFieldFocused = true }
                        } else if isEmojiOnly && emojiCount <= 3 {
                            Text(message.body ?? "")
                                .font(.system(size: 60))
                        } else {
                            Text(message.body ?? "")
                                .padding(10)
                                .background(Color.accentColor.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .font(.system(size: 15))
                        }
                    }
                }
                // Reaction below message
                if let reactionStr {
                    ReactionBarView(emojis: reactionStr.map { String($0) }, isMine: message.senderID == myID)
                } else if message.senderID != myID && message.id == messages.last?.id {
                    ReactionBarView(emojis: [], isMine: false) {
                        plusReactionTarget = message
                        isEmojiPickerShown = true
                    }
                }
            }
        }
        .popover(isPresented: Binding<Bool>(
            get: { reactionStore.reactingMessageID == message.id && message.senderID != myID },
            set: { val in if !val { reactionStore.reactingMessageID = nil } }
        ), attachmentAnchor: .point(.bottom), arrowEdge: .bottom) {
            ReactionPickerView()
                .environment(reactionStore)
                .presentationCompactAdaptation(.none)
                .interactiveDismissDisabled()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
        .padding(message.senderID == myID ? .trailing : .leading, 12)
        .id(message.id)
        // 相手メッセージのみロングタップでリアクション
        .onLongPressGesture(minimumDuration: 0.35) {
            guard message.senderID != myID else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            reactionStore.reactingMessageID = message.id // ピッカー起動
        }
        .contextMenu(menuItems: {
            if message.senderID == myID {
                Button {
                    editingMessage = message
                    editingText = message.body ?? ""
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteMessage(message)
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        })
    }

    // MARK: - Extracted Helper Views
    @ViewBuilder
    private func imageBubble(for message: Message) -> some View {
        // Handle new single asset messages
        if let assetPath = message.assetPath,
           let img = UIImage(contentsOfFile: assetPath) {
            VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 4) {
                HStack {
                    if message.senderID == myID {
                        Spacer(minLength: 0)
                    }
                    let id = assetPath
                    Button {
                        let targetMessage = messages.first { $0.assetPath == assetPath }
                        heroImage = img
                        heroImageID = id
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                            showHero = true
                        }
                    } label: {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .matchedGeometryEffect(id: id, in: heroNS)
                    }
                    if message.senderID != myID {
                        Spacer(minLength: 0)
                    }
                }
                
                // Show reactions if any
                if let reactions = message.reactionEmoji, !reactions.isEmpty {
                    ReactionBarView(emojis: reactions.map { String($0) }, isMine: message.senderID == myID)
                }
                
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .padding(message.senderID == myID ? .trailing : .leading, 8)
            .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
            .id(message.id)
            return
        }
        
        // Legacy: Handle old imageLocalURLs
        VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.senderID == myID {
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.imageLocalURLs, id: \.path) { url in
                            if let img = UIImage(contentsOfFile: url.path) {
                                Button {
                                    // 画像プレビューを起動
                                    let imgs = message.imageLocalURLs.compactMap { UIImage(contentsOfFile: $0.path) }
                                    previewImages = imgs
                                    if let idx = imgs.firstIndex(of: img) {
                                        previewStartIndex = idx
                                    }
                                    isPreviewShown = true
                                } label: {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .matchedGeometryEffect(id: url.path, in: heroNS)
                                }
                            }
                        }
                    }
                }
                .frame(height: 120)
                if message.senderID != myID {
                    Spacer(minLength: 0)
                }
            }
            
            // Aggregate reactions for slider
            let aggregatedReactions = aggregateSliderReactions(for: message)
            if !aggregatedReactions.isEmpty {
                ReactionBarView(emojis: aggregatedReactions, isMine: message.senderID == myID)
            }
            
            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .padding(message.senderID == myID ? .trailing : .leading, 8)
        .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
        .id(message.id)
    }
    
    // Helper to aggregate reactions from consecutive image messages
    private func aggregateSliderReactions(for message: Message) -> [String] {
        guard !message.imageLocalURLs.isEmpty else { return [] }
        
        // Find consecutive image messages from same sender within 3 minutes
        let senderID = message.senderID
        let messageIndex = messages.firstIndex(where: { $0.id == message.id }) ?? 0
        var reactions: [String] = []
        
        // Look backward
        for i in stride(from: messageIndex, through: 0, by: -1) {
            let msg = messages[i]
            if msg.senderID == senderID && 
               (!msg.imageLocalURLs.isEmpty || msg.assetPath != nil) &&
               abs(msg.createdAt.timeIntervalSince(message.createdAt)) < 180 {
                if let r = msg.reactionEmoji {
                    reactions.append(contentsOf: r.map { String($0) })
                }
            } else if msg.senderID == senderID {
                break
            }
        }
        
        // Look forward
        for i in (messageIndex + 1)..<messages.count {
            let msg = messages[i]
            if msg.senderID == senderID && 
               (!msg.imageLocalURLs.isEmpty || msg.assetPath != nil) &&
               abs(msg.createdAt.timeIntervalSince(message.createdAt)) < 180 {
                if let r = msg.reactionEmoji {
                    reactions.append(contentsOf: r.map { String($0) })
                }
            } else if msg.senderID == senderID {
                break
            }
        }
        
        return reactions
    }

    // MARK: - Actions
    private func sendMessage(_ text: String) {
        let message = Message(roomID: roomID,
                              senderID: myID,
                              body: text,
                              createdAt: .now,
                              isSent: false)
        modelContext.insert(message)
        
        // ChatRoomの最終メッセージを更新
        chatRoom.lastMessageText = text
        chatRoom.lastMessageDate = Date()
        
        Task { @MainActor in
            try? await CKSync.saveMessage(message)
            message.isSent = true
        }
    }

    // 編集も含めた送信コミット関数
    private func commitSend(with content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let target = editingMessage {
            // 既存メッセージを編集
            target.body = trimmed
            target.isSent = false
            Task { @MainActor in
                if let recName = target.ckRecordName {
                    try? await CKSync.updateMessageBody(recordName: recName, newBody: trimmed)
                } else {
                    try? await CKSync.saveMessage(target)
                }
                target.isSent = true
            }
            // リセット
            editingMessage = nil
            text = ""
        } else {
            sendMessage(trimmed)
            text = ""
        }
    }

    private func sendSelectedImages() {
        guard !photosPickerItems.isEmpty else { return }
        let items = photosPickerItems
        photosPickerItems = []

        // 各画像を個別メッセージとして即時送信
        Task { @MainActor in
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                
                // Save to local cache
                guard let localURL = AttachmentManager.saveImageToCache(image) else { continue }
                
                // Create message immediately
                let message = Message(roomID: roomID,
                                    senderID: myID,
                                    body: nil,
                                    assetPath: localURL.path,
                                    createdAt: .now,
                                    isSent: false)
                modelContext.insert(message)
                
                // ChatRoomの最終メッセージを更新
                chatRoom.lastMessageText = "📷 写真"
                chatRoom.lastMessageDate = Date()
                
                // Upload to CloudKit in background
                Task {
                    if let recName = try? await CKSync.saveImageMessage(image, roomID: roomID, senderID: myID) {
                        await MainActor.run {
                            message.ckRecordName = recName
                            message.isSent = true
                        }
                    }
                }
            }
        }
    }

    /// Deletes message locally and (if possible) from CloudKit
    private func deleteMessage(_ message: Message) {
        modelContext.delete(message)
        if let recName = message.ckRecordName {
            Task { try? await CKSync.deleteMessage(recordName: recName) }
        }
    }

    private func insertVideoMessage(_ url: URL) {
        // 永続領域へコピー
        let dstURL = AttachmentManager.makeFileURL(ext: url.pathExtension)
        try? FileManager.default.copyItem(at: url, to: dstURL)

        let message = Message(roomID: roomID,
                              senderID: myID,
                              body: "video://" + dstURL.path,
                              createdAt: .now,
                              isSent: false)
        modelContext.insert(message)
        Task { @MainActor in
            if let recName = try? await CKSync.saveVideo(dstURL, roomID: roomID, senderID: myID) {
                message.ckRecordName = recName
            }
            message.isSent = true
        }
    }

    // MARK: - Inline edit commit
    private func commitInlineEdit() {
        guard let target = editingMessage else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editingMessage = nil; return }

        target.body = trimmed
        target.isSent = false
        Task { @MainActor in
            if let recName = target.ckRecordName {
                try? await CKSync.updateMessageBody(recordName: recName, newBody: trimmed)
            } else {
                try? await CKSync.saveMessage(target)
            }
            target.isSent = true
        }
        editingMessage = nil
    }

    private func autoDownloadNewImages() {
        for message in messages {
            // Download single asset messages
            if let assetPath = message.assetPath,
               let image = UIImage(contentsOfFile: assetPath) {
                // Check if not already saved
                let imageName = URL(fileURLWithPath: assetPath).lastPathComponent
                if !UserDefaults.standard.bool(forKey: "downloaded_\(imageName)") {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    UserDefaults.standard.set(true, forKey: "downloaded_\(imageName)")
                    print("[DEBUG] Auto-downloaded image: \(imageName)")
                }
            }
        }
    }
} // end struct ChatView 

// MARK: - Emoji Detection Helper
private extension String {
    /// Returns true if the string consists solely of unicode scalars that present as emoji (ignoring whitespace).
    var isOnlyEmojis: Bool {
        let scalars = trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        guard scalars.isEmpty == false else { return false }
        return scalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji }
    }
} 

// (重複定義だった ReactionBarView を削除しました。ファイル `ReactionBarView.swift` の定義を利用します) 