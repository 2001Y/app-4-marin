import CloudKit
import CryptoKit
import Combine
import SwiftUI
import SwiftData

let CloudKitContainerIdentifier = "iCloud.forMarin-test"

@MainActor
class CloudKitChatManager: ObservableObject {
    static let shared: CloudKitChatManager = CloudKitChatManager()
    
    private let container = CKContainer(identifier: CloudKitContainerIdentifier)
    // 共有UIや受諾処理で同一コンテナを参照できるように公開アクセサを用意
    var containerForSharing: CKContainer { container }
    var containerID: String { container.containerIdentifier ?? "iCloud.forMarin-test" }
    let privateDB: CKDatabase  // 🏗️ [IDEAL MVVM] ViewModelからアクセス可能にする
    let sharedDB: CKDatabase   // 🏗️ [IDEAL MVVM] ViewModelからアクセス可能にする
    
    // ゾーン解決用の簡易キャッシュ（zoneName -> zoneID）
    private var privateZoneCache: [String: CKRecordZone.ID] = [:]
    private var sharedZoneCache: [String: CKRecordZone.ID] = [:]
    // roomID -> scope ("private" or "shared") を永続キャッシュ
    private var roomScopeCache: [String: String] = [:]
    private let roomScopeDefaultsKey = "CloudKitChatManager.RoomScopeCache"
    private let privateDBTokenKey = "CloudKitChatManager.PrivateDBChangeToken"
    private let sharedDBTokenKey = "CloudKitChatManager.SharedDBChangeToken"
    private let zoneTokenKey = "CloudKitChatManager.ZoneChangeTokens"

    private var privateDBChangeToken: CKServerChangeToken?
    private var sharedDBChangeToken: CKServerChangeToken?
    private var zoneChangeTokens: [String: CKServerChangeToken] = [:]
    private let privateZoneCacheKey = "CloudKitChatManager.PrivateZoneCache"
    private let sharedZoneCacheKey = "CloudKitChatManager.SharedZoneCache"

    enum ZonePurpose {
        case message
        case signal
    }

    private enum RoomScope: String {
        case `private`
        case shared

        var databaseScope: CKDatabase.Scope {
            switch self {
            case .shared: return .shared
            default: return .private
            }
        }

        init?(databaseScope: CKDatabase.Scope) {
            switch databaseScope {
            case .shared: self = .shared
            case .private: self = .private
            default: return nil
            }
        }
    }

    private struct ZoneCacheEntry: Codable {
        let zoneName: String
        let ownerName: String?

        init(zoneID: CKRecordZone.ID) {
            self.zoneName = zoneID.zoneName
            self.ownerName = zoneID.ownerName
        }

        func makeZoneID() -> CKRecordZone.ID {
            if let ownerName, !ownerName.isEmpty {
                return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            }
            return CKRecordZone.ID(zoneName: zoneName)
        }
    }

    struct SignalSessionSnapshot {
        let recordID: CKRecord.ID
        let sessionKey: String
        let roomID: String
        let callerUserID: String
        let calleeUserID: String
        var activeCallEpoch: Int
        var updatedAt: Date?
    }

    enum SignalEnvelopeType: String {
        case offer
        case answer
    }

    struct SignalEnvelopeSnapshot {
        let recordID: CKRecord.ID
        let sessionKey: String
        let roomID: String
        let callEpoch: Int
        let ownerUserID: String
        let type: SignalEnvelopeType
        let sdp: String
        let createdAt: Date?
    }

    struct SignalIceChunkSnapshot {
        let recordID: CKRecord.ID
        let sessionKey: String
        let roomID: String
        let callEpoch: Int
        let ownerUserID: String
        let candidate: String
        let candidateType: String?
        let createdAt: Date?
    }

    struct ParticipantProfileSnapshot {
        let userID: String
        var name: String?
        var avatarData: Data?
    }

    struct ChatShareDescriptor {
        let share: CKShare
        let shareURL: URL
        let roomRecordID: CKRecord.ID
        let zoneID: CKRecordZone.ID
    }

    private enum ShareParticipantIdentifier {
        case email(String)
        case phoneNumber(String)
        case recordName(String)
    }
    struct DatabaseChangeSummary {
        let changedZoneIDs: [CKRecordZone.ID]
        let deletedZoneIDs: [CKRecordZone.ID]
    }

    struct ZoneChangeBatch {
        let changedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
    }
    
    private enum SubscriptionID {
        static let privateDatabase = "db-sub-private"
        static let sharedDatabase = "db-sub-shared"
    }

    @Published var currentUserID: String?
    @Published var isInitialized: Bool = false
    @Published var lastError: Error?
    private var isBootstrapping = false

    struct ProfileCacheEntry {
        var name: String?
        var avatarData: Data?
        var shapeIndex: Int?
    }
    // プロフィールキャッシュ（userID -> キャッシュエントリ）
    private var profileCache: [String: ProfileCacheEntry] = [:]
    
    // Build / environment diagnostics
    private var isTestFlightBuild: Bool {
        let receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? ""
        return receipt == "sandboxReceipt"
    }
    
    
    private init() {
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
        setupSyncNotificationObservers()
        
        // 永続化されたスコープ/ゾーンマップをロード
        if let data = UserDefaults.standard.data(forKey: roomScopeDefaultsKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            roomScopeCache = map
        }
        if let data = UserDefaults.standard.data(forKey: privateZoneCacheKey) {
            if let map = try? JSONDecoder().decode([String: ZoneCacheEntry].self, from: data) {
                var restored: [String: CKRecordZone.ID] = [:]
                for (roomID, entry) in map {
                    restored[roomID] = entry.makeZoneID()
                }
                privateZoneCache = restored
            } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
                var restored: [String: CKRecordZone.ID] = [:]
                for (roomID, zoneName) in legacy {
                    restored[roomID] = CKRecordZone.ID(zoneName: zoneName)
                }
                privateZoneCache = restored
            }
        }
        if let data = UserDefaults.standard.data(forKey: sharedZoneCacheKey) {
            if let map = try? JSONDecoder().decode([String: ZoneCacheEntry].self, from: data) {
                var restored: [String: CKRecordZone.ID] = [:]
                for (roomID, entry) in map {
                    restored[roomID] = entry.makeZoneID()
                }
                sharedZoneCache = restored
            } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
                var restored: [String: CKRecordZone.ID] = [:]
                for (roomID, zoneName) in legacy {
                    restored[roomID] = CKRecordZone.ID(zoneName: zoneName)
                }
                sharedZoneCache = restored
            }
        }

        loadChangeTokens()
    }

    func bootstrapIfNeeded() async {
        guard !isInitialized, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await initialize()
        guard isInitialized else { return }
        do {
            try await ensureSubscriptions()
            log("✅ [BOOTSTRAP] Database subscriptions ensured", category: "subs")
            await performInviteMaintenance()
        } catch {
            log("⚠️ [BOOTSTRAP] Failed to ensure database subscriptions: \(error)", category: "subs")
        }
    }

    func ensureCurrentUserID() async throws -> String {
        if let cached = currentUserID, !cached.isEmpty {
            return cached
        }

        await bootstrapIfNeeded()
        if let cached = currentUserID, !cached.isEmpty {
            return cached
        }

        let status = await checkAccountStatus()
        guard status == .available else {
            log("⚠️ [IDENTITY] CloudKit account unavailable when fetching user ID: \(status.rawValue)", category: "account")
            throw CloudKitChatError.userNotAuthenticated
        }

        do {
            let recordName = try await container.userRecordID().recordName
            currentUserID = recordName
            log("✅ [IDENTITY] Resolved current user recordName: \(recordName)", category: "account")
            return recordName
        } catch {
            log("❌ [IDENTITY] Failed to fetch current user record ID: \(error)", category: "account")
            throw error
        }
    }

    private func setupSyncNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name.CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleAccountChanged()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .cloudKitShareAccepted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.ensureSubscriptions()
                } catch {
                    log("⚠️ [SUBSCRIPTION] Failed to ensure subscriptions after share acceptance: \(error)", category: "subs")
                }
            }
        }
    }

    func handleAccountChanged() async {
        log("[ACCOUNT] CloudKit account change detected. Resetting state...", category: "account")

        currentUserID = nil
        isInitialized = false
        lastError = nil

        roomScopeCache.removeAll()
        privateZoneCache.removeAll()
        sharedZoneCache.removeAll()
        UserDefaults.standard.removeObject(forKey: roomScopeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: privateZoneCacheKey)
        UserDefaults.standard.removeObject(forKey: sharedZoneCacheKey)

        clearCache()
        clearAllChangeTokens()

        if #available(iOS 17.0, *) {
            await CKSyncEngineManager.shared.resetEngines()
        }
        await bootstrapIfNeeded()
    }
    
    // MARK: - Initialization
    
    /// CloudKit 初期化と自動レガシーデータリセット
    private func initialize() async {
        log("🚀 [INITIALIZATION] Starting CloudKitChatManager initialization...", category: "zone")
        let containerIDString = container.containerIdentifier ?? "unknown"
        #if DEBUG
        let buildChannel = "Debug (assumed CloudKit Development env)"
        #else
        let buildChannel = isTestFlightBuild ? "TestFlight (assumed CloudKit Production env)" : "Release (assumed CloudKit Production env)"
        #endif
        let ckSharingSupported = (Bundle.main.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool) == true
        log("🧭 [ENV] CK Container: \(containerIDString) | Build: \(buildChannel) | CKSharingSupported=\(ckSharingSupported)", category: "zone")
        
        // アカウント状態の確認
        let accountStatus = await checkAccountStatus()
        guard accountStatus == .available else {
            log("❌ [INITIALIZATION] CloudKit account not available: \(accountStatus.rawValue)", category: "account")
            lastError = CloudKitChatError.userNotAuthenticated
            return
        }
        
        do {
            // 自動レガシーデータリセット
            try await resetIfLegacyDataDetected()
            
            // UserID の設定
            currentUserID = try await container.userRecordID().recordName
            log("✅ [INITIALIZATION] Current UserID: \(currentUserID ?? "nil")", category: "account")
            
            // スキーマ作成
            try await createSchemaIfNeeded()

            // 一貫性チェックと必要に応じた完全リセット
            await validateAndResetIfInconsistent()
            
            isInitialized = true
            log("✅ [INITIALIZATION] CloudKitChatManager initialization completed successfully", category: "zone")
            
        } catch {
            log("❌ [INITIALIZATION] CloudKitChatManager initialization failed: \(error)", category: "error")
            lastError = error
        }
    }

    // 旧マイグレーションは廃止（不整合検知→完全リセットで回復）

    // MARK: - Tutorial Seeding (CloudKit)
    /// ルーム作成時にチュートリアルメッセージをCloudKitへ投入
    private func seedTutorialMessages(to zoneID: CKRecordZone.ID, ownerID: String) async {
        let samples: [String] = [
            "4-Marinへようこそ！🌊",
            "大切な人と2人だけの空間です",
            "😊",
            "画像も送れます📸",
            "リアクションもできるよ",
            "長押しで編集もできます",
            "ビデオ通話やカレンダー共有も",
            "2人だけの思い出を作ろう💕"
        ]
        var records: [CKRecord] = []
        let roomID = zoneID.zoneName
        for (idx, body) in samples.enumerated() {
            let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
            let rec = CKRecord(recordType: "Message", recordID: recID)
            rec["roomID"] = roomID as CKRecordValue
            rec["senderID"] = ownerID as CKRecordValue
            rec["text"] = body as CKRecordValue
            let ts = Date().addingTimeInterval(TimeInterval(idx))
            rec["timestamp"] = ts as CKRecordValue
            records.append(rec)
        }
        do {
            _ = try await privateDB.modifyRecords(saving: records, deleting: [])
            log("✅ [SEED] Seeded tutorial messages (\(records.count)) to zone: \(roomID)", category: "zone")
        } catch {
            log("⚠️ [SEED] Failed to seed tutorial messages: \(error)", category: "zone")
        }
    }

    // MARK: - Room Creation & Sharing

    // MARK: - Change Tokens & Delta Fetch

    private func database(for scope: CKDatabase.Scope) -> CKDatabase {
        switch scope {
        case .shared: return sharedDB
        default: return privateDB
        }
    }

    private func changeToken(for scope: CKDatabase.Scope) -> CKServerChangeToken? {
        switch scope {
        case .shared: return sharedDBChangeToken
        default: return privateDBChangeToken
        }
    }

    private func setChangeToken(_ token: CKServerChangeToken?, for scope: CKDatabase.Scope) {
        switch scope {
        case .shared: sharedDBChangeToken = token
        default: privateDBChangeToken = token
        }
    }

    private func zoneTokenKey(for scope: CKDatabase.Scope, zoneID: CKRecordZone.ID) -> String {
        let ownerName = zoneID.ownerName
        return "\(scope.rawValue)|\(zoneID.zoneName)|\(ownerName)"
    }

    private func zoneToken(for scope: CKDatabase.Scope, zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        zoneChangeTokens[zoneTokenKey(for: scope, zoneID: zoneID)]
    }

    private func setZoneToken(_ token: CKServerChangeToken?, for scope: CKDatabase.Scope, zoneID: CKRecordZone.ID) {
        let key = zoneTokenKey(for: scope, zoneID: zoneID)
        if let token {
            zoneChangeTokens[key] = token
        } else {
            zoneChangeTokens.removeValue(forKey: key)
        }
    }

    private func loadChangeTokens() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: privateDBTokenKey),
           let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) {
            privateDBChangeToken = token
        }
        if let data = defaults.data(forKey: sharedDBTokenKey),
           let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) {
            sharedDBChangeToken = token
        }
        if let raw = defaults.dictionary(forKey: zoneTokenKey) as? [String: Data] {
            var restored: [String: CKServerChangeToken] = [:]
            for (key, data) in raw {
                if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) {
                    restored[key] = token
                }
            }
            zoneChangeTokens = restored
        }
    }

    private func persistChangeTokens() {
        let defaults = UserDefaults.standard
        if let token = privateDBChangeToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            defaults.set(data, forKey: privateDBTokenKey)
        } else {
            defaults.removeObject(forKey: privateDBTokenKey)
        }
        if let token = sharedDBChangeToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            defaults.set(data, forKey: sharedDBTokenKey)
        } else {
            defaults.removeObject(forKey: sharedDBTokenKey)
        }
        var raw: [String: Data] = [:]
        for (key, token) in zoneChangeTokens {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                raw[key] = data
            }
        }
        defaults.set(raw, forKey: zoneTokenKey)
    }

    private func clearChangeTokens(for scope: CKDatabase.Scope) {
        setChangeToken(nil, for: scope)
        let prefix = "\(scope.rawValue)|"
        zoneChangeTokens = zoneChangeTokens.filter { !$0.key.hasPrefix(prefix) }
    }

    func clearAllChangeTokens() {
        clearChangeTokens(for: .private)
        clearChangeTokens(for: .shared)
        persistChangeTokens()
    }

    private func shouldTriggerFullReset(for error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .changeTokenExpired, .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            if let partials = ckError.partialErrorsByItemID?.values {
                return partials.contains { shouldTriggerFullReset(for: $0) }
            }
            return false
        default:
            return false
        }
    }

    func fetchDatabaseChanges(scope: CKDatabase.Scope) async throws -> DatabaseChangeSummary {
        let database = database(for: scope)
        let previousToken = changeToken(for: scope)
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchDatabaseChangesOperation(previousServerChangeToken: previousToken)
            operation.qualityOfService = .userInitiated
            var changed: [CKRecordZone.ID] = []
            var deleted: [CKRecordZone.ID] = []

            operation.recordZoneWithIDChangedBlock = { zoneID in
                if zoneID.zoneName != CKRecordZone.ID.defaultZoneName {
                    changed.append(zoneID)
                }
            }

            operation.recordZoneWithIDWasDeletedBlock = { zoneID in
                if zoneID.zoneName != CKRecordZone.ID.defaultZoneName {
                    deleted.append(zoneID)
                    self.setZoneToken(nil, for: scope, zoneID: zoneID)
                }
            }

            operation.changeTokenUpdatedBlock = { newToken in
                self.setChangeToken(newToken, for: scope)
            }

            operation.fetchDatabaseChangesResultBlock = { result in
                switch result {
                case .success(let payload):
                    self.setChangeToken(payload.serverChangeToken, for: scope)
                    self.persistChangeTokens()
                    continuation.resume(returning: DatabaseChangeSummary(changedZoneIDs: changed, deletedZoneIDs: deleted))
                case .failure(let error):
                    if self.shouldTriggerFullReset(for: error) {
                        self.clearChangeTokens(for: scope)
                        self.persistChangeTokens()
                        continuation.resume(throwing: CloudKitChatError.requiresFullReset)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
    }

    private func extractSavedRecord(from results: [CKRecord.ID: Result<CKRecord, Error>], recordID: CKRecord.ID) throws -> CKRecord {
        guard let outcome = results[recordID] else {
            throw CloudKitChatError.recordSaveFailed
        }
        switch outcome {
        case .success(let record):
            return record
        case .failure(let error):
            throw error
        }
    }

    func fetchRecordZoneChanges(scope: CKDatabase.Scope,
                                zoneIDs: [CKRecordZone.ID],
                                desiredKeys: [String]? = nil) async throws -> ZoneChangeBatch {
        guard !zoneIDs.isEmpty else {
            return ZoneChangeBatch(changedRecords: [], deletedRecordIDs: [])
        }

        let database = database(for: scope)
        var configurations: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        for zoneID in zoneIDs {
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: zoneToken(for: scope, zoneID: zoneID),
                resultsLimit: nil,
                desiredKeys: desiredKeys
            )
            configurations[zoneID] = configuration
        }

        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIDs, configurationsByRecordZoneID: configurations)
            operation.qualityOfService = .userInitiated
            let group = CKOperationGroup()
            group.name = "sync.fetchZoneChanges.\(scope.rawValue)"
            operation.group = group

            var changedRecords: [CKRecord] = []
            var deletedRecordIDs: [CKRecord.ID] = []
            var requiresReset = false

            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    changedRecords.append(record)
                case .failure(let error):
                    log("[SYNC] Failed to fetch changed record: \(error)", category: "sync")
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedRecordIDs.append(recordID)
            }

            operation.recordZoneChangeTokensUpdatedBlock = { zoneID, token, _ in
                self.setZoneToken(token, for: scope, zoneID: zoneID)
            }

            operation.recordZoneFetchResultBlock = { zoneID, result in
                switch result {
                case .success(let payload):
                    self.setZoneToken(payload.serverChangeToken, for: scope, zoneID: zoneID)
                case .failure(let error):
                    if self.shouldTriggerFullReset(for: error) {
                        self.setZoneToken(nil, for: scope, zoneID: zoneID)
                        requiresReset = true
                    } else {
                        log("[SYNC] Zone fetch error for \(zoneID.zoneName): \(error)", category: "sync")
                    }
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                if requiresReset {
                    self.persistChangeTokens()
                    continuation.resume(throwing: CloudKitChatError.requiresFullReset)
                    return
                }

                switch result {
                case .success:
                    self.persistChangeTokens()
                    continuation.resume(returning: ZoneChangeBatch(changedRecords: changedRecords, deletedRecordIDs: deletedRecordIDs))
                case .failure(let error):
                    if self.shouldTriggerFullReset(for: error) {
                        self.persistChangeTokens()
                        continuation.resume(throwing: CloudKitChatError.requiresFullReset)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
    }

    func performInviteMaintenance(retentionDays: Int = 7) async {
        await InvitationManager.shared.cleanupOrphanedInviteReferences()
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        do {
            let modelContext = try ModelContainerBroker.shared.mainContext()
            var removedRooms = Set<String>()
            let legacyRemoved = await purgeLegacyPendingInvites(modelContext: modelContext)
            removedRooms.formUnion(legacyRemoved)
            let staleRemoved = await purgeStaleZones(olderThan: cutoff, excluding: removedRooms, modelContext: modelContext)
            removedRooms.formUnion(staleRemoved)
            if !removedRooms.isEmpty {
                do {
                    try modelContext.save()
                } catch {
                    log("⚠️ [MAINTENANCE] Failed to persist invite maintenance results: \(error)", category: "zone")
                }
            }
        } catch ModelContainerBroker.BrokerError.containerUnavailable {
            log("ℹ️ [MAINTENANCE] ModelContainer unavailable, skipping invite maintenance", category: "zone")
        } catch {
            log("⚠️ [MAINTENANCE] Invite maintenance aborted: \(error)", category: "zone")
        }
    }

    private func purgeLegacyPendingInvites(modelContext: ModelContext) async -> Set<String> {
        var removed: Set<String> = []
        do {
            let descriptor = FetchDescriptor<ChatRoom>()
            let rooms = try modelContext.fetch(descriptor)
            for room in rooms {
                guard let participant = room.primaryCounterpart else { continue }
                let remoteID = participant.userID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard await isOwnerOfRoom(room.roomID) else { continue }
                if remoteID.caseInsensitiveCompare("pending") == .orderedSame {
                    let zoneID = CKRecordZone.ID(zoneName: room.roomID)
                    do {
                        if try await deleteRoom(zoneID: zoneID, roomID: room.roomID, modelContext: modelContext) {
                            removed.insert(room.roomID)
                        }
                    } catch {
                        log("⚠️ [MAINTENANCE] Failed to purge legacy pending invite roomID=\(room.roomID): \(error)", category: "zone")
                    }
                }
            }
        } catch {
            log("⚠️ [MAINTENANCE] Failed to enumerate rooms for legacy purge: \(error)", category: "zone")
        }
        return removed
    }

    private func purgeStaleZones(olderThan cutoff: Date,
                                 excluding excludedRooms: Set<String>,
                                 modelContext: ModelContext) async -> Set<String> {
        var removed: Set<String> = []
        do {
            let descriptor = FetchDescriptor<ChatRoom>()
            let rooms = try modelContext.fetch(descriptor)
            for room in rooms {
                guard !excludedRooms.contains(room.roomID) else { continue }
                guard await isOwnerOfRoom(room.roomID) else { continue }
                let hasRemote = room.participants.contains(where: { !$0.isLocal && !$0.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                guard !hasRemote else { continue }
                guard room.createdAt < cutoff else { continue }
                let zoneID = CKRecordZone.ID(zoneName: room.roomID)
                do {
                    let shareDescriptor = try await fetchShare(for: room.roomID)
                    let nonOwnerParticipants = shareDescriptor.share.participants.filter { $0.role != .owner }
                    let hasAccepted = nonOwnerParticipants.contains(where: { $0.acceptanceStatus == .accepted })
                    let hasPending = nonOwnerParticipants.contains(where: { $0.acceptanceStatus == .pending || $0.acceptanceStatus == .unknown })
                    if !hasAccepted && (nonOwnerParticipants.isEmpty || hasPending) {
                        if try await deleteRoom(zoneID: zoneID, roomID: room.roomID, modelContext: modelContext) {
                            removed.insert(room.roomID)
                            log("🧹 [MAINTENANCE] Removed stale invite roomID=\(room.roomID)", category: "zone")
                        }
                    }
                } catch {
                    if let chatError = error as? CloudKitChatError, chatError == .shareNotFound {
                        do {
                            if try await deleteRoom(zoneID: zoneID, roomID: room.roomID, modelContext: modelContext) {
                                removed.insert(room.roomID)
                                log("🧹 [MAINTENANCE] Removed roomID=\(room.roomID) without share metadata", category: "zone")
                            }
                        } catch {
                            log("⚠️ [MAINTENANCE] Failed to delete room without share roomID=\(room.roomID): \(error)", category: "zone")
                        }
                    } else if let ckError = error as? CKError, ckError.code == .unknownItem {
                        do {
                            if try await deleteRoom(zoneID: zoneID, roomID: room.roomID, modelContext: modelContext) {
                                removed.insert(room.roomID)
                                log("🧹 [MAINTENANCE] Removed roomID=\(room.roomID) with missing share record", category: "zone")
                            }
                        } catch {
                            log("⚠️ [MAINTENANCE] Failed to delete missing-share room roomID=\(room.roomID): \(error)", category: "zone")
                        }
                    } else {
                        log("⚠️ [MAINTENANCE] Retention check failed for roomID=\(room.roomID): \(error)", category: "zone")
                    }
                }
            }
        } catch {
            log("⚠️ [MAINTENANCE] Failed to enumerate rooms for retention: \(error)", category: "zone")
        }
        return removed
    }

    func handleDeletedZones(_ zoneIDs: [CKRecordZone.ID]) async {
        guard !zoneIDs.isEmpty else { return }
        do {
            let modelContext = try ModelContainerBroker.shared.mainContext()
            var didModify = false
            for zoneID in zoneIDs {
                let roomID = zoneID.zoneName
                removeCaches(for: roomID)
                setZoneToken(nil, for: .private, zoneID: zoneID)
                setZoneToken(nil, for: .shared, zoneID: zoneID)
                let mutated = try deleteLocalData(for: roomID, modelContext: modelContext)
                didModify = didModify || mutated
                log("🧹 [MAINTENANCE] Cleaned up after remote zone deletion roomID=\(roomID)", category: "zone")
            }
            persistChangeTokens()
            if didModify {
                do { try modelContext.save() } catch { log("⚠️ [MAINTENANCE] Failed to save deletions from zone removal: \(error)", category: "zone") }
            }
        } catch ModelContainerBroker.BrokerError.containerUnavailable {
            log("ℹ️ [MAINTENANCE] ModelContainer unavailable; skipped local cleanup for deleted zones", category: "zone")
        } catch {
            log("⚠️ [MAINTENANCE] Failed to clean up deleted zones: \(error)", category: "zone")
        }
    }

    private func deleteRoom(zoneID: CKRecordZone.ID,
                            roomID: String,
                            modelContext: ModelContext) async throws -> Bool {
        do {
            _ = try await privateDB.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch {
            if let ckError = error as? CKError, ckError.code == .zoneNotFound {
                // already removed on server; continue with local cleanup
            } else {
                throw error
            }
        }
        removeCaches(for: roomID)
        setZoneToken(nil, for: .private, zoneID: zoneID)
        setZoneToken(nil, for: .shared, zoneID: zoneID)
        persistChangeTokens()
        let mutated = try deleteLocalData(for: roomID, modelContext: modelContext)
        return mutated
    }

    private func deleteLocalData(for roomID: String, modelContext: ModelContext) throws -> Bool {
        var mutated = false
        var roomDescriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
        roomDescriptor.fetchLimit = 1
        if let room = try modelContext.fetch(roomDescriptor).first {
            modelContext.delete(room)
            mutated = true
        }
        let messageDescriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.roomID == roomID })
        let messages = try modelContext.fetch(messageDescriptor)
        for message in messages {
            modelContext.delete(message)
            mutated = true
        }
        return mutated
    }

    private func removeCaches(for roomID: String) {
        roomScopeCache.removeValue(forKey: roomID)
        privateZoneCache.removeValue(forKey: roomID)
        sharedZoneCache.removeValue(forKey: roomID)
        persistZoneCaches()
        persistRoomScopeCache()
    }

    // MARK: - Public: Revoke share (owner) or leave shared zone (participant) and cleanup caches
    func revokeShareAndDeleteIfNeeded(roomID: String) async {
        do {
            let (db, zoneID) = try await resolveDatabaseAndZone(for: roomID)
            switch db.databaseScope {
            case .private:
                do { _ = try await privateDB.modifyRecordZones(saving: [], deleting: [zoneID]) }
                catch { if let ck = error as? CKError, ck.code == .zoneNotFound { /* ignore */ } else { log("⚠️ [REVOKE] Failed to delete private zone: \(error)", category: "share") } }
            case .shared:
                do { _ = try await sharedDB.modifyRecordZones(saving: [], deleting: [zoneID]) }
                catch { if let ck = error as? CKError, ck.code == .zoneNotFound { /* ignore */ } else { log("⚠️ [LEAVE] Failed to leave shared zone: \(error)", category: "share") } }
            default:
                break
            }
            removeCaches(for: roomID)
            persistChangeTokens()
            log("✅ [ROOM] Revoked/left zone and cleared caches roomID=\(roomID)", category: "share")
        } catch {
            log("⚠️ [ROOM] Failed to revoke/leave roomID=\(roomID): \(error)", category: "share")
        }
    }

    private func makeParticipantIdentifier(
        from rawValue: String,
        ownerRecordName: String
    ) throws -> ShareParticipantIdentifier {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("⚠️ Empty invitee identifier", level: "WARN", category: "share")
            throw CloudKitChatError.invalidUserID
        }
        if trimmed == ownerRecordName {
            log("⚠️ Invitee identifier refers to current user", level: "WARN", category: "share")
            throw CloudKitChatError.invalidUserID
        }
        if trimmed.contains("@") {
            return .email(trimmed.lowercased())
        }
        let allowedPhoneCharacters = CharacterSet(charactersIn: "+0123456789-() ")
        let isPhoneLike = trimmed.unicodeScalars.allSatisfy { allowedPhoneCharacters.contains($0) }
        if isPhoneLike {
            let digits = trimmed.filter { $0.isNumber }
            guard !digits.isEmpty else {
                log("⚠️ Phone-like identifier lacks digits", level: "WARN", category: "share")
                throw CloudKitChatError.invalidUserID
            }
            let normalized = trimmed.replacingOccurrences(of: " ", with: "")
            return .phoneNumber(normalized)
        }
        return .recordName(trimmed)
    }

    private func fetchShareParticipant(for identifier: ShareParticipantIdentifier) async throws -> CKShare.Participant {
        do {
            switch identifier {
            case .email(let email):
                return try await fetchShareParticipant(emailAddress: email)
            case .phoneNumber(let phone):
                return try await fetchShareParticipant(phoneNumber: phone)
            case .recordName(let recordName):
                return try await fetchShareParticipant(recordName: recordName)
            }
        } catch {
            if let ckError = error as? CKError, ckError.code == .unknownItem {
                throw CloudKitChatError.userNotFound
            }
            throw error
        }
    }

    private func fetchShareParticipant(emailAddress: String) async throws -> CKShare.Participant {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchShareParticipant(withEmailAddress: emailAddress) { participant, error in
                if let participant {
                    continuation.resume(returning: participant)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CloudKitChatError.userNotFound)
                }
            }
        }
    }

    private func fetchShareParticipant(phoneNumber: String) async throws -> CKShare.Participant {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchShareParticipant(withPhoneNumber: phoneNumber) { participant, error in
                if let participant {
                    continuation.resume(returning: participant)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CloudKitChatError.userNotFound)
                }
            }
        }
    }

    private func fetchShareParticipant(recordName: String) async throws -> CKShare.Participant {
        let recordID = CKRecord.ID(recordName: recordName)
        return try await withCheckedThrowingContinuation { continuation in
            container.fetchShareParticipant(withUserRecordID: recordID) { participant, error in
                if let participant {
                    continuation.resume(returning: participant)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CloudKitChatError.userNotFound)
                }
            }
        }
    }

    private func performModifyRecordsOperation(
        database: CKDatabase,
        recordsToSave: [CKRecord],
        groupName: String,
        isAtomic: Bool = true
    ) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: nil)
            operation.qualityOfService = .userInitiated
            operation.isAtomic = isAtomic
            if !isAtomic {
                operation.savePolicy = .changedKeys
            }
            let group = CKOperationGroup()
            group.name = groupName
            operation.group = group

            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            operation.perRecordSaveBlock = { recordID, result in
                results[recordID] = result
            }

            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private func performModifyRecordZonesOperation(
        database: CKDatabase,
        zonesToSave: [CKRecordZone],
        groupName: String
    ) async throws -> [CKRecordZone.ID: Result<CKRecordZone, Error>] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: zonesToSave, recordZoneIDsToDelete: nil)
            operation.qualityOfService = .userInitiated
            let group = CKOperationGroup()
            group.name = groupName
            operation.group = group

            var results: [CKRecordZone.ID: Result<CKRecordZone, Error>] = [:]
            operation.perRecordZoneSaveBlock = { zoneID, result in
                results[zoneID] = result
            }

            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private func ensureZoneExists(roomID: String, zoneID: CKRecordZone.ID) async throws {
        if let cached = privateZoneCache[roomID], cached == zoneID {
            return
        }

        if let existing = try? await findZone(named: roomID, in: privateDB), existing == zoneID {
            return
        }

        let results = try await performModifyRecordZonesOperation(
            database: privateDB,
            zonesToSave: [CKRecordZone(zoneID: zoneID)],
            groupName: "share.zone.prepare.\(roomID)"
        )

        guard let outcome = results[zoneID] else {
            throw CloudKitChatError.signalingZoneUnavailable
        }

        switch outcome {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private func fetchZoneWideShare(zoneID: CKRecordZone.ID) async throws -> CKShare {
        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let record = try await privateDB.record(for: shareRecordID)
        guard let share = record as? CKShare else {
            throw CloudKitChatError.shareNotFound
        }
        return share
    }

    func createSharedChatRoom(roomID: String, invitedUserID: String? = nil) async throws -> ChatShareDescriptor {
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty else {
            log("⚠️ Refusing to create share with empty roomID", level: "WARN", category: "share")
            throw CloudKitChatError.recordSaveFailed
        }

        let ownerRecordName = try await ensureCurrentUserID()
        let zoneID = CKRecordZone.ID(zoneName: normalizedRoomID)

        try await ensureZoneExists(roomID: normalizedRoomID, zoneID: zoneID)
        cache(roomID: normalizedRoomID, scope: .private, zoneID: zoneID)

        let roomRecordID = CKSchema.roomRecordID(for: normalizedRoomID, zoneID: zoneID)

        var existingRoomRecord: CKRecord?
        if let record = try? await privateDB.record(for: roomRecordID) {
            existingRoomRecord = record
        }

        let share: CKShare
        if let existingShare = try? await fetchZoneWideShare(zoneID: zoneID) {
            share = existingShare
        } else {
            share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = "4-Marin Chat" as CKRecordValue
            // 誰でもQR/URLで参加できるように公開権限を RW に設定（UICloudSharingController を使わない運用のため）
            share.publicPermission = .readWrite
        }

        var roomRecord: CKRecord
        if let existingRoomRecord {
            roomRecord = existingRoomRecord
        } else {
            roomRecord = CKRecord(recordType: CKSchema.SharedType.room, recordID: roomRecordID)
            roomRecord[CKSchema.FieldKey.roomID] = normalizedRoomID as CKRecordValue
            roomRecord[CKSchema.FieldKey.name] = normalizedRoomID as CKRecordValue
        }

        if let invitedUserID, !invitedUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inviteeIdentifier = try makeParticipantIdentifier(from: invitedUserID, ownerRecordName: ownerRecordName)
            let participant = try await fetchShareParticipant(for: inviteeIdentifier)
            participant.permission = .readWrite
            participant.role = .privateUser
            share.addParticipant(participant)
        }

        let wasNewShare = share.recordChangeTag == nil

        do {
            let saveResults = try await performModifyRecordsOperation(
                database: privateDB,
                recordsToSave: [roomRecord, share],
                groupName: "share.create.\(normalizedRoomID)"
            )

            guard let roomOutcome = saveResults[roomRecordID] else {
                log("❌ Room save result missing roomID=\(normalizedRoomID)", category: "share")
                throw CloudKitChatError.recordSaveFailed
            }
            switch roomOutcome {
            case .success:
                break
            case .failure(let error):
                log("❌ Room save failed roomID=\(normalizedRoomID): \(error)", category: "share")
                throw CloudKitChatError.recordSaveFailed
            }

            guard let shareOutcome = saveResults[share.recordID] else {
                log("❌ CKShare save result missing roomID=\(normalizedRoomID)", category: "share")
                throw CloudKitChatError.recordSaveFailed
            }

            let savedShareRecord: CKRecord
            switch shareOutcome {
            case .success(let record):
                savedShareRecord = record
            case .failure(let error):
                log("❌ CKShare save failed roomID=\(normalizedRoomID): \(error)", category: "share")
                throw CloudKitChatError.recordSaveFailed
            }

            guard let savedShare = savedShareRecord as? CKShare else {
                log("❌ Saved record is not CKShare roomID=\(normalizedRoomID)", category: "share")
                throw CloudKitChatError.recordSaveFailed
            }

            guard let url = savedShare.url else {
                log("❌ CKShare missing URL roomID=\(normalizedRoomID)", category: "share")
                throw CloudKitChatError.shareURLUnavailable
            }

            cache(roomID: normalizedRoomID, scope: .private, zoneID: zoneID)
            if wasNewShare {
                if existingRoomRecord == nil {
                    await seedTutorialMessages(to: zoneID, ownerID: ownerRecordName)
                }
                
                // オーナーのRoomMemberレコードを作成
                // 重要: Zone-wide sharingでは、オーナーはPrivate Databaseで操作する
                // オーナーがPrivate DBに作成したレコードは、参加者がShared DBから参照できる
                // 逆に、参加者がShared DBに作成したレコードは、オーナーがPrivate DBから参照できる
                let memberRecordID = CKSchema.roomMemberRecordID(userId: ownerRecordName, zoneID: zoneID)
                let memberRecord = CKRecord(recordType: CKSchema.SharedType.roomMember, recordID: memberRecordID)
                
                // メッセージと同じようにCKRecordValueとして設定
                memberRecord[CKSchema.FieldKey.userId] = ownerRecordName as CKRecordValue
                
                // DEBUG: RoomMemberレコード作成時のuserIDフィールドを確認
                log("[DEBUG] Creating RoomMember record=\(memberRecordID.recordName) with userId=\(ownerRecordName)", category: "share")
                
                let displayName = (UserDefaults.standard.string(forKey: "myDisplayName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayName.isEmpty {
                    memberRecord[CKSchema.FieldKey.displayName] = displayName as CKRecordValue
                }
                
                // メッセージと同じようにCKSyncEngineManagerを使用
                if #available(iOS 17.0, *) {
                    log("📤 [ZONE-SHARE] Creating owner RoomMember via CKSyncEngine", category: "share")
                    await CKSyncEngineManager.shared.queueRoomMember(userID: ownerRecordName, displayName: displayName, roomID: normalizedRoomID)
                    await CKSyncEngineManager.shared.kickSyncNow()
                    log("✅ [ZONE-SHARE] Queued owner's RoomMember record to CKSyncEngine", category: "share")
                } else {
                    // iOS 17未満の場合は従来の方法を使用
                    do {
                        _ = try await privateDB.save(memberRecord)
                        log("✅ Created owner's RoomMember record in private DB roomID=\(normalizedRoomID) (legacy)", category: "share")
                    } catch {
                        log("⚠️ Failed to create owner's RoomMember record: \(error)", category: "share")
                        if let ckError = error as? CKError {
                            log("⚠️ CKError code=\(ckError.code.rawValue) desc=\(ckError.localizedDescription)", category: "share")
                        }
                    }
                }
                
            log("✅ Created zone-wide share roomID=\(normalizedRoomID)", category: "share")
        } else {
            log("ℹ️ Updated zone-wide share roomID=\(normalizedRoomID)", category: "share")
        }
        
        // 共有URLのログ
        log("📎 [SHARE URL] Generated share URL for roomID=\(normalizedRoomID): \(url.absoluteString)", category: "share")

        return ChatShareDescriptor(share: savedShare, shareURL: url, roomRecordID: roomRecordID, zoneID: zoneID)
        } catch {
            if let ckError = error as? CKError,
               let partial = ckError.partialErrorsByItemID {
                for (anyID, itemError) in partial {
                    if let recordID = anyID as? CKRecord.ID {
                        log("❌ Partial failure recordID=\(recordID.recordName): \(itemError)", category: "share")
                    } else {
                        log("❌ Partial failure itemID=\(anyID): \(itemError)", category: "share")
                    }
                }
            }
            log("❌ Failed to create zone-wide share roomID=\(normalizedRoomID): \(error)", category: "share")
            throw error
        }
    }

    func getRoomRecord(roomID: String) async throws -> CKRecord {
        let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let recordID = CKSchema.roomRecordID(for: roomID, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        log("✅ Retrieved Room record=\(record.recordID.recordName) scope=\(database.databaseScope)", category: "share")
        return record
    }

    func fetchShare(for roomID: String) async throws -> ChatShareDescriptor {
        let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        guard database.databaseScope == .private else {
            log("⚠️ fetchShare requires owner scope roomID=\(roomID)", category: "share")
            throw CloudKitChatError.shareNotFound
        }

        let roomRecordID = CKSchema.roomRecordID(for: roomID, zoneID: zoneID)
        _ = try await database.record(for: roomRecordID)

        let share = try await fetchZoneWideShare(zoneID: zoneID)
        guard let url = share.url else {
            log("⚠️ CKShare missing URL roomID=\(roomID)", category: "share")
            throw CloudKitChatError.shareURLUnavailable
        }

        cache(roomID: roomID, scope: .private, zoneID: zoneID)
        return ChatShareDescriptor(share: share, shareURL: url, roomRecordID: roomRecordID, zoneID: zoneID)
    }
    
    /// 🌟 [AUTO RESET] レガシーデータを検出した場合の自動リセット
    func resetIfLegacyDataDetected() async throws {
        let hasLegacyData = await detectLegacyData()
        
        if hasLegacyData {
            log("🚀 [AUTO RESET] Legacy data detected, performing automatic reset to ideal implementation", category: "zone")
            
            // 理想実装への自動移行ログ
            log("📋 [AUTO RESET] Migration plan:", category: "zone")
            log("   • Clear legacy CloudKit data (CD_ChatRoom → Room, body → text)", category: "zone")
            log("   • Clear local SwiftData (unsync'd messages)", category: "zone")
            log("   • Rebuild with ideal schema (desiredKeys, indexes, MessageReaction)", category: "zone")
            log("   • Enable automatic 🌟 [IDEAL] implementation", category: "zone")
            
            do {
                log("🔄 [AUTO RESET] Starting performCompleteReset...", category: "zone")
                try await performCompleteReset(bypassSafetyCheck: true)
                log("✅ [AUTO RESET] performCompleteReset completed successfully", category: "zone")
            } catch {
                log("❌ [AUTO RESET] performCompleteReset failed: \(error)", category: "error")
                throw error
            }
            
            // リセット実行フラグを設定
            
            log("✅ [AUTO RESET] Legacy data reset completed - ideal implementation active", category: "zone")
            NotificationCenter.default.post(name: .cloudKitResetPerformed, object: nil)
            
        } else {
            log("✅ [AUTO RESET] No legacy data detected - ideal implementation already active", category: "zone")
        }
    }
    
    /// 🌟 [IDEAL] スキーマ作成（理想実装 - チャット別ゾーン）
    private func createSchemaIfNeeded() async throws {
        log("🔧 [IDEAL SCHEMA] Checking if ideal schema setup is needed...", category: "share")
        
        // 既に作成済みの場合はスキップ
        if isInitialized {
            log("✅ [IDEAL SCHEMA] Schema already configured, skipping setup", category: "share")
            return
        }
        
        // 🌟 [IDEAL] レガシーSharedRoomsゾーンの存在チェック（警告目的）
        do {
            let zones = try await privateDB.allRecordZones()
            let legacyZone = zones.first { $0.zoneID.zoneName == "SharedRooms" }
            
            if legacyZone != nil {
                log("⚠️ [IDEAL SCHEMA] Legacy SharedRooms zone detected - this should be removed by auto-reset", category: "share")
                log("🌟 [IDEAL SCHEMA] Ideal implementation uses individual chat zones (chat-xxxxx)", category: "share")
            } else {
                log("✅ [IDEAL SCHEMA] No legacy SharedRooms zone found - ideal architecture active", category: "share")
            }
        } catch {
            log("⚠️ [IDEAL SCHEMA] Could not check for legacy zones: \(error)", category: "share")
        }
        
        // 🌟 [IDEAL] スキーマ準備（チャット作成時にゾーンを個別作成するため、ここでは全体設定のみ）
        log("🌟 [IDEAL SCHEMA] Schema ready - individual chat zones will be created per chat", category: "share")
        log("✅ [IDEAL SCHEMA] Ideal schema setup completed", category: "share")
    }
    
    /// CloudKit アカウント状態の確認
    private func checkAccountStatus() async -> CKAccountStatus {
        return await withCheckedContinuation { continuation in
            container.accountStatus { status, error in
                if let error = error {
                    log("❌ Failed to check CloudKit account status: \(error)", category: "share")
                    continuation.resume(returning: .couldNotDetermine)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }
    
    /// キャッシュをクリア
    private func clearCache() {
        profileCache.removeAll()
        log("🧹 Profile cache cleared", category: "share")
    }

    private func persistRoomScopeCache() {
        do {
            let data = try JSONEncoder().encode(roomScopeCache)
            UserDefaults.standard.set(data, forKey: roomScopeDefaultsKey)
        } catch {
            log("⚠️ Failed to persist roomScopeCache: \(error)", category: "share")
        }
    }

    private func persistZoneCaches() {
        persistZoneCache(privateZoneCache, key: privateZoneCacheKey)
        persistZoneCache(sharedZoneCache, key: sharedZoneCacheKey)
    }

    private func persistZoneCache(_ cache: [String: CKRecordZone.ID], key: String) {
        let entries = cache.mapValues { ZoneCacheEntry(zoneID: $0) }
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            log("⚠️ Failed to persist zone cache key=\(key): \(error)", category: "share")
        }
    }

    private func cache(roomID: String, scope: RoomScope, zoneID: CKRecordZone.ID) {
        switch scope {
        case .private:
            privateZoneCache[roomID] = zoneID
        case .shared:
            sharedZoneCache[roomID] = zoneID
        }
        roomScopeCache[roomID] = scope.rawValue
        persistZoneCaches()
        persistRoomScopeCache()
    }

    @MainActor
    private func ensureLocalParticipant(for room: ChatRoom, scope: RoomScope) {
        let current = (currentUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let participant = ChatRoom.Participant(userID: current,
                                               isLocal: true,
                                               role: scope == .private ? .owner : .participant,
                                               displayName: nil,
                                               avatarData: nil,
                                               lastUpdatedAt: Date())
        room.upsertParticipant(participant)
    }

    // MARK: - Bootstrap Rooms (Owned / Shared)

    /// 共有DB側に存在するチャットゾーンからローカルのChatRoomをブートストラップ
    @MainActor
    func bootstrapSharedRooms(modelContext: ModelContext) async {
        do {
            let zones = try await fetchRecordZones(in: sharedDB)
            var createdOrUpdated = 0
            for zone in zones where zone.zoneID.zoneName != CKRecordZone.ID.defaultZoneName {
                let roomID = zone.zoneID.zoneName
                let roomRecordID = CKSchema.roomRecordID(for: roomID, zoneID: zone.zoneID)
                if (try? await sharedDB.record(for: roomRecordID)) == nil { continue }

                // キャッシュ更新
                cache(roomID: roomID, scope: .shared, zoneID: zone.zoneID)

                // SwiftDataに存在しなければ作成
                var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
                descriptor.fetchLimit = 1
                let room: ChatRoom
                if let existing = (try? modelContext.fetch(descriptor))?.first {
                    room = existing
                } else {
                    room = ChatRoom(roomID: roomID)
                    modelContext.insert(room)
                }
                ensureLocalParticipant(for: room, scope: .shared)

                // 可能なら相手プロフィールを反映
                log("[DEBUG] Fetching remote participant profile for room=\(roomID)", category: "share")
                if let profile = try? await fetchRemoteParticipantFromRoomMember(roomID: roomID) {
                    log("[DEBUG] Found remote profile for room=\(roomID): \(String(profile.userID.prefix(8)))", category: "share")
                    apply(profile: profile, to: room)
                } else {
                    log("[DEBUG] No remote profile found yet for room=\(roomID)", category: "share")
                }

                do { try modelContext.save(); createdOrUpdated += 1 } catch { log("⚠️ Failed to save ChatRoom bootstrap (shared): \(error)", category: "share") }
            }
            if createdOrUpdated > 0 { log("✅ Bootstrapped/updated shared rooms: \(createdOrUpdated)", category: "share") }
        } catch {
            log("⚠️ Failed to bootstrap shared rooms: \(error)", category: "share")
        }
    }

    /// プライベートDB側に存在するチャットゾーンからローカルのChatRoomをブートストラップ
    @MainActor
    func bootstrapOwnedRooms(modelContext: ModelContext) async {
        do {
            let zones = try await fetchRecordZones(in: privateDB)
            var created = 0
            for zone in zones where zone.zoneID.zoneName != CKRecordZone.ID.defaultZoneName {
                let roomID = zone.zoneID.zoneName
                let roomRecordID = CKSchema.roomRecordID(for: roomID, zoneID: zone.zoneID)
                if (try? await privateDB.record(for: roomRecordID)) == nil { continue }

                // キャッシュ更新
                cache(roomID: roomID, scope: .private, zoneID: zone.zoneID)

                // SwiftDataに存在しなければ作成（所有者側は remoteUserID は空のまま）
                var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
                descriptor.fetchLimit = 1
                if let existing = (try? modelContext.fetch(descriptor))?.first {
                    ensureLocalParticipant(for: existing, scope: .private)
                } else {
                    let room = ChatRoom(roomID: roomID)
                    modelContext.insert(room)
                    ensureLocalParticipant(for: room, scope: .private)
                    do { try modelContext.save(); created += 1 } catch { log("⚠️ Failed to save ChatRoom bootstrap (owned): \(error)", category: "share") }
                }
            }
            if created > 0 { log("✅ Bootstrapped owned rooms: \(created)", category: "share") }
        } catch {
            log("⚠️ Failed to bootstrap owned rooms: \(error)", category: "share")
        }
    }

    // MARK: - Reactions (Fetch)

    /// 指定メッセージに紐づくリアクション一覧を取得（正規化レコード Reaction のみ）
    func getReactionsForMessage(messageRecordName: String, roomID: String) async throws -> [MessageReaction] {
        let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let msgRef = MessageReaction.createMessageReference(messageID: messageRecordName, zoneID: zoneID)

        var reactions: [MessageReaction] = []

        // Reaction のみ（旧スキーマへのフォールバックは行わない）
        let predicate = NSPredicate(format: "%K == %@", CKSchema.FieldKey.messageRef, msgRef)
        let query = CKQuery(recordType: CKSchema.SharedType.reaction, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.FieldKey.creationDate, ascending: true)]
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        for (_, r) in results {
            if let rec = try? r.get(), let m = MessageReaction.fromCloudKitRecord(rec) { reactions.append(m) }
        }

        // 重複除去 + 作成日で安定ソート
        let unique = Dictionary(grouping: reactions, by: { $0.id }).compactMap { $0.value.first }
        return unique.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Avatar shape helpers
    func stableShapeIndex(for userID: String) -> Int {
        // SHA256の先頭バイトを使用（0-4の5種類）
        let data = Data(userID.utf8)
        let digest = SHA256.hash(data: data)
        // Sequence.first の曖昧さを避け、安全に先頭バイトを取得
        let firstByte: UInt8 = digest.withUnsafeBytes { buf in
            buf.first ?? 0
        }
        return Int(firstByte % 5)
    }
    func getCachedAvatarShapeIndex(for userID: String) -> Int? {
        profileCache[userID]?.shapeIndex
    }
    
    /// 完全リセット実行（CloudKit・ローカル含む全消去）
    func performCompleteReset(bypassSafetyCheck: Bool = false) async throws {
        log("🔄 [RESET] Starting complete CloudKit reset...", category: "share")
        // 環境によるブロックは行わない（常に実行可能）
        
        do {
            // 1. 全サブスクリプションを削除
            try await removeAllSubscriptions()
            
            // 2. プライベートDBをクリア
            try await clearPrivateDatabase()
            
            // 3. 共有ゾーンから離脱
            try await leaveAllSharedDatabases()
            
            // 4. UserDefaultsをクリア
            clearUserDefaults()
            
            // 5. ローカルSwiftDataをクリア
            try await clearLocalDatabase()
            
            // 6. キャッシュをクリア
            clearCache()
            
            log("✅ [RESET] Complete CloudKit reset finished successfully", category: "share")
            
        } catch {
            log("❌ [RESET] Complete CloudKit reset failed: \(error)", category: "share")
            throw CloudKitChatError.resetFailed
        }
    }

    /// 全てをリセット（統合API）
    func resetAll() async throws {
        try await performCompleteReset(bypassSafetyCheck: true)
    }
    
    /// 💡 [AUTO RESET] レガシーデータの検出（CloudKit + ローカルDB）
    private func detectLegacyData() async -> Bool {
        log("🔍 [AUTO RESET] Starting comprehensive legacy data detection...", category: "share")
        
        // 1. CloudKit レガシーデータ検出（ゾーンベース - クエリエラー回避）
        log("🔍 [AUTO RESET] Checking for legacy architecture patterns (zone-based detection)", category: "share")
        
        // 2. レガシーゾーン（SharedRooms）の検出 - 別途tryブロック
        do {
            let zones = try await privateDB.allRecordZones()
            let sharedRoomsZone = zones.first { $0.zoneID.zoneName == "SharedRooms" }
            
            if sharedRoomsZone != nil {
                log("⚠️ [LEGACY DETECTED] Legacy 'SharedRooms' zone found - should use individual chat zones", category: "share")
                log("🔍 [AUTO RESET] Legacy data detection completed: LEGACY DATA FOUND (SharedRooms zone)", category: "share")
                return true
            }
            
            log("CloudKit legacy zones not found (expected for ideal implementation)", category: "share")
        } catch {
            log("CloudKit legacy zone check completed with error (will continue): \(error)", category: "share")
        }
        
        // 3. ローカルDB（SwiftData）のレガシーデータ検出
        let localLegacyCount = await detectLocalLegacyData()
        if localLegacyCount > 0 {
            log("⚠️ [LEGACY DETECTED] \(localLegacyCount) local messages with no CloudKit sync (ckRecordName: nil)", category: "share")
            log("🔍 [AUTO RESET] Legacy data detection completed: LEGACY DATA FOUND (local unsync data)", category: "share")
            return true
        }
        
        log("🔍 [AUTO RESET] Legacy data detection completed: NO LEGACY DATA", category: "share")
        
        return false
    }
    
    /// ローカルDB（SwiftData）のレガシーデータ検出
    private func detectLocalLegacyData() async -> Int {
        do {
            let unsyncedCount = try ModelContainerBroker.shared.countMessagesMissingCloudRecord()
            log("[AUTO RESET] Local messages without CloudKit record=\(unsyncedCount)", category: "share")
            if unsyncedCount >= 50 {
                log("⚠️ [AUTO RESET] Detected \(unsyncedCount) unsynced messages — recommend manual review", category: "share")
            }
            return unsyncedCount
        } catch ModelContainerBroker.BrokerError.containerUnavailable {
            log("[AUTO RESET] ModelContainer not yet available for legacy check", category: "share")
            return 0
        } catch {
            log("[AUTO RESET] Failed to inspect local database: \(error)", category: "share")
            return 1
        }
    }

    private func clearPrivateDatabase() async throws {
        do {
            let zones = try await privateDB.allRecordZones()
            let customZones = zones.filter { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            if !customZones.isEmpty {
                let zoneIDs = customZones.map { $0.zoneID }
                _ = try await privateDB.modifyRecordZones(saving: [], deleting: zoneIDs)
                log("🗑️ [RESET] Deleted \(zoneIDs.count) private custom zones", category: "share")
            }
        } catch {
            log("⚠️ [RESET] Failed to clear private database: \(error)", category: "share")
            throw error
        }
    }

    private func leaveAllSharedDatabases() async throws {
        do {
            let sharedZones = try await sharedDB.allRecordZones()
            let customShared = sharedZones.filter { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            if !customShared.isEmpty {
                let zoneIDs = customShared.map { $0.zoneID }
                _ = try await sharedDB.modifyRecordZones(saving: [], deleting: zoneIDs)
                log("🚪 [RESET] Left \(zoneIDs.count) shared zones", category: "share")
            }
        } catch {
            log("⚠️ [RESET] Failed to leave shared zones: \(error)", category: "share")
            throw error
        }
    }

    private func clearUserDefaults() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys
        for key in keys where key.hasPrefix("didSeedTutorial_") || key.hasPrefix("FaceTimeIDs") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "recentEmojis")
        defaults.removeObject(forKey: "autoDownloadImages")
        defaults.removeObject(forKey: "hasSeenWelcome")
        defaults.synchronize()
        log("🧹 [RESET] Cleared UserDefaults entries", category: "share")
    }

    private func clearLocalDatabase() async throws {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let context = try ModelContainer(for: Message.self, Anniversary.self, ChatRoom.self).mainContext
                    let descriptor = FetchDescriptor<Message>()
                    let messages = try context.fetch(descriptor)
                    for message in messages { context.delete(message) }
                    try context.save()
                    log("🧹 [RESET] Cleared \(messages.count) messages from SwiftData", category: "share")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func validateAndResetIfInconsistent() async {
        do {
            let issues = try await findInconsistencies()
            guard !issues.isEmpty else {
                log("✅ [HEALTH CHECK] Database configuration is consistent", category: "share")
                return
            }
            log("❗ [HEALTH CHECK] Inconsistencies detected — performing full reset", category: "share")
            for issue in issues { log("• \(issue)", category: "share") }
            do {
                try await performCompleteReset(bypassSafetyCheck: true)
                try await ensureSubscriptions()
                log("✅ [HEALTH CHECK] Full reset completed", category: "share")
            } catch {
                log("❌ [HEALTH CHECK] Full reset failed: \(error)", category: "share")
                lastError = error
            }
        } catch {
            log("⚠️ [HEALTH CHECK] Consistency check failed: \(error)", category: "share")
        }
    }

    private func findInconsistencies() async throws -> [String] {
        var issues: [String] = []
        do {
            let zones = try await privateDB.allRecordZones()
            if zones.contains(where: { $0.zoneID.zoneName == "SharedRooms" }) {
                issues.append("Legacy zone 'SharedRooms' exists")
            }
        } catch {
            issues.append("Failed to list private zones: \(error)")
        }
        do {
            let zones = try await sharedDB.allRecordZones()
            let orphaned = zones.filter { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            for zone in orphaned {
                let recordID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                if (try? await sharedDB.record(for: recordID)) == nil {
                    issues.append("Shared zone \(zone.zoneID.zoneName) missing Room record")
                }
            }
        } catch {
            // shared DB might be empty; ignore errors unless critical
        }
        return issues
    }

    // MARK: - Subscription Management


    private func ensureSubscriptions() async throws {
        try await ensureDatabaseSubscription(
            database: privateDB,
            scopeLabel: "private",
            subscriptionID: SubscriptionID.privateDatabase
        )
        try await ensureDatabaseSubscription(
            database: sharedDB,
            scopeLabel: "shared",
            subscriptionID: SubscriptionID.sharedDatabase
        )
    }

    private func ensureDatabaseSubscription(
        database: CKDatabase,
        scopeLabel: String,
        subscriptionID: String
    ) async throws {
        let desiredID = CKSubscription.ID(subscriptionID)
        let desiredSubscription = CKDatabaseSubscription(subscriptionID: desiredID)
        desiredSubscription.notificationInfo = buildNotificationInfo()

        // 冪等に作成/更新（既存確認は行わない）
        log("🛠️ [SUBS] Ensuring database subscription scope=\(scopeLabel)", category: "share")
        try await modifySubscriptions(
            database: database,
            toSave: [desiredSubscription],
            toDelete: []
        )
    }

    private func ensureZoneSubscription(zoneID: CKRecordZone.ID, database: CKDatabase) async throws {
        let identifier = "zone-\(zoneID.zoneName)-\(database.databaseScope.rawValue)"
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: CKSubscription.ID(identifier))
        subscription.notificationInfo = buildNotificationInfo()

        log("🛠️ [SUBS] Ensuring zone subscription id=\(identifier)", category: "share")
        try await modifySubscriptions(database: database, toSave: [subscription], toDelete: [])
    }

    private func ensureSignalQuerySubscriptions(roomID: String, zoneID: CKRecordZone.ID, database: CKDatabase) async throws {
        let scopeLabel = database.databaseScope == .private ? "owner" : "participant"
        let baseIdentifier = "signal-\(zoneID.zoneName)-\(database.databaseScope.rawValue)"

        func makeSubscription(recordType: String, suffix: String) -> CKQuerySubscription {
            let subscriptionID = CKSubscription.ID("\(baseIdentifier)-\(suffix)")
            let subscription = CKQuerySubscription(recordType: recordType,
                                                   predicate: NSPredicate(value: true),
                                                   subscriptionID: subscriptionID,
                                                   options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
            subscription.zoneID = zoneID
            subscription.notificationInfo = buildNotificationInfo()
            return subscription
        }

        let subscriptions = [
            makeSubscription(recordType: CKSchema.SharedType.signalEnvelope, suffix: "envelope"),
            makeSubscription(recordType: CKSchema.SharedType.signalIceChunk, suffix: "ice"),
            makeSubscription(recordType: CKSchema.SharedType.signalSession, suffix: "session")
        ]

        log("🛠️ [SUBS] Ensuring signal query subscriptions room=\(roomID) scope=\(scopeLabel)", category: "share")
        try await modifySubscriptions(database: database, toSave: subscriptions, toDelete: [])
    }


    private func subscriptionNeedsUpdate(_ existing: CKSubscription, comparedTo desired: CKSubscription) -> Bool {
        guard type(of: existing) == type(of: desired) else { return true }
        let existingInfo = existing.notificationInfo
        let desiredInfo = desired.notificationInfo

        return existingInfo?.shouldSendContentAvailable != desiredInfo?.shouldSendContentAvailable ||
               existingInfo?.shouldBadge != desiredInfo?.shouldBadge ||
               existingInfo?.soundName != desiredInfo?.soundName ||
               existingInfo?.desiredKeys != desiredInfo?.desiredKeys
    }

    private func modifySubscriptions(database: CKDatabase,
                                     toSave: [CKSubscription],
                                     toDelete: [CKSubscription.ID]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: toSave, subscriptionIDsToDelete: toDelete)
            operation.qualityOfService = .userInitiated
            operation.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    // fetchSubscriptions はSDK差分が大きいため使用しない（冪等作成方針）

    private func fetchRecordZones(in database: CKDatabase) async throws -> [CKRecordZone] {
        return try await database.allRecordZones()
    }

    private func buildNotificationInfo() -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        info.soundName = nil
        return info
    }

    // 全サブスクリプション取得（Result 版シグネチャ）
    // fetchSubscriptions は使用しない（固定IDの冪等削除/作成方針）

    // MARK: - SettingsView Compatibility APIs
    /// 本番環境かどうか（TestFlight/Debugを除外）
    func checkIsProductionEnvironment() -> Bool {
        #if DEBUG
        return false
        #else
        return !isTestFlightBuild
        #endif
    }

    /// 緊急リセット（強制）: すべてのCloudKit/ローカルを削除
    func performEmergencyReset() async throws {
        try await performCompleteReset(bypassSafetyCheck: true)
        if #available(iOS 17.0, *) {
            await CKSyncEngineManager.shared.resetEngines()
        }
    }

    /// ローカルのみのリセット（CloudKitデータは保持）
    func performLocalReset() async throws {
        try await clearLocalDatabase()
        clearUserDefaults()
        clearCache()
        if #available(iOS 17.0, *) {
            await CKSyncEngineManager.shared.resetEngines()
        }
    }

    /// クラウドのみ完全リセット（ローカルは呼び出し側で初期化）
    func performCompleteCloudReset() async throws {
        try await removeAllSubscriptions()
        try await clearPrivateDatabase()
        try await leaveAllSharedDatabases()
        clearCache()
    }

    // MARK: - FaceTime ID 保存（プライベートDBのプロフィールレコード）
    func saveFaceTimeID(_ value: String) async throws {
        // ローカル保存（UI既存仕様に合わせてAppStorageが先）
        UserDefaults.standard.set(value, forKey: "myFaceTimeID")

        let recordID = CKRecord.ID(recordName: "MyProfile", zoneID: CKRecordZone.default().zoneID)
        let record: CKRecord
        if let existing = try? await privateDB.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CKSchema.PrivateType.myProfile, recordID: recordID)
        }
        record[CKSchema.FieldKey.faceTimeID] = value as CKRecordValue

        do {
            _ = try await privateDB.save(record)
            log("✅ [PROFILE] Saved FaceTimeID to CloudKit private profile", category: "account")
        } catch {
            log("⚠️ [PROFILE] Failed to save FaceTimeID to CloudKit: \(error)", category: "account")
            throw error
        }
    }

    private func removeAllSubscriptions() async throws {
        let privateIDs = [CKSubscription.ID(SubscriptionID.privateDatabase)]
        let sharedIDs = [CKSubscription.ID(SubscriptionID.sharedDatabase)]
        do { try await modifySubscriptions(database: privateDB, toSave: [], toDelete: privateIDs) } catch { /* ignore unknown */ }
        do { try await modifySubscriptions(database: sharedDB, toSave: [], toDelete: sharedIDs) } catch { /* ignore unknown */ }
        log("[SUBSCRIPTION] Removed known subscriptions from both databases", category: "share")
    }

    // MARK: - Room / Zone Resolution

    private func adjustDatabaseIfNeeded(roomID: String,
                                        database: CKDatabase,
                                        zoneID: CKRecordZone.ID) -> (CKDatabase, CKRecordZone.ID) {
        if database.databaseScope == .shared {
            let ownerName = zoneID.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultOwners: Set<String> = [CKCurrentUserDefaultName, CKCurrentUserDefaultName, "__defaultOwner__"]
            if defaultOwners.contains(ownerName) || ownerName.isEmpty {
                log("[ZONE] resolveDatabaseAndZone override: shared scope points to owner=\(ownerName.isEmpty ? "nil" : ownerName) -> using private DB room=\(roomID) zone=\(zoneID.zoneName)", category: "share")
                sharedZoneCache.removeValue(forKey: roomID)
                cache(roomID: roomID, scope: .private, zoneID: zoneID)
                return (privateDB, zoneID)
            }
        }
        return (database, zoneID)
    }

    func resolveDatabaseAndZone(for roomID: String) async throws -> (CKDatabase, CKRecordZone.ID) {
        if let scopeString = roomScopeCache[roomID],
           let scope = RoomScope(rawValue: scopeString),
           let cachedZone = zoneFromCache(roomID: roomID, scope: scope) {
            let db = scope.databaseScope == .shared ? sharedDB : privateDB
            log("[ZONE] resolveDatabaseAndZone(cache) room=\(roomID) scope=\(scope) zone=\(cachedZone.zoneName)", category: "share")
            return adjustDatabaseIfNeeded(roomID: roomID, database: db, zoneID: cachedZone)
        }

        if let zoneID = privateZoneCache[roomID] {
            cache(roomID: roomID, scope: .private, zoneID: zoneID)
            log("[ZONE] resolveDatabaseAndZone(privateCache) room=\(roomID) zone=\(zoneID.zoneName)", category: "share")
            return (privateDB, zoneID)
        }

        if let zoneID = sharedZoneCache[roomID] {
            cache(roomID: roomID, scope: .shared, zoneID: zoneID)
            log("[ZONE] resolveDatabaseAndZone(sharedCache) room=\(roomID) zone=\(zoneID.zoneName)", category: "share")
            return adjustDatabaseIfNeeded(roomID: roomID, database: sharedDB, zoneID: zoneID)
        }

        if let zoneID = try await findZone(named: roomID, in: privateDB) {
            cache(roomID: roomID, scope: .private, zoneID: zoneID)
            log("[ZONE] resolveDatabaseAndZone(privateLookup) room=\(roomID) zone=\(zoneID.zoneName)", category: "share")
            return (privateDB, zoneID)
        }

        if let zoneID = try await findZone(named: roomID, in: sharedDB) {
            cache(roomID: roomID, scope: .shared, zoneID: zoneID)
            log("[ZONE] resolveDatabaseAndZone(sharedLookup) room=\(roomID) zone=\(zoneID.zoneName)", category: "share")
            return adjustDatabaseIfNeeded(roomID: roomID, database: sharedDB, zoneID: zoneID)
        }

        log("[ZONE] resolveDatabaseAndZone failed room=\(roomID) — zone not found", category: "share")
        throw CloudKitChatError.roomNotFound
    }

    private func resolveZoneContext(for roomID: String) async throws -> (database: CKDatabase, zoneID: CKRecordZone.ID, scope: RoomScope) {
        let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        guard let scope = RoomScope(databaseScope: database.databaseScope) else {
            log("❌ [ZONE] Unsupported database scope=\(database.databaseScope.rawValue) room=\(roomID)", category: "share")
            throw CloudKitChatError.roomNotFound
        }
        return (database, zoneID, scope)
    }

    private func ensureOwnerShareForSignal(roomID: String) async {
        do {
            if let descriptor = try? await fetchShare(for: roomID) {
                await ensureOwnerParticipant(for: descriptor)
                return
            }
            let descriptor = try await createSharedChatRoom(roomID: roomID)
            await ensureOwnerParticipant(for: descriptor)
        } catch {
            log("⚠️ [SIGNAL] Failed to ensure shared zone for room=\(roomID): \(error)", category: "share")
        }
    }

    func resolveZone(for roomID: String, purpose: ZonePurpose) async throws -> (CKDatabase, CKRecordZone.ID) {
        let context: (database: CKDatabase, zoneID: CKRecordZone.ID, scope: RoomScope)
        do {
            context = try await resolveZoneContext(for: roomID)
        } catch let error as CloudKitChatError where purpose == .signal && error == .roomNotFound {
            throw CloudKitChatError.signalingZoneUnavailable
        } catch {
            throw error
        }

        switch purpose {
        case .message:
            log("[ZONE] resolveZone(message) room=\(roomID) scope=\(context.scope.rawValue) zone=\(context.zoneID.zoneName)", category: "share")
            return (context.database, context.zoneID)
        case .signal:
            switch context.scope {
            case .private:
                await ensureOwnerShareForSignal(roomID: roomID)
                log("[ZONE] resolveZone(signal) owner scope=private zone=\(context.zoneID.zoneName)", category: "share")
                return (context.database, context.zoneID)
            case .shared:
                log("[ZONE] resolveZone(signal) participant scope=shared zone=\(context.zoneID.zoneName)", category: "share")
                return (context.database, context.zoneID)
            }
        }
    }

    private func ensureOwnerParticipant(for descriptor: ChatShareDescriptor) async {
        do {
            let current = try await currentUserRecordName()
            if descriptor.share.participants.contains(where: { $0.userIdentity.userRecordID?.recordName == current }) {
                return
            }
            let participant = try await fetchParticipant(recordName: current)
            participant.permission = .readWrite
            participant.role = .privateUser
            descriptor.share.addParticipant(participant)
            try await saveShare(descriptor.share)
            log("[SIGNAL] Added owner participant to share room=\(descriptor.zoneID.zoneName)", category: "share")
        } catch {
            log("⚠️ [SIGNAL] Failed to add owner participant: \(error)", category: "share")
        }
    }

    private func fetchParticipant(recordName: String) async throws -> CKShare.Participant {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare.Participant, Error>) in
            let lookupInfo = CKUserIdentity.LookupInfo(userRecordID: CKRecord.ID(recordName: recordName))
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [lookupInfo])
            operation.perShareParticipantResultBlock = { _, result in
                switch result {
                case .success(let participant):
                    continuation.resume(returning: participant)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            operation.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.container.add(operation)
        }
    }

    private func saveShare(_ share: CKShare) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [share], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.privateDB.add(op)
        }
    }

    private func zoneFromCache(roomID: String, scope: RoomScope) -> CKRecordZone.ID? {
        switch scope {
        case .private:
            return privateZoneCache[roomID]
        case .shared:
            return sharedZoneCache[roomID]
        }
    }

    private func findZone(named roomID: String, in database: CKDatabase) async throws -> CKRecordZone.ID? {
        let zones = try await fetchRecordZones(in: database)
        return zones.first(where: { $0.zoneID.zoneName == roomID })?.zoneID
    }

    func isOwnerCached(_ roomID: String) -> Bool? {
        guard let scopeString = roomScopeCache[roomID],
              let scope = RoomScope(rawValue: scopeString) else { return nil }
        return scope == .private
    }

    func isOwnerOfRoom(_ roomID: String) async -> Bool {
        if let cached = isOwnerCached(roomID) { return cached }
        do {
            let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
            if let scope = RoomScope(databaseScope: database.databaseScope) {
                cache(roomID: roomID, scope: scope, zoneID: zoneID)
                return scope == .private
            }
        } catch {
            log("⚠️ Failed to determine ownership for room=\(roomID): \(error)", category: "share")
        }
        return false
    }

    func getOwnedRooms() async -> [String] {
        guard let currentUserID else { return [] }
        var owned: [String] = []
        do {
            let zones = try await privateDB.allRecordZones()
            for zone in zones where zone.zoneID.zoneName != CKRecordZone.ID.defaultZoneName {
                let roomID = zone.zoneID.zoneName
                let recordID = CKRecord.ID(recordName: roomID, zoneID: zone.zoneID)
                if let record = try? await privateDB.record(for: recordID),
                   let creator = record["createdBy"] as? String, creator == currentUserID {
                    owned.append(roomID)
                }
            }
        } catch {
            log("⚠️ Failed to enumerate owned rooms: \(error)", category: "share")
        }
        return owned
    }

    func getParticipatingRooms() async -> [String] {
        var participating: [String] = []
        let query = CKQuery(recordType: CKSchema.SharedType.room, predicate: NSPredicate(value: true))
        do {
            let (results, _) = try await sharedDB.records(matching: query)
            for (_, result) in results {
                if let record = try? result.get(),
                   let roomID = record["roomID"] as? String {
                    participating.append(roomID)
                }
            }
        } catch {
            log("⚠️ Failed to enumerate participating rooms: \(error)", category: "share")
        }
        return participating
    }

    func resolvePrivateZoneIDIfExists(roomID: String) async throws -> CKRecordZone.ID? {
        do {
            let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
            return database.databaseScope == .private ? zoneID : nil
        } catch {
            throw error
        }
    }

    func resolveSharedZoneIDIfExists(roomID: String) async throws -> CKRecordZone.ID? {
        if let cached = sharedZoneCache[roomID] { return cached }
        let zones = try await sharedDB.allRecordZones()
        if let zone = zones.first(where: { $0.zoneID.zoneName == roomID }) {
            sharedZoneCache[roomID] = zone.zoneID
            return zone.zoneID
        }
        return nil
    }

    func setupRoomSubscription(for roomID: String) async throws {
        do {
            let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
            try await ensureSubscriptions()
            try await ensureZoneSubscription(zoneID: zoneID, database: database)
            try await ensureSignalQuerySubscriptions(roomID: roomID, zoneID: zoneID, database: database)
        } catch {
            log("⚠️ Failed to setup room subscription for room=\(roomID): \(error)", category: "share")
            throw error
        }
    }

    func isSignalZoneReady(roomID: String) async -> Bool {
        do {
            _ = try await resolveZone(for: roomID, purpose: .signal)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Signal Sessions (Offer / Answer / ICE)

    private func signalSessionKey(roomID: String, localUserID: String, remoteUserID: String) -> String {
        let trimmedRoom = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = localUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let (lo, hi) = a <= b ? (a, b) : (b, a)
        return "\(trimmedRoom)#\(lo)#\(hi)"
    }

    private func makeSignalSessionRecord(from snapshot: SignalSessionSnapshot, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: CKSchema.SharedType.signalSession, recordID: snapshot.recordID)
        record[CKSchema.FieldKey.sessionKey] = snapshot.sessionKey as CKRecordValue
        record[CKSchema.FieldKey.roomID] = snapshot.roomID as CKRecordValue
        record[CKSchema.FieldKey.userId] = snapshot.callerUserID as CKRecordValue
        record[CKSchema.FieldKey.otherUserId] = snapshot.calleeUserID as CKRecordValue
        record[CKSchema.FieldKey.callEpoch] = snapshot.activeCallEpoch as CKRecordValue
        record[CKSchema.FieldKey.updatedAt] = (snapshot.updatedAt ?? Date()) as CKRecordValue
        return record
    }

    private func signalSessionSnapshot(from record: CKRecord) -> SignalSessionSnapshot {
        let sessionKey = (record[CKSchema.FieldKey.sessionKey] as? String) ?? ""
        let roomID = (record[CKSchema.FieldKey.roomID] as? String) ?? record.recordID.zoneID.zoneName
        let caller = (record[CKSchema.FieldKey.userId] as? String) ?? ""
        let callee = (record[CKSchema.FieldKey.otherUserId] as? String) ?? ""
        let callEpoch = record[CKSchema.FieldKey.callEpoch] as? Int ?? 0
        let updatedAt = record[CKSchema.FieldKey.updatedAt] as? Date
        return SignalSessionSnapshot(recordID: record.recordID,
                                     sessionKey: sessionKey,
                                     roomID: roomID,
                                     callerUserID: caller,
                                     calleeUserID: callee,
                                     activeCallEpoch: callEpoch,
                                     updatedAt: updatedAt)
    }

    func ensureSignalSession(roomID: String, localUserID: String, remoteUserID: String) async throws -> SignalSessionSnapshot {
        let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
        let key = signalSessionKey(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID)
        let recordID = CKSchema.signalSessionRecordID(sessionKey: key, zoneID: zoneID)
        do {
            let record = try await database.record(for: recordID)
            return signalSessionSnapshot(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            let snapshot = SignalSessionSnapshot(recordID: recordID,
                                                 sessionKey: key,
                                                 roomID: roomID,
                                                 callerUserID: localUserID,
                                                 calleeUserID: remoteUserID,
                                                 activeCallEpoch: 0,
                                                 updatedAt: Date())
            let results = try await performModifyRecordsOperation(
                database: database,
                recordsToSave: [makeSignalSessionRecord(from: snapshot, existing: nil)],
                groupName: "signal.session.ensure.\(roomID)",
                isAtomic: false
            )
            let saved = try extractSavedRecord(from: results, recordID: recordID)
            return signalSessionSnapshot(from: saved)
        } catch {
            throw error
        }
    }

    func updateSignalSession(roomID: String, localUserID: String, remoteUserID: String, nextCallEpoch: Int) async throws -> SignalSessionSnapshot {
        let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
        let key = signalSessionKey(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID)
        let recordID = CKSchema.signalSessionRecordID(sessionKey: key, zoneID: zoneID)
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return try await ensureSignalSession(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID)
        }
        var snapshot = signalSessionSnapshot(from: existing)
        snapshot.activeCallEpoch = max(snapshot.activeCallEpoch, nextCallEpoch)
        snapshot.updatedAt = Date()
        let results = try await performModifyRecordsOperation(
            database: database,
            recordsToSave: [makeSignalSessionRecord(from: snapshot, existing: existing)],
            groupName: "signal.session.update.\(roomID)",
            isAtomic: false
        )
        let saved = try extractSavedRecord(from: results, recordID: recordID)
        return signalSessionSnapshot(from: saved)
    }

    private func makeSignalEnvelopeRecord(sessionKey: String,
                                          roomID: String,
                                          ownerUserID: String,
                                          callEpoch: Int,
                                          type: SignalEnvelopeType,
                                          sdp: String,
                                          existing: CKRecord? = nil,
                                          zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKSchema.signalEnvelopeRecordID(sessionKey: sessionKey, callEpoch: callEpoch, envelopeType: type.rawValue, zoneID: zoneID)
        let record = existing ?? CKRecord(recordType: CKSchema.SharedType.signalEnvelope, recordID: recordID)
        record[CKSchema.FieldKey.sessionKey] = sessionKey as CKRecordValue
        record[CKSchema.FieldKey.roomID] = roomID as CKRecordValue
        record[CKSchema.FieldKey.callEpoch] = callEpoch as CKRecordValue
        record[CKSchema.FieldKey.ownerUserId] = ownerUserID as CKRecordValue
        record[CKSchema.FieldKey.envelopeType] = type.rawValue as CKRecordValue
        record[CKSchema.FieldKey.payload] = sdp as CKRecordValue
        record[CKSchema.FieldKey.updatedAt] = Date() as CKRecordValue
        return record
    }

    private func decodeSignalEnvelope(_ record: CKRecord) -> SignalEnvelopeSnapshot? {
        guard let sessionKey = record[CKSchema.FieldKey.sessionKey] as? String else { return nil }
        let roomID = (record[CKSchema.FieldKey.roomID] as? String) ?? record.recordID.zoneID.zoneName
        let callEpoch = record[CKSchema.FieldKey.callEpoch] as? Int ?? 0
        guard let owner = record[CKSchema.FieldKey.ownerUserId] as? String else { return nil }
        guard let rawType = record[CKSchema.FieldKey.envelopeType] as? String,
              let type = SignalEnvelopeType(rawValue: rawType) else { return nil }
        guard let sdp = record[CKSchema.FieldKey.payload] as? String, !sdp.isEmpty else { return nil }
        let createdAt = record[CKSchema.FieldKey.updatedAt] as? Date ?? record.creationDate
        return SignalEnvelopeSnapshot(recordID: record.recordID,
                                      sessionKey: sessionKey,
                                      roomID: roomID,
                                      callEpoch: callEpoch,
                                      ownerUserID: owner,
                                      type: type,
                                      sdp: sdp,
                                      createdAt: createdAt)
    }

    private func decodeSignalIceChunk(_ record: CKRecord) -> SignalIceChunkSnapshot? {
        guard let sessionKey = record[CKSchema.FieldKey.sessionKey] as? String else { return nil }
        let roomID = (record[CKSchema.FieldKey.roomID] as? String) ?? record.recordID.zoneID.zoneName
        let callEpoch = record[CKSchema.FieldKey.callEpoch] as? Int ?? 0
        guard let owner = record[CKSchema.FieldKey.ownerUserId] as? String else { return nil }
        guard let candidate = record[CKSchema.FieldKey.candidate] as? String else { return nil }
        let candidateType = record[CKSchema.FieldKey.candidateType] as? String
        let createdAt = record[CKSchema.FieldKey.chunkCreatedAt] as? Date ?? record.creationDate
        return SignalIceChunkSnapshot(recordID: record.recordID,
                                      sessionKey: sessionKey,
                                      roomID: roomID,
                                      callEpoch: callEpoch,
                                      ownerUserID: owner,
                                      candidate: candidate,
                                      candidateType: candidateType,
                                      createdAt: createdAt)
    }

    func publishOffer(roomID: String, localUserID: String, remoteUserID: String, callEpoch: Int, sdp: String) async throws -> SignalEnvelopeSnapshot {
        let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
        let session = try await updateSignalSession(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID, nextCallEpoch: callEpoch)
        let record = makeSignalEnvelopeRecord(sessionKey: session.sessionKey,
                                              roomID: roomID,
                                              ownerUserID: localUserID,
                                              callEpoch: callEpoch,
                                              type: .offer,
                                              sdp: sdp,
                                              zoneID: zoneID)
        let results = try await performModifyRecordsOperation(
            database: database,
            recordsToSave: [record],
            groupName: "signal.offer.\(roomID)",
            isAtomic: false
        )
        let saved = try extractSavedRecord(from: results, recordID: record.recordID)
        return decodeSignalEnvelope(saved)!
    }

    func publishAnswer(roomID: String, localUserID: String, remoteUserID: String, callEpoch: Int, sdp: String) async throws -> SignalEnvelopeSnapshot {
        let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
        _ = try await updateSignalSession(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID, nextCallEpoch: callEpoch)
        let record = makeSignalEnvelopeRecord(sessionKey: signalSessionKey(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID),
                                              roomID: roomID,
                                              ownerUserID: localUserID,
                                              callEpoch: callEpoch,
                                              type: .answer,
                                              sdp: sdp,
                                              zoneID: zoneID)
        let results = try await performModifyRecordsOperation(
            database: database,
            recordsToSave: [record],
            groupName: "signal.answer.\(roomID)",
            isAtomic: false
        )
        let saved = try extractSavedRecord(from: results, recordID: record.recordID)
        return decodeSignalEnvelope(saved)!
    }

    func publishIceCandidate(roomID: String, localUserID: String, remoteUserID: String, callEpoch: Int, encodedCandidate: String, candidateType: String?) async throws -> SignalIceChunkSnapshot {
        let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
        _ = try await updateSignalSession(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID, nextCallEpoch: callEpoch)
        let sessionKey = signalSessionKey(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID)
        let recordID = CKSchema.signalIceChunkRecordID(sessionKey: sessionKey, callEpoch: callEpoch, ownerUserID: localUserID, zoneID: zoneID)
        let record = CKRecord(recordType: CKSchema.SharedType.signalIceChunk, recordID: recordID)
        record[CKSchema.FieldKey.sessionKey] = sessionKey as CKRecordValue
        record[CKSchema.FieldKey.roomID] = roomID as CKRecordValue
        record[CKSchema.FieldKey.callEpoch] = callEpoch as CKRecordValue
        record[CKSchema.FieldKey.ownerUserId] = localUserID as CKRecordValue
        record[CKSchema.FieldKey.candidate] = encodedCandidate as CKRecordValue
        if let candidateType {
            record[CKSchema.FieldKey.candidateType] = candidateType as CKRecordValue
        }
        record[CKSchema.FieldKey.chunkCreatedAt] = Date() as CKRecordValue
        let results = try await performModifyRecordsOperation(
            database: database,
            recordsToSave: [record],
            groupName: "signal.ice.\(roomID)",
            isAtomic: false
        )
        let saved = try extractSavedRecord(from: results, recordID: recordID)
        return decodeSignalIceChunk(saved)!
    }

    func decodeSignalRecord(_ record: CKRecord) -> SignalEnvelopeSnapshot? {
        guard record.recordType == CKSchema.SharedType.signalEnvelope else { return nil }
        return decodeSignalEnvelope(record)
    }

    func decodeSignalIceRecord(_ record: CKRecord) -> SignalIceChunkSnapshot? {
        guard record.recordType == CKSchema.SharedType.signalIceChunk else { return nil }
        return decodeSignalIceChunk(record)
    }

    func primaryCounterpartUserID(roomID: String) -> String? {
        let participants = ModelContainerBroker.shared.participantsSnapshot(roomID: roomID)
        let remoteParticipant = participants.first(where: { !$0.isLocal })
        
        if let remote = remoteParticipant {
            log("[P2P] primaryCounterpartUserID found remote participant: \(String(remote.userID.prefix(8))) for room=\(roomID)", category: "share")
            return remote.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            log("[P2P] primaryCounterpartUserID no remote participant found for room=\(roomID). Total participants=\(participants.count)", category: "share")
            return nil
        }
    }

    // MARK: - Participant Profiles

    @MainActor
    func inferRemoteParticipantAndUpdateRoom(roomID: String, modelContext: ModelContext) async {
        do {
            var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID },
                                                      sortBy: [SortDescriptor(\.createdAt)])
            descriptor.fetchLimit = 1
            guard let room = try modelContext.fetch(descriptor).first else {
                log("⚠️ ChatRoom not found for roomID=\(roomID)", category: "share")
                return
            }

            if let counterpart = room.primaryCounterpart,
               !counterpart.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }

            if let localProfile = try localParticipantInfo(roomID: roomID, modelContext: modelContext) {
                apply(profile: localProfile, to: room)
                return
            }

            if let remoteProfile = try await fetchRemoteParticipantFromRoomMember(roomID: roomID) {
                apply(profile: remoteProfile, to: room)
            } else {
                log("⚠️ Could not infer remote participant for roomID=\(roomID)", category: "share")
            }
        } catch {
            log("❌ Failed to infer remote participant for roomID=\(roomID): \(error)", category: "share")
        }
    }

    func saveMasterProfile(name: String?, avatarData: Data?) async throws {
        let userID = try await ensureCurrentUserID()
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedName, !normalizedName.isEmpty {
            UserDefaults.standard.set(normalizedName, forKey: "myDisplayName")
        } else {
            UserDefaults.standard.removeObject(forKey: "myDisplayName")
        }

        if let avatarData, !avatarData.isEmpty {
            UserDefaults.standard.set(avatarData, forKey: "myAvatarData")
        } else {
            UserDefaults.standard.removeObject(forKey: "myAvatarData")
        }

        profileCache[userID] = ProfileCacheEntry(name: normalizedName, avatarData: avatarData, shapeIndex: nil)

        let recordID = CKRecord.ID(recordName: "PROFILE_\(userID)")
        let record: CKRecord
        if let existing = try? await privateDB.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CKSchema.PrivateType.myProfile, recordID: recordID)
            record[CKSchema.FieldKey.userId] = userID as CKRecordValue
        }

        if let normalizedName, !normalizedName.isEmpty {
            record[CKSchema.FieldKey.displayName] = normalizedName as CKRecordValue
        } else {
            record[CKSchema.FieldKey.displayName] = nil
        }

        var tempFile: URL?
        if let avatarData, !avatarData.isEmpty {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("avatar_master_\(UUID().uuidString).dat")
            try avatarData.write(to: fileURL, options: .atomic)
            tempFile = fileURL
            record[CKSchema.FieldKey.avatarAsset] = CKAsset(fileURL: fileURL)
        } else {
            record[CKSchema.FieldKey.avatarAsset] = nil
        }

        defer {
            if let tempFile {
                try? FileManager.default.removeItem(at: tempFile)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    log("✅ Saved master profile for userID=\(userID)", category: "share")
                    continuation.resume()
                case .failure(let error):
                    log("❌ Failed to save master profile: \(error)", category: "share")
                    continuation.resume(throwing: error)
                }
            }
            self.privateDB.add(operation)
        }
    }

    func upsertParticipantProfile(in roomID: String, name: String?, avatarData: Data?) async throws {
        let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let userID = try await currentUserRecordName()
        let recordID = CKSchema.roomMemberRecordID(userId: userID, zoneID: zoneID)

        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CKSchema.SharedType.roomMember, recordID: recordID)
            record[CKSchema.FieldKey.userId] = userID as CKRecordValue
        }

        if let name {
            record[CKSchema.FieldKey.displayName] = name as CKRecordValue
        } else {
            record[CKSchema.FieldKey.displayName] = nil
        }

        var tempFile: URL?
        if let avatarData, !avatarData.isEmpty {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("avatar_\(UUID().uuidString).dat")
            try avatarData.write(to: fileURL, options: .atomic)
            tempFile = fileURL
            record[CKSchema.FieldKey.avatarAsset] = CKAsset(fileURL: fileURL)
        } else {
            record[CKSchema.FieldKey.avatarAsset] = nil
        }

        defer {
            if let tempFile {
                try? FileManager.default.removeItem(at: tempFile)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    log("✅ Upserted participant profile record=\(record.recordID.recordName)", category: "share")
                    continuation.resume(returning: ())
                case .failure(let error):
                    log("❌ Failed to upsert participant profile: \(error)", category: "share")
                    continuation.resume(throwing: error)
                }
            }
            database.add(op)
        }
    }

    func updateParticipantProfileInAllZones(name: String?, avatarData: Data?) async {
        let uniqueRooms = Set(roomScopeCache.keys)
        for roomID in uniqueRooms {
            do {
                try await upsertParticipantProfile(in: roomID, name: name, avatarData: avatarData)
            } catch {
                log("⚠️ Failed to update participant profile in room=\(roomID): \(error)", category: "share")
            }
        }
    }

    func fetchParticipantProfile(userID: String, roomID: String) async throws -> ParticipantProfileSnapshot {
        let (database, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let recordID = CKSchema.roomMemberRecordID(userId: userID, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        return snapshot(from: record)
    }

    func fetchProfile(userID: String) async -> ParticipantProfileSnapshot? {
        if let current = currentUserID, current == userID {
            // CloudKit のプライベートプロフィールを優先
            if let cloud = await fetchMyDisplayNameFromCloudInternal() {
                let name = cloud.name
                let avatar = cloud.avatar
                return ParticipantProfileSnapshot(userID: userID, name: name, avatarData: avatar)
            }
            // フォールバック: ローカルキャッシュ
            let name = UserDefaults.standard.string(forKey: "myDisplayName")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatar = UserDefaults.standard.data(forKey: "myAvatarData")
            return ParticipantProfileSnapshot(userID: userID, name: name, avatarData: avatar)
        }
        return nil
    }

    // MARK: - Cloud display name fetch (current user)
    func fetchMyDisplayNameFromCloud() async -> String? {
        return await fetchMyDisplayNameFromCloudInternal()?.name
    }

    private func fetchMyDisplayNameFromCloudInternal() async -> (name: String?, avatar: Data?)? {
        do {
            let userID = try await ensureCurrentUserID()
            let recordID = CKRecord.ID(recordName: "PROFILE_\(userID)")
            let record = try await privateDB.record(for: recordID)
            let name = (record[CKSchema.FieldKey.displayName] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var avatarData: Data? = nil
            if let asset = record[CKSchema.FieldKey.avatarAsset] as? CKAsset, let url = asset.fileURL {
                avatarData = try? Data(contentsOf: url)
            }
            return (name: (name?.isEmpty == true ? nil : name), avatar: avatarData)
        } catch {
            return nil
        }
    }

    private func localParticipantInfo(roomID: String, modelContext: ModelContext) throws -> ParticipantProfileSnapshot? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.roomID == roomID },
                                                 sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 50
        let messages = try modelContext.fetch(descriptor)
        for message in messages {
            if let info = Message.extractParticipantJoinedInfo(from: message.body),
               let userID = info.userID {
                return ParticipantProfileSnapshot(userID: userID, name: info.name, avatarData: nil)
            }
        }
        return nil
    }

    private func fetchRemoteParticipantFromRoomMember(roomID: String) async throws -> ParticipantProfileSnapshot? {
        guard let context = try? ModelContainerBroker.shared.mainContext() else { return nil }
        var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
        descriptor.fetchLimit = 1
        guard let room = (try? context.fetch(descriptor))?.first else { return nil }
        guard let participant = room.participants.first(where: { !$0.isLocal }) else { return nil }
        return ParticipantProfileSnapshot(userID: participant.userID,
                                          name: participant.displayName,
                                          avatarData: participant.avatarData)
    }

    private func snapshot(from record: CKRecord) -> ParticipantProfileSnapshot {
        // より柔軟な型変換を試みる
        var userID = ""
        
        if let stringValue = record[CKSchema.FieldKey.userId] as? String {
            userID = stringValue
        } else if let nsStringValue = record[CKSchema.FieldKey.userId] as? NSString {
            userID = nsStringValue as String
        } else if let ckRecordValue = record[CKSchema.FieldKey.userId] {
            // CKRecordValueの場合の処理
            userID = String(describing: ckRecordValue)
        }
        
        // フォールバック: recordNameからuserIDを抽出
        // RoomMemberのrecordNameは "RM_{userId}" の形式
        if userID.isEmpty {
            let recordName = record.recordID.recordName
            if recordName.hasPrefix("RM_") {
                userID = String(recordName.dropFirst(3))
                log("🔧 [FALLBACK] Extracted userID from recordName: \(recordName) -> \(userID)", category: "share")
            } else {
                log("⚠️ [DEBUG] RoomMember record=\(recordName) has empty userId field and unexpected recordName format", category: "share")
                log("⚠️ [DEBUG] Record fields: \(record.allKeys())", category: "share") 
                if let rawValue = record[CKSchema.FieldKey.userId] {
                    log("⚠️ [DEBUG] userId raw value type=\(type(of: rawValue)) value=\(rawValue)", category: "share")
                } else {
                    log("⚠️ [DEBUG] userId field is nil in record", category: "share")
                }
            }
        }
        
        var avatarData: Data?
        if let asset = record[CKSchema.FieldKey.avatarAsset] as? CKAsset,
           let url = asset.fileURL {
            avatarData = try? Data(contentsOf: url)
        }
        let name = record[CKSchema.FieldKey.displayName] as? String
        return ParticipantProfileSnapshot(userID: userID, name: name, avatarData: avatarData)
    }

    @MainActor
    func ingestRoomMemberRecord(_ record: CKRecord) async {
        log("[DEBUG] [SIGNAL] ingestRoomMemberRecord called record=\(record.recordID.recordName) recordType=\(record.recordType)", category: "share")
        
        let zoneID = record.recordID.zoneID
        let roomID = zoneID.zoneName
        guard !roomID.isEmpty else {
            log("⚠️ [SIGNAL] Empty roomID in RoomMember record=\(record.recordID.recordName)", category: "share")
            return
        }

        let scope: RoomScope = zoneID.ownerName.isEmpty ? .private : .shared
        cache(roomID: roomID, scope: scope, zoneID: zoneID)
        
        log("[DEBUG] [SIGNAL] Zone info roomID=\(roomID) scope=\(scope) ownerName=\(zoneID.ownerName)", category: "share")

        guard let context = try? ModelContainerBroker.shared.mainContext() else {
            log("⚠️ [SIGNAL] Unable to ingest RoomMember (no model context) room=\(roomID)", category: "share")
            return
        }

        var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
        descriptor.fetchLimit = 1

        let room: ChatRoom
        if let existing = (try? context.fetch(descriptor))?.first {
            room = existing
            log("[DEBUG] [SIGNAL] Found existing room for RoomMember room=\(roomID)", category: "share")
        } else {
            room = ChatRoom(roomID: roomID)
            context.insert(room)
            ensureLocalParticipant(for: room, scope: scope)
            log("[DEBUG] [SIGNAL] Created new room for RoomMember room=\(roomID)", category: "share")
        }

        let profile = snapshot(from: record)
        let normalizedID = profile.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            log("⚠️ [SIGNAL] Empty userID in RoomMember record=\(record.recordID.recordName) room=\(roomID)", category: "share")
            return
        }

        let current = (currentUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = normalizedID == current
        
        log("[DEBUG] [SIGNAL] Processing RoomMember record=\(record.recordID.recordName) room=\(roomID) userID=\(String(normalizedID.prefix(8))) isLocal=\(isLocal) current=\(String(current.prefix(8)))", category: "share")
        
        let participant = ChatRoom.Participant(userID: normalizedID,
                                               isLocal: isLocal,
                                               role: isLocal ? .owner : .participant,
                                               displayName: profile.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                                               avatarData: profile.avatarData,
                                               lastUpdatedAt: Date())

        room.upsertParticipant(participant)
        
        let participantsBefore = room.participants.count
        log("[DEBUG] [SIGNAL] After upsertParticipant room=\(roomID) participants count=\(participantsBefore)", category: "share")

        if !isLocal,
           let name = participant.displayName,
           !name.isEmpty,
           (room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            room.displayName = name
        }

        do {
            try context.save()
            let participantsAfter = room.participants.count
            log("[SIGNAL] Ingested RoomMember record=\(record.recordID.recordName) room=\(roomID) userID=\(String(normalizedID.prefix(8))) isLocal=\(isLocal) participants=\(participantsAfter)", category: "share")
            
            // P2P再起動: リモート参加者が設定された場合、P2Pを再起動
            if !isLocal && P2PController.shared.currentRoomID == roomID {
                let myID = (currentUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                log("[P2P] Remote participant resolved via RoomMember, triggering P2P restart for room=\(roomID) remote=\(String(normalizedID.prefix(8)))", category: "share")
                
                // 少し遅延を入れてからP2Pを再起動
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒待機
                    if P2PController.shared.currentRoomID == roomID {
                        P2PController.shared.closeIfCurrent(roomID: roomID, reason: "remote-participant-resolved")
                        P2PController.shared.startIfNeeded(roomID: roomID, myID: myID, remoteID: normalizedID)
                    }
                }
            }
        } catch {
            log("⚠️ [SIGNAL] Failed to persist RoomMember room=\(roomID): \(error)", category: "share")
            if let nsError = error as NSError? {
                log("⚠️ [SIGNAL] NSError domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)", category: "share")
            }
        }
    }

    private func apply(profile: ParticipantProfileSnapshot, to room: ChatRoom) {
        let trimmedID = profile.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }

        let normalizedName = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = trimmedID == (currentUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let participant = ChatRoom.Participant(userID: trimmedID,
                                               isLocal: isLocal,
                                               role: isLocal ? .owner : .participant,
                                               displayName: normalizedName,
                                               avatarData: profile.avatarData,
                                               lastUpdatedAt: Date())
        room.upsertParticipant(participant)

        if !isLocal,
           let name = normalizedName,
           !name.isEmpty,
           (room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            room.displayName = name
        }
        log("✅ Updated participants for room=\(room.roomID) userID=\(trimmedID)", category: "share")
    }

    private func currentUserRecordName() async throws -> String {
        if let id = currentUserID, !id.isEmpty { return id }
        let recordName = try await container.userRecordID().recordName
        currentUserID = recordName
        return recordName
    }

// MARK: - Error Types

enum CloudKitChatError: LocalizedError {
        case userNotAuthenticated
        case recordSaveFailed
        case roomNotFound
        case shareNotFound  // 🌟 [IDEAL SHARING UI] CKShare検索エラー用
        case invalidMessage
        case networkUnavailable
        case invalidUserID
        case userNotFound
        case discoverabilityDenied
        case shareURLUnavailable
        case requiresFullReset
        case schemaCreationInProgress
        case productionResetBlocked
        case resetFailed
        case signalingZoneUnavailable
        
        var errorDescription: String? {
            switch self {
            case .userNotAuthenticated:
                return "CloudKitユーザー認証が必要です"
            case .recordSaveFailed:
                return "レコードの保存に失敗しました"
            case .roomNotFound:
                return "チャットルームが見つかりません"
            case .shareNotFound:
                return "共有情報が見つかりません"
            case .invalidMessage:
                return "無効なメッセージです"
            case .networkUnavailable:
                return "ネットワークに接続できません"
            case .invalidUserID:
                return "自分自身のIDは指定できません"
            case .userNotFound:
                return "指定されたユーザーが見つかりません"
            case .discoverabilityDenied:
                return "連絡先の公開が許可されていません"
            case .shareURLUnavailable:
                return "共有URLを生成できませんでした"
            case .requiresFullReset:
                return "差分トークンが失効しました。完全リセットを実行してください"
            case .schemaCreationInProgress:
                return "データベース初期化中です。しばらくお待ちください"
            case .productionResetBlocked:
                return "本番環境でのリセットは安全のためブロックされています。force=trueを使用してください"
            case .resetFailed:
                return "データリセットに失敗しました"
            case .signalingZoneUnavailable:
                return "共有チャットのシグナリングゾーンを解決できませんでした"
            }
        }
    }

}

extension CloudKitChatManager.ChatShareDescriptor: Identifiable {
    var id: CKRecord.ID { share.recordID }
}

// MARK: - Notifications

extension Notification.Name {
    static let cloudKitSchemaReady = Notification.Name("CloudKitSchemaReady")
    static let cloudKitResetPerformed = Notification.Name("CloudKitResetPerformed")
    static let cloudKitShareAccepted = Notification.Name("CloudKitShareAccepted")  // 🌟 [IDEAL SHARING] 招待受信通知
}
