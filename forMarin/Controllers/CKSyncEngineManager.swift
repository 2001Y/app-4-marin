import Foundation
import CloudKit

@available(iOS 17.0, *)
actor CKSyncEngineManager: CKSyncEngineDelegate {
    static let shared = CKSyncEngineManager()

    private let container: CKContainer
    private let privateDB: CKDatabase
    private let sharedDB: CKDatabase

    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var outboxRecords: [CKRecord.ID: CKRecord] = [:]
    private var outboxAccess: [CKRecord.ID: Date] = [:]

    private let privateStateKey = "CKSyncEngine.State.Private"
    private let sharedStateKey = "CKSyncEngine.State.Shared"

    init(containerID: String = "iCloud.forMarin-test") {
        self.container = CKContainer(identifier: containerID)
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
    }

    func start() async {
        await setupEngines()
    }

    private func setupEngines() async {
        // Private
        do {
            let config = CKSyncEngine.Configuration(
                database: privateDB,
                stateSerialization: loadState(forKey: privateStateKey),
                delegate: self
            )
            privateEngine = CKSyncEngine(config)
        }
        // Shared
        do {
            let config = CKSyncEngine.Configuration(
                database: sharedDB,
                stateSerialization: loadState(forKey: sharedStateKey),
                delegate: self
            )
            sharedEngine = CKSyncEngine(config)
        }
    }

    // MARK: - CKSyncEngineDelegate

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await persistState(update.stateSerialization, for: syncEngine)
            await cleanupOutboxRecords()
            await logPendingSummary(prefix: "stateUpdate", syncEngine: syncEngine)

        case .accountChange(_):
            // 口数を減らす。必要時のみMessageSyncServiceへ再同期を促す
            await CKSyncEngineManager.requestUnifiedRefresh()

        case .fetchedRecordZoneChanges(_):
            // 取得イベントは既存の差分適用ロジックを流用
            await CKSyncEngineManager.requestUnifiedRefresh()
            await logPendingSummary(prefix: "fetchedRecordZoneChanges", syncEngine: syncEngine)

        case .sentRecordZoneChanges(_):
            // 送信完了：必要に応じて最小リフレッシュ
            await cleanupOutboxRecords()
            await CKSyncEngineManager.requestUnifiedRefresh()
            await logPendingSummary(prefix: "sentRecordZoneChanges", syncEngine: syncEngine)

        case .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .fetchedDatabaseChanges, .willSendChanges, .didSendChanges,
             .sentDatabaseChanges:
            await logPendingSummary(prefix: String(describing: event), syncEngine: syncEngine)

        @unknown default:
            break
        }
    }

    private func logPendingSummary(prefix: String, syncEngine: CKSyncEngine) async {
        let rec = syncEngine.state.pendingRecordZoneChanges.count
        let db = syncEngine.state.pendingDatabaseChanges.count
        let scope = (syncEngine.database.databaseScope == .private) ? "private" : "shared"
        log("[ENGINE] event=\(prefix) scope=\(scope) pending{records=\(rec), db=\(db)}", category: "CKSyncEngine")
    }

    private func cleanupOutboxRecords() {
        // エンジンのペンディングに存在しないIDはoutboxから除去
        var alive: Set<CKRecord.ID> = []
        if let p = privateEngine {
            for change in p.state.pendingRecordZoneChanges {
                if case let .saveRecord(id) = change { alive.insert(id) }
            }
        }
        if let s = sharedEngine {
            for change in s.state.pendingRecordZoneChanges {
                if case let .saveRecord(id) = change { alive.insert(id) }
            }
        }
        // フィルタリング（alive以外を削除）
        outboxRecords = outboxRecords.filter { alive.contains($0.key) }
        outboxAccess = outboxAccess.filter { alive.contains($0.key) }
        // LRUで上限制御
        let cap = 2000
        if outboxRecords.count > cap {
            let sortedByAccess = outboxAccess.sorted { $0.value < $1.value }
            let overflow = outboxRecords.count - cap
            for (i, kv) in sortedByAccess.enumerated() {
                if i >= overflow { break }
                outboxRecords.removeValue(forKey: kv.key)
                outboxAccess.removeValue(forKey: kv.key)
            }
        }
    }

    private func touchOutbox(id: CKRecord.ID) {
        outboxAccess[id] = Date()
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // シンプルにエンジンの保有する全ペンディングを供給
        let pending = syncEngine.state.pendingRecordZoneChanges
        guard !pending.isEmpty else { return nil }

        // Actorの状態をスナップショットして同期クロージャから参照
        let snapshot = await self.outboxRecords
        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending
        ) { recordID in
            return snapshot[recordID]
        }
        return batch
    }

    // MARK: - Helpers
    private func loadState(forKey key: String) -> CKSyncEngine.State.Serialization? {
        // 環境差異によるAPI相違を避けるため、状態の永続化は当面無効化
        return nil
    }

    private func persistState(_ state: CKSyncEngine.State.Serialization, for engine: CKSyncEngine) async {
        // 当面は状態を保存しない
    }

    private static func requestUnifiedRefresh() async {
        await MainActor.run {
            MessageSyncService.shared.checkForUpdates()
        }
    }

    // MARK: - Public API (queue WorkItems)
    func queueMessage(_ message: Message) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: message.roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            // ゾーン確保
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            // Record 構築
            let recID = CKRecord.ID(recordName: message.id.uuidString, zoneID: zoneID)
            let record = CKRecord(recordType: "Message", recordID: recID)
            record["roomID"] = message.roomID as CKRecordValue
            let senderID: String = await MainActor.run { CloudKitChatManager.shared.currentUserID ?? "" }
            record["senderID"] = senderID as CKRecordValue
            record["text"] = (message.body ?? "") as CKRecordValue
            record["timestamp"] = message.createdAt as CKRecordValue
            outboxRecords[recID] = record
            outboxAccess[recID] = Date()

            // WorkItem 追加
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recID)])
            // 可能なら即時送信を軽く促す（スパムしない）
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch {
            // 失敗時は従来経路へ委譲しない（完全移行）
        }
    }

    func queueAttachment(messageRecordName: String, roomID: String, localFileURL: URL) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
            let record = CKRecord(recordType: "MessageAttachment", recordID: recID)
            let messageID = CKRecord.ID(recordName: messageRecordName, zoneID: zoneID)
            record["messageRef"] = CKRecord.Reference(recordID: messageID, action: .none)
            record["asset"] = CKAsset(fileURL: localFileURL)
            record["createdAt"] = Date() as CKRecordValue
            outboxRecords[recID] = record
            outboxAccess[recID] = Date()

            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recID)])
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }

    func queueReaction(messageRecordName: String, roomID: String, emoji: String, userID: String) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            let recID = CKRecord.ID(recordName: MessageReaction.createID(messageRecordName: messageRecordName, userID: userID, emoji: emoji), zoneID: zoneID)
            let record = CKRecord(recordType: "MessageReaction", recordID: recID)
            let messageID = CKRecord.ID(recordName: messageRecordName, zoneID: zoneID)
            record["messageRef"] = CKRecord.Reference(recordID: messageID, action: .none)
            record["emoji"] = emoji as CKRecordValue
            record["userID"] = userID as CKRecordValue
            record["createdAt"] = Date() as CKRecordValue
            outboxRecords[recID] = record
            outboxAccess[recID] = Date()

            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recID)])
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }

    // MARK: - Public API (stats / control)
    struct PendingStats {
        let recordChanges: Int
        let databaseChanges: Int
        var total: Int { recordChanges + databaseChanges }
    }

    func pendingStats() -> PendingStats {
        var rec = 0
        var db = 0
        if let p = privateEngine {
            rec += p.state.pendingRecordZoneChanges.count
            db += p.state.pendingDatabaseChanges.count
        }
        if let s = sharedEngine {
            rec += s.state.pendingRecordZoneChanges.count
            db += s.state.pendingDatabaseChanges.count
        }
        return PendingStats(recordChanges: rec, databaseChanges: db)
    }

    func kickSyncNow() async {
        if let p = privateEngine {
            try? await p.sendChanges(CKSyncEngine.SendChangesOptions())
            try? await p.fetchChanges(CKSyncEngine.FetchChangesOptions())
        }
        if let s = sharedEngine {
            try? await s.sendChanges(CKSyncEngine.SendChangesOptions())
            try? await s.fetchChanges(CKSyncEngine.FetchChangesOptions())
        }
    }

    func resetEngines() async {
        // 永続状態をクリアして再構築（完全リセット）
        UserDefaults.standard.removeObject(forKey: privateStateKey)
        UserDefaults.standard.removeObject(forKey: sharedStateKey)
        outboxRecords.removeAll()
        outboxAccess.removeAll()
        await setupEngines()
    }

    // MARK: - Public API (update/delete WorkItems)
    func queueUpdateMessage(recordName: String, roomID: String, newBody: String, newTimestamp: Date = Date()) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            let record = CKRecord(recordType: "Message", recordID: recID)
            record["roomID"] = roomID as CKRecordValue
            let uid: String? = await MainActor.run { CloudKitChatManager.shared.currentUserID }
            if let uid { record["senderID"] = uid as CKRecordValue }
            record["text"] = newBody as CKRecordValue
            record["timestamp"] = newTimestamp as CKRecordValue
            outboxRecords[recID] = record
            outboxAccess[recID] = Date()

            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recID)])
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }

    func queueDeleteMessage(recordName: String, roomID: String) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recID)])
            outboxRecords.removeValue(forKey: recID)
            outboxAccess.removeValue(forKey: recID)
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }

    // MARK: - Public API (Anniversary WorkItems)
    func queueAnniversaryCreate(recordName: String, roomID: String, title: String, date: Date) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            // Ensure custom zone exists in engine state
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            let record = CKRecord(recordType: "CD_Anniversary", recordID: recID)
            record["title"] = title as CKRecordValue
            record["date"] = date as CKRecordValue
            record["roomID"] = roomID as CKRecordValue
            record["createdAt"] = Date() as CKRecordValue
            outboxRecords[recID] = record
            outboxAccess[recID] = Date()

            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recID)])
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }

    func queueAnniversaryUpdate(recordName: String, roomID: String, title: String, date: Date) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            let record = CKRecord(recordType: "CD_Anniversary", recordID: recID)
            record["title"] = title as CKRecordValue
            record["date"] = date as CKRecordValue
            record["roomID"] = roomID as CKRecordValue
            outboxRecords[recID] = record
            outboxAccess[recID] = Date()

            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recID)])
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }

    func queueAnniversaryDelete(recordName: String, roomID: String) async {
        do {
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let engine = (db.databaseScope == .private) ? privateEngine : sharedEngine
            guard let engine else { return }

            let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recID)])
            outboxRecords.removeValue(forKey: recID)
            outboxAccess.removeValue(forKey: recID)
            try? await engine.sendChanges(CKSyncEngine.SendChangesOptions())
        } catch { }
    }
}
