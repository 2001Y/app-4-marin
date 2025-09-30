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
    private let stateDirectoryName = "CKSyncState"
    // Local copy of subscription IDs to avoid accessing CloudKitChatManager internals
    private enum LocalSubscriptionID {
        static let privateDatabase = "db-sub-private"
        static let sharedDatabase = "db-sub-shared"
    }

    // Pushコアレス用（スコープ別直列スケジューラ）
    private var pendingScopes: Set<CKDatabase.Scope> = []
    private var isDraining: Bool = false

    init() {
        let container = CKContainer(identifier: CloudKitContainerIdentifier)
        self.container = container
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

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        let scopeHint = CKSyncEngineManager.databaseScope(from: userInfo)
        let roomHint = CKSyncEngineManager.roomHint(from: notification, userInfo: userInfo)
        let reason = "push:\(notification.subscriptionID ?? "unknown")"

        await enqueue(scope: scopeHint, reason: reason)
        await CKSyncEngineManager.requestLegacyRefresh(roomID: roomHint)

        return true
    }

    @discardableResult
    func fetchChanges(scope: CKDatabase.Scope? = nil, reason: String) async -> Bool {
        let scopes = scope.map { [$0] } ?? [.private, .shared]
        var triggered = false
        for candidate in scopes {
            switch candidate {
            case .private:
                triggered = await fetch(engine: privateEngine, scopeLabel: "private", reason: reason) || triggered
            case .shared:
                triggered = await fetch(engine: sharedEngine, scopeLabel: "shared", reason: reason) || triggered
            default:
                continue
            }
        }
        return triggered
    }

    private func fetch(engine: CKSyncEngine?, scopeLabel: String, reason: String) async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.fetchChanges()
            let zones = Self.pendingZoneCount(in: engine)
            log("[ENGINE] fetchChanges success scope=\(scopeLabel) reason=\(reason) pendingZones=\(zones)", category: "CKSyncEngine")
            return true
        } catch {
            if let ck = error as? CKError {
                if let ra = ck.retryAfterSeconds {
                    log("[ENGINE] fetchChanges failed scope=\(scopeLabel) reason=\(reason) code=\(ck.code.rawValue) retry_after_seconds=\(ra)", category: "CKSyncEngine")
                } else {
                    log("[ENGINE] fetchChanges failed scope=\(scopeLabel) reason=\(reason) code=\(ck.code.rawValue)", category: "CKSyncEngine")
                }
            } else {
                log("[ENGINE] fetchChanges failed scope=\(scopeLabel) reason=\(reason) error=\(error)", category: "CKSyncEngine")
            }
            return false
        }
    }

    private nonisolated static func databaseScope(from userInfo: [AnyHashable: Any]) -> CKDatabase.Scope? {
        guard let ck = userInfo["ck"] as? [String: Any] else { return nil }
        if let sid = ck["sid"] as? String {
            if sid == LocalSubscriptionID.privateDatabase { return .private }
            if sid == LocalSubscriptionID.sharedDatabase { return .shared }
        }
        if let dbs = ck["dbs"] as? Int {
            switch dbs {
            case 2: return .private
            case 3: return .shared
            default: return nil
            }
        }
        return nil
    }

    private nonisolated static func roomHint(from notification: CKNotification, userInfo: [AnyHashable: Any]) -> String? {
        if let query = notification as? CKQueryNotification, let zoneID = query.recordID?.zoneID {
            return zoneID.zoneName
        }
        if let zone = notification as? CKRecordZoneNotification, let zoneID = zone.recordZoneID {
            return zoneID.zoneName
        }
        return zoneIDFromMetadata(userInfo)
    }

    private nonisolated static func zoneIDFromMetadata(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let ck = userInfo["ck"] as? [String: Any] else { return nil }
        if let met = ck["met"] as? [String: Any], let zid = met["zid"] as? String, !zid.isEmpty {
            return zid
        }
        if let fet = ck["fet"] as? [String: Any], let zid = fet["zid"] as? String, !zid.isEmpty {
            return zid
        }
        return nil
    }

    // MARK: - CKSyncEngineDelegate

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await persistState(update.stateSerialization, for: syncEngine)
            await cleanupOutboxRecords()
            await logPendingSummary(prefix: "stateUpdate", syncEngine: syncEngine)

        case .accountChange(_):
            // 口数を減らす。必要時のみMessageSyncPipelineへ再同期を促す
            await CKSyncEngineManager.requestUnifiedRefresh()

        case .fetchedRecordZoneChanges(_):
            // 取得イベントは既存の差分適用ロジックを流用
            await CKSyncEngineManager.requestUnifiedRefresh()
            await logPendingSummary(prefix: "fetchedRecordZoneChanges", syncEngine: syncEngine)
            await emitZoneChangeHints(syncEngine: syncEngine)

        case .sentRecordZoneChanges(_):
            // 送信完了：必要に応じて最小リフレッシュ
            await cleanupOutboxRecords()
            await CKSyncEngineManager.requestUnifiedRefresh()
            await logPendingSummary(prefix: "sentRecordZoneChanges", syncEngine: syncEngine)

        case .didFetchRecordZoneChanges:
            await logPendingSummary(prefix: String(describing: event), syncEngine: syncEngine)
            await emitZoneChangeHints(syncEngine: syncEngine)

        case .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges,
             .fetchedDatabaseChanges, .willSendChanges, .didSendChanges,
             .sentDatabaseChanges:
            await logPendingSummary(prefix: String(describing: event), syncEngine: syncEngine)

        @unknown default:
            break
        }
    }

    private func emitZoneChangeHints(syncEngine: CKSyncEngine) async {
        let scope = syncEngine.database.databaseScope
        var changed: [CKRecordZone.ID: Int] = [:]
        var deleted: [CKRecordZone.ID: Int] = [:]
        for change in syncEngine.state.pendingRecordZoneChanges {
            switch change {
            case .saveRecord(let rid):
                changed[rid.zoneID, default: 0] += 1
            case .deleteRecord(let rid):
                deleted[rid.zoneID, default: 0] += 1
            default:
                break
            }
        }
        let changedSnapshot = changed
        let deletedSnapshot = deleted
        await MainActor.run {
            for (zone, c) in changedSnapshot {
                let d = deletedSnapshot[zone, default: 0]
                MessageSyncPipeline.shared.onZoneChangeHint(scope: scope, zoneID: zone, changed: c, deleted: d)
            }
            for (zone, d) in deletedSnapshot where changedSnapshot[zone] == nil {
                MessageSyncPipeline.shared.onZoneChangeHint(scope: scope, zoneID: zone, changed: 0, deleted: d)
            }
        }
    }

    private func logPendingSummary(prefix: String, syncEngine: CKSyncEngine) async {
        let rec = syncEngine.state.pendingRecordZoneChanges.count
        let db = syncEngine.state.pendingDatabaseChanges.count
        let scope = (syncEngine.database.databaseScope == .private) ? "private" : "shared"
        let zones = Self.pendingZoneCount(in: syncEngine)
        log("[ENGINE] event=\(prefix) scope=\(scope) pending{records=\(rec), db=\(db), zones=\(zones)}", category: "CKSyncEngine")
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
        // シリアライズ未実装の検知（outboxに存在しない saveRecord）
        var saveCount = 0
        var missing = 0
        for change in pending {
            if case let .saveRecord(id) = change {
                saveCount += 1
                if snapshot[id] == nil { missing += 1 }
            }
        }
        if saveCount > 0 && missing > 0 {
            log("[ENGINE] serialize.coverage missingRecords=\(missing)/\(saveCount)", category: "CKSyncEngine")
        }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending
        ) { recordID in
            return snapshot[recordID]
        }
        return batch
    }

    // MARK: - Helpers
    private static func pendingZoneCount(in engine: CKSyncEngine) -> Int {
        var zones: Set<CKRecordZone.ID> = []
        for change in engine.state.pendingRecordZoneChanges {
            switch change {
            case .saveRecord(let rid), .deleteRecord(let rid):
                zones.insert(rid.zoneID)
            default:
                break
            }
        }
        return zones.count
    }
    private func loadState(forKey key: String) -> CKSyncEngine.State.Serialization? {
        guard let url = stateFileURL(for: key) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return nil }
            // Swift 6 SDK: Serialization は Codable 準拠
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            log("[ENGINE] Failed to load state for key=\(key) error=\(error)", category: "CKSyncEngine")
            return nil
        }
    }

    private func persistState(_ state: CKSyncEngine.State.Serialization, for engine: CKSyncEngine) async {
        guard let key = stateKey(for: engine), let url = stateFileURL(for: key) else { return }
        do {
            try ensureStateDirectoryExists()
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: Data.WritingOptions.atomic)
            log("[ENGINE] Persisted state key=\(key) bytes=\(data.count)", category: "CKSyncEngine")
            log("metric=engine_state_persisted key=\(key) bytes=\(data.count)", category: "metrics")
        } catch {
            log("[ENGINE] Failed to persist state key=\(key) error=\(error)", category: "CKSyncEngine")
        }
    }

    private static func requestUnifiedRefresh() async {
        await requestLegacyRefresh(roomID: nil)
    }

    private static func requestLegacyRefresh(roomID: String?) async {
        await MainActor.run {
            if let roomID {
                MessageSyncPipeline.shared.checkForUpdates(roomID: roomID)
            } else {
                MessageSyncPipeline.shared.checkForUpdates()
            }
        }
    }

    // MARK: - Scope scheduler
    private func enqueue(scope: CKDatabase.Scope?, reason: String) async {
        if let s = scope {
            pendingScopes.insert(s)
        } else {
            pendingScopes.insert(.private)
            pendingScopes.insert(.shared)
        }
        if !isDraining {
            isDraining = true
            Task { await drain(reason: reason) }
        }
    }

    private func drain(reason: String) async {
        while let scope = pendingScopes.popFirst() {
            switch scope {
            case .private:
                _ = await fetch(engine: privateEngine, scopeLabel: "private", reason: reason)
            case .shared:
                _ = await fetch(engine: sharedEngine, scopeLabel: "shared", reason: reason)
            default:
                break
            }
        }
        isDraining = false
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

            let reactionID = MessageReaction.createID(messageRecordName: messageRecordName, userID: userID, emoji: emoji)
            let reaction = MessageReaction(
                id: reactionID,
                messageRef: MessageReaction.createMessageReference(messageID: messageRecordName, zoneID: zoneID),
                userID: userID,
                emoji: emoji,
                createdAt: Date()
            )
            let record = reaction.toCloudKitRecord(in: zoneID)
            let recID = record.recordID
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
        removePersistedState(for: privateStateKey)
        removePersistedState(for: sharedStateKey)
        await setupEngines()
    }

    private func stateKey(for engine: CKSyncEngine) -> String? {
        if engine === privateEngine { return privateStateKey }
        if engine === sharedEngine { return sharedStateKey }
        return nil
    }

    private func stateFileURL(for key: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(stateDirectoryName, isDirectory: true)
            .appendingPathComponent("\(key).state", isDirectory: false)
    }

    private func ensureStateDirectoryExists() throws {
        guard let dirURL = stateFileURL(for: "directory_probe")?.deletingLastPathComponent() else { return }
        if !FileManager.default.fileExists(atPath: dirURL.path) {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
    }

    private func removePersistedState(for key: String) {
        guard let url = stateFileURL(for: key) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                log("[ENGINE] Removed persisted state key=\(key)", category: "CKSyncEngine")
            }
        } catch {
            log("[ENGINE] Failed to remove state key=\(key) error=\(error)", category: "CKSyncEngine")
        }
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
