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
    static let shared = MessageSyncService()
    
    private let container = CKContainer(identifier: "iCloud.forMarin-test")
    private let privateDB: CKDatabase
    private let sharedDB: CKDatabase
    
    // Combine Publishers for reactive updates
    let messageReceived = PassthroughSubject<Message, Never>()
    let messageDeleted = PassthroughSubject<String, Never>()
    let syncError = PassthroughSubject<Error, Never>()
    let syncStatusChanged = PassthroughSubject<Bool, Never>()
    
    // Queue for offline messages
    private var offlineMessageQueue: [Message] = []
    
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
    
    
    override init() {
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
        super.init()
        setupNotificationObservers()
        setupSyncEngine()
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
        // For iOS 17+, we'll use a simpler approach initially
        // CKSyncEngine requires more complex delegate implementation
        log("Using legacy CloudKit sync for now", category: "MessageSyncService")
        
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
                log("📱 Loaded Shared DB change token", category: "MessageSyncService")
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
                log("💾 Persisted Shared DB change token", category: "MessageSyncService")
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
        let isOwner = await chatManager.isOwnerOfRoom(roomID)
        
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
    
    func sendMessage(_ message: Message) {
        guard !isSyncDisabled else {
            log("🛑 Sync is disabled, skipping message send", category: "MessageSyncService")
            return
        }
        
        Task {
            do {
                let record = createCKRecord(from: message)
                let savedRecord = try await privateDB.save(record)
                await MainActor.run {
                    message.ckRecordName = savedRecord.recordID.recordName
                    message.isSent = true
                    log("Message sent successfully: \(message.id)", category: "MessageSyncService")
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
                let recordID = CKRecord.ID(recordName: recordName)
                let record = try await privateDB.record(for: recordID)
                
                // Update record fields
                record["body"] = (message.body ?? "") as CKRecordValue
                record["reactions"] = (message.reactionEmoji ?? "") as CKRecordValue
                
                _ = try await privateDB.save(record)
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
                let recordID = CKRecord.ID(recordName: recordName)
                try await privateDB.deleteRecord(withID: recordID)
                
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
            log("🛑 Sync is disabled, skipping update check", category: "MessageSyncService")
            return
        }
        
        log("🔄 Manual checkForUpdates called for roomID: \(roomID ?? "nil")", category: "MessageSyncService")
        
        Task {
            do {
                try await performQuery(roomID: roomID)
            } catch {
                await MainActor.run {
                    // 共有DB/招待未受理ヒント
                    if let ckError = error as? CKError {
                        if ckError.code == .partialFailure {
                            log("🧩 Partial failure during sync - possible missing share acceptance", category: "MessageSyncService")
                        }
                    }
                    // スキーマ関連のエラーかチェック
                    if let ckError = error as? CKError, ckError.code == .invalidArguments {
                        if ckError.localizedDescription.contains("Unknown field") {
                            log("⚠️ Schema not ready yet, will retry later: \(ckError.localizedDescription)", category: "MessageSyncService")
                            // スキーマ準備待ちのため、エラーとして扱わない
                            return
                        }
                    }
                    
                    syncError.send(error)
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
            let isOwner = await chatManager.isOwnerOfRoom(roomID)
            
            if isOwner {
                log("🔍 Querying as OWNER for roomID: \(roomID)", category: "MessageSyncService")
                // オーナー：Private DBの共有ゾーンを検索
                let privateRecords = await queryPrivateDatabase(roomID: roomID)
                let sharedZoneRecords = await querySharedZones(roomID: roomID)
                allRecords = privateRecords + sharedZoneRecords
            } else {
                log("🔍 Querying as PARTICIPANT for roomID: \(roomID)", category: "MessageSyncService")
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
            log("🔍 Processing \(deduplicatedRecords.count) unique records (from \(allRecords.count) total) for roomID: \(roomID ?? "nil")", category: "MessageSyncService")
            
            // クールダウンチェック
            let timeSinceLastSync = Date().timeIntervalSince(self.lastSyncTime)
            if timeSinceLastSync < self.syncCooldown {
                log("⏰ Sync cooldown active, skipping duplicate sync (last sync: \(timeSinceLastSync)s ago)", category: "MessageSyncService")
                return
            }
            
            var newMessagesCount = 0
            var duplicateCount = 0
            
            for record in deduplicatedRecords {
                let recordRoomID = record["roomID"] as? String ?? "unknown"
                let recordSenderID = record["senderID"] as? String ?? "unknown"
                let recordBody = record["body"] as? String ?? "empty"
                let recordCreatedAt = record["createdAt"] as? Date ?? Date()
                let recordName = record.recordID.recordName
                
                // 重複チェック：最近同期したレコードかどうか
                if self.recentlySyncedRecords.contains(recordName) {
                    duplicateCount += 1
                    
                    // 特定のメッセージのみ詳細ログ
                    if recordBody.contains("たああ") || recordBody.contains("たあああ") {
                        log("🎯 TRACKED MESSAGE ALREADY SYNCED: '\(recordBody)' (recordName: \(recordName))", category: "MessageSyncService")
                    }
                    continue
                }
                
                log("📝 Found record - recordName: \(recordName), roomID: \(recordRoomID), senderID: \(recordSenderID), body: \(recordBody.prefix(50)), createdAt: \(recordCreatedAt)", category: "MessageSyncService")
                
                // 特定のメッセージを追跡（たああメッセージなど）
                if recordBody.contains("たああ") || recordBody.contains("たあああ") {
                    log("🎯 TRACKED MESSAGE FOUND: '\(recordBody)' in record \(recordName)", category: "MessageSyncService")
                }
                
                // roomIDフィルタリングチェック
                if let targetRoomID = roomID, recordRoomID != targetRoomID {
                    log("⚠️ Skipping record due to roomID mismatch: \(recordRoomID) != \(targetRoomID)", category: "MessageSyncService")
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
                predicate = NSPredicate(format: "createdAt > %@", oneWeekAgo as NSDate)
            }
            
            let query = CKQuery(recordType: "CD_Message", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            
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
            // 1. 全ての共有ゾーンを取得
            let zones = try await privateDB.allRecordZones()
            let sharedZones = zones.filter { zone in
                // 共有ゾーンの特定（_defaultではなく、カスタムゾーン）
                !zone.zoneID.zoneName.hasPrefix("_") && zone.zoneID.zoneName != "_defaultZone"
            }
            
            log("📁 Found \(sharedZones.count) shared zones", category: "MessageSyncService")
            
            var allRecords: [CKRecord] = []
            
            // 2. 各共有ゾーンでメッセージを検索
            for zone in sharedZones {
                let zoneRecords = await querySpecificZone(zoneID: zone.zoneID, roomID: roomID)
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
    private func querySpecificZone(zoneID: CKRecordZone.ID, roomID: String?) async -> [CKRecord] {
        do {
            let predicate: NSPredicate
            if let roomID = roomID {
                predicate = NSPredicate(format: "roomID == %@", roomID)
            } else {
                // 最近のメッセージのみ取得
                let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                predicate = NSPredicate(format: "createdAt > %@", oneWeekAgo as NSDate)
            }
            
            let query = CKQuery(recordType: "CD_Message", predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            
            let (results, _) = try await privateDB.records(matching: query, inZoneWith: zoneID)
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
            
            log("🔍 Found \(changedZoneIDs.count) changed zones in Shared DB", category: "MessageSyncService")
            if changedZoneIDs.isEmpty {
                log("🛈 Shared DB changed zones = 0. If peer created a share, it may be unaccepted. Ensure CKShare URL is accepted on this device.", category: "MessageSyncService")
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
            
            var changedZoneIDs: [CKRecordZone.ID] = []
            
            dbChangesOp.recordZoneWithIDChangedBlock = { zoneID in
                changedZoneIDs.append(zoneID)
            }
            
            dbChangesOp.recordZoneWithIDWasDeletedBlock = { zoneID in
                log("🗑️ Zone deleted from Shared DB: \(zoneID.zoneName)", category: "MessageSyncService")
            }
            
            dbChangesOp.changeTokenUpdatedBlock = { [weak self] newToken in
                self?.sharedDBChangeToken = newToken
                log("📱 Shared DB change token updated", category: "MessageSyncService")
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
                        log("🛈 No changed zones in shared DB (token advanced). If expecting incoming messages, verify share acceptance on this account.", category: "MessageSyncService")
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
                    desiredKeys: nil
                )
            ]
        )
        
        // Simplified direct async implementation
        var fetchedRecords: [CKRecord] = []
        let semaphore = DispatchSemaphore(value: 0)
        
        zoneChangesOp.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                // roomIDフィルタリング
                if let targetRoomID = roomID {
                    let recordRoomID = record["roomID"] as? String ?? ""
                    if recordRoomID == targetRoomID {
                        fetchedRecords.append(record)
                    }
                } else {
                    fetchedRecords.append(record)
                }
            case .failure(let error):
                log("⚠️ Error fetching record \(recordID.recordName): \(error)", category: "MessageSyncService")
            }
        }
        
        zoneChangesOp.recordWithIDWasDeletedBlock = { recordID, recordType in
            log("🗑️ Record deleted from Shared zone \(zoneID.zoneName): \(recordID.recordName)", category: "MessageSyncService")
        }
        
        zoneChangesOp.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneID, newToken, data in
            if let newToken = newToken {
                self?.zoneChangeTokens[zoneID] = newToken
            }
            log("📱 Zone \(zoneID.zoneName) change token updated", category: "MessageSyncService")
        }
        
        zoneChangesOp.recordZoneFetchResultBlock = { (zoneID: CKRecordZone.ID, result: Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), Error>) in
            switch result {
            case .success:
                log("✅ Zone \(zoneID.zoneName) fetch completed successfully", category: "MessageSyncService")
            case .failure(let error):
                log("⚠️ Error fetching zone \(zoneID.zoneName): \(error)", category: "MessageSyncService")
            }
        }
        
        zoneChangesOp.fetchRecordZoneChangesResultBlock = { result in
            switch result {
            case .failure(let error):
                log("❌ Shared zone \(zoneID.zoneName) fetch failed: \(error)", category: "MessageSyncService")
            case .success:
                log("📂 Shared zone \(zoneID.zoneName) fetch completed with \(fetchedRecords.count) records", category: "MessageSyncService")
            }
            semaphore.signal()
        }
        
        sharedDB.add(zoneChangesOp)
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume(returning: fetchedRecords)
            }
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
            
            let query = CKQuery(recordType: "CD_Message", predicate: predicate)
            let queryOperation = CKQueryOperation(query: query)
            
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
    
    private func createCKRecord(from message: Message) -> CKRecord {
        let recordID = CKRecord.ID(recordName: message.ckRecordName ?? UUID().uuidString)
        let record = CKRecord(recordType: "CD_Message", recordID: recordID)
        
        record["roomID"] = message.roomID as CKRecordValue
        record["senderID"] = message.senderID as CKRecordValue
        record["body"] = (message.body ?? "") as CKRecordValue
        record["createdAt"] = message.createdAt as CKRecordValue
        record["reactions"] = (message.reactionEmoji ?? "") as CKRecordValue
        
        // Handle asset path for images/videos
        if let assetPath = message.assetPath {
            let assetURL = URL(fileURLWithPath: assetPath)
            if FileManager.default.fileExists(atPath: assetPath) {
                record["asset"] = CKAsset(fileURL: assetURL)
            }
        }
        
        return record
    }
    
    private func createMessage(from record: CKRecord) -> Message? {
        guard record.recordType == "CD_Message",
              let roomID = record["roomID"] as? String,
              let senderID = record["senderID"] as? String,
              let createdAt = record["createdAt"] as? Date else {
            return nil
        }
        
        let body = record["body"] as? String
        let reactions = record["reactions"] as? String
        var assetPath: String?
        
        // Handle asset download
        if let asset = record["asset"] as? CKAsset,
           let fileURL = asset.fileURL {
            let localURL = AttachmentManager.makeFileURL(ext: fileURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: fileURL, to: localURL)
                assetPath = localURL.path
            } catch {
                log("Failed to copy asset: \(error)", category: "MessageSyncService")
            }
        }
        
        return Message(
            roomID: roomID,
            senderID: senderID,
            body: body,
            assetPath: assetPath,
            ckRecordName: record.recordID.recordName,
            createdAt: createdAt,
            isSent: true,
            reactionEmoji: reactions
        )
    }
    
    // MARK: - Offline Support
    
    func queueOfflineMessage(_ message: Message) {
        offlineMessageQueue.append(message)
        saveOfflineQueue()
    }
    
    func processOfflineQueue() {
        for message in offlineMessageQueue {
            sendMessage(message)
        }
        offlineMessageQueue.removeAll()
        saveOfflineQueue()
        log("Processed \(offlineMessageQueue.count) offline messages", category: "MessageSyncService")
    }
    
    private func saveOfflineQueue() {
        // In a real implementation, you would serialize the queue to persistent storage
        UserDefaults.standard.set(offlineMessageQueue.count, forKey: "OfflineMessageCount")
    }
    
    // MARK: - Conflict Resolution
    
    func handleConflict(_ record: CKRecord, serverRecord: CKRecord) async -> CKRecord {
        // Use ConflictResolver for sophisticated conflict resolution
        return await ConflictResolver.shared.resolveConflict(localRecord: record, serverRecord: serverRecord)
    }
}

// MARK: - Legacy Support

class LegacyMessageSyncService: MessageSyncService {
    // Fallback implementation for iOS < 17.0
    // Uses traditional CKQuerySubscription approach
    
    override init() {
        super.init()
        log("Using legacy CloudKit implementation", category: "LegacyMessageSyncService")
    }
    
    // Override methods to use traditional CloudKit APIs
    override func sendMessage(_ message: Message) {
        // Use existing CKSync implementation
        Task {
            do {
                let recordName = try await CKSync.saveMessage(message)
                await MainActor.run {
                    message.ckRecordName = recordName
                    message.isSent = true
                }
            } catch {
                await MainActor.run {
                    syncError.send(error)
                }
            }
        }
    }
}