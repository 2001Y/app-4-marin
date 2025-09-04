import Foundation
import CloudKit
import Combine
import SwiftData

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

@available(iOS 17.0, *)
@MainActor
class MessageSyncService: NSObject, ObservableObject {

    // Reaction update key for Hashable Set
    private struct ReactionKey: Hashable {
        let roomID: String
        let messageRecordName: String
    }
    static let shared = MessageSyncService()
    
    let container = CKContainer(identifier: "iCloud.forMarin-test")
    let privateDB: CKDatabase
    private let sharedDB: CKDatabase
    
    // Combine Publishers for reactive updates
    let messageReceived = PassthroughSubject<Message, Never>()
    let messageDeleted = PassthroughSubject<String, Never>()
    let syncError = PassthroughSubject<Error, Never>()
    let syncStatusChanged = PassthroughSubject<Bool, Never>()
    // Reactions updated for a specific message in a specific room
    let reactionsUpdated = PassthroughSubject<(roomID: String, messageRecordName: String), Never>()
    // 添付更新イベント（roomID, messageRecordName, localPath）
    let attachmentsUpdated = PassthroughSubject<(roomID: String, messageRecordName: String, localPath: String), Never>()
    
    
    // Schema creation flag
    private var isSyncDisabled: Bool = false
    
    // 同期制御用のキャッシュ
    private var recentlySyncedRecords: Set<String> = []
    private var lastSyncTime: Date = Date()
    private let syncCooldown: TimeInterval = 5.0 // 5秒のクールダウン
    
    // パフォーマンス最適化：変更トークン管理
    private var privateDBChangeToken: CKServerChangeToken?
    private var sharedDBChangeToken: CKServerChangeToken?
    private var zoneChangeTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]
    // 同期トリガのコアレッサ（多重実行抑止＋デバウンス）
    private let syncCoordinator = SyncCoordinator()
    // Legacy検出に伴う多重リセット抑止
    private var hasTriggeredLegacyReset: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    
    
    override init() {
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
        super.init()
        setupNotificationObservers()
        setupSyncEngine()
        // Combine → NSNotification 橋渡し（View側の既存購読へ通知）
        reactionsUpdated
            .receive(on: RunLoop.main)
            .sink { info in
                NotificationCenter.default.post(
                    name: .reactionsUpdated,
                    object: nil,
                    userInfo: ["roomID": info.roomID, "recordName": info.messageRecordName]
                )
            }
            .store(in: &cancellables)
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .disableMessageSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                log("🛑 Sync disabled for schema creation", category: "MessageSyncService")
                self?.isSyncDisabled = true
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .enableMessageSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                log("✅ Sync re-enabled after schema creation", category: "MessageSyncService")
                self?.isSyncDisabled = false
            }
        }
    }
    
    // MARK: - CKSyncEngine Setup
    
    private func setupSyncEngine() {
        // iOS 17+ 前提: シンプルなDBサブスクリプション＋差分同期パイプライン
        log("Using CloudKit DB subscriptions + delta sync (iOS17+)", category: "MessageSyncService")
        
        // パフォーマンス最適化：保存されたトークンを復元
        loadPersistedTokens()
    }
    
    // MARK: - Performance Optimization: Token Management
    
    /// 永続化されたトークンを読み込み
    private func loadPersistedTokens() {
        let userDefaults = UserDefaults.standard
        
        // Private DB変更トークン
        if let privateTokenData = userDefaults.data(forKey: "MessageSync.PrivateDBToken") {
            do {
                privateDBChangeToken = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: privateTokenData)
                log("📱 Loaded Private DB change token", category: "MessageSyncService")
            } catch {
                log("⚠️ Failed to load Private DB change token: \(error)", category: "MessageSyncService")
            }
        }
        
        // Shared DB変更トークン
        if let sharedTokenData = userDefaults.data(forKey: "MessageSync.SharedDBToken") {
            do {
                sharedDBChangeToken = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: sharedTokenData)
                log("📱 Loaded Shared DB change token", level: "DEBUG", category: "MessageSyncService")
            } catch {
                log("⚠️ Failed to load Shared DB change token: \(error)", category: "MessageSyncService")
            }
        }
        
        // ゾーン変更トークン（簡略化のため最初は空で開始）
        log("📱 Token loading completed", category: "MessageSyncService")
    }
    
    /// 変更トークンを永続化
    private func persistTokens() {
        let userDefaults = UserDefaults.standard
        
        // Private DB変更トークン
        if let privateToken = privateDBChangeToken {
            do {
                let tokenData = try NSKeyedArchiver.archivedData(withRootObject: privateToken, requiringSecureCoding: true)
                userDefaults.set(tokenData, forKey: "MessageSync.PrivateDBToken")
                log("💾 Persisted Private DB change token", category: "MessageSyncService")
            } catch {
                log("⚠️ Failed to persist Private DB change token: \(error)", category: "MessageSyncService")
            }
        }
        
        // Shared DB変更トークン
        if let sharedToken = sharedDBChangeToken {
            do {
                let tokenData = try NSKeyedArchiver.archivedData(withRootObject: sharedToken, requiringSecureCoding: true)
                userDefaults.set(tokenData, forKey: "MessageSync.SharedDBToken")
                log("💾 Persisted Shared DB change token", level: "DEBUG", category: "MessageSyncService")
            } catch {
                log("⚠️ Failed to persist Shared DB change token: \(error)", category: "MessageSyncService")
            }
        }
        
        userDefaults.synchronize()
    }
    
    /// トークンをクリア（デバッグ用）
    func clearPersistedTokens() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: "MessageSync.PrivateDBToken")
        userDefaults.removeObject(forKey: "MessageSync.SharedDBToken")
        userDefaults.synchronize()
        
        privateDBChangeToken = nil
        sharedDBChangeToken = nil
        zoneChangeTokens.removeAll()
        
        log("🧹 All change tokens cleared", category: "MessageSyncService")
    }
    
    
    // MARK: - Public API
    
    /// 統一されたメッセージ同期API - 役割を自動判定して適切なデータベースを使用
    func syncMessagesForRoom(_ roomID: String) async {
        guard !isSyncDisabled else {
            log("🛑 Sync is disabled, skipping room sync", category: "MessageSyncService")
            return
        }
        
        log("🔄 Starting unified sync for roomID: \(roomID)", category: "MessageSyncService")
        
        do {
            try await performQuery(roomID: roomID)
            await MainActor.run {
                syncStatusChanged.send(true)
                log("✅ Unified sync completed successfully for roomID: \(roomID)", category: "MessageSyncService")
            }
        } catch {
            await MainActor.run {
                syncError.send(error)
                syncStatusChanged.send(false)
                log("❌ Unified sync failed for roomID: \(roomID): \(error)", category: "MessageSyncService")
            }
        }
    }
    
    /// 全メッセージの統一同期（オーナー/参加者両方のメッセージ）
    func syncAllMessages() async {
        guard !isSyncDisabled else {
            log("🛑 Sync is disabled, skipping all messages sync", category: "MessageSyncService")
            return
        }
        
        log("🔄 Starting unified sync for all messages", category: "MessageSyncService")
        
        do {
            try await performQuery(roomID: nil)
            await MainActor.run {
                syncStatusChanged.send(true)
                log("✅ Unified sync completed successfully for all messages", category: "MessageSyncService")
            }
        } catch {
            await MainActor.run {
                syncError.send(error)
                syncStatusChanged.send(false)
                log("❌ Unified sync failed for all messages: \(error)", category: "MessageSyncService")
            }
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
    
    /// 統合診断機能 - 同期状態の詳細レポート
    func generateSyncDiagnosticReport() async -> String {
        let chatManager = CloudKitChatManager.shared
        var report = "📊 MessageSyncService 診断レポート\n"
        report += "================================================\n\n"
        
        // 基本状態
        report += "🔧 基本状態:\n"
        report += "  - Sync有効: \(!isSyncDisabled)\n"
        report += "  - 最終同期時刻: \(lastSyncTime)\n"
        report += "  - 同期済みレコード数: \(recentlySyncedRecords.count)\n\n"
        
        // トークン状態
        report += "📱 変更トークン状態:\n"
        report += "  - Private DB: \(privateDBChangeToken != nil ? "保存済み" : "未保存")\n"
        report += "  - Shared DB: \(sharedDBChangeToken != nil ? "保存済み" : "未保存")\n"
        report += "  - ゾーントークン数: \(zoneChangeTokens.count)\n\n"
        
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
        
        report += "\n🔍 推奨アクション:\n"
        if privateDBChangeToken == nil && !ownedRooms.isEmpty {
            report += "  - Private DB同期を実行してトークンを取得\n"
        }
        if sharedDBChangeToken == nil && !participatingRooms.isEmpty {
            report += "  - Shared DB同期を実行してトークンを取得\n"
        }
        if recentlySyncedRecords.count > 1000 {
            report += "  - 同期キャッシュをクリーンアップ\n"
        }
        
        return report
    }
    
    /// パフォーマンス最適化のクリーンアップ
    func performMaintenanceCleanup() {
        // 古い同期キャッシュをクリア
        if recentlySyncedRecords.count > 1000 {
            recentlySyncedRecords.removeAll()
            log("🧹 Sync cache cleaned up", category: "MessageSyncService")
        }
        
        // トークンを永続化
        persistTokens()
        
        log("🔧 Maintenance cleanup completed (no strategy cache in new implementation)", category: "MessageSyncService")
    }
    
    /// 🌟 [IDEAL UPLOAD] メッセージ送信（長時間実行アップロード対応）
    func sendMessage(_ message: Message) {
        guard !isSyncDisabled else {
            log("🛑 Sync is disabled, skipping message send", category: "MessageSyncService")
            return
        }
        
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
            let record = createCKRecord(from: message, zoneID: zoneID)
            
            // 🌟 [IDEAL UPLOAD] 添付ファイルがある場合は長時間実行アップロードを使用
            let hasAttachment = record["attachment"] as? CKAsset != nil
            let savedRecord: CKRecord
            
            if hasAttachment {
                log("📤 [IDEAL UPLOAD] Using CKModifyRecordsOperation.isLongLived for large asset", category: "MessageSyncService")
                savedRecord = try await performLongLivedUpload(record, in: targetDB)
            } else {
                savedRecord = try await targetDB.save(record)
            }
            await MainActor.run {
                message.ckRecordName = savedRecord.recordID.recordName
                message.isSent = true
                
                // CKAssetがある場合はログを出力
                if let _ = record["attachment"] as? CKAsset {
                    log("✅ [IDEAL UPLOAD] Message with attachment sent successfully: \(message.id)", category: "MessageSyncService")
                } else {
                    log("Message sent successfully: \(message.id)", category: "MessageSyncService")
                }
            }
        } catch {
            await MainActor.run {
                // スキーマ関連のエラーかチェック
                if let ckError = error as? CKError, ckError.code == .invalidArguments {
                    if ckError.localizedDescription.contains("Unknown field") {
                        log("⚠️ Schema not ready for message send, message will be queued: \(ckError.localizedDescription)", category: "MessageSyncService")
                        message.isSent = false
                        // MessageStoreでリトライされるようにエラーを送信しない
                        return
                    }
                }
                
                syncError.send(error)
                log("Failed to send message: \(error)", category: "MessageSyncService")
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
                    log("❌ [IDEAL UPLOAD] Record save failed: \(error)", category: "MessageSyncService")
                }
            }
            
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success():
                    if let record = savedRecord {
                        log("✅ [IDEAL UPLOAD] Long-lived operation completed successfully", category: "MessageSyncService")
                        continuation.resume(returning: record)
                    } else {
                        let error = CloudKitChatError.recordSaveFailed
                        log("❌ [IDEAL UPLOAD] No record returned from long-lived operation", category: "MessageSyncService")
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    log("❌ [IDEAL UPLOAD] Long-lived operation failed: \(error)", category: "MessageSyncService")
                    continuation.resume(throwing: error)
                }
            }
            
            // オペレーションの進捗追跡
            operation.perRecordProgressBlock = { record, progress in
                log("⏳ [IDEAL UPLOAD] Upload progress for \(record.recordID.recordName): \(Int(progress * 100))%", category: "MessageSyncService")
            }
            
            log("⏳ [IDEAL UPLOAD] Starting long-lived upload operation", category: "MessageSyncService")
            database.add(operation)
        }
    }
    
    func updateMessage(_ message: Message) {
        guard !isSyncDisabled else {
            log("🛑 Sync is disabled, skipping message update", category: "MessageSyncService")
            return
        }
        
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
                    log("Message updated successfully: \(message.id)", category: "MessageSyncService")
                }
            } catch {
                await MainActor.run {
                    syncError.send(error)
                    log("Failed to update message: \(error)", category: "MessageSyncService")
                }
            }
        }
    }
    
    func deleteMessage(_ message: Message) {
        guard let recordName = message.ckRecordName else {
            log("Cannot delete message without CloudKit record name", category: "MessageSyncService")
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
                    messageDeleted.send(message.id.uuidString)
                    log("Message deleted successfully: \(message.id)", category: "MessageSyncService")
                }
            } catch {
                await MainActor.run {
                    syncError.send(error)
                    log("Failed to delete message: \(error)", category: "MessageSyncService")
                }
            }
        }
    }

    func checkForUpdates(roomID: String? = nil) {
        guard !isSyncDisabled else {
            log("Sync is disabled, skipping update check", category: "MessageSyncService")
            return
        }

        log("Manual checkForUpdates called for roomID: \(roomID ?? "nil")", level: "DEBUG", category: "MessageSyncService")

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
                log("Sync cooldown active, skip. Δt=\(dt)", level: "DEBUG", category: "MessageSyncService")
                return
            }
            do {
                try await self.performQuery(roomID: roomID)
            } catch {
                await MainActor.run {
                    if let ckError = error as? CKError, ckError.code == .partialFailure {
                        log("Partial failure during sync - possible missing share acceptance", level: "DEBUG", category: "MessageSyncService")
                    }
                    if let ckError = error as? CKError, ckError.code == .invalidArguments,
                       ckError.localizedDescription.contains("Unknown field") {
                        log("Schema not ready yet, will retry later: \(ckError.localizedDescription)", level: "DEBUG", category: "MessageSyncService")
                        return
                    }
                    self.syncError.send(error)
                    log("Manual sync failed: \(error)", category: "MessageSyncService")
                }
            }
        }
    }
    
    private func performQuery(roomID: String?) async throws {
        let chatManager = CloudKitChatManager.shared
        var allRecords: [CKRecord] = []
        
        // 役割ベースの検索ロジック
        if let roomID = roomID {
            let cached = chatManager.isOwnerCached(roomID)
            let isOwner: Bool
            if let cached { isOwner = cached } else { isOwner = await chatManager.isOwnerOfRoom(roomID) }
            
            if isOwner {
                // OWNER側はPrivate DBの当該ゾーンのみを検索
                // オーナー：Private DBの当該カスタムゾーンを直接検索
                do {
                    if let zoneID = try await chatManager.resolvePrivateZoneIDIfExists(roomID: roomID) {
                        let zoneRecords = await querySpecificZone(database: privateDB, zoneID: zoneID, roomID: roomID)
                        allRecords = zoneRecords
                    } else {
                        log("⚠️ Owner zone not found for roomID=\(roomID)", category: "MessageSyncService")
                        allRecords = []
                    }
                } catch {
                    log("⚠️ Failed to resolve private zone for roomID=\(roomID): \(error)", category: "MessageSyncService")
                    allRecords = []
                }
            } else {
                // 参加者側はShared DBを検索
                // 参加者：Shared DBを検索
                let sharedDBRecords = await querySharedDatabase(roomID: roomID)
                allRecords = sharedDBRecords
            }
        } else {
            log("🔍 Querying ALL messages (both owned and participating)", category: "MessageSyncService")
            // roomIDが指定されていない場合：全てのメッセージを取得
            let privateRecords = await queryPrivateDatabase(roomID: nil)
            let sharedZoneRecords = await querySharedZones(roomID: nil)
            let sharedDBRecords = await querySharedDatabase(roomID: nil)
            allRecords = privateRecords + sharedZoneRecords + sharedDBRecords
        }
        
        // 重複排除
        var uniqueRecords: [String: CKRecord] = [:]
        for record in allRecords {
            uniqueRecords[record.recordID.recordName] = record
        }
        
        let deduplicatedRecords = Array(uniqueRecords.values)
        
        // Process all unique messages with duplicate prevention
        await MainActor.run {
            // サマリのみを出力
            log("🔄 Sync processing: unique=\(deduplicatedRecords.count) total=\(allRecords.count) room=\(roomID ?? "nil")", category: "MessageSyncService")
            
            // クールダウンチェック
            let timeSinceLastSync = Date().timeIntervalSince(self.lastSyncTime)
            if timeSinceLastSync < self.syncCooldown { return }
            
            var newMessagesCount = 0
            var duplicateCount = 0
            
            for record in deduplicatedRecords {
                let recordRoomID = record["roomID"] as? String ?? "unknown"
                let recordName = record.recordID.recordName
                
                // 重複チェック：最近同期したレコードかどうか
                if self.recentlySyncedRecords.contains(recordName) {
                    duplicateCount += 1
                    continue
                }
                
                // 個別レコードの詳細ログは抑制
                
                // roomIDフィルタリングチェック
                if let targetRoomID = roomID, recordRoomID != targetRoomID {
                    // 対象ルーム以外はスキップ
                    continue
                }
                
                if let message = self.createMessage(from: record) {
                    log("✅ Created message object: \(message.id), body: \(message.body?.prefix(50) ?? "nil")", category: "MessageSyncService")
                    
                    // 特定のメッセージを追跡
                    if let body = message.body, (body.contains("たああ") || body.contains("たあああ")) {
                        log("🎯 TRACKED MESSAGE CREATED: Message ID \(message.id), body: '\(body)'", category: "MessageSyncService")
                    }
                    
                    // 同期したレコードをキャッシュに追加
                    self.recentlySyncedRecords.insert(recordName)
                    newMessagesCount += 1
                    
                    self.messageReceived.send(message)
                } else {
                    log("❌ Failed to create message from record: \(record.recordID.recordName)", category: "MessageSyncService")
                }
            }
            
            // キャッシュクリーンアップ（メモリ効率のため）
            if self.recentlySyncedRecords.count > 1000 {
                self.recentlySyncedRecords.removeAll()
                log("🧹 Cleaned up sync cache", category: "MessageSyncService")
            }
            
            self.lastSyncTime = Date()
            
            log("Manual sync completed with \(deduplicatedRecords.count) unique records (from \(allRecords.count) total) - New: \(newMessagesCount), Duplicates: \(duplicateCount)", category: "MessageSyncService")
        }
    }
    
    /// Private DBのデフォルトゾーンからメッセージを検索
    private func queryPrivateDatabase(roomID: String?) async -> [CKRecord] {
        log("🔍 Querying Private DB default zone...", category: "MessageSyncService")
        
        do {
            let predicate: NSPredicate
            if let roomID = roomID {
                predicate = NSPredicate(format: "roomID == %@", roomID)
            } else {
                // Zone wide queryを避けるため、最近のメッセージのみ取得
                let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                predicate = NSPredicate(format: "timestamp > %@", oneWeekAgo as NSDate)
            }
            
            let query = CKQuery(recordType: "Message", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            
            let (results, _) = try await privateDB.records(matching: query, inZoneWith: nil)
            let records = results.compactMap { try? $0.1.get() }
            
            log("✅ Private DB query completed with \(records.count) records", category: "MessageSyncService")
            return records
            
        } catch {
            log("❌ Private DB query failed: \(error)", category: "MessageSyncService")
            return []
        }
    }
    
    /// Private DBの共有ゾーンからメッセージを検索
    private func querySharedZones(roomID: String?) async -> [CKRecord] {
        log("🔍 Querying Private DB shared zones...", category: "MessageSyncService")
        
        do {
            // 1. 共有DBの全てのゾーンを取得
            let zones = try await sharedDB.allRecordZones()
            let sharedZones = zones.filter { zone in
                // 共有ゾーンの特定（_defaultではなく、カスタムゾーン）
                !zone.zoneID.zoneName.hasPrefix("_") && zone.zoneID.zoneName != "_defaultZone"
            }
            
            log("📁 Found \(sharedZones.count) shared zones", category: "MessageSyncService")
            
            var allRecords: [CKRecord] = []
            
            // 2. 各共有ゾーンでメッセージを検索（Shared DBを使用）
            for zone in sharedZones {
                let zoneRecords = await querySpecificZone(database: sharedDB, zoneID: zone.zoneID, roomID: roomID)
                allRecords.append(contentsOf: zoneRecords)
            }
            
            log("✅ Shared zones query completed with \(allRecords.count) records", category: "MessageSyncService")
            return allRecords
            
        } catch {
            log("❌ Shared zones query failed: \(error)", category: "MessageSyncService")
            return []
        }
    }
    
    /// 特定のゾーンでメッセージを検索
    private func querySpecificZone(database: CKDatabase, zoneID: CKRecordZone.ID, roomID: String?) async -> [CKRecord] {
        do {
            let predicate: NSPredicate
            if let roomID = roomID {
                predicate = NSPredicate(format: "roomID == %@", roomID)
            } else {
                // 最近のメッセージのみ取得
                let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                predicate = NSPredicate(format: "timestamp > %@", oneWeekAgo as NSDate)
            }
            
            let query = CKQuery(recordType: "Message", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            
            let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
            let records = results.compactMap { try? $0.1.get() }
            
            log("📂 Zone \(zoneID.zoneName) query completed with \(records.count) records", category: "MessageSyncService")
            return records
            
        } catch {
            log("⚠️ Zone \(zoneID.zoneName) query failed: \(error)", category: "MessageSyncService")
            return []
        }
    }
    
    /// Shared DBからメッセージを検索（2段階構成）
    private func querySharedDatabase(roomID: String?) async -> [CKRecord] {
        log("🔍 Querying Shared DB using 2-stage approach...", category: "MessageSyncService")
        
        do {
            // Step 1: 変更があったゾーンIDを取得
            let changedZoneIDs = try await fetchChangedZonesFromSharedDB()
            
            log("🔍 Found \(changedZoneIDs.count) changed zones in Shared DB", level: (changedZoneIDs.isEmpty ? "DEBUG" : "INFO"), category: "MessageSyncService")
                    if changedZoneIDs.isEmpty {
                log("🛈 Shared DB changed zones = 0. If peer created a share, it may be unaccepted. Ensure CKShare URL is accepted on this device.", level: "DEBUG", category: "MessageSyncService")
            }
            
            var allRecords: [CKRecord] = []
            
            // Step 2: 各ゾーンから変更されたレコードを取得
            for zoneID in changedZoneIDs {
                let zoneRecords = await fetchRecordsFromSharedZone(zoneID: zoneID, roomID: roomID)
                allRecords.append(contentsOf: zoneRecords)
            }
            
            log("✅ Shared DB query completed with \(allRecords.count) records", category: "MessageSyncService")
            return allRecords
            
        } catch {
            log("❌ Shared DB query failed: \(error)", category: "MessageSyncService")
            return []
        }
    }
    
    /// Shared DBから変更があったゾーンIDを取得
    private func fetchChangedZonesFromSharedDB() async throws -> [CKRecordZone.ID] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecordZone.ID], Error>) -> Void in
            let sharedDB = container.sharedCloudDatabase
            
            // 永続化されたShared DB変更トークンを使用
            let dbChangesOp = CKFetchDatabaseChangesOperation(previousServerChangeToken: sharedDBChangeToken)
            dbChangesOp.qualityOfService = .userInitiated
            
            var changedZoneIDs: [CKRecordZone.ID] = []
            
            dbChangesOp.recordZoneWithIDChangedBlock = { zoneID in
                changedZoneIDs.append(zoneID)
            }
            
            dbChangesOp.recordZoneWithIDWasDeletedBlock = { zoneID in
                log("🗑️ Zone deleted from Shared DB: \(zoneID.zoneName)", category: "MessageSyncService")
            }
            
            dbChangesOp.changeTokenUpdatedBlock = { [weak self] newToken in
                self?.sharedDBChangeToken = newToken
                log("📱 Shared DB change token updated", level: "DEBUG", category: "MessageSyncService")
            }
            
            dbChangesOp.fetchDatabaseChangesResultBlock = { [weak self] (result: Result<(serverChangeToken: CKServerChangeToken, moreComing: Bool), Error>) in
                switch result {
                case .failure(let error):
                    continuation.resume(throwing: error)
                case .success(let (serverChangeToken, _)):
                    // 最終トークンを保存して永続化
                    self?.sharedDBChangeToken = serverChangeToken
                    self?.persistTokens()
                    if changedZoneIDs.isEmpty {
                        log("🛈 No changed zones in shared DB (token advanced). If expecting incoming messages, verify share acceptance on this account.", level: "DEBUG", category: "MessageSyncService")
                    }
                    continuation.resume(returning: changedZoneIDs)
                }
            }
            
            sharedDB.add(dbChangesOp)
        }
    }
    
    /// 特定のShared DBゾーンからレコードを取得
    private func fetchRecordsFromSharedZone(zoneID: CKRecordZone.ID, roomID: String?) async -> [CKRecord] {
        return await _fetchRecordsFromSharedZoneImpl(zoneID: zoneID, roomID: roomID)
    }
    
    private func _fetchRecordsFromSharedZoneImpl(zoneID: CKRecordZone.ID, roomID: String?) async -> [CKRecord] {
        let sharedDB = container.sharedCloudDatabase
        
        // 永続化されたゾーン変更トークンを使用
        let zoneToken = zoneChangeTokens[zoneID]
        let zoneChangesOp = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [
                zoneID: CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                    previousServerChangeToken: zoneToken,
                    resultsLimit: nil,
                    // 🌟 [IDEAL DESIREDKEYS]
                    // Include message / reaction / attachment fields we care about
                    desiredKeys: ["roomID", "senderID", "text", "timestamp", "messageRef", "emoji", "asset", "createdAt"]
                )
            ]
        )
        zoneChangesOp.qualityOfService = .userInitiated
        
        // Simplified direct async implementation
        var fetchedRecords: [CKRecord] = []
        var affectedReactions: Set<ReactionKey> = [] // set of affected (roomID, messageRecordName)
        var pendingAttachments: [(roomID: String, msgName: String, fileURL: URL)] = []
        
        zoneChangesOp.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if record.recordType == "MessageReaction" {
                    if let messageRef = record["messageRef"] as? CKRecord.Reference {
                        let rid = messageRef.recordID.zoneID.zoneName
                        let msgName = messageRef.recordID.recordName
                        // ルーム指定がある場合はそのルームのみ
                        if let targetRoomID = roomID {
                            if targetRoomID == rid { affectedReactions.insert(ReactionKey(roomID: rid, messageRecordName: msgName)) }
                        } else {
                            affectedReactions.insert(ReactionKey(roomID: rid, messageRecordName: msgName))
                        }
                    }
                } else if record.recordType == "MessageAttachment" {
                    if let messageRef = record["messageRef"] as? CKRecord.Reference,
                       let asset = record["asset"] as? CKAsset,
                       let srcURL = asset.fileURL {
                        let rid = messageRef.recordID.zoneID.zoneName
                        let msgName = messageRef.recordID.recordName
                        // ローカルへ保存
                        let localURL = AttachmentManager.makeFileURL(ext: srcURL.pathExtension)
                        do {
                            if !FileManager.default.fileExists(atPath: localURL.path) {
                                try FileManager.default.copyItem(at: srcURL, to: localURL)
                            }
                            pendingAttachments.append((roomID: rid, msgName: msgName, fileURL: localURL))
                        } catch {
                            log("Failed to copy attachment asset: \(error)", category: "MessageSyncService")
                        }
                    }
                } else {
                    // Message等は従来通り収集
                    if let targetRoomID = roomID {
                        let recordRoomID = record["roomID"] as? String ?? ""
                        if recordRoomID == targetRoomID { fetchedRecords.append(record) }
                    } else {
                        fetchedRecords.append(record)
                    }
                }
            case .failure(let error):
                log("⚠️ Error fetching record \(recordID.recordName): \(error)", category: "MessageSyncService")
            }
        }
        
        zoneChangesOp.recordWithIDWasDeletedBlock = { [weak self] recordID, recordType in
            log("🗑️ Record deleted from Shared zone \(zoneID.zoneName): \(recordID.recordName)", category: "MessageSyncService")
            // Reaction削除時はゾーン単位で再同期（対象特定不可のため）
            if recordType == "MessageReaction" {
                Task { try? await self?.performQuery(roomID: zoneID.zoneName) }
            }
        }
        
        zoneChangesOp.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneID, newToken, data in
            if let newToken = newToken {
                self?.zoneChangeTokens[zoneID] = newToken
            }
                        log("📱 Zone \(zoneID.zoneName) change token updated", level: "DEBUG", category: "MessageSyncService")
        }
        
        zoneChangesOp.recordZoneFetchResultBlock = { (zoneID: CKRecordZone.ID, result: Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), Error>) in
            switch result {
            case .success:
                log("✅ Zone \(zoneID.zoneName) fetch completed successfully", level: "DEBUG", category: "MessageSyncService")
            case .failure(let error):
                log("⚠️ Error fetching zone \(zoneID.zoneName): \(error)", category: "MessageSyncService")
            }
        }
        
        return await withCheckedContinuation { continuation in
            zoneChangesOp.fetchRecordZoneChangesResultBlock = { [weak self] result in
                switch result {
                case .failure(let error):
                    log("❌ Shared zone \(zoneID.zoneName) fetch failed: \(error)", category: "MessageSyncService")
                case .success:
                    log("📂 Shared zone \(zoneID.zoneName) fetch completed with \(fetchedRecords.count) records", category: "MessageSyncService")
                }
                // 影響のあったメッセージのみReactions更新イベントを発行
                for key in affectedReactions {
                    self?.reactionsUpdated.send((roomID: key.roomID, messageRecordName: key.messageRecordName))
                }
                // 添付更新イベントを通知
                if let self = self {
                    for item in pendingAttachments {
                        self.attachmentsUpdated.send((roomID: item.roomID, messageRecordName: item.msgName, localPath: item.fileURL.path))
                    }
                }
                continuation.resume(returning: fetchedRecords)
            }
            sharedDB.add(zoneChangesOp)
        }
    }
    
    private func queryDatabase(_ database: CKDatabase, roomID: String?, databaseName: String) async throws -> [CKRecord] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            let predicate: NSPredicate
            if let roomID = roomID {
                predicate = NSPredicate(format: "roomID == %@", roomID)
            } else {
                predicate = NSPredicate(value: true)
            }
            
            let query = CKQuery(recordType: "Message", predicate: predicate)
            let queryOperation = CKQueryOperation(query: query)
            queryOperation.qualityOfService = .userInitiated
            // 🌟 [IDEAL DESIREDKEYS] Exclude attachment for list performance - fetch individually when needed
            // 'timestamp' が未定義のレコードでも動作するよう desiredKeys は任意
            queryOperation.desiredKeys = ["roomID", "senderID", "text", "timestamp"]
            
            var fetchedRecords: [CKRecord] = []
            
            queryOperation.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    fetchedRecords.append(record)
                case .failure(let error):
                    log("Failed to fetch record from \(databaseName) DB: \(error)", category: "MessageSyncService")
                }
            }
            
            queryOperation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    log("\(databaseName) DB query completed with \(fetchedRecords.count) records", category: "MessageSyncService")
                    continuation.resume(returning: fetchedRecords)
                    
                    // Handle cursor for pagination if needed
                    if let cursor = cursor {
                        Task {
                            let _ = try await self.continueFetchFromDatabase(cursor: cursor, database: database, databaseName: databaseName)
                            // Note: For simplicity, we're not combining paginated results here
                            // In a production app, you'd want to handle pagination properly
                        }
                    }
                    
                case .failure(let error):
                    log("\(databaseName) DB query failed: \(error)", category: "MessageSyncService")
                    // Don't fail the entire operation if one database fails
                    continuation.resume(returning: [])
                }
            }
            
            database.add(queryOperation)
        }
    }
    
    private func continueFetchFromDatabase(cursor: CKQueryOperation.Cursor, database: CKDatabase, databaseName: String) async throws -> [CKRecord] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            let continueOperation = CKQueryOperation(cursor: cursor)
            continueOperation.qualityOfService = .userInitiated
            // 🌟 [IDEAL DESIREDKEYS] Exclude attachment for list performance - fetch individually when needed
            continueOperation.desiredKeys = ["roomID", "senderID", "text", "timestamp"]
            
            var continuedRecords: [CKRecord] = []
            
            continueOperation.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    continuedRecords.append(record)
                case .failure(let error):
                    log("Failed to fetch record from \(databaseName) DB: \(error)", category: "MessageSyncService")
                }
            }
            
            continueOperation.queryResultBlock = { result in
                switch result {
                case .success(let nextCursor):
                    log("Continue fetch from \(databaseName) DB completed with \(continuedRecords.count) more records", category: "MessageSyncService")
                    continuation.resume(returning: continuedRecords)
                    
                    if let nextCursor = nextCursor {
                        Task {
                            _ = try await self.continueFetchFromDatabase(cursor: nextCursor, database: database, databaseName: databaseName)
                        }
                    }
                    
                case .failure(let error):
                    log("Continue fetch from \(databaseName) DB failed: \(error)", category: "MessageSyncService")
                    continuation.resume(returning: [])
                }
            }
            
            database.add(continueOperation)
        }
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
                    log("[AUTO RESET] Legacy Message record detected (missing required fields). Resetting...", category: "MessageSyncService")
                }
                Task {
                    do {
                        try await CloudKitChatManager.shared.performCompleteReset(bypassSafetyCheck: true)
                        await MainActor.run {
                            log("[AUTO RESET] Complete reset finished.", category: "MessageSyncService")
                        }
                    } catch {
                        await MainActor.run {
                            log("[AUTO RESET] Complete reset failed: \(error)", category: "MessageSyncService")
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
                log("Failed to copy asset: \(error)", category: "MessageSyncService")
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
