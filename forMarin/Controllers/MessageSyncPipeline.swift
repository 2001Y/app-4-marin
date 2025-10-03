import Foundation
import CloudKit
import SwiftData

extension Notification.Name {
    static let messagePipelineDidStart = Notification.Name("MessagePipelineDidStart")
    static let messagePipelineDidFinish = Notification.Name("MessagePipelineDidFinish")
    static let messagePipelineDidFail = Notification.Name("MessagePipelineDidFail")
    static let messagePipelineDidReceiveMessage = Notification.Name("MessagePipelineDidReceiveMessage")
    static let messagePipelineDidDeleteMessage = Notification.Name("MessagePipelineDidDeleteMessage")
    static let messagePipelineDidUpdateReactions = Notification.Name("MessagePipelineDidUpdateReactions")
    static let messagePipelineDidUpdateAttachment = Notification.Name("MessagePipelineDidUpdateAttachment")
    static let messagePipelineZoneDidChange = Notification.Name("MessagePipelineZoneDidChange")
}

// MARK: - CloudKit Error Extensions

extension Error {
    var isConflictError: Bool {
        if let ckError = self as? CKError {
            return ckError.code == .serverRecordChanged
        }
        return false
    }
    
    var serverRecord: CKRecord? {
        if let ckError = self as? CKError,
           ckError.code == .serverRecordChanged {
            return ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        }
        return nil
    }
}

/// Notificationベースの同期パイプライン。
/// 旧 `MessageSyncService` (Combine + 手動クエリ) は CKSyncEngine と二重取得を起こしていたため廃止済み。
/// このクラスを唯一の同期経路として維持すること。
@available(iOS 17.0, *)
@MainActor
final class MessageSyncPipeline: NSObject {

    // Reaction update key for Hashable Set
    private struct ReactionKey: Hashable {
        let roomID: String
        let messageRecordName: String
    }

    private struct SyncBatch {
        var records: [CKRecord]
        var deletedRecordIDs: [CKRecord.ID]
        var deletedZoneIDs: [CKRecordZone.ID]

        mutating func merge(_ other: SyncBatch) {
            records.append(contentsOf: other.records)
            deletedRecordIDs.append(contentsOf: other.deletedRecordIDs)
            deletedZoneIDs.append(contentsOf: other.deletedZoneIDs)
        }
    }

    private let messageDesiredKeys: [String] = [
        // Message
        "roomID",
        "senderID",
        "text",
        "timestamp",
        "attachment",
        "createdAt",
        // Common refs used by non-Message types too
        CKSchema.FieldKey.messageRef,
        CKSchema.FieldKey.memberRef,
        CKSchema.FieldKey.emoji,
        // MessageAttachment
        CKSchema.FieldKey.asset,
        // SignalMailbox
        CKSchema.FieldKey.userId,
        CKSchema.FieldKey.targetUserId,
        CKSchema.FieldKey.intentEpoch,
        CKSchema.FieldKey.callEpoch,
        CKSchema.FieldKey.consumedEpoch,
        CKSchema.FieldKey.lastSeenAt,
        CKSchema.FieldKey.updatedAt,
        CKSchema.FieldKey.mailboxPayload
    ]
    static let shared = MessageSyncPipeline()
    
    let privateDB: CKDatabase
    private let sharedDB: CKDatabase
    
    // Schema creation flag
    
    // 同期制御用のキャッシュ
    private var recentlySyncedRecords: Set<String> = []
    private var lastSyncTime: Date = Date()
    private let syncCooldown: TimeInterval = 5.0 // 5秒のクールダウン
    
    // パフォーマンス最適化：変更トークン管理
    // 同期トリガのコアレッサ（多重実行抑止＋デバウンス）
    private let syncCoordinator = SyncCoordinator()
    // Legacy検出に伴う多重リセット抑止
    private var hasTriggeredLegacyReset: Bool = false
    override init() {
        // CloudKit 接続は CloudKitChatManager に集約（コンテナIDの重複定義を排除）
        self.privateDB = CloudKitChatManager.shared.privateDB
        self.sharedDB = CloudKitChatManager.shared.sharedDB
        super.init()
        setupSyncEngine()
    }

    // ゾーン単位の変更ヒント（CKSyncEngine由来）
    func onZoneChangeHint(scope: CKDatabase.Scope, zoneID: CKRecordZone.ID, changed: Int, deleted: Int) {
        let roomID = zoneID.zoneName
        log("[ZONE] zone_changed scope=\(scope.rawValue) zone=\(roomID) changed=\(changed) deleted=\(deleted)", category: "MessageSyncPipeline")
        NotificationCenter.default.post(name: .messagePipelineZoneDidChange,
                                        object: nil,
                                        userInfo: [
                                            "scope": scope.rawValue,
                                            "zoneID": zoneID,
                                            "roomID": roomID,
                                            "changedCount": changed,
                                            "deletedCount": deleted
                                        ])
    }

    private func notifySyncStarted(roomID: String?) {
        NotificationCenter.default.post(name: .messagePipelineDidStart,
                                        object: nil,
                                        userInfo: ["roomID": roomID as Any])
    }

    private func notifySyncFinished(roomID: String?) {
        NotificationCenter.default.post(name: .messagePipelineDidFinish,
                                        object: nil,
                                        userInfo: ["roomID": roomID as Any])
    }

    private func notifySyncFailed(roomID: String?, error: Error) {
        NotificationCenter.default.post(name: .messagePipelineDidFail,
                                        object: nil,
                                        userInfo: ["roomID": roomID as Any, "error": error])
    }

    private func notifyMessageReceived(_ message: Message) {
        NotificationCenter.default.post(name: .messagePipelineDidReceiveMessage,
                                        object: nil,
                                        userInfo: ["message": message])
    }

    private func notifyMessageDeleted(messageID: String) {
        NotificationCenter.default.post(name: .messagePipelineDidDeleteMessage,
                                        object: nil,
                                        userInfo: ["messageID": messageID])
    }

    private func notifyReactionsUpdated(roomID: String, messageRecordName: String) {
        NotificationCenter.default.post(name: .messagePipelineDidUpdateReactions,
                                        object: nil,
                                        userInfo: ["roomID": roomID, "recordName": messageRecordName])
    }

    private func notifyAttachmentUpdated(roomID: String, messageRecordName: String, localPath: String) {
        NotificationCenter.default.post(name: .messagePipelineDidUpdateAttachment,
                                        object: nil,
                                        userInfo: ["roomID": roomID, "recordName": messageRecordName, "localPath": localPath])
    }
    
    // MARK: - CKSyncEngine Setup
    
    private func setupSyncEngine() {
        // iOS 17+ 前提: シンプルなDBサブスクリプション＋差分同期パイプライン
        log("Using CloudKit DB subscriptions + delta sync (iOS17+)", category: "MessageSyncPipeline")
    }

    // MARK: - Public API
    
    /// 統一されたメッセージ同期API - 役割を自動判定して適切なデータベースを使用
    func syncMessagesForRoom(_ roomID: String) async {
        
        log("🔄 Starting unified sync for roomID: \(roomID)", category: "MessageSyncPipeline")
        notifySyncStarted(roomID: roomID)
        do {
            try await performQuery(roomID: roomID)
            log("✅ Unified sync completed successfully for roomID: \(roomID)", category: "MessageSyncPipeline")
            notifySyncFinished(roomID: roomID)
        } catch {
            log("❌ Unified sync failed for roomID: \(roomID): \(error)", category: "MessageSyncPipeline")
            notifySyncFailed(roomID: roomID, error: error)
        }
    }
    
    /// 全メッセージの統一同期（オーナー/参加者両方のメッセージ）
    func syncAllMessages() async {
        
        log("🔄 Starting unified sync for all messages", category: "MessageSyncPipeline")
        notifySyncStarted(roomID: nil)
        do {
            try await performQuery(roomID: nil)
            log("✅ Unified sync completed successfully for all messages", category: "MessageSyncPipeline")
            notifySyncFinished(roomID: nil)
        } catch {
            log("❌ Unified sync failed for all messages: \(error)", category: "MessageSyncPipeline")
            notifySyncFailed(roomID: nil, error: error)
        }
    }
    
    /// 役割ベースの同期戦略を取得（デバッグ/診断用）
    func getSyncStrategy(for roomID: String) async -> String {
        let chatManager = CloudKitChatManager.shared
        let cached = chatManager.isOwnerCached(roomID)
        let isOwner: Bool
        if let cached { isOwner = cached } else { isOwner = await chatManager.isOwnerOfRoom(roomID) }
        
        if isOwner {
            return "OWNER - Private DB (default + shared zones)"
        } else {
            return "PARTICIPANT - Shared DB (2-stage fetch)"
        }
    }
    

    func clearPersistedTokens() {
        CloudKitChatManager.shared.clearAllChangeTokens()
    }

    /// 統合診断機能 - 同期状態の詳細レポート
    func generateSyncDiagnosticReport() async -> String {
        let chatManager = CloudKitChatManager.shared
        var report = "📊 MessageSyncPipeline 診断レポート\n"
        report += "================================================\n\n"
        
        // 基本状態
        report += "🔧 基本状態:\n"
        report += "  - 最終同期時刻: \(lastSyncTime)\n"
        report += "  - 同期済みレコード数: \(recentlySyncedRecords.count)\n\n"
        
        // トークン状態
        report += "📱 変更トークン状態:\n"
        report += "  - Token storage managed by CloudKitChatManager (auto)\n\n"
        
        // 役割分析
        report += "👥 役割分析:\n"
        let ownedRooms = await chatManager.getOwnedRooms()
        let participatingRooms = await chatManager.getParticipatingRooms()
        report += "  - オーナーとしてのルーム数: \(ownedRooms.count)\n"
        report += "  - 参加者としてのルーム数: \(participatingRooms.count)\n\n"
        
        if !ownedRooms.isEmpty {
            report += "  オーナールーム: \(ownedRooms.prefix(3).joined(separator: ", "))\n"
        }
        if !participatingRooms.isEmpty {
            report += "  参加ルーム: \(participatingRooms.prefix(3).joined(separator: ", "))\n"
        }
        
        if recentlySyncedRecords.count > 1000 {
            report += "\n🔍 推奨アクション:\n"
            report += "  - 同期キャッシュをクリーンアップ\n"
        }
        
        return report
    }
    
    /// パフォーマンス最適化のクリーンアップ
    func performMaintenanceCleanup() {
        // 古い同期キャッシュをクリア
        if recentlySyncedRecords.count > 1000 {
            recentlySyncedRecords.removeAll()
            log("🧹 Sync cache cleaned up", category: "MessageSyncPipeline")
        }

        log("🔧 Maintenance cleanup completed (no strategy cache in new implementation)", category: "MessageSyncPipeline")
    }
    
    /// 🌟 [IDEAL UPLOAD] メッセージ送信（長時間実行アップロード対応）
    func sendMessage(_ message: Message) {
        
        // 🌟 [IDEAL UPLOAD] async実行で長時間実行アップロード対応
        self.sendMessageAsync(message)
    }
    
    /// 🌟 [IDEAL UPLOAD] 非同期メッセージ送信実装
    private func sendMessageAsync(_ message: Message) {
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performMessageSend(message)
        }
    }
    
    /// 🌟 [IDEAL UPLOAD] メッセージ送信の実際の実装
    private func performMessageSend(_ message: Message) async {
        do {
            // 送信先DBとゾーンを解決（オーナー=private / 参加者=shared）
            let (targetDB, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: message.roomID)
            let scopeLabel = (targetDB.databaseScope == .shared) ? "shared" : "private"
            log("[MSG] Sending message room=\(message.roomID) scope=\(scopeLabel) zone=\(zoneID.zoneName) id=\(message.id)", category: "MessageSyncPipeline")
            let record = createCKRecord(from: message, zoneID: zoneID)
            
            // 🌟 [IDEAL UPLOAD] 添付ファイルがある場合は長時間実行アップロードを使用
            let hasAttachment = record["attachment"] as? CKAsset != nil
            let savedRecord: CKRecord
            
            if hasAttachment {
                log("📤 [IDEAL UPLOAD] Using CKModifyRecordsOperation.isLongLived for large asset", category: "MessageSyncPipeline")
                savedRecord = try await performLongLivedUpload(record, in: targetDB)
            } else {
                savedRecord = try await targetDB.save(record)
            }
            await MainActor.run {
                message.ckRecordName = savedRecord.recordID.recordName
                message.isSent = true
                
                // CKAssetがある場合はログを出力
                if let _ = record["attachment"] as? CKAsset {
                    log("✅ [IDEAL UPLOAD] Message with attachment sent successfully: \(message.id)", category: "MessageSyncPipeline")
                } else {
                    log("[MSG] Message send success id=\(message.id) scope=\(scopeLabel) zone=\(zoneID.zoneName)", category: "MessageSyncPipeline")
                }
            }
        } catch {
            await MainActor.run {
                // スキーマ関連のエラーかチェック
                if let ckError = error as? CKError, ckError.code == .invalidArguments {
                    if ckError.localizedDescription.contains("Unknown field") {
                        log("⚠️ Schema not ready for message send, message will be queued: \(ckError.localizedDescription)", category: "MessageSyncPipeline")
                        message.isSent = false
                        // MessageStoreでリトライされるようにエラーを送信しない
                        return
                    }
                }
                if let ckError = error as? CKError, (ckError.code == .permissionFailure || ckError.localizedDescription.lowercased().contains("shared zone update is not enabled")) {
                    let isProd = CloudKitChatManager.shared.checkIsProductionEnvironment()
                    let containerID = CloudKitChatManager.shared.containerID
                    let ownerCached = CloudKitChatManager.shared.isOwnerCached(message.roomID)
                    let scopeHint = (ownerCached == false) ? "shared(参加者推定)" : ((ownerCached == true) ? "private(オーナー)" : "unknown")
                    log("🧭 [GUIDE] CloudKit 書込権限エラー（\(ckError.code.rawValue)）: 'Zone wide sharing' がOFF もしくは参加者が READ_ONLY の可能性", category: "MessageSyncPipeline")
                    log("🧭 [GUIDE] Console(\(isProd ? "Production" : "Development")) → Data → Private Database → Zones → [対象ゾーン(= roomID: \(message.roomID))] → 'Zone wide sharing is enabled' を ON", category: "MessageSyncPipeline")
                    log("🧭 [GUIDE] CKShare の参加者 Permission を READ_WRITE に設定 | container=\(containerID) scopeHint=\(scopeHint)", category: "MessageSyncPipeline")
                }
                
                notifySyncFailed(roomID: message.roomID, error: error)
                log("❌ [MSG] Message send failed id=\(message.id) room=\(message.roomID) error=\(error)", category: "MessageSyncPipeline")
            }
        }
    }
    
    /// 🌟 [IDEAL UPLOAD] 長時間実行アップロード実装
    private func performLongLivedUpload(_ record: CKRecord, in database: CKDatabase) async throws -> CKRecord {
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.qualityOfService = .userInitiated
            
            // 長時間実行を有効にする（iOS 11+の推奨方法）
            operation.configuration.isLongLived = true
            operation.savePolicy = .allKeys
            
            var savedRecord: CKRecord?
            
            operation.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success(let record):
                    savedRecord = record
                case .failure(let error):
                    log("❌ [IDEAL UPLOAD] Record save failed: \(error)", category: "MessageSyncPipeline")
                }
            }
            
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success():
                    if let record = savedRecord {
                        log("✅ [IDEAL UPLOAD] Long-lived operation completed successfully", category: "MessageSyncPipeline")
                        continuation.resume(returning: record)
                    } else {
                        let error = CloudKitChatManager.CloudKitChatError.recordSaveFailed
                        log("❌ [IDEAL UPLOAD] No record returned from long-lived operation", category: "MessageSyncPipeline")
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    log("❌ [IDEAL UPLOAD] Long-lived operation failed: \(error)", category: "MessageSyncPipeline")
                    continuation.resume(throwing: error)
                }
            }
            
            // オペレーションの進捗追跡
            operation.perRecordProgressBlock = { record, progress in
                log("⏳ [IDEAL UPLOAD] Upload progress for \(record.recordID.recordName): \(Int(progress * 100))%", category: "MessageSyncPipeline")
            }
            
            log("⏳ [IDEAL UPLOAD] Starting long-lived upload operation", category: "MessageSyncPipeline")
            database.add(operation)
        }
    }
    
    func updateMessage(_ message: Message) {
        
        guard let recordName = message.ckRecordName else {
            sendMessage(message)
            return
        }
        
        Task {
            do {
                // ゾーンを解決してRecordIDを構築
                let (_, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: message.roomID)
                let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
                // フェッチは両DBで試行
                let record: CKRecord
                if let rec = try? await privateDB.record(for: recordID) { record = rec } else { record = try await sharedDB.record(for: recordID) }
                
                // Update record fields（reactions/isSentはCloudKitに保存しない）
                record["text"] = (message.body ?? "") as CKRecordValue
                
                // 保存も該当DBへ
                if (try? await privateDB.record(for: recordID)) != nil {
                    _ = try await privateDB.save(record)
                } else {
                    _ = try await sharedDB.save(record)
                }
                await MainActor.run {
                    message.isSent = true
                    log("Message updated successfully: \(message.id)", category: "MessageSyncPipeline")
                }
            } catch {
                await MainActor.run {
                    notifySyncFailed(roomID: message.roomID, error: error)
                    log("Failed to update message: \(error)", category: "MessageSyncPipeline")
                }
            }
        }
    }
    
    func deleteMessage(_ message: Message) {
        guard let recordName = message.ckRecordName else {
            log("Cannot delete message without CloudKit record name", category: "MessageSyncPipeline")
            return
        }

        Task {
            do {
                let (_, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: message.roomID)
                let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
                if (try? await privateDB.record(for: recordID)) != nil {
                    try await privateDB.deleteRecord(withID: recordID)
                } else {
                    try await sharedDB.deleteRecord(withID: recordID)
                }

                await MainActor.run {
                    notifyMessageDeleted(messageID: message.id.uuidString)
                    log("Message deleted successfully: \(message.id)", category: "MessageSyncPipeline")
                }
            } catch {
                await MainActor.run {
                    notifySyncFailed(roomID: message.roomID, error: error)
                    log("Failed to delete message: \(error)", category: "MessageSyncPipeline")
                }
            }
        }
    }

    func checkForUpdates(roomID: String? = nil) {

        log("Manual checkForUpdates called for roomID: \(roomID ?? "nil")", level: "DEBUG", category: "MessageSyncPipeline")

        Task { [weak self] in
            await self?.performManualSync(roomID: roomID)
        }
    }
    
    private func performManualSync(roomID: String?) async {
        await syncCoordinator.requestSync(trigger: "manual") { [weak self] in
            guard let self = self else { return }
            let (dt, cooldown): (TimeInterval, TimeInterval) = await MainActor.run {
                (Date().timeIntervalSince(self.lastSyncTime), self.syncCooldown)
            }
            if dt < cooldown {
                log("Sync cooldown active, skip. Δt=\(dt)", level: "DEBUG", category: "MessageSyncPipeline")
                return
            }
            await MainActor.run { self.notifySyncStarted(roomID: roomID) }
            do {
                try await self.performQuery(roomID: roomID)
                await MainActor.run { self.notifySyncFinished(roomID: roomID) }
            } catch {
                await MainActor.run {
                    if let ckError = error as? CKError, ckError.code == .partialFailure {
                        log("Partial failure during sync - possible missing share acceptance", level: "DEBUG", category: "MessageSyncPipeline")
                    }
                    if let ckError = error as? CKError, ckError.code == .invalidArguments,
                       ckError.localizedDescription.contains("Unknown field") {
                        log("Schema not ready yet, will retry later: \(ckError.localizedDescription)", level: "DEBUG", category: "MessageSyncPipeline")
                        self.notifySyncFinished(roomID: roomID)
                        return
                    }
                    self.notifySyncFailed(roomID: roomID, error: error)
                    log("Manual sync failed: \(error)", category: "MessageSyncPipeline")
                }
            }
        }
    }
    
    private func fetchDelta(for scope: CKDatabase.Scope, roomID: String?) async throws -> SyncBatch {
        let manager = CloudKitChatManager.shared
        let summary = try await manager.fetchDatabaseChanges(scope: scope)
        let filteredChanged: [CKRecordZone.ID]
        if let roomID {
            filteredChanged = summary.changedZoneIDs.filter { $0.zoneName == roomID }
        } else {
            filteredChanged = summary.changedZoneIDs
        }

        let zoneBatch: CloudKitChatManager.ZoneChangeBatch
        if filteredChanged.isEmpty {
            zoneBatch = CloudKitChatManager.ZoneChangeBatch(changedRecords: [], deletedRecordIDs: [])
        } else {
            zoneBatch = try await manager.fetchRecordZoneChanges(scope: scope,
                                                                 zoneIDs: filteredChanged,
                                                                 desiredKeys: messageDesiredKeys)
        }

        let filteredDeletedZones: [CKRecordZone.ID]
        if let roomID {
            filteredDeletedZones = summary.deletedZoneIDs.filter { $0.zoneName == roomID }
        } else {
            filteredDeletedZones = summary.deletedZoneIDs
        }

        return SyncBatch(records: zoneBatch.changedRecords,
                         deletedRecordIDs: zoneBatch.deletedRecordIDs,
                         deletedZoneIDs: filteredDeletedZones)
    }

    private func performQuery(roomID: String?) async throws {
        let chatManager = CloudKitChatManager.shared
        var scopesToSync: [CKDatabase.Scope] = []

        if let roomID {
            let cached = chatManager.isOwnerCached(roomID)
            let isOwner: Bool
            if let cached {
                isOwner = cached
            } else {
                isOwner = await chatManager.isOwnerOfRoom(roomID)
            }
            scopesToSync = [isOwner ? .private : .shared]
        } else {
            scopesToSync = [.private, .shared]
        }

        var aggregate = SyncBatch(records: [], deletedRecordIDs: [], deletedZoneIDs: [])

        for scope in scopesToSync {
            do {
                let batch = try await fetchDelta(for: scope, roomID: roomID)
                aggregate.merge(batch)
            } catch let error as CloudKitChatManager.CloudKitChatError {
                if error == .requiresFullReset {
                    log("⚠️ Detected invalid change token for scope=\(scope.rawValue). Triggering full reset.", category: "MessageSyncPipeline")
                    try await chatManager.performCompleteReset(bypassSafetyCheck: true)
                    throw error
                } else {
                    throw error
                }
            }
        }

        if !aggregate.deletedZoneIDs.isEmpty {
            await chatManager.handleDeletedZones(Array(Set(aggregate.deletedZoneIDs)))
        }

        handleRecordDeletions(aggregate.deletedRecordIDs)
        await processNonMessageRecords(aggregate.records, roomFilter: roomID)

        let messageRecords = aggregate.records.filter { $0.recordType == "Message" }
        await MainActor.run {
            processRecords(messageRecords, roomID: roomID)
        }
    }

    private func handleRecordDeletions(_ recordIDs: [CKRecord.ID]) {
        guard !recordIDs.isEmpty else { return }
        for recordID in recordIDs {
            recentlySyncedRecords.remove(recordID.recordName)
            notifyMessageDeleted(messageID: recordID.recordName)
        }
    }

    private func processNonMessageRecords(_ records: [CKRecord], roomFilter: String?) async {
        let reactionTypes: Set<String> = [CKSchema.SharedType.reaction, "MessageReaction"]
        var affectedReactions: Set<ReactionKey> = []
        var pendingAttachments: [(roomID: String, messageRecordName: String, fileURL: URL)] = []
        var mailboxApplied = 0

        for record in records {
            if reactionTypes.contains(record.recordType) {
                if let messageRef = record[CKSchema.FieldKey.messageRef] as? CKRecord.Reference {
                    let zoneRoomID = messageRef.recordID.zoneID.zoneName
                    let messageName = messageRef.recordID.recordName
                    if let filter = roomFilter, filter != zoneRoomID { continue }
                    affectedReactions.insert(ReactionKey(roomID: zoneRoomID, messageRecordName: messageName))
                }
                continue
            }

            if record.recordType == "MessageAttachment" {
                guard let messageRef = record["messageRef"] as? CKRecord.Reference,
                      let asset = record["asset"] as? CKAsset,
                      let srcURL = asset.fileURL else { continue }
                let zoneRoomID = messageRef.recordID.zoneID.zoneName
                if let filter = roomFilter, filter != zoneRoomID { continue }
                let messageName = messageRef.recordID.recordName
                let localURL = AttachmentManager.makeFileURL(ext: srcURL.pathExtension)
                do {
                    if !FileManager.default.fileExists(atPath: localURL.path) {
                        try FileManager.default.copyItem(at: srcURL, to: localURL)
                    }
                    pendingAttachments.append((roomID: zoneRoomID, messageRecordName: messageName, fileURL: localURL))
                } catch {
                    log("⚠️ Failed to copy attachment asset: \(error)", category: "MessageSyncPipeline")
                }
                continue
            }

            if record.recordType == CKSchema.SharedType.signalMailbox {
                let zoneRoomID = record.recordID.zoneID.zoneName
                if let filter = roomFilter, filter != zoneRoomID { continue }
                let applied = await P2PController.shared.applyMailboxRecord(record)
                if applied {
                    mailboxApplied += 1
                }
                continue
            }
        }

        for key in affectedReactions {
            notifyReactionsUpdated(roomID: key.roomID, messageRecordName: key.messageRecordName)
        }

        for item in pendingAttachments {
            notifyAttachmentUpdated(roomID: item.roomID, messageRecordName: item.messageRecordName, localPath: item.fileURL.path)
        }

        if mailboxApplied > 0 {
            log("[P2P] Applied SignalMailbox records: \(mailboxApplied)", category: "MessageSyncPipeline")
        }
    }

    @MainActor
    private func processRecords(_ records: [CKRecord], roomID: String?) {
        // 重複排除
        var uniqueRecords: [String: CKRecord] = [:]
        for record in records {
            uniqueRecords[record.recordID.recordName] = record
        }

        let deduplicatedRecords = Array(uniqueRecords.values)

        log("🔁 Sync processing: unique=\(deduplicatedRecords.count) total=\(records.count) room=\(roomID ?? "nil")", category: "MessageSyncPipeline")

        // クールダウンチェック
        let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
        if timeSinceLastSync < syncCooldown { return }

        var newMessagesCount = 0
        var duplicateCount = 0

        for record in deduplicatedRecords {
            let recordRoomID = record["roomID"] as? String ?? "unknown"
            let recordName = record.recordID.recordName

            if recentlySyncedRecords.contains(recordName) {
                duplicateCount += 1
                continue
            }

            if let targetRoomID = roomID, recordRoomID != targetRoomID {
                continue
            }

            if let message = createMessage(from: record) {
                log("✅ Created message object: \(message.id), body: \(message.body?.prefix(50) ?? "nil")", category: "MessageSyncPipeline")
                recentlySyncedRecords.insert(recordName)
                newMessagesCount += 1
                notifyMessageReceived(message)
            } else {
                log("❌ Failed to create message from record: \(record.recordID.recordName)", category: "MessageSyncPipeline")
            }
        }

        if recentlySyncedRecords.count > 1000 {
            recentlySyncedRecords.removeAll()
            log("🧽 Cleaned up sync cache", category: "MessageSyncPipeline")
        }

        lastSyncTime = Date()

        log("Manual sync completed with \(deduplicatedRecords.count) unique records (from \(records.count) total) - New: \(newMessagesCount), Duplicates: \(duplicateCount)", category: "MessageSyncPipeline")
    }
    

    

    
    // MARK: - Record Conversion
    
    private func createCKRecord(from message: Message, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: message.ckRecordName ?? UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: "Message", recordID: recordID)
        
        record["roomID"] = message.roomID as CKRecordValue
        record["senderID"] = message.senderID as CKRecordValue
        record["text"] = (message.body ?? "") as CKRecordValue
        record["timestamp"] = message.createdAt as CKRecordValue
        
        // Handle asset path for images/videos
        if let assetPath = message.assetPath {
            let assetURL = URL(fileURLWithPath: assetPath)
            if FileManager.default.fileExists(atPath: assetPath) {
                record["attachment"] = CKAsset(fileURL: assetURL)
            }
        }
        
        return record
    }
    
    private func createMessage(from record: CKRecord) -> Message? {
        guard record.recordType == "Message",
              let roomID = record["roomID"] as? String,
              let senderID = record["senderID"] as? String,
              let createdAt = record["timestamp"] as? Date else {
            // 旧スキーマ（必須キー欠如）を検出したら完全リセットを実行
            if record.recordType == "Message" && !hasTriggeredLegacyReset {
                hasTriggeredLegacyReset = true
                Task { @MainActor in
                    log("[AUTO RESET] Legacy Message record detected (missing required fields). Resetting...", category: "MessageSyncPipeline")
                }
                Task {
                    do {
                        try await CloudKitChatManager.shared.performCompleteReset(bypassSafetyCheck: true)
                        await MainActor.run {
                            log("[AUTO RESET] Complete reset finished.", category: "MessageSyncPipeline")
                        }
                    } catch {
                        await MainActor.run {
                            log("[AUTO RESET] Complete reset failed: \(error)", category: "MessageSyncPipeline")
                        }
                    }
                }
            }
            return nil
        }
        
        let body = record["text"] as? String
        var assetPath: String?
        
        // Handle asset download
        if let asset = record["attachment"] as? CKAsset,
           let fileURL = asset.fileURL {
            let localURL = AttachmentManager.makeFileURL(ext: fileURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: fileURL, to: localURL)
                assetPath = localURL.path
            } catch {
                log("Failed to copy asset: \(error)", category: "MessageSyncPipeline")
            }
        }
        
        let msg = Message(
            roomID: roomID,
            senderID: senderID,
            body: body,
            assetPath: assetPath,
            ckRecordName: record.recordID.recordName,
            createdAt: createdAt,
            isSent: true
        )
        // 正規化リアクションを取得してUIに反映
        Task { @MainActor in
            do {
                let list = try await CloudKitChatManager.shared.getReactionsForMessage(
                    messageRecordName: record.recordID.recordName,
                    roomID: roomID
                )
                var builder = ""
                let grouped = Dictionary(grouping: list, by: { $0.emoji })
                for (emoji, items) in grouped {
                    builder += String(repeating: emoji, count: items.count)
                }
                // reactionEmoji は廃止（CloudKit正規化に統一）
            } catch {
                // 応答なしは無視
            }
        }
        return msg
    }
    
    // MARK: - Offline Support (Legacy removed) – Engine に委譲済み
    
    // MARK: - Conflict Resolution
    
    func handleConflict(_ record: CKRecord, serverRecord: CKRecord) async -> CKRecord {
        // Use ConflictResolver for sophisticated conflict resolution
        return await ConflictResolver.shared.resolveConflict(localRecord: record, serverRecord: serverRecord)
    }
}

// iOS 17+ 前提のため、レガシー実装は削除
