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
    private var notificationTokens: [NSObjectProtocol] = []
    // 添付がメッセージ本体より先に届いた場合の一時キャッシュ（recordName -> localPath）
    private var pendingAttachmentPaths: [String: String] = [:]
    
    // Offline support
    private let offlineManager = OfflineManager.shared
    
    init(modelContext: ModelContext, roomID: String) {
        self.modelContext = modelContext
        self.roomID = roomID
        
        log("🏗️ Initialized with roomID: \(roomID)", category: "MessageStore")
        
        setupSyncSubscriptions()
        loadInitialMessages()
        
        // 特定のルーム用のPush Notificationサブスクリプションを設定
        setupRoomPushNotifications()
        
        // デバッグ出力/定期チェックは抑制（必要時に明示的に呼び出す）
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    // MARK: - Setup
    
    private func setupSyncSubscriptions() {
        let currentRoomID = self.roomID
        
        if #available(iOS 17.0, *) {
            // NOTE: MessageSyncPipeline 通知ベース。旧 MessageSyncService (Combine) は再導入しないこと。
            let center = NotificationCenter.default

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidReceiveMessage,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self,
                      let message = notification.userInfo?["message"] as? Message,
                      message.roomID == currentRoomID else { return }
                Task { @MainActor in self.handleReceivedMessage(message) }
            })

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidDeleteMessage,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self,
                      let messageID = notification.userInfo?["messageID"] as? String else { return }
                Task { @MainActor in self.handleDeletedMessage(messageID) }
            })

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidStart,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self else { return }
                let roomInfo = notification.userInfo?["roomID"] as? String
                if roomInfo == nil || roomInfo == currentRoomID {
                    Task { @MainActor in self.isSyncing = true }
                }
            })

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidFinish,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self else { return }
                let roomInfo = notification.userInfo?["roomID"] as? String
                if roomInfo == nil || roomInfo == currentRoomID {
                    Task { @MainActor in self.isSyncing = false }
                }
            })

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidFail,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self,
                      let error = notification.userInfo?["error"] as? Error else { return }
                let roomInfo = notification.userInfo?["roomID"] as? String
                if roomInfo == nil || roomInfo == currentRoomID {
                    Task { @MainActor in
                        self.syncError = error
                        self.isSyncing = false
                        log("Sync error: \(error)", category: "MessageStore")
                    }
                }
            })

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidUpdateReactions,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self,
                      let room = notification.userInfo?["roomID"] as? String,
                      room == currentRoomID,
                      let recordName = notification.userInfo?["recordName"] as? String else { return }
                Task { @MainActor in self.refreshReactions(for: recordName) }
            })

            notificationTokens.append(center.addObserver(forName: .messagePipelineDidUpdateAttachment,
                                                          object: nil,
                                                          queue: nil) { [weak self] notification in
                guard let self,
                      let room = notification.userInfo?["roomID"] as? String,
                      room == currentRoomID,
                      let recordName = notification.userInfo?["recordName"] as? String,
                      let localPath = notification.userInfo?["localPath"] as? String else { return }
                Task { @MainActor in
                    if let idx = self.messages.firstIndex(where: { $0.ckRecordName == recordName }) {
                        self.messages[idx].assetPath = localPath
                        do { try self.modelContext.save() } catch { log("Failed to save attachment path: \(error)", category: "MessageStore") }
                        log("Attachment updated for message=\(recordName)", level: "DEBUG", category: "MessageStore")
                    } else {
                        self.pendingAttachmentPaths[recordName] = localPath
                        log("Attachment queued (message not yet in UI): record=\(recordName)", level: "DEBUG", category: "MessageStore")
                    }
                }
            })
        }
        
        // Subscribe to offline manager events
        offlineManager.$isOnline
            .sink { [weak self] isOnline in
                Task { @MainActor in
                    if isOnline { self?.handleNetworkRestored() } else { self?.handleNetworkLost() }
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to failed message notifications
        NotificationCenter.default.publisher(for: .messageFailedPermanently)
            .sink { [weak self] notification in
                Task { @MainActor in
                    if let message = notification.userInfo?["message"] as? Message,
                       message.roomID == currentRoomID {
                        self?.handleMessageFailedPermanently(message)
                    }
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to schema ready notifications
        NotificationCenter.default.publisher(for: .cloudKitSchemaReady)
            .sink { [weak self] _ in
                Task { @MainActor in
                    log("CloudKit schema is ready, retrying failed messages", category: "MessageStore")
                    self?.retryFailedMessages()
                }
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
            MessageSyncPipeline.shared.checkForUpdates(roomID: roomID)
        }
    }
    
    // MARK: - Message Operations
    
func sendMessage(_ text: String) {
        guard let senderID = CloudKitChatManager.shared.currentUserID else {
            log("❌ Cannot send: currentUserID not available", category: "MessageStore")
            return
        }
        let message = Message(
            roomID: roomID,
            senderID: senderID,
            body: text,
            createdAt: Date(),
            isSent: false
        )
        
        // 追跡用の一時デバッグは削除（方針準拠）
        
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
            // 一時デバッグロギングを撤去
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
    
    func sendImageMessage(_ image: UIImage) {
        guard let senderID = CloudKitChatManager.shared.currentUserID else {
            log("❌ Cannot send image: currentUserID not available", category: "MessageStore")
            return
        }
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
        // 楽観的UI反映 + ローカル保存（テキストと整合）
        _ = message.generateRecordName()
        withAnimation(.easeInOut(duration: 0.2)) {
            messages.append(message)
            messages.sort { $0.createdAt < $1.createdAt }
        }
        modelContext.insert(message)
        do {
            try modelContext.save()
            log("Message(image) saved locally: id=\(message.id)", category: "MessageStore")
        } catch {
            if let idx = messages.firstIndex(of: message) { _ = withAnimation { messages.remove(at: idx) } }
            log("Failed to save image message locally: \(error)", category: "MessageStore")
            return
        }
        // 同期キューへ登録
        syncToCloudKit(message)
    }
    
    func sendVideoMessage(_ videoURL: URL) {
        guard let senderID = CloudKitChatManager.shared.currentUserID else {
            log("❌ Cannot send video: currentUserID not available", category: "MessageStore")
            return
        }
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
        // 楽観的UI反映 + ローカル保存（テキストと整合）
        _ = message.generateRecordName()
        withAnimation(.easeInOut(duration: 0.2)) {
            messages.append(message)
            messages.sort { $0.createdAt < $1.createdAt }
        }
        modelContext.insert(message)
        do {
            try modelContext.save()
            log("Message(video) saved locally: id=\(message.id)", category: "MessageStore")
        } catch {
            if let idx = messages.firstIndex(of: message) { _ = withAnimation { messages.remove(at: idx) } }
            log("Failed to save video message locally: \(error)", category: "MessageStore")
            return
        }
        // 同期キューへ登録
        syncToCloudKit(message)
    }
    
    func updateMessage(_ message: Message, newBody: String) {
        let oldBody = message.body
        message.body = newBody
        message.isSent = false
        let recNameInfo = message.ckRecordName ?? "nil"
        log("✏️ [UI UPDATE] commit start id=\(message.id) record=\(recNameInfo) room=\(message.roomID) newLen=\(newBody.count)", category: "MessageStore")
        
        // Save to persistent storage
        do {
            try modelContext.save()
            log("✏️ [UI UPDATE] local saved id=\(message.id) record=\(recNameInfo)", category: "MessageStore")
        } catch {
            // Revert on failure
            message.body = oldBody
            log("❌ [UI UPDATE] local save failed id=\(message.id) record=\(recNameInfo) error=\(error)", category: "MessageStore")
            return
        }
        
        // Sync via CKSyncEngine (WorkItem)
        Task { @MainActor in
            if #available(iOS 17.0, *) {
                if let recordName = message.ckRecordName {
                    await CKSyncEngineManager.shared.queueUpdateMessage(
                        recordName: recordName,
                        roomID: message.roomID,
                        newBody: newBody,
                        newTimestamp: Date()
                    )
                    message.isSent = true
                    log("✏️ [UI UPDATE] queued to Engine id=\(message.id) record=\(recNameInfo)", category: "MessageStore")
                }
            } else {
                
                log("⚠️ [UI UPDATE] CKSyncEngine not available on this OS version", category: "MessageStore")
                
            }
        }
    }
    
    func deleteMessage(_ message: Message) {
        let recNameInfo = message.ckRecordName ?? "nil"
        log("🗑️ [UI DELETE] request id=\(message.id) record=\(recNameInfo) room=\(message.roomID) hasAsset=\(message.assetPath != nil)", category: "MessageStore")
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
            log("🗑️ [UI DELETE] local removed id=\(message.id) record=\(recNameInfo)", category: "MessageStore")
        } catch {
            log("❌ [UI DELETE] local delete failed id=\(message.id) record=\(recNameInfo) error=\(error)", category: "MessageStore")
            // Re-add to UI if delete failed
            withAnimation {
                messages.append(message)
                messages.sort { $0.createdAt < $1.createdAt }
            }
            return
        }
        
        // Sync deletion via CKSyncEngine (WorkItem)
        if let recordName = message.ckRecordName, #available(iOS 17.0, *) {
            Task { @MainActor in
                await CKSyncEngineManager.shared.queueDeleteMessage(recordName: recordName, roomID: message.roomID)
                log("🗑️ [UI DELETE] queued to Engine record=\(recordName)", category: "MessageStore")
            }
        }
    }
    
    /// メッセージにリアクション絵文字を追加（CloudKit正規化レコードに一本化）
    func addReaction(_ emoji: String, to message: Message) {
        log("Reaction enqueue only (CloudKit): \(emoji) to id=\(message.id)", category: "MessageStore")
        
        guard let recordName = message.ckRecordName else {
            log("Cannot sync reaction: message has no CloudKit record name", category: "MessageStore")
            return
        }
        
        Task { @MainActor in
            if #available(iOS 17.0, *) {
                if let userID = CloudKitChatManager.shared.currentUserID {
                    await CKSyncEngineManager.shared.queueReaction(
                        messageRecordName: recordName,
                        roomID: message.roomID,
                        emoji: emoji,
                        userID: userID
                    )
                    message.isSent = true
                    log("Reaction enqueued to CKSyncEngine: \(emoji)", category: "MessageStore")
                }
            } else {
                let error = NSError(
                    domain: "MessageStore",
                    code: -1001,
                    userInfo: [NSLocalizedDescriptionKey: "iOS 17 or later is required for CloudKit reaction sync"]
                )
                syncError = error
                log("❌ Reaction sync requires iOS 17+: \(error.localizedDescription)", category: "MessageStore")
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func refreshReactions(for messageRecordName: String) {
        let currentRoomID = self.roomID
        guard messages.contains(where: { $0.ckRecordName == messageRecordName }) else { return }
        Task { @MainActor in
            do {
                let list = try await CloudKitChatManager.shared.getReactionsForMessage(
                    messageRecordName: messageRecordName,
                    roomID: currentRoomID
                )
                if !list.isEmpty {
                    log("Reactions fetched (count=\(list.count)) for message: \(messageRecordName)", category: "MessageStore")
                }
                NotificationCenter.default.post(
                    name: .reactionsUpdated,
                    object: nil,
                    userInfo: ["recordName": messageRecordName]
                )
            } catch {
                log("Failed to refresh reactions for message: \(messageRecordName) - \(error)", category: "MessageStore")
            }
        }
    }
    /*
            log("🎯 ENQUEUE TRACKED MESSAGE (ENGINE): '\(body)' - Message ID: \(message.id)", category: "MessageStore")
        }

        // Engineへ完全移行：WorkItem化して送信を委譲
        Task { @MainActor in
            if #available(iOS 17.0, *) {
                await CKSyncEngineManager.shared.queueMessage(message)
                if let path = message.assetPath {
                    await CKSyncEngineManager.shared.queueAttachment(
                        messageRecordName: message.id.uuidString,
                        roomID: message.roomID,
                        localFileURL: URL(fileURLWithPath: path)
                    )
                }
                log("📮 Queued message to CKSyncEngine: id=\(message.id)", category: "MessageStore")
            } else {
                log("⚠️ CKSyncEngine not available on this OS version", category: "MessageStore")
            }
        }
    }
    
*/
    private func syncToCloudKit(_ message: Message) {
        guard message.isValidForSync else {
            log("Message is not valid for sync: \(message.id)", category: "MessageStore")
            return
        }
        // 一時デバッグロギングを撤去
        Task { @MainActor in
            if #available(iOS 17.0, *) {
                await CKSyncEngineManager.shared.queueMessage(message)
                if let path = message.assetPath {
                    await CKSyncEngineManager.shared.queueAttachment(
                        messageRecordName: message.id.uuidString,
                        roomID: message.roomID,
                        localFileURL: URL(fileURLWithPath: path)
                    )
                }
                log("Queued message to CKSyncEngine: id=\(message.id)", category: "MessageStore")
            } else {
                log("CKSyncEngine not available on this OS version", category: "MessageStore")
            }
        }
    }

    private func handleReceivedMessage(_ message: Message) {
        // 受信処理の重複チェックは行うが、ログは最小限
        
        // 改善された重複チェック：より厳密にチェックし、デバッグ情報を追加
        if let targetRecordName = message.ckRecordName {
            // 1. メモリ内のメッセージをチェック（同一レコード名で同一送信者のみ）
            let existingInMemory = messages.first(where: { 
                $0.ckRecordName == targetRecordName && $0.senderID == message.senderID 
            })
            if let existing = existingInMemory {
                // 既存UI更新（送達確定・リアクション差分・添付反映）
                existing.isSent = true
                // reactionEmoji は廃止（CloudKit正規化に統一）
                if let newPath = message.assetPath, existing.assetPath != newPath {
                    existing.assetPath = newPath
                }
                // 添付が先行していた場合の適用
                if let queuedPath = pendingAttachmentPaths[targetRecordName] {
                    if existing.assetPath != queuedPath {
                        existing.assetPath = queuedPath
                        do { try modelContext.save() } catch { log("Failed to save queued attachment path: \(error)", category: "MessageStore") }
                    }
                    pendingAttachmentPaths.removeValue(forKey: targetRecordName)
                }
                log("[DEDUP] In-memory matched ck=\(String(targetRecordName.prefix(8))) sender=\(String(message.senderID.prefix(8)))", category: "MessageStore")
                return
            }
            
            // 異なる送信者の同一レコード名は処理を続行
            let sameRecordDifferentSender = messages.first(where: { 
                $0.ckRecordName == targetRecordName && $0.senderID != message.senderID 
            })
            _ = sameRecordDifferentSender
            
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
                    existing.isSent = true
                    // UIにまだ無ければ追加
                    let inUI = messages.contains { $0.ckRecordName == targetRecordName && $0.senderID == currentSenderID }
                    if !inUI {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            messages.append(existing)
                            messages.sort { $0.createdAt < $1.createdAt }
                        }
                        log("[DEDUP] DB matched and appended ck=\(String(targetRecordName.prefix(8)))", category: "MessageStore")
                    }
                    // 添付が先行していた場合の適用
                    if let queuedPath = pendingAttachmentPaths[targetRecordName] {
                        if existing.assetPath != queuedPath {
                            existing.assetPath = queuedPath
                            do { try modelContext.save() } catch { log("Failed to save queued attachment path: \(error)", category: "MessageStore") }
                        }
                        pendingAttachmentPaths.removeValue(forKey: targetRecordName)
                    }
                    log("[DEDUP] DB matched ck=\(String(targetRecordName.prefix(8))) sender=\(String(currentSenderID.prefix(8)))", category: "MessageStore")
                    return
                }
                
                // 異なる送信者の同一レコード名をチェック（情報ログのみ）
                let differentSenderDescriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { msg in 
                        msg.ckRecordName == targetRecordName && msg.senderID != currentSenderID
                    }
                )
                let differentSenderMessages = try modelContext.fetch(differentSenderDescriptor)
                _ = differentSenderMessages
            } catch {
                // エラーが発生した場合は処理を続行
            }
            
            // 重複なし
        } else {
            // ckRecordNameがない場合は、他の条件で重複チェック
            let possibleDuplicate = messages.first { existing in
                existing.senderID == message.senderID &&
                existing.body == message.body &&
                abs(existing.createdAt.timeIntervalSince(message.createdAt)) < 60 // 60秒以内に拡大
            }
            
            if let duplicate = possibleDuplicate {
                _ = duplicate
                log("[DEDUP] Heuristic duplicate (no ck) sender=\(String(message.senderID.prefix(8))) body=\(String((message.body ?? "").prefix(10)))", category: "MessageStore")
                return
            }
        }
        
        // システムメッセージ（FaceTime登録）の場合はローカルに相手のFaceTimeIDを保存
        if let sysID = Message.extractFaceTimeID(from: message.body) {
            var dict = (UserDefaults.standard.dictionary(forKey: "FaceTimeIDs") as? [String: String]) ?? [:]
            dict[message.senderID] = sysID
            UserDefaults.standard.set(dict, forKey: "FaceTimeIDs")
            log("📞 [SYS] Stored FaceTimeID for sender=\(String(message.senderID.prefix(8)))", category: "MessageStore")
        }

        // roomIDチェック
        if message.roomID != self.roomID {
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
            
            // 添付が先に到着していた場合はここで適用
            if let rnFull = message.ckRecordName, let queuedPath = pendingAttachmentPaths[rnFull] {
                if message.assetPath != queuedPath {
                    message.assetPath = queuedPath
                    pendingAttachmentPaths.removeValue(forKey: rnFull)
                    do { try modelContext.save() } catch { log("Failed to save queued attachment path: \(error)", category: "MessageStore") }
                }
            }
            
            let rn = message.ckRecordName.map { String($0.prefix(8)) } ?? "nil"
            log("✅ Message received: id=\(message.id) sender=\(String(message.senderID.prefix(8))) record=\(rn)", category: "MessageStore")
        
        } catch {
            log("❌ Failed to save received message: \(error)", category: "MessageStore")
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
        log("Manual refresh requested for roomID: \(roomID)", category: "MessageStore")
        
        if #available(iOS 17.0, *) {
            MessageSyncPipeline.shared.checkForUpdates(roomID: roomID)
        } else {
            // Manual refresh for legacy implementation
            loadInitialMessages()
        }
        
        // 余計な全件ダンプは行わず、必要最小限の差分確認のみ実施
        Task { @MainActor in
            do {
                let descriptor = FetchDescriptor<Message>()
                let allMessages = try modelContext.fetch(descriptor)
                let currentRoomMessages = allMessages.filter { $0.roomID == self.roomID }
                let sortedMessages = currentRoomMessages.sorted { $0.createdAt < $1.createdAt }
                
                // 送信者別サマリを短く出力（UI検証しやすく集約）
                let myID = CloudKitChatManager.shared.currentUserID ?? "unknown"
                let mineCount = sortedMessages.filter { $0.senderID == myID }.count
                let otherCount = sortedMessages.count - mineCount
                log("Local DB: total=\(sortedMessages.count) room=\(roomID) mine=\(mineCount) other=\(otherCount)", category: "MessageStore")
                log("UI shows \(messages.count) messages", category: "MessageStore")
                
                // 件数/内容差分に応じてUI最小更新
                if sortedMessages.count != messages.count {
                    log("Message count mismatch detected. Reloading UI...", category: "MessageStore")
                    log("Before UI update: messages.count = \(messages.count), sortedMessages.count = \(sortedMessages.count)", category: "MessageStore")
                    
                    self.messages.removeAll()
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.messages = sortedMessages
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            log("After UI update: messages.count = \(self.messages.count)", category: "MessageStore")
                            if self.messages.count != sortedMessages.count {
                                self.messages = sortedMessages
                            }
                        }
                    }
                } else {
                    // 同数でも本文差分があれば最小更新
                    let uiMessageBodies = Set(messages.compactMap(\.body))
                    let dbMessageBodies = Set(sortedMessages.compactMap(\.body))
                    if uiMessageBodies != dbMessageBodies {
                        log("Message content mismatch detected despite same count. Reloading UI...", category: "MessageStore")
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.messages = sortedMessages
                        }
                    }
                }
            } catch {
                log("Failed to refresh from local DB: \(error)", category: "MessageStore")
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
            MessageSyncPipeline.shared.checkForUpdates(roomID: roomID)
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
                    
                    // 一時デバッグロギングを撤去
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
    
    func getOfflineStatistics() async -> OfflineStatistics {
        let unsentCount = getUnsentMessageCount()
        var queued = 0
        if #available(iOS 17.0, *) {
            let stats = await CKSyncEngineManager.shared.pendingStats()
            queued = stats.total
        }
        return OfflineStatistics(
            isOnline: offlineManager.isOnline,
            queuedMessages: queued,
            failedMessages: 0,
            unsentMessages: unsentCount,
            lastSyncDate: offlineManager.lastSyncDate
        )
    }
    
    func forceSync() async {
        if #available(iOS 17.0, *) {
            await CKSyncEngineManager.shared.kickSyncNow()
        } else {
            log("⚠️ forceSync no-op (CKSyncEngine unavailable)", category: "MessageStore")
        }
    }
    
    func clearOfflineQueue() {
        if #available(iOS 17.0, *) {
            Task { await CKSyncEngineManager.shared.resetEngines() }
        } else {
            log("⚠️ clearOfflineQueue no-op (CKSyncEngine unavailable)", category: "MessageStore")
        }
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
