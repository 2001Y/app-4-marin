import Foundation
import SwiftData
import Combine
import CloudKit
import UIKit
import SwiftUI

// MARK: - Error Extensions for Offline Management

extension Error {
    var isNetworkError: Bool {
        if let ckError = self as? CKError {
            return ckError.code == .networkUnavailable || 
                   ckError.code == .networkFailure ||
                   ckError.code == .requestRateLimited
        }
        
        if let urlError = self as? URLError {
            return urlError.code == .notConnectedToInternet ||
                   urlError.code == .networkConnectionLost ||
                   urlError.code == .timedOut
        }
        
        return false
    }
}

@MainActor
class MessageStore: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isSyncing: Bool = false
    
    // エラーは内部処理に留めてUIの再描画を最小化
    private(set) var syncError: Error? {
        didSet {
            if syncError != nil {
                // エラー時のみ必要に応じてUI通知
                log("Sync error occurred: \(syncError?.localizedDescription ?? "Unknown")", category: "MessageStore")
            }
        }
    }
    
    private let modelContext: ModelContext
    private let roomID: String
    private var cancellables = Set<AnyCancellable>()
    
    // Offline support
    private let offlineManager = OfflineManager.shared
    
    // Modern CKSyncEngine service (iOS 17+)
    @available(iOS 17.0, *)
    private var syncService: MessageSyncService {
        return MessageSyncService.shared
    }
    
    init(modelContext: ModelContext, roomID: String) {
        self.modelContext = modelContext
        self.roomID = roomID
        
        log("🏗️ Initialized with roomID: \(roomID)", category: "MessageStore")
        log("🗄️ ModelContext: \(ObjectIdentifier(modelContext))", category: "MessageStore")
        log("🗄️ ModelContainer: \(ObjectIdentifier(modelContext.container))", category: "MessageStore")
        
        setupSyncSubscriptions()
        loadInitialMessages()
        
        // 特定のルーム用のPush Notificationサブスクリプションを設定
        setupRoomPushNotifications()
        
        // 初期化時にDB全体をデバッグ出力
        debugPrintEntireDatabase()
        
        // 定期的なDBチェックを開始（デバッグ用）
        #if DEBUG
        startPeriodicDatabaseCheck()
        #endif
    }
    
    // MARK: - Setup
    
    private func setupSyncSubscriptions() {
        let currentRoomID = self.roomID
        
        if #available(iOS 17.0, *) {
            // Subscribe to MessageSyncService events
            syncService.messageReceived
                .filter { message in message.roomID == currentRoomID }
                .sink { [weak self] message in
                    self?.handleReceivedMessage(message)
                }
                .store(in: &cancellables)
            
            syncService.messageDeleted
                .sink { [weak self] messageID in
                    self?.handleDeletedMessage(messageID)
                }
                .store(in: &cancellables)
            
            syncService.syncError
                .sink { [weak self] error in
                    self?.syncError = error
                    log("Sync error: \(error)", category: "MessageStore")
                }
                .store(in: &cancellables)
            
            syncService.syncStatusChanged
                .sink { [weak self] isSyncing in
                    self?.isSyncing = isSyncing
                }
                .store(in: &cancellables)

            // Subscribe to reaction updates for this room only
            syncService.reactionsUpdated
                .filter { $0.roomID == currentRoomID }
                .sink { [weak self] payload in
                    self?.refreshReactions(for: payload.messageRecordName)
                }
                .store(in: &cancellables)
        }
        
        // Subscribe to offline manager events
        offlineManager.$isOnline
            .sink { [weak self] isOnline in
                if isOnline {
                    self?.handleNetworkRestored()
                } else {
                    self?.handleNetworkLost()
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to failed message notifications
        NotificationCenter.default.publisher(for: .messageFailedPermanently)
            .sink { [weak self] notification in
                if let message = notification.userInfo?["message"] as? Message,
                   message.roomID == currentRoomID {
                    self?.handleMessageFailedPermanently(message)
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to schema ready notifications
        NotificationCenter.default.publisher(for: .cloudKitSchemaReady)
            .sink { [weak self] _ in
                log("CloudKit schema is ready, retrying failed messages", category: "MessageStore")
                self?.retryFailedMessages()
            }
            .store(in: &cancellables)
        
        // UserIDマイグレーションは廃止（roomID=zoneName不変のため）
    }
    
    /// 特定のルーム用のPush Notificationサブスクリプションを設定
    private func setupRoomPushNotifications() {
        Task {
            do {
                try await CloudKitChatManager.shared.setupRoomSubscription(for: roomID)
                log("✅ Room subscription setup completed for: \(roomID)", category: "MessageStore")
            } catch {
                log("❌ Failed to setup room subscription: \(error)", category: "MessageStore")
            }
        }
    }
    
    private func loadInitialMessages() {
        isLoading = true
        
        // Load messages from local SwiftData
        do {
            let descriptor = FetchDescriptor<Message>()
            let allMessages = try modelContext.fetch(descriptor)
            let currentRoomID = self.roomID
            let filteredMessages = allMessages.filter { message in
                return message.roomID == currentRoomID
            }
            messages = filteredMessages.sorted { $0.createdAt < $1.createdAt }
            log("Loaded \(messages.count) messages from local storage", category: "MessageStore")
        } catch {
            log("Failed to load messages: \(error)", category: "MessageStore")
        }
        
        isLoading = false
        
        // Trigger sync check
        if #available(iOS 17.0, *) {
            syncService.checkForUpdates(roomID: roomID)
        }
    }
    
    // MARK: - Message Operations
    
    func sendMessage(_ text: String, senderID: String) {
        let message = Message(
            roomID: roomID,
            senderID: senderID,
            body: text,
            createdAt: Date(),
            isSent: false
        )
        
        // 特定のメッセージを追跡
        if text.contains("たああ") || text.contains("たあああ") {
            log("🎯 SENDING TRACKED MESSAGE: '\(text)' - Message ID: \(message.id)", category: "MessageStore")
        }
        
        // Optimistic UI update with batch processing
        _ = message.generateRecordName()
        
        // Batch UI update
        withAnimation(.easeInOut(duration: 0.2)) {
            messages.append(message)
        }
        
        modelContext.insert(message)
        
        // Save to persistent storage
        do {
            try modelContext.save()
            log("Message saved locally: \(message.id)", category: "MessageStore")
            
            // 特定のメッセージの保存を追跡
            if text.contains("たああ") || text.contains("たあああ") {
                log("🎯 TRACKED MESSAGE SAVED TO LOCAL DB: '\(text)'", category: "MessageStore")
            }
        } catch {
            // Remove from UI if save failed
            if let index = messages.firstIndex(of: message) {
                _ = withAnimation {
                    messages.remove(at: index)
                }
            }
            log("Failed to save message locally: \(error)", category: "MessageStore")
            return
        }
        
        // Sync to CloudKit
        syncToCloudKit(message)
    }
    
    func sendImageMessage(_ image: UIImage, senderID: String) {
        guard let localURL = AttachmentManager.saveImageToCache(image) else {
            log("Failed to save image to cache", category: "MessageStore")
            return
        }
        
        let message = Message(
            roomID: roomID,
            senderID: senderID,
            body: nil,
            assetPath: localURL.path,
            createdAt: Date(),
            isSent: false
        )
        
        // Optimistic UI update
        _ = message.generateRecordName()
        messages.append(message)
        modelContext.insert(message)
        
        // Save to persistent storage
        do {
            try modelContext.save()
            log("Image message saved locally: \(message.id)", category: "MessageStore")
        } catch {
            log("Failed to save image message locally: \(error)", category: "MessageStore")
            return
        }
        
        // Sync to CloudKit
        syncToCloudKit(message)
    }
    
    func sendVideoMessage(_ videoURL: URL, senderID: String) {
        // Copy to permanent storage
        let permanentURL = AttachmentManager.makeFileURL(ext: videoURL.pathExtension)
        
        do {
            try FileManager.default.copyItem(at: videoURL, to: permanentURL)
        } catch {
            log("Failed to copy video to permanent storage: \(error)", category: "MessageStore")
            return
        }
        
        let message = Message(
            roomID: roomID,
            senderID: senderID,
            body: nil,
            assetPath: permanentURL.path,
            createdAt: Date(),
            isSent: false
        )
        
        // Optimistic UI update
        _ = message.generateRecordName()
        messages.append(message)
        modelContext.insert(message)
        
        // Save to persistent storage
        do {
            try modelContext.save()
            log("Video message saved locally: \(message.id)", category: "MessageStore")
        } catch {
            log("Failed to save video message locally: \(error)", category: "MessageStore")
            return
        }
        
        // Sync to CloudKit
        syncToCloudKit(message)
    }
    
    func updateMessage(_ message: Message, newBody: String) {
        let oldBody = message.body
        message.body = newBody
        message.isSent = false
        
        // Save to persistent storage
        do {
            try modelContext.save()
            log("Message updated locally: \(message.id)", category: "MessageStore")
        } catch {
            // Revert on failure
            message.body = oldBody
            log("Failed to update message locally: \(error)", category: "MessageStore")
            return
        }
        
        // Sync to CloudKit
        Task {
            do {
                if let recordName = message.ckRecordName {
                    try await CloudKitChatManager.shared.updateMessage(recordName: recordName, roomID: message.roomID, newBody: newBody)
                    await MainActor.run {
                        message.isSent = true
                    }
                }
            } catch {
                await MainActor.run {
                    syncError = error
                    log("Failed to update message in CloudKit: \(error)", category: "MessageStore")
                }
            }
        }
    }
    
    func deleteMessage(_ message: Message) {
        // Remove from UI with animation
        if let index = messages.firstIndex(of: message) {
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                messages.remove(at: index)
            }
        }
        
        // Remove from persistent storage
        modelContext.delete(message)
        
        do {
            try modelContext.save()
            log("Message deleted locally: \(message.id)", category: "MessageStore")
        } catch {
            log("Failed to delete message locally: \(error)", category: "MessageStore")
            // Re-add to UI if delete failed
            withAnimation {
                messages.append(message)
                messages.sort { $0.createdAt < $1.createdAt }
            }
            return
        }
        
        // Sync deletion to CloudKit
        if let recordName = message.ckRecordName {
            Task {
                do {
                    try await CloudKitChatManager.shared.deleteMessage(recordName: recordName, roomID: message.roomID)
                    log("Message deleted from CloudKit: \(recordName)", category: "MessageStore")
                } catch {
                    await MainActor.run {
                        syncError = error
                        log("Failed to delete message from CloudKit: \(error)", category: "MessageStore")
                    }
                }
            }
        }
    }
    
    /// メッセージにリアクション絵文字を追加
    func addReaction(_ emoji: String, to message: Message) {
        // ローカルで即座に更新
        let currentReactions = message.reactionEmoji ?? ""
        message.reactionEmoji = currentReactions + emoji
        
        // UI更新
        objectWillChange.send()
        
        // ローカル保存
        do {
            try modelContext.save()
            log("Reaction added locally: \(emoji) to \(message.id)", category: "MessageStore")
        } catch {
            log("Failed to save reaction locally: \(error)", category: "MessageStore")
            return
        }
        
        // CloudKitに同期
        guard let recordName = message.ckRecordName else {
            log("Cannot sync reaction: message has no CloudKit record name", category: "MessageStore")
            return
        }
        
        Task {
            do {
                if let userID = CloudKitChatManager.shared.currentUserID {
                    try await CloudKitChatManager.shared.addReactionToMessage(
                        messageRecordName: recordName,
                        roomID: message.roomID,
                        emoji: emoji,
                        userID: userID
                    )
                }
                await MainActor.run {
                    message.isSent = true
                }
                log("Reaction synced to CloudKit: \(emoji)", category: "MessageStore")
            } catch {
                await MainActor.run {
                    syncError = error
                }
                log("Failed to sync reaction to CloudKit: \(error)", category: "MessageStore")
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func refreshReactions(for messageRecordName: String) {
        let currentRoomID = self.roomID
        guard let idx = messages.firstIndex(where: { $0.ckRecordName == messageRecordName }) else { return }
        Task { @MainActor in
            do {
                let list = try await CloudKitChatManager.shared.getReactionsForMessage(
                    messageRecordName: messageRecordName,
                    roomID: currentRoomID
                )
                let grouped = Dictionary(grouping: list, by: { $0.emoji })
                var builder = ""
                for (emoji, items) in grouped {
                    builder += String(repeating: emoji, count: items.count)
                }
                messages[idx].reactionEmoji = builder
                log("🔁 Refreshed reactions for message: \(messageRecordName)", category: "MessageStore")
            } catch {
                log("⚠️ Failed to refresh reactions for message: \(messageRecordName) - \(error)", category: "MessageStore")
            }
        }
    }

    private func syncToCloudKit(_ message: Message) {
        guard message.isValidForSync else {
            log("Message is not valid for sync: \(message.id)", category: "MessageStore")
            return
        }
        
        // 特定のメッセージを追跡
        if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
            log("🎯 SYNCING TRACKED MESSAGE TO CLOUDKIT: '\(body)' - Message ID: \(message.id)", category: "MessageStore")
        }
        
        // Check if online before attempting sync
        if !offlineManager.isOnline {
            log("Offline, queueing message: \(message.id)", category: "MessageStore")
            offlineManager.queueMessage(message)
            return
        }
        
        Task {
            do {
                // CloudKitChatManagerを使用して共有チャット管理
                let chatManager = CloudKitChatManager.shared
                
                // ルームレコードを取得、存在しない場合は作成を試行
                var roomRecord: CKRecord?
                do {
                    roomRecord = try await chatManager.getRoomRecord(roomID: message.roomID)
                } catch {
                    log("Room record not found for roomID: \(message.roomID)", category: "MessageStore")
                    roomRecord = nil
                }
                
                if roomRecord == nil {
                    log("No shared room found for roomID: \(message.roomID), attempting to create...", category: "MessageStore")
                    
                    // roomIDから相手のユーザーIDを推定（これは理想的ではないが、一時的な対処）
                    // より良い解決策は、ChatRoomモデルに相手のユーザーIDを保存することです
                    do {
                        // ChatRoomモデルからremoteUserIDを取得
                        let descriptor = FetchDescriptor<ChatRoom>()
                        let allRooms = try modelContext.fetch(descriptor)
                        
                        log("🔍 Searching for ChatRoom with roomID: \(message.roomID)", category: "MessageStore")
                        log("📋 Found \(allRooms.count) total ChatRooms:", category: "MessageStore")
                        for (index, room) in allRooms.enumerated() {
                            log("📋 Room \(index): ID=\(room.id), roomID=\(room.roomID), remoteUserID=\(room.remoteUserID)", category: "MessageStore")
                            
                            // roomIDの詳細比較
                            let isMatch = room.roomID == message.roomID
                            log("🔍 Room \(index) roomID match: \(isMatch)", category: "MessageStore")
                            if !isMatch {
                                log("📊 Target roomID length: \(message.roomID.count)", category: "MessageStore")
                                log("📊 Room \(index) roomID length: \(room.roomID.count)", category: "MessageStore")
                                log("📊 Target roomID: '\(message.roomID)'", category: "MessageStore")
                                log("📊 Room \(index) roomID: '\(room.roomID)'", category: "MessageStore")
                                
                                // 部分一致をチェック
                                if message.roomID.count >= 20 && room.roomID.count >= 20 {
                                    let targetPrefix = String(message.roomID.prefix(20))
                                    let roomPrefix = String(room.roomID.prefix(20))
                                    log("📊 Prefix match (20 chars): \(targetPrefix == roomPrefix)", category: "MessageStore")
                                }
                            }
                        }
                        
                        if let chatRoom = allRooms.first(where: { $0.roomID == message.roomID }) {
                            log("✅ Found local ChatRoom, creating CloudKit shared room for remote user: \(chatRoom.remoteUserID)", category: "MessageStore")
                            let _ = try await chatManager.createSharedChatRoom(roomID: message.roomID, invitedUserID: chatRoom.remoteUserID)
                            roomRecord = try await chatManager.getRoomRecord(roomID: message.roomID)
                            log("✅ Successfully created shared room for roomID: \(message.roomID)", category: "MessageStore")
                        } else {
                            // 部分一致での検索を試行（デバッグ用）
                            let partialMatches = allRooms.filter { room in
                                room.roomID.contains(message.roomID.prefix(10)) || message.roomID.contains(room.roomID.prefix(10))
                            }
                            
                            if !partialMatches.isEmpty {
                                log("🔍 Found partial matches:", category: "MessageStore")
                                for match in partialMatches {
                                    log("📋 Partial match: roomID=\(match.roomID)", category: "MessageStore")
                                }
                            }
                            
                            log("❌ Could not find local ChatRoom for roomID: \(message.roomID)", category: "MessageStore")
                            await MainActor.run {
                                message.isSent = false
                                syncError = CloudKitChatError.roomNotFound
                            }
                            return
                        }
                    } catch {
                        log("❌ Failed to fetch ChatRooms or create shared room: \(error)", category: "MessageStore")
                        await MainActor.run {
                            message.isSent = false
                            syncError = error
                        }
                        return
                    }
                }
                
                guard roomRecord != nil else {
                    log("❌ Still no room record available for roomID: \(message.roomID)", category: "MessageStore")
                    await MainActor.run {
                        message.isSent = false
                        syncError = CloudKitChatError.roomNotFound
                    }
                    return
                }
                
                // 共有ルームにメッセージを送信
                try await chatManager.sendMessage(message, to: message.roomID)
                await MainActor.run {
                    message.ckRecordName = message.id.uuidString  // メッセージIDをレコード名として使用
                    message.isSent = true
                    log("Message synced to shared room: \(message.id)", category: "MessageStore")
                    
                    // 特定のメッセージの同期成功を追跡
                    if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                        log("🎯 TRACKED MESSAGE SUCCESSFULLY SYNCED TO CLOUDKIT: '\(body)' - recordName: \(message.id.uuidString)", category: "MessageStore")
                    }
                }
                
            } catch {
                await MainActor.run {
                    message.isSent = false
                    syncError = error
                    log("Failed to sync message: \(error)", category: "MessageStore")
                    
                    // Queue for retry if it's a network error
                    if error.isNetworkError {
                        offlineManager.queueMessage(message)
                    }
                }
            }
        }
    }
    
    private func handleReceivedMessage(_ message: Message) {
        log("🔍 Handling received message - ID: \(message.id), roomID: \(message.roomID), senderID: \(message.senderID), body: \(message.body?.prefix(50) ?? "nil"), ckRecordName: \(message.ckRecordName ?? "nil")", category: "MessageStore")
        
        // 特定のメッセージを追跡（たああメッセージなど）
        if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
            log("🎯 TRACKED MESSAGE RECEIVED: Message ID \(message.id), body: '\(body)', ckRecordName: \(message.ckRecordName ?? "nil")", category: "MessageStore")
        }
        
        // 詳細な重複チェック
        log("🔍 Local messages count: \(messages.count)", category: "MessageStore")
        log("📋 Local ckRecordNames: \(messages.compactMap(\.ckRecordName).prefix(10))", category: "MessageStore")
        log("👥 Local senderIDs: \(messages.map(\.senderID).prefix(10))", category: "MessageStore")
        log("📨 Incoming senderID: \(message.senderID)", category: "MessageStore")
        
        // 改善された重複チェック：より厳密にチェックし、デバッグ情報を追加
        if let targetRecordName = message.ckRecordName {
            // 1. メモリ内のメッセージをチェック（同一レコード名で同一送信者のみ）
            let existingInMemory = messages.first(where: { 
                $0.ckRecordName == targetRecordName && $0.senderID == message.senderID 
            })
            if let existing = existingInMemory {
                log("⚠️ Found existing message in memory with same ckRecordName and senderID:", category: "MessageStore")
                log("📌 Existing - ID: \(existing.id), senderID: \(existing.senderID), body: \(existing.body?.prefix(50) ?? "nil"), createdAt: \(existing.createdAt)", category: "MessageStore")
                log("📌 New      - ID: \(message.id), senderID: \(message.senderID), body: \(message.body?.prefix(50) ?? "nil"), createdAt: \(message.createdAt)", category: "MessageStore")
                // 既存メッセージのリアクション表示のみ更新（本文は変わらない想定）
                if let newReactions = message.reactionEmoji, !newReactions.isEmpty, existing.reactionEmoji != newReactions {
                    existing.reactionEmoji = newReactions
                    log("🔁 Updated reaction display for existing message: \(targetRecordName)", category: "MessageStore")
                } else {
                    log("📱 Same message from same sender already exists in UI - no action needed", category: "MessageStore")
                }
                
                // 特定のメッセージの重複を詳しくログ
                if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                    log("🎯 TRACKED MESSAGE DUPLICATE DETECTED IN MEMORY - Already in UI", category: "MessageStore")
                }
                
                return
            }
            
            // 異なる送信者の同一レコード名は処理を続行
            let sameRecordDifferentSender = messages.first(where: { 
                $0.ckRecordName == targetRecordName && $0.senderID != message.senderID 
            })
            if sameRecordDifferentSender != nil {
                log("🔄 Found same recordName from different sender - allowing cross-device message", category: "MessageStore")
            }
            
            // 2. ローカルデータベースもチェック（同一送信者の重複のみ）
            do {
                let currentSenderID = message.senderID
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { msg in 
                        msg.ckRecordName == targetRecordName && msg.senderID == currentSenderID
                    }
                )
                let existingMessages = try modelContext.fetch(descriptor)
                if !existingMessages.isEmpty {
                    let existing = existingMessages.first!
                    log("⚠️ Found existing message in database with same ckRecordName and senderID: \(targetRecordName)", category: "MessageStore")
                    log("📌 DB Existing - ID: \(existing.id), senderID: \(existing.senderID), body: \(existing.body?.prefix(50) ?? "nil"), createdAt: \(existing.createdAt)", category: "MessageStore")
                    log("📌 New        - ID: \(message.id), senderID: \(message.senderID), body: \(message.body?.prefix(50) ?? "nil"), createdAt: \(message.createdAt)", category: "MessageStore")
                    
                    // 同一送信者のメッセージがUIに表示されているかチェック
                    let inUI = messages.contains { $0.ckRecordName == targetRecordName && $0.senderID == currentSenderID }
                    
                    // 特定のメッセージの重複を詳しくログ
                    if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                        log("🎯 TRACKED MESSAGE DUPLICATE DETECTED IN DATABASE - Not adding to avoid duplicates", category: "MessageStore")
                        log("🎯 But checking if it's in UI...", category: "MessageStore")
                        log("🎯 Is message in UI? \(inUI)", category: "MessageStore")
                    }
                    
                    // UIに表示されていない場合は追加（同一送信者のメッセージ対象）
                    if !inUI {
                        log("📱 Message from same sender exists in DB but not in UI - Adding to UI: \(existing.body?.prefix(30) ?? "nil")", category: "MessageStore")
                        withAnimation(.easeInOut(duration: 0.2)) {
                            messages.append(existing)
                            messages.sort { $0.createdAt < $1.createdAt }
                        }
                        
                        // 特定のメッセージの場合は追加ログ
                        if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                            log("🎯 TRACKED MESSAGE EXISTS IN DB BUT NOT IN UI - Added to UI", category: "MessageStore")
                        }
                    }
                    
                    return
                }
                
                // 異なる送信者の同一レコード名をチェック（情報ログのみ）
                let differentSenderDescriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { msg in 
                        msg.ckRecordName == targetRecordName && msg.senderID != currentSenderID
                    }
                )
                let differentSenderMessages = try modelContext.fetch(differentSenderDescriptor)
                if !differentSenderMessages.isEmpty {
                    log("🔄 Found message with same recordName from different sender in DB - allowing cross-device message", category: "MessageStore")
                }
            } catch {
                log("⚠️ Failed to check database for duplicates: \(error)", category: "MessageStore")
                // エラーが発生した場合は処理を続行
            }
            
            log("✅ No existing message found with ckRecordName: \(targetRecordName)", category: "MessageStore")
        } else {
            log("⚠️ Message has no ckRecordName, using alternative duplicate check", category: "MessageStore")
            
            // ckRecordNameがない場合は、他の条件で重複チェック
            let possibleDuplicate = messages.first { existing in
                existing.senderID == message.senderID &&
                existing.body == message.body &&
                abs(existing.createdAt.timeIntervalSince(message.createdAt)) < 60 // 60秒以内に拡大
            }
            
            if let duplicate = possibleDuplicate {
                log("⚠️ Found possible duplicate message based on content and timing", category: "MessageStore")
                log("📌 Duplicate - ID: \(duplicate.id), createdAt: \(duplicate.createdAt)", category: "MessageStore")
                log("📌 New      - ID: \(message.id), createdAt: \(message.createdAt)", category: "MessageStore")
                return
            }
        }
        
        // roomIDチェック
        if message.roomID != self.roomID {
            log("⚠️ RoomID mismatch - Message roomID: \(message.roomID), Store roomID: \(self.roomID)", category: "MessageStore")
            return
        }
        
        // Add to local storage
        modelContext.insert(message)
        
        do {
            try modelContext.save()
            
            // Update UI with animation
            withAnimation(.easeInOut(duration: 0.2)) {
                messages.append(message)
                messages.sort { $0.createdAt < $1.createdAt }
            }
            
            log("✅ Successfully received new message: \(message.id), body: \(message.body?.prefix(50) ?? "nil")", category: "MessageStore")
            
            // 受信成功時に追跡メッセージをハイライト
            if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                log("🎯 *** TRACKED MESSAGE SUCCESSFULLY RECEIVED AND SAVED *** '\(body)'", category: "MessageStore")
                log("🎯 Message details: ID=\(message.id), roomID=\(message.roomID), senderID=\(message.senderID), ckRecordName=\(message.ckRecordName ?? "nil")", category: "MessageStore")
                log("🎯 Current messages count: \(messages.count)", category: "MessageStore")
            }
            
        } catch {
            log("❌ Failed to save received message: \(error)", category: "MessageStore")
            
            // 保存失敗時にも追跡メッセージをハイライト
            if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                log("🎯 *** TRACKED MESSAGE FAILED TO SAVE *** '\(body)' - Error: \(error)", category: "MessageStore")
            }
        }
    }
    
    private func handleDeletedMessage(_ recordName: String) {
        // Find and remove message
        if let index = messages.firstIndex(where: { $0.ckRecordName == recordName }) {
            let message = messages[index]
            messages.remove(at: index)
            modelContext.delete(message)
            
            do {
                try modelContext.save()
                log("Deleted message: \(recordName)", category: "MessageStore")
            } catch {
                log("Failed to delete message: \(error)", category: "MessageStore")
            }
        }
    }
    
    // MARK: - Public Utilities
    
    func refresh() {
        log("🔄 Manual refresh requested for roomID: \(roomID)", category: "MessageStore")
        
        if #available(iOS 17.0, *) {
            syncService.checkForUpdates(roomID: roomID)
        } else {
            // Manual refresh for legacy implementation
            loadInitialMessages()
        }
        
        // 追加の手動確認：ローカルDBをリロードして、UIに反映されていないメッセージがあるかチェック
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                let currentRoomMessages = allMessages.filter { $0.roomID == self.roomID }
                let sortedMessages = currentRoomMessages.sorted { $0.createdAt < $1.createdAt }
                
                log("🔄 Local DB has \(sortedMessages.count) messages for room \(roomID)", category: "MessageStore")
                log("🔄 UI shows \(messages.count) messages", category: "MessageStore")
                
                // 全メッセージの詳細をログ出力
                log("🔍 All messages in local DB for this room:", category: "MessageStore")
                for (index, msg) in sortedMessages.enumerated() {
                    let body = msg.body ?? "nil"
                    let truncatedBody = String(body.prefix(20))
                    log("🔍 [\(index)] ID: \(msg.id), body: '\(truncatedBody)', createdAt: \(msg.createdAt), ckRecordName: \(msg.ckRecordName ?? "nil")", category: "MessageStore")
                    
                    // 特定のメッセージを詳細チェック
                    if body.contains("たああ") || body.contains("たあああ") {
                        log("🎯 FOUND TRACKED MESSAGE IN LOCAL DB: '\(body)'", category: "MessageStore")
                    }
                }
                
                // UIとローカルDBの差分をチェック
                if sortedMessages.count != messages.count {
                    log("⚠️ Message count mismatch detected. Reloading UI...", category: "MessageStore")
                    log("🔧 Before UI update: messages.count = \(messages.count), sortedMessages.count = \(sortedMessages.count)", category: "MessageStore")
                    
                    // 強制的なUI更新（複数の方法を試行）
                    self.messages.removeAll()
                    
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.messages = sortedMessages
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            log("🔧 After UI update: messages.count = \(self.messages.count)", category: "MessageStore")
                            
                            // さらに確認して必要があれば再度更新
                            if self.messages.count != sortedMessages.count {
                                log("🚨 UI update failed, forcing direct assignment", category: "MessageStore")
                                self.messages = sortedMessages
                            }
                        }
                    }
                } else {
                    // カウントが同じでも内容が違うかもしれないのでチェック
                    let uiMessageBodies = Set(messages.compactMap(\.body))
                    let dbMessageBodies = Set(sortedMessages.compactMap(\.body))
                    
                    if uiMessageBodies != dbMessageBodies {
                        log("⚠️ Message content mismatch detected despite same count. Reloading UI...", category: "MessageStore")
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.messages = sortedMessages
                        }
                    }
                }
                
                // 全データベースから「たああ」を含むメッセージを検索
                let allDbMessages = try modelContext.fetch(FetchDescriptor<Message>())
                let trackedMessagesAllRooms = allDbMessages.filter { message in
                    if let body = message.body {
                        return body.contains("たああ") || body.contains("たあああ")
                    }
                    return false
                }
                
                if !trackedMessagesAllRooms.isEmpty {
                    log("🎯 Found \(trackedMessagesAllRooms.count) tracked messages in ENTIRE DB:", category: "MessageStore")
                    for msg in trackedMessagesAllRooms {
                        log("🎯 - ID: \(msg.id), roomID: \(msg.roomID), body: '\(msg.body ?? "nil")', createdAt: \(msg.createdAt)", category: "MessageStore")
                    }
                } else {
                    log("🚫 No 'たああ' messages found in entire local database", category: "MessageStore")
                }
                
                // デバッグ情報を自動出力
                log("🔧 AUTO-RUNNING DEBUG FUNCTIONS...", category: "MessageStore")
                self.debugPrintAllMessages()
                self.debugSearchMessages("たああ")
                self.debugCompareRoomMessages()
                
            } catch {
                log("❌ Failed to refresh from local DB: \(error)", category: "MessageStore")
            }
        }
    }
    
    func retryFailedMessages() {
        let failedMessages = messages.filter { !$0.isSent }
        
        for message in failedMessages {
            log("Retrying failed message: \(message.id)", category: "MessageStore")
            syncToCloudKit(message)
        }
    }
    
    func getMessageCount() -> Int {
        return messages.count
    }
    
    func getUnsentMessageCount() -> Int {
        return messages.filter { !$0.isSent }.count
    }
    
    // MARK: - Offline Event Handlers
    
    private func handleNetworkRestored() {
        log("Network restored for room: \(roomID)", category: "MessageStore")
        
        // Refresh to get latest messages
        if #available(iOS 17.0, *) {
            syncService.checkForUpdates(roomID: roomID)
        }
        
        // Retry failed messages
        retryFailedMessages()
    }
    
    private func handleNetworkLost() {
        log("Network lost for room: \(roomID)", category: "MessageStore")
        // No immediate action needed - messages will be queued automatically
    }
    
    private func handleMessageFailedPermanently(_ message: Message) {
        log("Message failed permanently: \(message.id)", category: "MessageStore")
        
        // Mark message as failed in UI
        message.isSent = false
        objectWillChange.send()
        
        // Show error state
        syncError = MessageStoreError.messageFailed(message.id.uuidString)
    }
    
    // ユーザーIDマイグレーション/一時ID更新のロジックは廃止（roomID=zoneName を不変とする）
    
    // MARK: - Debug Functions
    
    /// デバッグ用：データベース全体の状態を出力
    func debugPrintEntireDatabase() {
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                
                log("==================================================", category: "App")
                log("🔍 DEBUG: ENTIRE DATABASE CONTENTS", category: "MessageStore")
                log("🔍 Total messages in DB: \(allMessages.count)", category: "MessageStore")
                log("==================================================", category: "App")
                
                let sortedMessages = allMessages.sorted { $0.createdAt < $1.createdAt }
                
                for (index, msg) in sortedMessages.enumerated() {
                    let body = msg.body ?? "nil"
                    let senderID = msg.senderID.isEmpty ? "empty" : msg.senderID
                    let roomID = msg.roomID.isEmpty ? "empty" : msg.roomID  // 完全なRoom IDでデバッグ
                    let recordName = msg.ckRecordName ?? "nil"
                    let isSent = msg.isSent ? "✅" : "❌"
                    
                    log("🔍 [\(String(format: "%02d", index))] \(isSent) '\(body)' | Room:\(roomID) | Sender:\(String(senderID.prefix(8))) | Record:\(String(recordName.prefix(8))) | \(msg.createdAt)", category: "MessageStore")
                    
                    // 特定のメッセージをハイライト
                    if body.contains("たああ") || body.contains("たああ") {
                        log("🎯 *** TRACKED MESSAGE FOUND IN DB *** '\(body)'", category: "MessageStore")
                    }
                }
                
                log("==================================================", category: "App")
                log("🔍 CURRENT ROOM: \(roomID)", category: "MessageStore")
                let roomMessages = sortedMessages.filter { $0.roomID == self.roomID }
                log("🔍 Messages for current room: \(roomMessages.count)", category: "MessageStore")
                log("🔍 Messages in UI: \(messages.count)", category: "MessageStore")
                log("==================================================", category: "App")
                
            } catch {
                log("❌ Failed to debug print database: \(error)", category: "MessageStore")
            }
        }
    }
    
    /// デバッグ用：定期的にDB状態をチェック
    func startPeriodicDatabaseCheck() {
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in
                log("🕐 Periodic DB check...", category: "MessageStore")
                self.debugPrintEntireDatabase()
            }
        }
    }
    
    /// デバッグ用：特定のメッセージをDB全体から検索
    func debugSearchForMessage(containing text: String) {
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                let matchingMessages = allMessages.filter { message in
                    if let body = message.body {
                        return body.contains(text)
                    }
                    return false
                }
                
                log("==================================================", category: "App")
                log("🔍 DEBUG SEARCH for '\(text)'", category: "MessageStore")
                log("🔍 Found \(matchingMessages.count) matching messages", category: "MessageStore")
                log("==================================================", category: "App")
                
                for (index, msg) in matchingMessages.enumerated() {
                    log("🔍 [\(index)] '\(msg.body ?? "nil")' | Room: \(String(msg.roomID.prefix(8))) | Sender: \(String(msg.senderID.prefix(8))) | \(msg.createdAt) | Record: \(msg.ckRecordName ?? "nil")", category: "MessageStore")
                }
                
                log("==================================================", category: "App")
                
            } catch {
                log("❌ Failed to search database: \(error)", category: "MessageStore")
            }
        }
    }
    
    // MARK: - Enhanced Utilities
    
    func getOfflineStatistics() -> OfflineStatistics {
        let queueStats = offlineManager.getQueueStatistics()
        let unsentCount = getUnsentMessageCount()
        
        return OfflineStatistics(
            isOnline: offlineManager.isOnline,
            queuedMessages: queueStats.totalQueued,
            failedMessages: queueStats.failedMessages,
            unsentMessages: unsentCount,
            lastSyncDate: offlineManager.lastSyncDate
        )
    }
    
    func forceSync() {
        offlineManager.forceSync()
    }
    
    func clearOfflineQueue() {
        offlineManager.clearQueue()
    }
    
    // MARK: - Debug Functions
    
    /// デバッグ用：DB全体のメッセージを表示
    func debugPrintAllMessages() {
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                
                log("\n" + String(repeating: "=", count: 80), category: "App")
                log("📊 ENTIRE DATABASE CONTENTS (\(allMessages.count) messages)", category: "DEBUG")
                log(String(repeating: "=", count: 80), category: "App")
                
                let sortedMessages = allMessages.sorted { $0.createdAt < $1.createdAt }
                
                for (index, msg) in sortedMessages.enumerated() {
                    let body = msg.body ?? "nil"
                    let senderInfo = msg.senderID.isEmpty ? "unknown" : msg.senderID
                    let roomInfo = msg.roomID.isEmpty ? "unknown" : String(msg.roomID.prefix(8))
                    let recordInfo = msg.ckRecordName ?? "nil"
                    
                    log("[\(String(format: "%03d", index))] 📝", category: "DEBUG")
                    log("    📍 Room: \(roomInfo)...", category: "App")
                    log("    👤 Sender: \(senderInfo)", category: "App")
                    log("    💬 Body: '\(body)'", category: "App")
                    log("    📅 Created: \(msg.createdAt)", category: "App")
                    log("    🆔 Record: \(recordInfo)", category: "App")
                    log("    ✅ Sent: \(msg.isSent)", category: "App")
                    log("", category: "App")
                }
                
                log(String(repeating: "=", count: 80), category: "App")
                log("END OF DATABASE DUMP", category: "DEBUG")
                log(String(repeating: "=", count: 80) + "\n", category: "App")
                
            } catch {
                log("❌ Failed to fetch all messages: \(error)", category: "DEBUG")
            }
        }
    }
    
    /// デバッグ用：特定のキーワードでDB全体を検索
    func debugSearchMessages(_ keyword: String) {
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                
                let matchingMessages = allMessages.filter { message in
                    if let body = message.body {
                        return body.contains(keyword)
                    }
                    return false
                }
                
                log("\n" + String(repeating: "=", count: 80), category: "App")
                log("🔍 SEARCH RESULTS for '\(keyword)' (\(matchingMessages.count) matches)", category: "DEBUG")
                log(String(repeating: "=", count: 80), category: "App")
                
                if matchingMessages.isEmpty {
                    log("🚫 No messages found containing '\(keyword)'", category: "DEBUG")
                } else {
                    let sortedMatches = matchingMessages.sorted { $0.createdAt < $1.createdAt }
                    
                    for (index, msg) in sortedMatches.enumerated() {
                        let body = msg.body ?? "nil"
                        let senderInfo = msg.senderID.isEmpty ? "unknown" : msg.senderID
                        let roomInfo = msg.roomID.isEmpty ? "unknown" : String(msg.roomID.prefix(8))
                        let recordInfo = msg.ckRecordName ?? "nil"
                        
                        log("MATCH [\(index + 1)] 🎯", category: "DEBUG")
                        log("    📍 Room: \(roomInfo)...", category: "App")
                        log("    👤 Sender: \(senderInfo)", category: "App")
                        log("    💬 Body: '\(body)'", category: "App")
                        log("    📅 Created: \(msg.createdAt)", category: "App")
                        log("    🆔 Record: \(recordInfo)", category: "App")
                        log("    ✅ Sent: \(msg.isSent)", category: "App")
                        log("", category: "App")
                    }
                }
                
                log(String(repeating: "=", count: 80), category: "App")
                log("END OF SEARCH RESULTS", category: "DEBUG")
                log(String(repeating: "=", count: 80) + "\n", category: "App")
                
            } catch {
                log("❌ Failed to search messages: \(error)", category: "DEBUG")
            }
        }
    }
    
    /// デバッグ用：現在のルームのメッセージと全体の比較
    func debugCompareRoomMessages() {
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                let currentRoomMessages = allMessages.filter { $0.roomID == self.roomID }
                
                log("\n" + String(repeating: "=", count: 80), category: "App")
                log("📊 ROOM MESSAGE COMPARISON", category: "DEBUG")
                log(String(repeating: "=", count: 80), category: "App")
                log("🏠 Current Room ID: \(roomID)", category: "DEBUG")
                log("📱 UI Messages: \(messages.count)", category: "DEBUG")
                log("🗄️ DB Room Messages: \(currentRoomMessages.count)", category: "DEBUG")
                log("🌍 Total DB Messages: \(allMessages.count)", category: "DEBUG")
                log("", category: "App")
                
                // UI とDBの違いをチェック
                let uiMessageIDs = Set(messages.map(\.id.uuidString))
                let dbMessageIDs = Set(currentRoomMessages.map(\.id.uuidString))
                
                let onlyInUI = uiMessageIDs.subtracting(dbMessageIDs)
                let onlyInDB = dbMessageIDs.subtracting(uiMessageIDs)
                
                if !onlyInUI.isEmpty {
                    log("⚠️ Messages only in UI (\(onlyInUI.count)): \(onlyInUI)", category: "DEBUG")
                }
                
                if !onlyInDB.isEmpty {
                    log("⚠️ Messages only in DB (\(onlyInDB.count)): \(onlyInDB)", category: "DEBUG")
                    
                    // DBにのみあるメッセージの詳細を表示
                    let dbOnlyMessages = currentRoomMessages.filter { onlyInDB.contains($0.id.uuidString) }
                    for msg in dbOnlyMessages {
                        log("🔍 DB-only message: '\(msg.body ?? "nil")' (Created: \(msg.createdAt))", category: "DEBUG")
                    }
                }
                
                // 異なるルームのメッセージも表示
                let otherRoomMessages = allMessages.filter { $0.roomID != self.roomID }
                if !otherRoomMessages.isEmpty {
                    log("", category: "App")
                    log("🏘️ Messages in other rooms (\(otherRoomMessages.count)):", category: "DEBUG")
                    let groupedByRoom = Dictionary(grouping: otherRoomMessages) { $0.roomID }
                    for (roomID, msgs) in groupedByRoom {
                        let roomInfo = String(roomID.prefix(8))
                        log("   Room \(roomInfo)...: \(msgs.count) messages", category: "DEBUG")
                    }
                }
                
                log(String(repeating: "=", count: 80), category: "App")
                log("END OF COMPARISON", category: "DEBUG")
                log(String(repeating: "=", count: 80) + "\n", category: "App")
                
            } catch {
                log("❌ Failed to compare room messages: \(error)", category: "DEBUG")
            }
        }
    }
}

// MARK: - Supporting Types

enum MessageStoreError: Error, LocalizedError, Sendable {
    case messageFailed(String) // Message ID instead of Message object
    case syncTimeout
    case invalidMessage
    case migrationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .messageFailed(let messageId):
            return "メッセージの送信に失敗しました: \(messageId)"
        case .syncTimeout:
            return "同期がタイムアウトしました"
        case .invalidMessage:
            return "無効なメッセージです"
        case .migrationFailed(let error):
            return "ユーザーIDマイグレーションに失敗しました: \(error)"
        }
    }
}

struct OfflineStatistics {
    let isOnline: Bool
    let queuedMessages: Int
    let failedMessages: Int
    let unsentMessages: Int
    let lastSyncDate: Date?
    
    var hasIssues: Bool {
        return queuedMessages > 0 || failedMessages > 0 || unsentMessages > 0
    }
}
