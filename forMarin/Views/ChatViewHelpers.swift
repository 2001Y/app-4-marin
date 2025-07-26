import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import UniformTypeIdentifiers

extension ChatView {
    
    // MARK: - Helper Methods
    
    // MARK: - Actions
    func sendMessage(_ text: String) {
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
            if let rec = try? await CKSync.saveMessage(message) {
                message.ckRecordName = rec
            }
            message.isSent = true
        }
    }

    // 編集も含めた送信コミット関数
    func commitSend(with content: String) {
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

        print("[DEBUG] sendSelectedMedia: Processing \(items.count) items")

        // 各メディアを個別メッセージとして即時送信
        Task { @MainActor in
            for (index, item) in items.enumerated() {
                print("[DEBUG] sendSelectedMedia: Processing item \(index + 1)")
                print("[DEBUG] sendSelectedMedia: Supported content types: \(item.supportedContentTypes)")
                
                // 動画か画像かを判定
                var isVideo = item.supportedContentTypes.contains(.movie) || 
                             item.supportedContentTypes.contains(.video) ||
                             item.supportedContentTypes.contains(UTType.movie) ||
                             item.supportedContentTypes.contains(UTType.video) ||
                             item.supportedContentTypes.contains(UTType.quickTimeMovie) ||
                             item.supportedContentTypes.contains(UTType.mpeg4Movie)
                print("[DEBUG] sendSelectedMedia: Is video? \(isVideo)")
                
                // 追加の判定: ファイル拡張子ベース
                if !isVideo {
                    // 動画判定が失敗した場合、ファイル拡張子で再判定
                    for contentType in item.supportedContentTypes {
                        print("[DEBUG] sendSelectedMedia: Content type: \(contentType)")
                        if contentType.preferredFilenameExtension?.lowercased() == "mov" ||
                           contentType.preferredFilenameExtension?.lowercased() == "mp4" ||
                           contentType.preferredFilenameExtension?.lowercased() == "m4v" {
                            print("[DEBUG] sendSelectedMedia: Detected video by file extension")
                            isVideo = true
                            break
                        }
                    }
                }
                
                if isVideo {
                    // 動画の場合
                    print("[DEBUG] sendSelectedMedia: Attempting to load video URL")
                    do {
                        // まず URL として読み込みを試行
                        if let videoURL = try await item.loadTransferable(type: URL.self) {
                            print("[DEBUG] sendSelectedMedia: Successfully loaded video URL: \(videoURL)")
                            print("[DEBUG] sendSelectedMedia: Video file exists: \(FileManager.default.fileExists(atPath: videoURL.path))")
                            
                            // ファイルサイズを明示的に取得
                            if let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
                               let fileSize = attributes[.size] as? Int64 {
                                print("[DEBUG] sendSelectedMedia: Video file size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)")
                            } else {
                                print("[DEBUG] sendSelectedMedia: Video file size: unknown")
                            }
                            
                            insertVideoMessage(videoURL)
                        } else {
                            print("[DEBUG] sendSelectedMedia: URL loading failed, trying Data method")
                            
                            // URL での読み込みが失敗した場合、Data として読み込んで一時ファイルに保存
                            if let videoData = try await item.loadTransferable(type: Data.self) {
                                print("[DEBUG] sendSelectedMedia: Successfully loaded video as Data: \(videoData.count) bytes")
                                
                                // データの先頭バイトをチェックしてファイル形式を推定
                                let header = videoData.prefix(12)
                                print("[DEBUG] sendSelectedMedia: Video data header: \(header.map { String(format: "%02X", $0) }.joined())")
                                
                                // ファイル拡張子を決定
                                let fileExtension: String
                                if header.starts(with: [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]) {
                                    fileExtension = "mp4"
                                    print("[DEBUG] sendSelectedMedia: Detected MP4 format")
                                } else if header.starts(with: [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]) {
                                    fileExtension = "mp4"
                                    print("[DEBUG] sendSelectedMedia: Detected MP4 format (variant)")
                                } else if header.starts(with: [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70]) {
                                    fileExtension = "m4v"
                                    print("[DEBUG] sendSelectedMedia: Detected M4V format")
                                } else {
                                    fileExtension = "mov"
                                    print("[DEBUG] sendSelectedMedia: Assuming MOV format")
                                }
                                
                                // 一時ファイルに保存
                                let tempURL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent(UUID().uuidString)
                                    .appendingPathExtension(fileExtension)
                                
                                do {
                                    try videoData.write(to: tempURL)
                                    print("[DEBUG] sendSelectedMedia: Saved video data to temp file: \(tempURL)")
                                    print("[DEBUG] sendSelectedMedia: Temp file exists: \(FileManager.default.fileExists(atPath: tempURL.path))")
                                    insertVideoMessage(tempURL)
                                } catch {
                                    print("[DEBUG] sendSelectedMedia: Failed to save video data to temp file: \(error)")
                                }
                            } else {
                                print("[DEBUG] sendSelectedMedia: Failed to load video as Data")
                            }
                        }
                    } catch {
                        print("[DEBUG] sendSelectedMedia: Error loading video URL: \(error)")
                    }
                } else {
                    // 画像の場合
                    print("[DEBUG] sendSelectedMedia: Attempting to load image data")
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { 
                            print("[DEBUG] sendSelectedMedia: Failed to load image data")
                            continue 
                        }
                        
                        print("[DEBUG] sendSelectedMedia: Successfully loaded image data")
                        
                        // Save to local cache
                        guard let localURL = AttachmentManager.saveImageToCache(image) else { 
                            print("[DEBUG] sendSelectedMedia: Failed to save image to cache")
                            continue 
                        }
                        
                        print("[DEBUG] sendSelectedMedia: Successfully saved image to cache: \(localURL)")
                        
                        // Create message immediately
                        let message = Message(roomID: roomID,
                                            senderID: myID,
                                            body: nil,
                                            assetPath: localURL.path,
                                            createdAt: .now,
                                            isSent: false)
                        modelContext.insert(message)
                        
                        print("[DEBUG] sendSelectedMedia: Created image message with ID: \(message.id)")
                        
                        // ChatRoomの最終メッセージを更新
                        chatRoom.lastMessageText = "📷 写真"
                        chatRoom.lastMessageDate = Date()
                        
                        // Upload to CloudKit in background
                        Task {
                            print("[DEBUG] sendSelectedMedia: Starting CloudKit upload for image")
                            if let recName = try? await CKSync.saveImageMessage(image, roomID: roomID, senderID: myID) {
                                await MainActor.run {
                                    message.ckRecordName = recName
                                    message.isSent = true
                                    print("[DEBUG] sendSelectedMedia: Successfully uploaded image to CloudKit: \(recName)")
                                }
                            } else {
                                print("[DEBUG] sendSelectedMedia: Failed to upload image to CloudKit")
                            }
                        }
                    } catch {
                        print("[DEBUG] sendSelectedMedia: Error processing image: \(error)")
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
        print("[DEBUG] insertVideoMessage: Starting with URL: \(url)")
        print("[DEBUG] insertVideoMessage: File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        // 動画圧縮チェック
        let processedURL = AttachmentManager.compressVideoIfNeeded(url) ?? url
        print("[DEBUG] insertVideoMessage: Using processed URL: \(processedURL)")
        
        // 永続領域へコピー
        let dstURL = AttachmentManager.makeFileURL(ext: processedURL.pathExtension)
        print("[DEBUG] insertVideoMessage: Destination URL: \(dstURL)")
        
        do {
            try FileManager.default.copyItem(at: processedURL, to: dstURL)
            print("[DEBUG] insertVideoMessage: Successfully copied video to destination")
        } catch {
            print("[DEBUG] insertVideoMessage: Failed to copy video: \(error)")
            return
        }

        let message = Message(roomID: roomID,
                              senderID: myID,
                              body: nil,
                              assetPath: dstURL.path,
                              createdAt: .now,
                              isSent: false)
        modelContext.insert(message)
        
        print("[DEBUG] insertVideoMessage: Created video message with ID: \(message.id)")
        
        // ChatRoomの最終メッセージを更新
        chatRoom.lastMessageText = "🎥 動画"
        chatRoom.lastMessageDate = Date()
        
        Task { @MainActor in
            print("[DEBUG] insertVideoMessage: Starting CloudKit upload")
            do {
                if let recName = try await CKSync.saveVideo(dstURL, roomID: roomID, senderID: myID) {
                    message.ckRecordName = recName
                    print("[DEBUG] insertVideoMessage: Successfully uploaded video to CloudKit: \(recName)")
                } else {
                    print("[DEBUG] insertVideoMessage: CloudKit upload returned nil record name")
                }
                message.isSent = true
                print("[DEBUG] insertVideoMessage: Video message marked as sent")
            } catch {
                print("[DEBUG] insertVideoMessage: Failed to save video to CloudKit: \(error)")
                message.isSent = false
            }
        }
    }
    
    func insertPhotoMessage(_ url: URL) {
        // 永続領域へコピー
        let dstURL = AttachmentManager.makeFileURL(ext: url.pathExtension)
        try? FileManager.default.copyItem(at: url, to: dstURL)

        let message = Message(roomID: roomID,
                              senderID: myID,
                              body: nil,
                              assetPath: dstURL.path,
                              createdAt: .now,
                              isSent: false)
        modelContext.insert(message)
        
        // ChatRoomの最終メッセージを更新
        chatRoom.lastMessageText = "📷 写真"
        chatRoom.lastMessageDate = Date()
        
        Task { @MainActor in
            if let image = UIImage(contentsOfFile: dstURL.path) {
                if let recName = try? await CKSync.saveImageMessage(image, roomID: roomID, senderID: myID) {
                    message.ckRecordName = recName
                }
            }
            message.isSent = true
        }
    }

    // MARK: - Inline edit commit
    func commitInlineEdit() {
        guard let target = editingMessage else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editingMessage = nil; return }

        target.body = trimmed
        target.isSent = false
        Task { @MainActor in
            do {
                if let recName = target.ckRecordName {
                    try await CKSync.updateMessageBody(recordName: recName, newBody: trimmed)
                } else {
                    let recordName = try await CKSync.saveMessage(target)
                    target.ckRecordName = recordName
                }
                target.isSent = true
            } catch {
                print("Failed to save message: \(error)")
                // エラー時は再送信可能にする
                target.isSent = false
            }
        }
        editingMessage = nil
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
                        print("[DEBUG] Auto-downloaded image: \(imageName)")
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
                    print("[DEBUG] notification permission granted = \(granted)")
                }
            }
        }

        if recentEmojisString.isEmpty {
            recentEmojisString = "😀,👍,🎉"
        }
        P2PController.shared.startIfNeeded(roomID: roomID, myID: myID)
        CKSync.modelContext = modelContext

        print("[DEBUG] ChatView appeared. messages = \(messages.count)")
        
        if autoDownloadImages {
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
            print("[DEBUG] Seeding tutorial messages for roomID: \(roomID), myID: \(myID), partner: \(partner)")
            TutorialDataSeeder.seed(into: modelContext,
                                    roomID: roomID,
                                    myID: myID,
                                    partnerID: partner)
            print("[DEBUG] Tutorial seeding completed")
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
                        } else {
                            ForEach(group.messages) { message in
                                bubble(for: message)
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnDrag()
            .onChange(of: messages.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
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
            let isImage = message.assetPath != nil
            let timeDiff = message.createdAt.timeIntervalSince(lastMessageTime)
            let isSameSender = message.senderID == lastSenderID
            let isWithinTimeWindow = timeDiff < 180 // 3分以内
            
            if isImage && isSameSender && isWithinTimeWindow && !currentImageGroup.isEmpty {
                // 既存の画像グループに追加
                currentImageGroup.append(message)
            } else if isImage {
                // 新しい画像グループを開始（まず既存グループを完了）
                if !currentImageGroup.isEmpty {
                    groups.append(MessageGroup(messages: currentImageGroup, isImageGroup: true, senderID: currentImageGroup.first?.senderID ?? ""))
                    currentImageGroup = []
                }
                currentImageGroup.append(message)
            } else {
                // テキストメッセージの場合、画像グループを完了して単独メッセージを追加
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
    
    // MARK: - Image Group Bubble
    @ViewBuilder
    func imageGroupBubble(for group: MessageGroup) -> some View {
        let allImages = group.messages.compactMap { message -> (UIImage, String, Message)? in
            if let assetPath = message.assetPath {
                // ファイル拡張子をチェックして、画像ファイルのみを処理
                let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext),
                   let image = UIImage(contentsOfFile: assetPath) {
                    return (image, assetPath, message)
                }
            }
            return nil
        }
        
        if allImages.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: group.senderID == myID ? .trailing : .leading, spacing: 4) {
            HStack {
                if group.senderID == myID {
                    Spacer(minLength: 0)
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(allImages.enumerated()), id: \.offset) { index, imageData in
                            let (image, imagePath, _) = imageData
                            Button {
                                // 全ての画像でプレビューを起動
                                previewImages = allImages.map { $0.0 }
                                previewStartIndex = index
                                isPreviewShown = true
                            } label: {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .matchedGeometryEffect(id: "\(imagePath)_group_\(index)_\(group.id)", in: heroNS)
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
                    // Add reaction to all messages in group
                    for message in group.messages {
                        var reactions = message.reactionEmoji ?? ""
                        reactions.append(emoji)
                        message.reactionEmoji = reactions
                        // Sync to CloudKit
                        if let recName = message.ckRecordName {
                            Task { try? await CKSync.updateReaction(recordName: recName, emoji: reactions) }
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