import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import UniformTypeIdentifiers

extension ChatView {
    
    // MARK: - Helper Methods
    
    // MARK: - Actions
    func sendMessage(_ text: String) {
        // Use MessageStore for sending messages
        guard let messageStore = messageStore else {
            log("ChatView: MessageStore not initialized, cannot send message", category: "DEBUG")
            return
        }
        
        messageStore.sendMessage(text, senderID: myID)
        
        // Update ChatRoom's last message info
        chatRoom.lastMessageText = text
        chatRoom.lastMessageDate = Date()
    }

    // 編集も含めた送信コミット関数
    func commitSend(with content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // 触覚フィードバック
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()

        if let target = editingMessage {
            // 既存メッセージを編集
            target.body = trimmed
            target.isSent = false
            Task { @MainActor in
                if let recName = target.ckRecordName {
                    try? await CKSync.updateMessageBody(recordName: recName, newBody: trimmed)
                } else {
                    if let rec = try? await CKSync.saveMessage(target) {
                        target.ckRecordName = rec
                    }
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

    func sendSelectedMedia() {
        guard !photosPickerItems.isEmpty else { return }
        let items = photosPickerItems
        photosPickerItems = []

        // 触覚フィードバック
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()

        log("sendSelectedMedia: Processing \(items.count) items", category: "DEBUG")

        // 各メディアを個別メッセージとして即時送信
        Task { @MainActor in
            for (index, item) in items.enumerated() {
                log("sendSelectedMedia: Processing item \(index + 1)", category: "DEBUG")
                log("sendSelectedMedia: Supported content types: \(item.supportedContentTypes)", category: "DEBUG")
                
                // 動画か画像かを判定
                var isVideo = item.supportedContentTypes.contains(.movie) || 
                             item.supportedContentTypes.contains(.video) ||
                             item.supportedContentTypes.contains(UTType.movie) ||
                             item.supportedContentTypes.contains(UTType.video) ||
                             item.supportedContentTypes.contains(UTType.quickTimeMovie) ||
                             item.supportedContentTypes.contains(UTType.mpeg4Movie)
                log("sendSelectedMedia: Is video? \(isVideo)", category: "DEBUG")
                
                // 追加の判定: ファイル拡張子ベース
                if !isVideo {
                    // 動画判定が失敗した場合、ファイル拡張子で再判定
                    for contentType in item.supportedContentTypes {
                        log("sendSelectedMedia: Content type: \(contentType)", category: "DEBUG")
                        if contentType.preferredFilenameExtension?.lowercased() == "mov" ||
                           contentType.preferredFilenameExtension?.lowercased() == "mp4" ||
                           contentType.preferredFilenameExtension?.lowercased() == "m4v" {
                            log("sendSelectedMedia: Detected video by file extension", category: "DEBUG")
                            isVideo = true
                            break
                        }
                    }
                }
                
                if isVideo {
                    // 動画の場合
                    log("sendSelectedMedia: Attempting to load video URL", category: "DEBUG")
                    do {
                        // まず URL として読み込みを試行
                        if let videoURL = try await item.loadTransferable(type: URL.self) {
                            log("sendSelectedMedia: Successfully loaded video URL: \(videoURL)", category: "DEBUG")
                            log("sendSelectedMedia: Video file exists: \(FileManager.default.fileExists(atPath: videoURL.path))", category: "DEBUG")
                            
                            // ファイルサイズを明示的に取得
                            if let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
                               let fileSize = attributes[.size] as? Int64 {
                                log("sendSelectedMedia: Video file size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)", category: "DEBUG")
                            } else {
                                log("sendSelectedMedia: Video file size: unknown", category: "DEBUG")
                            }
                            
                            insertVideoMessage(videoURL)
                        } else {
                            log("sendSelectedMedia: URL loading failed, trying Data method", category: "DEBUG")
                            
                            // URL での読み込みが失敗した場合、Data として読み込んで一時ファイルに保存
                            if let videoData = try await item.loadTransferable(type: Data.self) {
                                log("sendSelectedMedia: Successfully loaded video as Data: \(videoData.count) bytes", category: "DEBUG")
                                
                                // データの先頭バイトをチェックしてファイル形式を推定
                                let header = videoData.prefix(12)
                                log("sendSelectedMedia: Video data header: \(header.map { String(format: "%02X", $0) }.joined())", category: "DEBUG")
                                
                                // ファイル拡張子を決定
                                let fileExtension: String
                                if header.starts(with: [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]) {
                                    fileExtension = "mp4"
                                    log("sendSelectedMedia: Detected MP4 format", category: "DEBUG")
                                } else if header.starts(with: [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]) {
                                    fileExtension = "mp4"
                                    log("sendSelectedMedia: Detected MP4 format (variant)", category: "DEBUG")
                                } else if header.starts(with: [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70]) {
                                    fileExtension = "m4v"
                                    log("sendSelectedMedia: Detected M4V format", category: "DEBUG")
                                } else {
                                    fileExtension = "mov"
                                    log("sendSelectedMedia: Assuming MOV format", category: "DEBUG")
                                }
                                
                                // 一時ファイルに保存
                                let tempURL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent(UUID().uuidString)
                                    .appendingPathExtension(fileExtension)
                                
                                do {
                                    try videoData.write(to: tempURL)
                                    log("sendSelectedMedia: Saved video data to temp file: \(tempURL)", category: "DEBUG")
                                    log("sendSelectedMedia: Temp file exists: \(FileManager.default.fileExists(atPath: tempURL.path))", category: "DEBUG")
                                    insertVideoMessage(tempURL)
                                } catch {
                                    log("sendSelectedMedia: Failed to save video data to temp file: \(error)", category: "DEBUG")
                                }
                            } else {
                                log("sendSelectedMedia: Failed to load video as Data", category: "DEBUG")
                            }
                        }
                    } catch {
                        log("sendSelectedMedia: Error loading video URL: \(error)", category: "DEBUG")
                    }
                } else {
                    // 画像の場合
                    log("sendSelectedMedia: Attempting to load image data", category: "DEBUG")
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { 
                            log("sendSelectedMedia: Failed to load image data", category: "DEBUG")
                            continue 
                        }
                        
                        log("sendSelectedMedia: Successfully loaded image data", category: "DEBUG")
                        
                        // Save to local cache
                        guard let localURL = AttachmentManager.saveImageToCache(image) else { 
                            log("sendSelectedMedia: Failed to save image to cache", category: "DEBUG")
                            continue 
                        }
                        
                        log("sendSelectedMedia: Successfully saved image to cache: \(localURL)", category: "DEBUG")
                        
                        // Use MessageStore for sending image messages
                        guard let messageStore = messageStore else {
                            log("ChatView: MessageStore not initialized, cannot send image", category: "DEBUG")
                            continue
                        }
                        
                        messageStore.sendImageMessage(image, senderID: myID)
                        
                        log("sendSelectedMedia: Sent image message via MessageStore", category: "DEBUG")
                        
                        // ChatRoomの最終メッセージを更新
                        chatRoom.lastMessageText = "📷 写真"
                        chatRoom.lastMessageDate = Date()
                    } catch {
                        log("sendSelectedMedia: Error processing image: \(error)", category: "DEBUG")
                    }
                }
            }
        }
    }

    /// Deletes message locally and (if possible) from CloudKit
    func deleteMessage(_ message: Message) {
        modelContext.delete(message)
        if let recName = message.ckRecordName {
            Task { try? await CKSync.deleteMessage(recordName: recName) }
        }
    }

    func insertVideoMessage(_ url: URL) {
        log("insertVideoMessage: Starting with URL: \(url)", category: "DEBUG")
        log("insertVideoMessage: File exists: \(FileManager.default.fileExists(atPath: url.path))", category: "DEBUG")
        
        guard let messageStore = messageStore else {
            log("ChatView: MessageStore not initialized, cannot send video", category: "DEBUG")
            return
        }
        
        // 動画圧縮チェック
        let processedURL = AttachmentManager.compressVideoIfNeeded(url) ?? url
        log("insertVideoMessage: Using processed URL: \(processedURL)", category: "DEBUG")
        
        // Use MessageStore for sending video messages
        messageStore.sendVideoMessage(processedURL, senderID: myID)
        
        // Update ChatRoom's last message info
        chatRoom.lastMessageText = "🎥 動画"
        chatRoom.lastMessageDate = Date()
        
        log("insertVideoMessage: Video message sent via MessageStore", category: "DEBUG")
    }
    
    func insertPhotoMessage(_ url: URL) {
        guard let messageStore = messageStore else {
            log("ChatView: MessageStore not initialized, cannot send photo", category: "DEBUG")
            return
        }
        
        // Load image and send via MessageStore
        if let image = UIImage(contentsOfFile: url.path) {
            messageStore.sendImageMessage(image, senderID: myID)
            
            // Update ChatRoom's last message info
            chatRoom.lastMessageText = "📷 写真"
            chatRoom.lastMessageDate = Date()
            
            log("insertPhotoMessage: Photo message sent via MessageStore", category: "DEBUG")
        } else {
            log("insertPhotoMessage: Failed to load image from URL: \(url)", category: "DEBUG")
        }
    }

    // MARK: - Inline edit commit
    func commitInlineEdit() {
        guard let target = editingMessage else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editingMessage = nil; return }
        
        guard let messageStore = messageStore else {
            log("ChatView: MessageStore not initialized, cannot update message", category: "DEBUG")
            editingMessage = nil
            return
        }

        // Use MessageStore for updating messages
        messageStore.updateMessage(target, newBody: trimmed)
        editingMessage = nil
        
        log("commitInlineEdit: Message updated via MessageStore", category: "DEBUG")
    }

    func autoDownloadNewImages() {
        for message in messages {
            // Download single asset messages (images only)
            if let assetPath = message.assetPath {
                let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
                // 画像ファイルのみを処理
                if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext),
                   let image = UIImage(contentsOfFile: assetPath) {
                    // Check if not already saved
                    let imageName = URL(fileURLWithPath: assetPath).lastPathComponent
                    if !UserDefaults.standard.bool(forKey: "downloaded_\(imageName)") {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        UserDefaults.standard.set(true, forKey: "downloaded_\(imageName)")
                        log("Auto-downloaded image: \(imageName)", category: "DEBUG")
                    }
                }
            }
        }
    }

    func updateRecentEmoji(_ emoji: String) {
        var arr = recentEmojis
        if let idx = arr.firstIndex(of: emoji) {
            arr.remove(at: idx)
        }
        arr.insert(emoji, at: 0)
        if arr.count > 3 { arr = Array(arr.prefix(3)) }
        recentEmojisString = arr.joined(separator: ",")
    }
    
    // MARK: - Helper Methods for Message Finding
    func findTargetMessage(heroImageID: String) -> Message? {
        return messages.first(where: { $0.assetPath == heroImageID })
    }
    
    // MARK: - Event Handlers
    func handleEmojiSelection(_ newValue: String) {
        guard !newValue.isEmpty else { return }
        Task { @MainActor in
            commitSend(with: newValue)
        }
        updateRecentEmoji(newValue)
        pickedEmoji = ""
        isEmojiPickerShown = false
    }
    
    func handleViewAppearance() {
        // 外部オーディオを停止させない設定を再適用
        AudioSessionManager.configureForAmbient()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    log("notification permission granted = \(granted)", category: "DEBUG")
                }
            }
        }

        if recentEmojisString.isEmpty {
            recentEmojisString = "😀,👍,🎉"
        }
        P2PController.shared.startIfNeeded(roomID: roomID, myID: myID)

        // Refresh MessageStore for real-time sync
        messageStore?.refresh()
        log("ChatView appeared. MessageStore refreshed", category: "DEBUG")
        
        // デバッグ：ビュー表示時にDB全体をチェック
        #if DEBUG
        if let store = messageStore {
            log("=== ChatView: Full DB Debug Check ===", category: "DEBUG")
            store.debugPrintEntireDatabase()
            
            // 特定のメッセージを検索
            store.debugSearchForMessage(containing: "たああ")
            store.debugSearchForMessage(containing: "たあああ")
            log("=== End ChatView Debug Check ===", category: "DEBUG")
        }
        #endif
        
        if chatRoom.autoDownloadImages {
            autoDownloadNewImages()
        }
        Task {
            let (name, avatarData) = await CKSync.fetchProfile(for: remoteUserID)
            if let name = name {
                partnerName = name
            }
            if let avatarData = avatarData {
                partnerAvatar = UIImage(data: avatarData)
            }
        }
        
        // チュートリアルメッセージの表示判定
        if messages.isEmpty {
            let partner = remoteUserID.isEmpty ? "Partner" : remoteUserID
            log("Seeding tutorial messages for roomID: \(roomID), myID: \(myID), partner: \(partner)", category: "DEBUG")
            TutorialDataSeeder.seed(into: modelContext,
                                    roomID: roomID,
                                    myID: myID,
                                    partnerID: partner)
            log("Tutorial seeding completed", category: "DEBUG")
        }
    }
    
    func handleMessagesCountChange(_ newCount: Int) {
        guard newCount == 0 else { return }
        DispatchQueue.main.async {
            // このルームのチュートリアルフラグをリセット
            let tutorialKey = "didSeedTutorial_\(roomID)"
            UserDefaults.standard.set(false, forKey: tutorialKey)
            
            let partner = remoteUserID.isEmpty ? "Partner" : remoteUserID
            TutorialDataSeeder.seed(into: modelContext,
                                    roomID: roomID,
                                    myID: myID,
                                    partnerID: partner)
        }
    }
    
    // MARK: - Messages View
    @ViewBuilder 
    func messagesView() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groupedMessages, id: \.id) { group in
                        if group.isImageGroup {
                            imageGroupBubble(for: group)
                                .id(group.messages.last?.id) // ID for scroll targeting
                        } else {
                            ForEach(group.messages) { message in
                                bubble(for: message)
                                    .id(message.id) // ID for scroll targeting
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnDrag()
            .onChange(of: messages.count) { _, _ in
                // 新しいメッセージのスクロールを最適化
                if let lastMessage = messages.last {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    

    
    // MARK: - Helper Functions
    private func isImageFile(_ assetPath: String) -> Bool {
        let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext)
    }
    
    private func isVideoFile(_ assetPath: String) -> Bool {
        let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "avi"].contains(ext)
    }
    
    // MARK: - Media Group Helpers
    @ViewBuilder
    private func mediaThumbnailView(mediaItem: MediaItem, mediaPath: String, index: Int, groupId: UUID) -> some View {
        switch mediaItem {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .matchedGeometryEffect(id: "\(mediaPath)_group_\(index)_\(groupId)", in: heroNS)
        case .video(let videoURL):
            VideoThumbnailView(videoURL: videoURL)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .matchedGeometryEffect(id: "\(mediaPath)_group_\(index)_\(groupId)", in: heroNS)
        }
    }
    
    private func handleMediaGroupTap(allMedia: [(MediaItem, String, Message)], startIndex: Int) {
        // 画像・動画混在プレビューを起動
        let mediaItems = allMedia.map { $0.0 }
        previewMediaItems = mediaItems
        previewStartIndex = startIndex
        isPreviewShown = true
    }
    
    // MARK: - Message Grouping
    struct MessageGroup: Identifiable {
        let id = UUID()
        let messages: [Message]
        let isImageGroup: Bool
        let senderID: String
    }
    
    var groupedMessages: [MessageGroup] {
        var groups: [MessageGroup] = []
        var currentImageGroup: [Message] = []
        var lastSenderID: String = ""
        var lastMessageTime: Date = Date.distantPast
        
        for message in messages {
            let isImage = message.assetPath != nil && isImageFile(message.assetPath!)
            let isVideo = message.assetPath != nil && isVideoFile(message.assetPath!)
            let isMedia = isImage || isVideo
            let timeDiff = message.createdAt.timeIntervalSince(lastMessageTime)
            let isSameSender = message.senderID == lastSenderID
            let isWithinTimeWindow = timeDiff < 180 // 3分以内
            
            if isMedia && isSameSender && isWithinTimeWindow && !currentImageGroup.isEmpty {
                // 既存のメディアグループに追加（画像・動画混在）
                currentImageGroup.append(message)
            } else if isMedia {
                // 新しいメディアグループを開始（まず既存グループを完了）
                if !currentImageGroup.isEmpty {
                    groups.append(MessageGroup(messages: currentImageGroup, isImageGroup: true, senderID: currentImageGroup.first?.senderID ?? ""))
                    currentImageGroup = []
                }
                currentImageGroup.append(message)
            } else {
                // テキストメッセージの場合、メディアグループを完了して単独メッセージを追加
                if !currentImageGroup.isEmpty {
                    groups.append(MessageGroup(messages: currentImageGroup, isImageGroup: true, senderID: currentImageGroup.first?.senderID ?? ""))
                    currentImageGroup = []
                }
                groups.append(MessageGroup(messages: [message], isImageGroup: false, senderID: message.senderID))
            }
            
            lastSenderID = message.senderID
            lastMessageTime = message.createdAt
        }
        
        // 最後の画像グループがある場合は追加
        if !currentImageGroup.isEmpty {
            groups.append(MessageGroup(messages: currentImageGroup, isImageGroup: true, senderID: currentImageGroup.first?.senderID ?? ""))
        }
        
        return groups
    }
    
    // MARK: - Media Group Bubble (Image + Video)
    @ViewBuilder
    func imageGroupBubble(for group: MessageGroup) -> some View {
        let allMedia = group.messages.compactMap { message -> (MediaItem, String, Message)? in
            if let assetPath = message.assetPath {
                let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext),
                   let image = UIImage(contentsOfFile: assetPath) {
                    return (.image(image), assetPath, message)
                } else if ["mov", "mp4", "m4v", "avi"].contains(ext) {
                    return (.video(URL(fileURLWithPath: assetPath)), assetPath, message)
                }
            }
            return nil
        }
        
        if allMedia.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: group.senderID == myID ? .trailing : .leading, spacing: 4) {
            HStack {
                if group.senderID == myID {
                    Spacer(minLength: 0)
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(allMedia.enumerated()), id: \.offset) { index, mediaData in
                            let (mediaItem, mediaPath, _) = mediaData
                            Button {
                                // 全てのメディアでプレビューを起動
                                handleMediaGroupTap(allMedia: allMedia, startIndex: index)
                            } label: {
                                mediaThumbnailView(mediaItem: mediaItem, mediaPath: mediaPath, index: index, groupId: group.id)
                            }
                        }
                    }
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollTargetLayout()
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                
                if group.senderID != myID {
                    Spacer(minLength: 0)
                }
            }
            
            // Aggregate reactions from all messages in group
            let aggregatedReactions = aggregateGroupReactions(for: group)
            if !aggregatedReactions.isEmpty {
                ReactionBarView(emojis: aggregatedReactions, isMine: group.senderID == myID)
            }
            
            // Show timestamp of the last message in group
            if let lastMessage = group.messages.last {
                Text(lastMessage.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 0) // 画像スライダーの左右余白を0に
        .frame(maxWidth: .infinity, alignment: group.senderID == myID ? .trailing : .leading)
        .background {
            // EmojisReactionKit for partner image groups
            if group.senderID != myID, let firstMessage = group.messages.first {
                ReactionKitWrapperView(message: firstMessage) { emoji in
                    // 触覚フィードバック
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    
                    // Add reaction to all messages in group
                    for message in group.messages {
                        var reactions = message.reactionEmoji ?? ""
                        reactions.append(emoji)
                        message.reactionEmoji = reactions
                        // Sync to CloudKit
                        if let recName = message.ckRecordName {
                            Task { try? await CKSync.addReaction(recordName: recName, emoji: emoji) }
                        }
                    }
                    updateRecentEmoji(emoji)
                }
            }
        }
        }
    }
    
    // Helper to aggregate reactions from all messages in a group
    func aggregateGroupReactions(for group: MessageGroup) -> [String] {
        var reactions: [String] = []
        for message in group.messages {
            if let r = message.reactionEmoji {
                reactions.append(contentsOf: r.map { String($0) })
            }
        }
        return reactions
    }
}

// MARK: - Emoji Detection Helper
private extension String {
    /// Returns true if the string consists solely of unicode scalars that present as emoji (ignoring whitespace).
    var isOnlyEmojis: Bool {
        let scalars = trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        guard scalars.isEmpty == false else { return false }
        return scalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji }
    }
} 