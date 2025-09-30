import SwiftUI
import Combine
import SwiftData
import PhotosUI
import UIKit
import UniformTypeIdentifiers

extension ChatView {
    // グループ（同一送信者の連続メディア）用のCloudKit集計リアクションバー
    struct MessageGroup: Identifiable {
        let id = UUID()
        let messages: [Message]
        let isImageGroup: Bool
        let senderID: String
    }

    private struct ReactionGroupOverlay: View {
        let group: MessageGroup
        let roomID: String
        let isMine: Bool

        @State private var aggregated: [String] = []

        var body: some View {
            Group {
                if !aggregated.isEmpty {
                    ReactionBarView(emojis: aggregated, isMine: isMine)
                }
            }
            .task {
                // 各メッセージのリアクションをCloudKitから取得して集約
                var all: [String] = []
                for msg in group.messages {
                    let record = msg.ckRecordName ?? msg.id.uuidString
                    do {
                        let reactions = try await CloudKitChatManager.shared.getReactionsForMessage(messageRecordName: record, roomID: roomID)
                        all.append(contentsOf: reactions.map { $0.emoji })
                    } catch {
                        // 失敗時は該当メッセージ分はスキップ
                        log("ReactionGroupOverlay: fetch failed for msg=\(record) error=\(error)", category: "ChatView")
                    }
                }
                if !all.isEmpty { log("ReactionGroupOverlay: loaded total=\(all.count) emojis for group", category: "ChatView") }
                await MainActor.run { aggregated = all }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reactionsUpdated)) { notif in
                guard let info = notif.userInfo as? [String: Any], let updated = info["recordName"] as? String else { return }
                // 対象グループ内のどれかのメッセージに一致したら再集計
                let ids = Set(group.messages.map { $0.ckRecordName ?? $0.id.uuidString })
                if ids.contains(updated) {
                    Task {
                        var all: [String] = []
                        for msg in group.messages {
                            let record = msg.ckRecordName ?? msg.id.uuidString
                            do {
                                let reactions = try await CloudKitChatManager.shared.getReactionsForMessage(messageRecordName: record, roomID: roomID)
                                all.append(contentsOf: reactions.map { $0.emoji })
                            } catch {
                                log("ReactionGroupOverlay: refresh failed for msg=\(record) error=\(error)", category: "ChatView")
                            }
                        }
                        await MainActor.run { aggregated = all }
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    // MARK: - Actions
    @MainActor
    func sendMessage(_ text: String) {
        // Use MessageStore for sending messages
        guard let messageStore = messageStore else {
            log("ChatView: MessageStore not initialized, cannot send message", category: "DEBUG")
            return
        }
        
        messageStore.sendMessage(text)
        
        // Update ChatRoom's last message info
        chatRoom.lastMessageText = text
        chatRoom.lastMessageDate = Date()
    }

    // 編集も含めた送信コミット関数
    @MainActor
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
                if let store = messageStore {
                    store.updateMessage(target, newBody: trimmed)
                } else {
                    self.sendMessage(trimmed)
                }
            }
            // リセット（UIはメインスレッドで確実に反映）
            log("Edit: commit updated id=\(target.id)", category: "ChatView")
            editingMessage = nil
            text = ""
            log("[Compose] Cleared text after edit-send", category: "ChatView")
        } else {
            sendMessage(trimmed)
            text = ""
            log("[Compose] Cleared text after send", category: "ChatView")
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
                        
                        messageStore.sendImageMessage(image)
                        
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

    /// Deletes message via MessageStore (Engine経由)
    func deleteMessage(_ message: Message) {
        log("🗑️ [UI DELETE] action tapped id=\(message.id) record=\(message.ckRecordName ?? "nil")", category: "ChatView")
        guard let store = messageStore else {
            modelContext.delete(message)
            return
        }
        store.deleteMessage(message)
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
        messageStore.sendVideoMessage(processedURL)
        
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
            messageStore.sendImageMessage(image)
            
            // Update ChatRoom's last message info
            chatRoom.lastMessageText = "📷 写真"
            chatRoom.lastMessageDate = Date()
            
            log("insertPhotoMessage: Photo message sent via MessageStore", category: "DEBUG")
        } else {
            log("insertPhotoMessage: Failed to load image from URL: \(url)", category: "DEBUG")
        }
    }

    // 旧インライン編集コミット関数は不要（commitSendで編集更新に統合）

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

        messageStore?.refresh()
        log("ChatView appeared. MessageStore refreshed", category: "DEBUG")

        if chatRoom.autoDownloadImages {
            autoDownloadNewImages()
        }

        Task {
            do {
                var effectiveRemoteID = remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
                if effectiveRemoteID.isEmpty {
                    await CloudKitChatManager.shared.inferRemoteParticipantAndUpdateRoom(roomID: roomID, modelContext: modelContext)
                    effectiveRemoteID = chatRoom.remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                guard !effectiveRemoteID.isEmpty else {
                    log("ChatView: skip participant profile fetch (empty uid) room=\(roomID)", category: "ChatView")
                    return
                }

                P2PController.shared.startIfNeeded(roomID: roomID, myID: myID, remoteID: effectiveRemoteID)

                let myName = (UserDefaults.standard.string(forKey: "myDisplayName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let myAvatar = UserDefaults.standard.data(forKey: "myAvatarData") ?? Data()
                try await CloudKitChatManager.shared.upsertParticipantProfile(in: roomID, name: myName, avatarData: myAvatar)

                let sharedResult = try await CloudKitChatManager.shared.fetchParticipantProfile(userID: effectiveRemoteID, roomID: roomID)
                var nameToUse: String? = sharedResult.name
                var avatarToUse: Data? = sharedResult.avatarData
                if (nameToUse == nil || nameToUse!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    let privateResult = await CloudKitChatManager.shared.fetchProfile(userID: effectiveRemoteID)
                    if let privateResult {
                        nameToUse = privateResult.name
                        if avatarToUse == nil { avatarToUse = privateResult.avatarData }
                    }
                }
                if let name = nameToUse { partnerName = name }
                if let data = avatarToUse { partnerAvatar = UIImage(data: data) }
            } catch {
                log("Failed to refresh participant profile for roomID=\(roomID): \(error)", category: "ChatView")
            }
        }
    }
    
    func handleMessagesCountChange(_ newCount: Int) {
        guard newCount == 0 else { return }
        // チュートリアルの再投入は行わない（CloudKit側で一元化）
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
                    // ボトムセンチネル（常に存在する安定ID）
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                // 入力欄の実高さぶんを確保（メッセージが隠れないように）
                .animation(.easeInOut(duration: 0.2), value: messages.count)
            }
            // キーボードによるセーフエリア縮小を無視（レイアウトシフトを避ける）
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // キーボードは入力欄の下スワイプのみで閉じる方針に変更
            // （メッセージ一覧のスクロールでは閉じない）
            .onChange(of: messages.count) { _, _ in
                // 新しいメッセージのスクロールを最適化
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
            .onChange(of: isTextFieldFocused) { _, focused in
                if focused {
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
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
        // プレビュー用（ローカルに実体があるもののみを対象）
        let allMedia: [(MediaItem, String, Message)] = group.messages.compactMap { message in
            guard let assetPath = message.assetPath else { return nil }
            let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext),
               FileManager.default.fileExists(atPath: assetPath),
               let image = UIImage(contentsOfFile: assetPath) {
                return (.image(image), assetPath, message)
            } else if ["mov", "mp4", "m4v", "avi"].contains(ext),
                      FileManager.default.fileExists(atPath: assetPath) {
                return (.video(URL(fileURLWithPath: assetPath)), assetPath, message)
            }
            return nil
        }
        // プレビュー開始位置のマッピング（message.id -> index）
        let previewIndexMap: [UUID: Int] = Dictionary(uniqueKeysWithValues: allMedia.enumerated().map { ($1.2.id, $0) })

        VStack(alignment: group.senderID == myID ? .trailing : .leading, spacing: 4) {
            HStack {
                if group.senderID == myID { Spacer(minLength: 0) }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(group.messages.enumerated()), id: \.element.id) { displayIndex, message in
                            // 各セルを個別に判定し、ローカル実体が無ければプレースホルダを表示
                            if let assetPath = message.assetPath {
                                let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
                                let exists = FileManager.default.fileExists(atPath: assetPath)
                                if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext) {
                                    if exists, let image = UIImage(contentsOfFile: assetPath) {
                                        Button {
                                            if let start = previewIndexMap[message.id] {
                                                handleMediaGroupTap(allMedia: allMedia, startIndex: start)
                                            }
                                        } label: {
                                            mediaThumbnailView(mediaItem: .image(image), mediaPath: assetPath, index: displayIndex, groupId: group.id)
                                        }
                                    } else {
                                        // 画像の実体がまだ無い場合も落とさず表示
                                        missingMediaPlaceholder(type: .image, message: "画像を準備中…")
                                            .frame(width: 120, height: 120)
                                    }
                                } else if ["mov", "mp4", "m4v", "avi"].contains(ext) {
                                    if exists {
                                        let url = URL(fileURLWithPath: assetPath)
                                        Button {
                                            if let start = previewIndexMap[message.id] {
                                                handleMediaGroupTap(allMedia: allMedia, startIndex: start)
                                            }
                                        } label: {
                                            mediaThumbnailView(mediaItem: .video(url), mediaPath: assetPath, index: displayIndex, groupId: group.id)
                                        }
                                    } else {
                                        missingMediaPlaceholder(type: .video, message: "動画を準備中…")
                                            .frame(width: 120, height: 120)
                                    }
                                } else {
                                    // 未知拡張子
                                    missingMediaPlaceholder(type: .image, message: "未対応のメディア")
                                        .frame(width: 120, height: 120)
                                }
                            } else {
                                // assetPath = nil
                                missingMediaPlaceholder(type: .image, message: "メディアなし")
                                    .frame(width: 120, height: 120)
                            }
                        }
                    }
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollTargetLayout()
                .frame(height: 120)
                .frame(maxWidth: .infinity)

                if group.senderID != myID { Spacer(minLength: 0) }
            }

            // CloudKitベースのリアクション集計バー
            ReactionGroupOverlay(group: group, roomID: roomID, isMine: group.senderID == myID)

            // タイムスタンプ（グループ最後）
            if let lastMessage = group.messages.last {
                Text(lastMessage.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 0)
        .frame(maxWidth: .infinity, alignment: group.senderID == myID ? .trailing : .leading)
        .onLongPressGesture(minimumDuration: 0.3) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let first = group.messages.first {
                log("LongPress: image group (count=\(group.messages.count)) first id=\(first.id)", category: "ChatView")
                actionSheetTargetGroup = group.messages
                actionSheetMessage = first
            }
        }
    }
    
    // 旧：ローカル文字列ベースの集計は非推奨（CloudKit集計へ移行）
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
