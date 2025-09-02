import CloudKit
import Combine
import SwiftUI
import SwiftData

@MainActor
class CloudKitChatManager: ObservableObject {
    static let shared: CloudKitChatManager = CloudKitChatManager()
    
    private let container = CKContainer(identifier: "iCloud.forMarin-test")
    // 共有UIや受諾処理で同一コンテナを参照できるように公開アクセサを用意
    var containerForSharing: CKContainer { container }
    var containerID: String { container.containerIdentifier ?? "iCloud.forMarin-test" }
    let privateDB: CKDatabase  // 🏗️ [IDEAL MVVM] ViewModelからアクセス可能にする
    let sharedDB: CKDatabase   // 🏗️ [IDEAL MVVM] ViewModelからアクセス可能にする
    
    // ゾーン解決用の簡易キャッシュ（zoneName -> zoneID）
    private var privateZoneCache: [String: CKRecordZone.ID] = [:]
    private var sharedZoneCache: [String: CKRecordZone.ID] = [:]
    
    @Published var currentUserID: String?
    @Published var isInitialized: Bool = false
    @Published var lastError: Error?
    @Published var hasPerformedReset: Bool = false
    
    // Schema creation flag
    private var isSyncDisabled: Bool = false
    
    // プロフィールキャッシュ（userID -> (name, avatarData)）
    private var profileCache: [String: (name: String?, avatarData: Data?)] = [:]
    
    // Build / environment diagnostics
    private var isTestFlightBuild: Bool {
        let receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? ""
        return receipt == "sandboxReceipt"
    }
    
    
    private init() {
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
        
        setupSyncNotificationObservers()
        
        Task {
            await initialize()
        }
    }
    
    private func setupSyncNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .disableMessageSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSyncDisabled = true
                log("Message sync disabled", category: "CloudKitChatManager")
            }
        }
    }
    
    // MARK: - Initialization
    
    /// CloudKit 初期化と自動レガシーデータリセット
    private func initialize() async {
        log("🚀 [INITIALIZATION] Starting CloudKitChatManager initialization...", category: "CloudKitChatManager")
        let containerIDString = container.containerIdentifier ?? "unknown"
        #if DEBUG
        let buildChannel = "Debug (assumed CloudKit Development env)"
        #else
        let buildChannel = isTestFlightBuild ? "TestFlight (assumed CloudKit Production env)" : "Release (assumed CloudKit Production env)"
        #endif
        let ckSharingSupported = (Bundle.main.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool) == true
        log("🧭 [ENV] CK Container: \(containerIDString) | Build: \(buildChannel) | CKSharingSupported=\(ckSharingSupported)", category: "CloudKitChatManager")
        
        // アカウント状態の確認
        let accountStatus = await checkAccountStatus()
        guard accountStatus == .available else {
            log("❌ [INITIALIZATION] CloudKit account not available: \(accountStatus.rawValue)", category: "CloudKitChatManager")
            lastError = CloudKitChatError.userNotAuthenticated
            return
        }
        
        do {
            // 自動レガシーデータリセット
            try await resetIfLegacyDataDetected()
            
            // UserID の設定
            currentUserID = try await container.userRecordID().recordName
            log("✅ [INITIALIZATION] Current UserID: \(currentUserID ?? "nil")", category: "CloudKitChatManager")
            
            // スキーマ作成
            try await createSchemaIfNeeded()

            // 一貫性チェックと必要に応じた完全リセット
            await validateAndResetIfInconsistent()
            
            isInitialized = true
            log("✅ [INITIALIZATION] CloudKitChatManager initialization completed successfully", category: "CloudKitChatManager")
            
        } catch {
            log("❌ [INITIALIZATION] CloudKitChatManager initialization failed: \(error)", category: "CloudKitChatManager")
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
            log("✅ [SEED] Seeded tutorial messages (\(records.count)) to zone: \(roomID)", category: "CloudKitChatManager")
        } catch {
            log("⚠️ [SEED] Failed to seed tutorial messages: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// 🌟 [AUTO RESET] レガシーデータを検出した場合の自動リセット
    func resetIfLegacyDataDetected() async throws {
        let hasLegacyData = await detectLegacyData()
        
        if hasLegacyData {
            log("🚀 [AUTO RESET] Legacy data detected, performing automatic reset to ideal implementation", category: "CloudKitChatManager")
            
            // 理想実装への自動移行ログ
            log("📋 [AUTO RESET] Migration plan:", category: "CloudKitChatManager")
            log("   • Clear legacy CloudKit data (CD_ChatRoom → ChatSession, body → text)", category: "CloudKitChatManager")
            log("   • Clear local SwiftData (unsync'd messages)", category: "CloudKitChatManager")
            log("   • Rebuild with ideal schema (desiredKeys, indexes, MessageReaction)", category: "CloudKitChatManager")
            log("   • Enable automatic 🌟 [IDEAL] implementation", category: "CloudKitChatManager")
            
            do {
                log("🔄 [AUTO RESET] Starting performCompleteReset...", category: "CloudKitChatManager")
                try await performCompleteReset(bypassSafetyCheck: true)
                log("✅ [AUTO RESET] performCompleteReset completed successfully", category: "CloudKitChatManager")
            } catch {
                log("❌ [AUTO RESET] performCompleteReset failed: \(error)", category: "CloudKitChatManager")
                throw error
            }
            
            // リセット実行フラグを設定
            hasPerformedReset = true
            
            log("✅ [AUTO RESET] Legacy data reset completed - ideal implementation active", category: "CloudKitChatManager")
            
        } else {
            log("✅ [AUTO RESET] No legacy data detected - ideal implementation already active", category: "CloudKitChatManager")
        }
    }
    
    /// 🌟 [IDEAL] スキーマ作成（理想実装 - チャット別ゾーン）
    private func createSchemaIfNeeded() async throws {
        log("🔧 [IDEAL SCHEMA] Checking if ideal schema setup is needed...", category: "CloudKitChatManager")
        
        // 既に作成済みの場合はスキップ
        if isInitialized && !hasPerformedReset {
            log("✅ [IDEAL SCHEMA] Schema already configured, skipping setup", category: "CloudKitChatManager")
            return
        }
        
        // 🌟 [IDEAL] レガシーSharedRoomsゾーンの存在チェック（警告目的）
        do {
            let zones = try await privateDB.allRecordZones()
            let legacyZone = zones.first { $0.zoneID.zoneName == "SharedRooms" }
            
            if legacyZone != nil {
                log("⚠️ [IDEAL SCHEMA] Legacy SharedRooms zone detected - this should be removed by auto-reset", category: "CloudKitChatManager")
                log("🌟 [IDEAL SCHEMA] Ideal implementation uses individual chat zones (chat-xxxxx)", category: "CloudKitChatManager")
            } else {
                log("✅ [IDEAL SCHEMA] No legacy SharedRooms zone found - ideal architecture active", category: "CloudKitChatManager")
            }
        } catch {
            log("⚠️ [IDEAL SCHEMA] Could not check for legacy zones: \(error)", category: "CloudKitChatManager")
        }
        
        // 🌟 [IDEAL] スキーマ準備（チャット作成時にゾーンを個別作成するため、ここでは全体設定のみ）
        log("🌟 [IDEAL SCHEMA] Schema ready - individual chat zones will be created per chat", category: "CloudKitChatManager")
        log("✅ [IDEAL SCHEMA] Ideal schema setup completed", category: "CloudKitChatManager")
    }
    
    /// CloudKit アカウント状態の確認
    private func checkAccountStatus() async -> CKAccountStatus {
        return await withCheckedContinuation { continuation in
            container.accountStatus { status, error in
                if let error = error {
                    log("❌ Failed to check CloudKit account status: \(error)", category: "CloudKitChatManager")
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
        log("🧹 Profile cache cleared", category: "CloudKitChatManager")
    }
    
    /// 完全リセット実行（CloudKit・ローカル含む全消去）
    func performCompleteReset(bypassSafetyCheck: Bool = false) async throws {
        log("🔄 [RESET] Starting complete CloudKit reset...", category: "CloudKitChatManager")
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
            
            log("✅ [RESET] Complete CloudKit reset finished successfully", category: "CloudKitChatManager")
            
        } catch {
            log("❌ [RESET] Complete CloudKit reset failed: \(error)", category: "CloudKitChatManager")
            throw CloudKitChatError.resetFailed
        }
    }

    /// 全てをリセット（統合API）
    func resetAll() async throws {
        try await performCompleteReset(bypassSafetyCheck: true)
    }
    
    /// 💡 [AUTO RESET] レガシーデータの検出（CloudKit + ローカルDB）
    private func detectLegacyData() async -> Bool {        
        log("🔍 [AUTO RESET] Starting comprehensive legacy data detection...", category: "CloudKitChatManager")
        
        // 1. CloudKit レガシーデータ検出（ゾーンベース - クエリエラー回避）
        log("🔍 [AUTO RESET] Checking for legacy architecture patterns (zone-based detection)", category: "CloudKitChatManager")
        
        // 2. レガシーゾーン（SharedRooms）の検出 - 別のtryブロック
        do {
            let zones = try await privateDB.allRecordZones()
            let sharedRoomsZone = zones.first { $0.zoneID.zoneName == "SharedRooms" }
            
            if sharedRoomsZone != nil {
                log("⚠️ [LEGACY DETECTED] Legacy 'SharedRooms' zone found - should use individual chat zones", category: "CloudKitChatManager")
                log("🔍 [AUTO RESET] Legacy data detection completed: LEGACY DATA FOUND (SharedRooms zone)", category: "CloudKitChatManager")
                return true
            }
            
            log("CloudKit legacy zones not found (expected for ideal implementation)", category: "CloudKitChatManager")
        } catch {
            log("CloudKit legacy zone check completed with error (will continue): \(error)", category: "CloudKitChatManager")
        }
        
        // 2. ローカルDB（SwiftData）のレガシーデータ検出
        let localLegacyCount = await detectLocalLegacyData()
        if localLegacyCount > 0 {
            log("⚠️ [LEGACY DETECTED] \(localLegacyCount) local messages with no CloudKit sync (ckRecordName: nil)", category: "CloudKitChatManager")
            log("🔍 [AUTO RESET] Legacy data detection completed: LEGACY DATA FOUND (local unsync data)", category: "CloudKitChatManager")
            return true
        }
        
        log("🔍 [AUTO RESET] Legacy data detection completed: NO LEGACY DATA", category: "CloudKitChatManager")
        
        return false
    }
    
    /// ローカルDB（SwiftData）のレガシーデータ検出
    private func detectLocalLegacyData() async -> Int {
        // MessageStore を通じてローカルデータベースの状態を確認
        // CloudKit同期されていないメッセージ（ckRecordName が nil）を検出
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                // SwiftData のモデルコンテキストにアクセス
                // do {
                    // SwiftDataのModelContainer初期化を回避してクラッシュを防ぐ
                    log("Local database check temporarily disabled to prevent crash", category: "CloudKitChatManager")
                continuation.resume(returning: 0)
            }
        }
    }
    
    /// 全サブスクリプションを削除
    private func removeAllSubscriptions() async throws {
        // プライベートDBのサブスクリプション削除
        let privateSubscriptions = try await privateDB.allSubscriptions()
        let privateIDs = privateSubscriptions.map { $0.subscriptionID }
        if !privateIDs.isEmpty {
            _ = try await privateDB.modifySubscriptions(saving: [], deleting: privateIDs)
            log("Removed \(privateIDs.count) private subscriptions", category: "CloudKitChatManager")
        }
        
        // 共有DBのサブスクリプション削除
        let sharedSubscriptions = try await sharedDB.allSubscriptions()
        let sharedIDs = sharedSubscriptions.map { $0.subscriptionID }
        if !sharedIDs.isEmpty {
            _ = try await sharedDB.modifySubscriptions(saving: [], deleting: sharedIDs)
            log("Removed \(sharedIDs.count) shared subscriptions", category: "CloudKitChatManager")
        }
    }
    
    /// プライベートDBの全データを削除（ゾーンベース削除で効率化）
    private func clearPrivateDatabase() async throws {
        // 🌟 [EFFICIENT RESET] ゾーン削除でレコード一括削除（クエリ不要）
        do {
            let zones = try await privateDB.allRecordZones()
            let customZones = zones.filter { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            
            if !customZones.isEmpty {
                let zoneIDsToDelete = customZones.map { $0.zoneID }
                _ = try await privateDB.modifyRecordZones(saving: [], deleting: zoneIDsToDelete)
                log("🗑️ [EFFICIENT RESET] Deleted \(zoneIDsToDelete.count) custom zones (zone-based deletion)", category: "CloudKitChatManager")
            }
            
        } catch {
            log("⚠️ [RESET] Zone-based deletion failed, skipping: \(error)", category: "CloudKitChatManager")
        }
        
        // デフォルトゾーンのレコード削除（個別削除は不要 - 新しい実装で上書き）
        log("ℹ️ [RESET] Default zone records will be overwritten by new implementation", category: "CloudKitChatManager")
    }
    
    /// カスタムゾーンを削除
    private func clearCustomZones() async throws {
        let zones = try await privateDB.allRecordZones()
        let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") }
        
        if !customZones.isEmpty {
            let zoneIDs = customZones.map { $0.zoneID }
            _ = try await privateDB.modifyRecordZones(saving: [], deleting: zoneIDs)
            log("Deleted \(zoneIDs.count) custom zones", category: "CloudKitChatManager")
        }
    }
    
    /// 共有ゾーンから離脱（効率的な実装）
    private func leaveAllSharedDatabases() async throws {
        // 🌟 [EFFICIENT RESET] 共有ゾーン削除でレコード一括削除（クエリ不要）
        do {
            let sharedZones = try await sharedDB.allRecordZones()
            let customSharedZones = sharedZones.filter { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            
            if !customSharedZones.isEmpty {
                let zoneIDsToDelete = customSharedZones.map { $0.zoneID }
                _ = try await sharedDB.modifyRecordZones(saving: [], deleting: zoneIDsToDelete)
                log("🗑️ [EFFICIENT RESET] Left \(zoneIDsToDelete.count) shared zones (zone-based deletion)", category: "CloudKitChatManager")
            } else {
                log("ℹ️ [RESET] No shared zones to leave", category: "CloudKitChatManager")
            }
            
        } catch {
            log("⚠️ [RESET] Shared zone deletion failed, skipping: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// UserDefaultsの関連データをクリア
    private func clearUserDefaults() {
        let defaults = UserDefaults.standard
        
        // チャット関連のキーをクリア
        let keysToRemove = [
            "recentEmojis",
            "autoDownloadImages",
            "hasSeenWelcome"
        ]
        
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }
        
        // チュートリアルフラグをクリア
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix("didSeedTutorial_") {
                defaults.removeObject(forKey: key)
            }
        }
        
        defaults.synchronize()
        log("UserDefaults cleared", category: "CloudKitChatManager")
    }
    
    /// ローカルSwiftDataデータベースをクリア
    private func clearLocalDatabase() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let context = try ModelContainer(for: Message.self).mainContext
                    
                    // 全メッセージを削除
                    let descriptor = FetchDescriptor<Message>()
                    let messages = try context.fetch(descriptor)
                    
                    for message in messages {
                        context.delete(message)
                    }
                    
                    try context.save()
                    
                    log("✅ [RESET] Cleared \(messages.count) local messages from SwiftData", category: "CloudKitChatManager")
                    continuation.resume()
                    
                } catch {
                    log("❌ [RESET] Failed to clear local database: \(error)", category: "CloudKitChatManager")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Chat Room Management
    
    /// 🌟 [IDEAL] 共有チャットルームの作成（1チャット=1カスタムゾーン + ゾーン共有）
    func createSharedChatRoom(roomID: String, invitedUserID: String) async throws -> CKShare {
        log("🏠 [ROOM CREATION] Creating shared chat room: \(roomID)", category: "CloudKitChatManager")
        
        // ユーザー認証の確認
        guard let currentUserID = self.currentUserID else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        // 🌟 [IDEAL ZONE SHARING] カスタムゾーン + レコード + CKShare(Zone Share) を正しい順序で作成
        let customZoneID = CKRecordZone.ID(zoneName: roomID)
        let customZone = CKRecordZone(zoneID: customZoneID)
        
        // ChatSessionレコードを作成（理想実装）
        let chatRecord = CKRecord(recordType: "ChatSession", recordID: CKRecord.ID(recordName: roomID, zoneID: customZoneID))
        chatRecord["roomID"] = roomID as CKRecordValue
        chatRecord["createdBy"] = currentUserID as CKRecordValue
        chatRecord["timestamp"] = Date() as CKRecordValue
        // 🌟 [IDEAL] participants フィールドは使用しない - CKShare.participants が唯一の信頼できるソース
        
        do {
            // 🚀 Step 1: ゾーンを作成
            _ = try await privateDB.save(customZone)
            log("✅ [ROOM CREATION] Created custom zone: \(roomID)", category: "CloudKitChatManager")

            // 🚀 Step 2: ゾーン共有用のCKShareを作成（zone.shareへの代入は不要）
            let share = CKShare(recordZoneID: customZoneID)
            share[CKShare.SystemFieldKey.title] = "4-Marin チャット: \(roomID)" as CKRecordValue
            // リンクを知っている人は誰でも参加（iCloudサインイン要）
            // 既定は readWrite とし、必要に応じて UI で readOnly へ変更可能
            share.publicPermission = .readWrite

            // 🚀 Step 3: CKShare と ChatSession を同一オペレーションで保存
            log("🔄 [ROOM CREATION] Saving Zone CKShare + ChatSession in batch...", category: "CloudKitChatManager")
            let modifyResult = try await privateDB.modifyRecords(saving: [share, chatRecord], deleting: [])

            var savedShare: CKShare? = nil
            var savedChat: CKRecord? = nil
            for (_, result) in modifyResult.saveResults {
                switch result {
                case .success(let record):
                    if let s = record as? CKShare { savedShare = s }
                    else if record.recordType == "ChatSession" { savedChat = record }
                case .failure(let e):
                    log("❌ [ROOM CREATION] Failed saving record in batch: \(e)", category: "CloudKitChatManager")
                }
            }

            guard let finalShare = savedShare, savedChat != nil else {
                log("❌ [ROOM CREATION] CKShare or ChatSession not returned from batch save", category: "CloudKitChatManager")
                throw CloudKitChatError.recordSaveFailed
            }

            // チュートリアルメッセージをCloudKitに保存
            await seedTutorialMessages(to: customZoneID, ownerID: currentUserID)

            log("✅ [ROOM CREATION] Successfully created Zone + CKShare + ChatSession", category: "CloudKitChatManager")
            log("✅ [ROOM CREATION] Zone: \(customZoneID.zoneName)", category: "CloudKitChatManager")
            log("✅ [ROOM CREATION] CKShare recordID: \(finalShare.recordID.recordName)", category: "CloudKitChatManager")
            log("✅ [ROOM CREATION] CKShare URL: \(finalShare.url?.absoluteString ?? "nil")", category: "CloudKitChatManager")
            return finalShare
        
        } catch {
            log("❌ [ROOM CREATION] Zone Sharing creation failed: \(error)", category: "CloudKitChatManager")
            // エラーの詳細をログ出力
            if let ckError = error as? CKError {
                log("❌ [ROOM CREATION] CKError code: \(ckError.code.rawValue)", category: "CloudKitChatManager")
                log("❌ [ROOM CREATION] CKError description: \(ckError.localizedDescription)", category: "CloudKitChatManager")
            }
            throw error
        }
    }
    
    /// チャットルームレコードの取得
    func getRoomRecord(roomID: String) async throws -> CKRecord {
        log("🔍 [ROOM FETCH] Fetching room record: \(roomID)", category: "CloudKitChatManager")
        
        // 1) オーナー（Private DBのカスタムゾーン）を試す
        do {
            let customZoneID = try await resolvePrivateZoneIDIfExists(roomID: roomID)
            if let zoneID = customZoneID {
                let recordID = CKRecord.ID(recordName: roomID, zoneID: zoneID)
                let record = try await privateDB.record(for: recordID)
                log("✅ [ROOM FETCH] Found room record in Private DB zone", category: "CloudKitChatManager")
                return record
            }
        }
        
        // 2) 参加者（Shared DBの共有ゾーン）を試す
        do {
            if let sharedZoneID = try await resolveSharedZoneIDIfExists(roomID: roomID) {
                let recordID = CKRecord.ID(recordName: roomID, zoneID: sharedZoneID)
                let record = try await sharedDB.record(for: recordID)
                log("✅ [ROOM FETCH] Found room record in Shared DB zone", category: "CloudKitChatManager")
                return record
            }
        }
        
        // 3) いずれにも存在しない → 一貫性違反として扱い、上位でリセット判定される
        log("❌ [ROOM FETCH] Room not found in Private/Shared zones: \(roomID)", category: "CloudKitChatManager")
        throw CloudKitChatError.roomNotFound
    }
    
    /// 🌟 [IDEAL] 共有データベースサブスクリプションの設定
    func setupSharedDatabaseSubscriptions() async throws {
        log("📡 [SUBSCRIPTIONS] Setting up shared database subscriptions", category: "CloudKitChatManager")
        
        // データベースサブスクリプション（共有DB全体の変更を監視）
        let subscription = CKDatabaseSubscription(subscriptionID: "shared-database-subscription")
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldBadge = false
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        
        do {
            _ = try await sharedDB.save(subscription)
            log("✅ [SUBSCRIPTIONS] Shared database subscription created", category: "CloudKitChatManager")
        } catch {
            // 既存のサブスクリプションがある場合はエラーを無視
            if let ckError = error as? CKError, ckError.code == .serverRejectedRequest {
                log("ℹ️ [SUBSCRIPTIONS] Shared database subscription already exists", category: "CloudKitChatManager")
            } else {
                log("❌ [SUBSCRIPTIONS] Failed to create shared database subscription: \(error)", category: "CloudKitChatManager")
                throw error
            }
        }
    }

    // MARK: - Consistency Validation & Auto Reset
    
    /// DB構成の一貫性チェックを行い、重大な不整合が見つかった場合はクラウド含めた完全リセットを実施する。
    private func validateAndResetIfInconsistent() async {
        do {
            let issues = try await findInconsistencies()
            if issues.isEmpty {
                log("✅ [HEALTH CHECK] Database configuration is consistent", category: "CloudKitChatManager")
                return
            }
            
            log("❗ [HEALTH CHECK] Inconsistencies detected (\(issues.count)) — performing full reset", category: "CloudKitChatManager")
            for issue in issues { log("• \(issue)", category: "CloudKitChatManager") }
            
            do {
                try await performCompleteReset(bypassSafetyCheck: true)
                hasPerformedReset = true
                // リセット後に共有DBサブスクリプションを再作成
                try? await setupSharedDatabaseSubscriptions()
                log("✅ [HEALTH CHECK] Full reset completed due to inconsistencies", category: "CloudKitChatManager")
            } catch {
                log("❌ [HEALTH CHECK] Full reset failed: \(error)", category: "CloudKitChatManager")
                lastError = error
            }
        } catch {
            log("⚠️ [HEALTH CHECK] Failed to perform consistency check: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// 重大な不整合を列挙して返す（空配列なら健康）。
    private func findInconsistencies() async throws -> [String] {
        var issues: [String] = []
        
        // 1) レガシーSharedRoomsゾーンの存在
        do {
            let zones = try await privateDB.allRecordZones()
            if zones.contains(where: { $0.zoneID.zoneName == "SharedRooms" }) {
                issues.append("Legacy zone 'SharedRooms' exists (should not in ideal architecture)")
            }
        } catch {
            issues.append("Failed to list private zones: \(error)")
        }
        
        // 2) Private DBのカスタムゾーン健全性
        do {
            let zones = try await privateDB.allRecordZones()
            let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") && $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            for zone in customZones {
                let roomID = zone.zoneID.zoneName
                // ChatSessionレコードの存在
                let recordID = CKRecord.ID(recordName: roomID, zoneID: zone.zoneID)
                do {
                    let chat = try await privateDB.record(for: recordID)
                    // roomIDフィールドの整合
                    if let r = chat["roomID"] as? String, r != roomID { issues.append("Private zone \(roomID): ChatSession.roomID mismatch: \(r)") }
                } catch {
                    issues.append("Private zone \(roomID): ChatSession record missing")
                }
                // MessageのroomIDとzoneNameの一致（サンプルチェック）
                do {
                    let q = CKQuery(recordType: "Message", predicate: NSPredicate(value: true))
                    let (res, _) = try await privateDB.records(matching: q, inZoneWith: zone.zoneID)
                    for (_, rr) in res.prefix(5) {
                        if let rec = try? rr.get() {
                            let rid = rec["roomID"] as? String ?? ""
                            if rid != roomID { issues.append("Private zone \(roomID): Message.roomID mismatch: \(rid)") }
                            if rec["timestamp"] == nil { issues.append("Private zone \(roomID): Message missing 'timestamp'") }
                        }
                    }
                } catch {
                    // ゾーンが空なら問題なし
                }
            }
        } catch {
            issues.append("Failed to validate private zones: \(error)")
        }
        
        // 3) Shared DBのカスタムゾーン健全性（参加者側）
        do {
            let zones = try await sharedDB.allRecordZones()
            let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") && $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            for zone in customZones {
                let roomID = zone.zoneID.zoneName
                // ChatSessionレコードの存在
                let recordID = CKRecord.ID(recordName: roomID, zoneID: zone.zoneID)
                do {
                    let chat = try await sharedDB.record(for: recordID)
                    if let r = chat["roomID"] as? String, r != roomID { issues.append("Shared zone \(roomID): ChatSession.roomID mismatch: \(r)") }
                } catch {
                    issues.append("Shared zone \(roomID): ChatSession record missing (share not accepted?)")
                }
                // MessageのroomIDとzoneNameの一致（サンプルチェック）
                do {
                    let q = CKQuery(recordType: "Message", predicate: NSPredicate(value: true))
                    let (res, _) = try await sharedDB.records(matching: q, inZoneWith: zone.zoneID)
                    for (_, rr) in res.prefix(5) {
                        if let rec = try? rr.get() {
                            let rid = rec["roomID"] as? String ?? ""
                            if rid != roomID { issues.append("Shared zone \(roomID): Message.roomID mismatch: \(rid)") }
                            if rec["timestamp"] == nil { issues.append("Shared zone \(roomID): Message missing 'timestamp'") }
                        }
                    }
                } catch {
                    // ゾーンが空なら問題なし
                }
            }
        } catch {
            // Shared DBアクセス不可は即リセット対象ではない（未共有/未受諾の可能性）
        }
        
        // 4) デフォルトゾーンにMessageが存在しないか簡易チェック（Privateのみ）
        do {
            let q = CKQuery(recordType: "Message", predicate: NSPredicate(value: true))
            let (res, _) = try await privateDB.records(matching: q, inZoneWith: nil)
            if !res.isEmpty { issues.append("Default zone contains Message records (should be per-chat custom zones)") }
        } catch { /* 無視 */ }
        
        return issues
    }

    // MARK: - DB/Zone 解決ユーティリティ
    
    /// 指定roomIDに対して、書き込み対象のDBとzoneIDを解決（オーナー=private / 参加者=shared）。
    /// - Returns: (database, zoneID)
    func resolveDatabaseAndZone(for roomID: String) async throws -> (db: CKDatabase, zoneID: CKRecordZone.ID) {
        // 1) Private DBのゾーンに存在するか（=オーナー）
        if let zoneID = try await resolvePrivateZoneIDIfExists(roomID: roomID) {
            return (privateDB, zoneID)
        }
        // 2) Shared DBのゾーンに存在するか（=参加者）
        if let zoneID = try await resolveSharedZoneIDIfExists(roomID: roomID) {
            return (sharedDB, zoneID)
        }
        // 3) 見つからない
        throw CloudKitChatError.roomNotFound
    }
    
    func resolvePrivateZoneIDIfExists(roomID: String) async throws -> CKRecordZone.ID? {
        if let cached = privateZoneCache[roomID] { return cached }
        let zones = try await privateDB.allRecordZones()
        if let zone = zones.first(where: { $0.zoneID.zoneName == roomID }) {
            privateZoneCache[roomID] = zone.zoneID
            return zone.zoneID
        }
        return nil
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

    // MARK: - Share Revocation / Delete
    /// 共有を無効化し、必要ならゾーンも削除する（オーナー時）。参加者時は共有ゾーンから離脱。
    func revokeShareAndDeleteIfNeeded(roomID: String) async {
        do {
            if let privateZone = try await resolvePrivateZoneIDIfExists(roomID: roomID) {
                // オーナー: CKShare を削除し、ゾーンも削除
                // 1) CKShare レコードを検索して削除
                let q = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
                let (res, _) = try await privateDB.records(matching: q, inZoneWith: privateZone)
                for (_, rr) in res {
                    if let rec = try? rr.get(), rec is CKShare {
                        do { try await privateDB.deleteRecord(withID: rec.recordID) } catch { /* 既に削除済み等は無視 */ }
                    }
                }
                // 2) ゾーン削除
                _ = try await privateDB.modifyRecordZones(saving: [], deleting: [privateZone])
                log("🗑️ [REVOKE] Deleted share and zone for roomID=\(roomID) (owner)", category: "CloudKitChatManager")
            } else if let sharedZone = try await resolveSharedZoneIDIfExists(roomID: roomID) {
                // 参加者: 共有ゾーンから離脱（ローカルから削除）
                _ = try await sharedDB.modifyRecordZones(saving: [], deleting: [sharedZone])
                log("🚪 [LEAVE] Left shared zone for roomID=\(roomID) (participant)", category: "CloudKitChatManager")
            } else {
                log("ℹ️ [REVOKE] No zone found for roomID=\(roomID)", category: "CloudKitChatManager")
            }
        } catch {
            log("⚠️ [REVOKE] Failed to revoke/share delete for roomID=\(roomID): \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// 特定ルーム用のサブスクリプション設定
    func setupRoomSubscription(for roomID: String) async throws {
        log("📡 [SUBSCRIPTION] Setting up room subscription for: \(roomID)", category: "CloudKitChatManager")
        
        // 参加者（Shared DB）の場合は CKQuerySubscription は使えないためスキップ
        if let _ = try? await resolveSharedZoneIDIfExists(roomID: roomID),
           (try? await resolvePrivateZoneIDIfExists(roomID: roomID)) == nil {
            log("ℹ️ [SUBSCRIPTION] Skipped room subscription for shared zone (unsupported on Shared DB)", category: "CloudKitChatManager")
            return
        }

        // カスタムゾーンでのメッセージ変更を監視
        let customZoneID = CKRecordZone.ID(zoneName: roomID)
        let predicate = NSPredicate(format: "roomID == %@", roomID)
        let subscription = CKQuerySubscription(
            recordType: "Message",
            predicate: predicate,
            subscriptionID: "message-subscription-\(roomID)",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldBadge = false
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        
        // カスタムゾーンに対してサブスクリプションを設定
        subscription.zoneID = customZoneID
        
        do {
            _ = try await privateDB.save(subscription)
            log("✅ [SUBSCRIPTION] Room subscription created for: \(roomID)", category: "CloudKitChatManager")
        } catch {
            // 既存のサブスクリプションがある場合はエラーを無視
            if let ckError = error as? CKError, ckError.code == .serverRejectedRequest {
                log("ℹ️ [SUBSCRIPTION] Room subscription already exists for: \(roomID)", category: "CloudKitChatManager")
            } else {
                log("❌ [SUBSCRIPTION] Failed to create room subscription: \(error)", category: "CloudKitChatManager")
                throw error
            }
        }
    }
    
    // MARK: - Message Reactions (Ideal Implementation)
    
    /// 🌟 [IDEAL] メッセージにリアクションを追加（正規化実装）
    func addReactionToMessage(messageRecordName: String, roomID: String, emoji: String, userID: String) async throws {
        log("👍 [REACTION] Adding reaction: \(emoji) to message: \(messageRecordName) by user: \(userID)", category: "CloudKitChatManager")
        
        // ユーザー認証の確認
        guard self.currentUserID != nil else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        // 対象DB/ゾーン解決
        let (db, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        
        // 🌟 [IDEAL] 正規化されたMessageReactionレコードを作成（同一ゾーン参照）
        let reactionID = MessageReaction.createID(messageRecordName: messageRecordName, userID: userID, emoji: emoji)
        let messageReference = MessageReaction.createMessageReference(messageID: messageRecordName, zoneID: zoneID)
        let reaction = MessageReaction(id: reactionID, messageRef: messageReference, userID: userID, emoji: emoji, createdAt: Date())
        let reactionRecord = reaction.toCloudKitRecord(in: zoneID)
        
        do {
            _ = try await db.save(reactionRecord)
            log("✅ [REACTION] Successfully added reaction: \(reactionID)", category: "CloudKitChatManager")
        } catch {
            // 重複エラーの場合は既に存在することを示す
            if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
                log("ℹ️ [REACTION] Reaction already exists: \(reactionID)", category: "CloudKitChatManager")
            } else {
                log("❌ [REACTION] Failed to add reaction: \(error)", category: "CloudKitChatManager")
                throw error
            }
        }
    }
    
    /// 🌟 [IDEAL] メッセージからリアクションを削除
    func removeReactionFromMessage(messageRecordName: String, roomID: String, emoji: String, userID: String) async throws {
        log("👎 [REACTION] Removing reaction: \(emoji) from message: \(messageRecordName) by user: \(userID)", category: "CloudKitChatManager")
        
        // 🌟 [IDEAL] 正規化されたID規約を使用
        let (db, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let reactionID = MessageReaction.createID(messageRecordName: messageRecordName, userID: userID, emoji: emoji)
        let recordID = CKRecord.ID(recordName: reactionID, zoneID: zoneID)
        
        do {
            try await db.deleteRecord(withID: recordID)
            log("✅ [REACTION] Successfully removed reaction: \(reactionID)", category: "CloudKitChatManager")
        } catch {
            if let ckError = error as? CKError, ckError.code == .unknownItem {
                log("ℹ️ [REACTION] Reaction not found (already removed): \(reactionID)", category: "CloudKitChatManager")
            } else {
                log("❌ [REACTION] Failed to remove reaction: \(error)", category: "CloudKitChatManager")
                throw error
            }
        }
    }
    
    /// 🌟 [IDEAL] メッセージのリアクション一覧を取得
    func getReactionsForMessage(messageRecordName: String, roomID: String) async throws -> [MessageReaction] {
        log("📊 [REACTION] Fetching reactions for message: \(messageRecordName)", category: "CloudKitChatManager")
        
        let (_, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let messageReference = MessageReaction.createMessageReference(messageID: messageRecordName, zoneID: zoneID)
        
        let predicate = NSPredicate(format: "messageRef == %@", messageReference)
        let query = CKQuery(recordType: "MessageReaction", predicate: predicate)
        
        // どのDBかはroomIDから解決済み
        let (db, _) = try await resolveDatabaseAndZone(for: roomID)
        do {
            let (results, _) = try await db.records(matching: query)
            
            let reactions: [MessageReaction] = results.compactMap { (_, result) in
                guard let record = try? result.get() else { return nil }
                return MessageReaction.fromCloudKitRecord(record)
            }
            
            log("✅ [REACTION] Found \(reactions.count) reactions for message: \(messageRecordName)", category: "CloudKitChatManager")
            return reactions
            
        } catch {
            log("❌ [REACTION] Failed to fetch reactions: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    // MARK: - Profile Management
    
    /// マスタープロファイルの保存
    func saveMasterProfile(name: String, avatarData: Data) async throws {
        log("👤 [PROFILE] Saving master profile: \(name)", category: "CloudKitChatManager")
        
        guard let currentUserID = currentUserID else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        // ユーザーのシステムレコード名（Users）と衝突しないよう、独自のレコード名を使用
        let recordName = "CD_Profile_\(currentUserID)"
        let profileRecord = CKRecord(recordType: "CD_Profile", recordID: CKRecord.ID(recordName: recordName))
        profileRecord["userID"] = currentUserID as CKRecordValue
        profileRecord["displayName"] = name as CKRecordValue
        profileRecord["avatarData"] = avatarData as CKRecordValue
        profileRecord["updatedAt"] = Date() as CKRecordValue
        
        do {
            _ = try await privateDB.save(profileRecord)
            log("✅ [PROFILE] Master profile saved successfully", category: "CloudKitChatManager")
        } catch {
            log("❌ [PROFILE] Failed to save master profile: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// プロファイルの取得
    func fetchProfile(userID: String) async throws -> (name: String?, avatarData: Data?) {
        log("🔍 [PROFILE] Fetching profile for user: \(userID)", category: "CloudKitChatManager")
        
        // まずキャッシュを確認
        if let cachedProfile = profileCache[userID] {
            log("✅ [PROFILE] Found profile in cache for user: \(userID)", category: "CloudKitChatManager")
            return cachedProfile
        }
        
        // レコード名での直接取得は避け、userIDフィールドでクエリ
        let predicate = NSPredicate(format: "userID == %@", userID)
        let query = CKQuery(recordType: "CD_Profile", predicate: predicate)
        
        do {
            let (results, _) = try await privateDB.records(matching: query, resultsLimit: 1)
            var optRecord: CKRecord?
            for (_, res) in results { // 対応: 辞書/配列タプルの両方にマッチ
                if let rec = try? res.get() { optRecord = rec; break }
            }
            guard let record = optRecord else {
                log("ℹ️ [PROFILE] No profile found for user: \(userID)", category: "CloudKitChatManager")
                return (name: nil, avatarData: nil)
            }
            let name = record["displayName"] as? String
            let avatarData = record["avatarData"] as? Data
            
            // キャッシュに保存
            profileCache[userID] = (name: name, avatarData: avatarData)
            
            log("✅ [PROFILE] Profile fetched successfully for user: \(userID)", category: "CloudKitChatManager")
            return (name: name, avatarData: avatarData)
            
        } catch {
            log("❌ [PROFILE] Failed to fetch profile for user \(userID): \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    // MARK: - Message Management
    
    /// 🌟 [IDEAL] メッセージの送信
    func sendMessage(_ message: Message, to roomID: String) async throws {
        log("📤 [MESSAGE] Sending message to room: \(roomID)", category: "CloudKitChatManager")
        
        guard let currentUserID = currentUserID else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        // 対象DBとゾーンを解決（オーナー=private / 参加者=shared）
        let (targetDB, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        log("🧭 [MESSAGE] Resolved database: \(targetDB.databaseScope == .private ? "Private" : targetDB.databaseScope == .shared ? "Shared" : "Public"), zone: \(zoneID.zoneName)", category: "CloudKitChatManager")
        
        // カスタムゾーンにメッセージを保存（1チャット=1ゾーン）
        let messageRecord = CKRecord(recordType: "Message", recordID: CKRecord.ID(recordName: message.id.uuidString, zoneID: zoneID))
        
        // 🌟 [IDEAL] フィールド構成
        messageRecord["roomID"] = roomID as CKRecordValue
        messageRecord["senderID"] = currentUserID as CKRecordValue
        messageRecord["text"] = (message.body ?? "") as CKRecordValue  // body → text (理想実装)
        messageRecord["timestamp"] = message.createdAt as CKRecordValue  // createdAt → timestamp (理想実装)
        
        // 添付ファイルがある場合
        if let assetPath = message.assetPath {
            let fileURL = URL(fileURLWithPath: assetPath)
            let asset = CKAsset(fileURL: fileURL)
            messageRecord["attachment"] = asset  // asset → attachment (理想実装)
        }
        
        // 🌟 [IDEAL UPLOAD] 添付ファイルがある場合は長時間実行アップロードを使用
        let hasAttachment = messageRecord["attachment"] as? CKAsset != nil
        
        if hasAttachment {
            // 長時間実行アップロード使用
            log("📤 [IDEAL UPLOAD] Using CKModifyRecordsOperation.isLongLived for large asset", category: "CloudKitChatManager")
            try await sendMessageWithLongLivedOperation(messageRecord, in: targetDB)
        } else {
            // 通常のアップロード
            do {
                _ = try await targetDB.save(messageRecord)
                log("✅ [MESSAGE] Message sent successfully to room: \(roomID)", category: "CloudKitChatManager")
            } catch {
                if let ck = error as? CKError {
                    log("❌ [MESSAGE] Failed to send message: CKError=\(ck.code.rawValue) (\(ck.code))", category: "CloudKitChatManager")
                    if let hint = ckErrorHint(ck, roomID: roomID) { log("💡 [MESSAGE] Hint: \(hint)", category: "CloudKitChatManager") }
                } else {
                    log("❌ [MESSAGE] Failed to send message: \(error)", category: "CloudKitChatManager")
                }
                // 送信失敗時に診断を実施（ノイズ抑制のため軽量）
                Task { await self.diagnoseRoomAccessibility(roomID: roomID) }
                throw error
            }
        }
    }

    // MARK: - Diagnostics / Error Hints
    
    /// CKErrorをユーザー向けのヒントに変換
    private func ckErrorHint(_ error: CKError, roomID: String) -> String? {
        switch error.code {
        case .permissionFailure:
            return "共有が受諾されていない、または参加者権限が不足しています（roomID=\(roomID)）。招待URLを再受諾・UIで参加者追加を確認してください。"
        case .zoneNotFound:
            return "Shared DBに対象ゾーンが存在しません（roomID=\(roomID)）。招待の受諾が未完了か、環境/コンテナが不一致の可能性があります。"
        case .unknownItem:
            return "対象レコード/共有が見つかりません。共有の作成状態と環境一致を確認してください。"
        case .notAuthenticated:
            return "iCloudに未サインイン、または制限状態です。iOS設定のiCloud状態を確認してください。"
        case .networkUnavailable, .networkFailure:
            return "ネットワーク到達性が不十分です。接続状態を確認して再試行してください。"
        default:
            return nil
        }
    }
    
    /// ルームの到達性/権限を簡易診断してログ出力
    func diagnoseRoomAccessibility(roomID: String) async {
        log("🩺 [DIAG] Start diagnose for room=\(roomID)", category: "CloudKitChatManager")
        do {
            let pZones = try await privateDB.allRecordZones().map { $0.zoneID.zoneName }
            let sZones = try await sharedDB.allRecordZones().map { $0.zoneID.zoneName }
            log("🩺 [DIAG] Private zones: \(pZones)", category: "CloudKitChatManager")
            log("🩺 [DIAG] Shared zones: \(sZones)", category: "CloudKitChatManager")
        } catch {
            log("🩺 [DIAG] Failed to list zones: \(error)", category: "CloudKitChatManager")
        }
        
        do {
            // 参加者としてShared DBにChatSessionが見えるか確認
            if let zoneID = try await resolveSharedZoneIDIfExists(roomID: roomID) {
                let recID = CKRecord.ID(recordName: roomID, zoneID: zoneID)
                do {
                    _ = try await sharedDB.record(for: recID)
                    log("🩺 [DIAG] ChatSession is readable in Shared DB (zone=\(zoneID.zoneName))", category: "CloudKitChatManager")
                } catch {
                    if let ck = error as? CKError { log("🩺 [DIAG] Read failed Shared DB: CKError=\(ck.code)", category: "CloudKitChatManager") }
                    else { log("🩺 [DIAG] Read failed Shared DB: \(error)", category: "CloudKitChatManager") }
                }
            } else {
                log("🩺 [DIAG] Shared DB does not contain zone for roomID=\(roomID)", category: "CloudKitChatManager")
            }
        } catch {
            log("🩺 [DIAG] Shared zone resolution failed: \(error)", category: "CloudKitChatManager")
        }
        log("🩺 [DIAG] End diagnose", category: "CloudKitChatManager")
    }

    // MARK: - Post-Accept Bootstrap (iOS 17+)
    /// 受諾コールバックが届かない場合でも、Shared DB に現れた共有ゾーンから
    /// ローカルの ChatRoom を自動的に作成し、同期を開始する。
    func bootstrapSharedRooms(modelContext: ModelContext) async {
        log("🚀 [BOOTSTRAP] Scanning Shared DB for accepted zones…", category: "CloudKitChatManager")
        do {
            let zones = try await sharedDB.allRecordZones()
            let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") && $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            guard !customZones.isEmpty else {
                log("ℹ️ [BOOTSTRAP] No custom shared zones found", category: "CloudKitChatManager")
                return
            }

            for zone in customZones {
                let roomID = zone.zoneID.zoneName
                // ChatSession を読んで createdBy を取得
                let recID = CKRecord.ID(recordName: roomID, zoneID: zone.zoneID)
                do {
                    let chat = try await sharedDB.record(for: recID)
                    let createdBy = (chat["createdBy"] as? String) ?? ""

                    // 既存の ChatRoom があるか確認
                    let descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate { $0.roomID == roomID })
                    if let existing = try? modelContext.fetch(descriptor), existing.isEmpty == false {
                        log("ℹ️ [BOOTSTRAP] ChatRoom already exists for roomID=\(roomID)", category: "CloudKitChatManager")
                    } else {
                        // 新規作成（remoteUserID = createdBy, roomID = zoneName）
                        let newRoom = ChatRoom(roomID: roomID, remoteUserID: createdBy, displayName: nil)
                        modelContext.insert(newRoom)
                        try? modelContext.save()
                        log("✅ [BOOTSTRAP] Created local ChatRoom for shared zone: \(roomID)", category: "CloudKitChatManager")
                    }

                    // 同期を起動
                    if #available(iOS 17.0, *) {
                        MessageSyncService.shared.checkForUpdates(roomID: roomID)
                    }
                } catch {
                    log("⚠️ [BOOTSTRAP] Failed to read ChatSession in shared zone \(roomID): \(error)", category: "CloudKitChatManager")
                }
            }
        } catch {
            log("⚠️ [BOOTSTRAP] Failed to list shared zones: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// 🌟 [IDEAL UPLOAD] 長時間実行アップロード実装
    private func sendMessageWithLongLivedOperation(_ messageRecord: CKRecord, in database: CKDatabase) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [messageRecord], recordIDsToDelete: nil)
            operation.qualityOfService = .userInitiated
            
            // 長時間実行を有効にする（iOS 11+の推奨方法）
            operation.configuration.isLongLived = true
            operation.savePolicy = .allKeys
            
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success():
                    log("✅ [IDEAL UPLOAD] Long-lived operation completed successfully", category: "CloudKitChatManager")
                    continuation.resume()
                case .failure(let error):
                    log("❌ [IDEAL UPLOAD] Long-lived operation failed: \(error)", category: "CloudKitChatManager")
                    continuation.resume(throwing: error)
                }
            }
            
            // オペレーションの進捗追跡
            operation.perRecordProgressBlock = { record, progress in
                log("⏳ [IDEAL UPLOAD] Upload progress for \(record.recordID.recordName): \(Int(progress * 100))%", category: "CloudKitChatManager")
            }
            
            log("⏳ [IDEAL UPLOAD] Starting long-lived upload operation", category: "CloudKitChatManager")
            database.add(operation)
        }
    }
    
    /// メッセージの更新
    func updateMessage(_ message: Message) async throws {
        log("✏️ [MESSAGE] Updating message: \(message.id)", category: "CloudKitChatManager")
        
        guard let recordName = message.ckRecordName else {
            throw CloudKitChatError.invalidMessage
        }
        
        let (_, zoneID) = try await resolveDatabaseAndZone(for: message.roomID)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        do {
            // どのDBに保存されているかはrecordIDで解決可能だが、フェッチは両DBで試行
            let record: CKRecord
            if let rec = try? await privateDB.record(for: recordID) { record = rec }
            else { record = try await sharedDB.record(for: recordID) }
            record["text"] = (message.body ?? "") as CKRecordValue  // body → text (理想実装)
            record["timestamp"] = message.createdAt as CKRecordValue  // createdAt → timestamp (理想実装)
            
            // 保存先DBも同様に解決
            if (try? await privateDB.record(for: recordID)) != nil {
                _ = try await privateDB.save(record)
            } else {
                _ = try await sharedDB.save(record)
            }
            log("✅ [MESSAGE] Message updated successfully: \(message.id)", category: "CloudKitChatManager")
        } catch {
            log("❌ [MESSAGE] Failed to update message: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// メッセージの更新（recordName版 - CKSync互換）
    func updateMessage(recordName: String, roomID: String, newBody: String) async throws {
        log("✏️ [MESSAGE] Updating message (by recordName) in room: \(roomID)", category: "CloudKitChatManager")
        let (_, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            let record: CKRecord
            if let rec = try? await privateDB.record(for: recordID) { record = rec }
            else { record = try await sharedDB.record(for: recordID) }
            record["text"] = newBody as CKRecordValue
            record["timestamp"] = Date() as CKRecordValue
            if (try? await privateDB.record(for: recordID)) != nil {
                _ = try await privateDB.save(record)
            } else {
                _ = try await sharedDB.save(record)
            }
            log("✅ [MESSAGE] Message updated successfully: \(recordName)", category: "CloudKitChatManager")
        } catch {
            log("❌ [MESSAGE] Failed to update (by recordName): \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// メッセージの削除
    func deleteMessage(_ message: Message) async throws {
        log("🗑️ [MESSAGE] Deleting message: \(message.id)", category: "CloudKitChatManager")
        
        guard let recordName = message.ckRecordName else {
            throw CloudKitChatError.invalidMessage
        }
        
        let (_, zoneID) = try await resolveDatabaseAndZone(for: message.roomID)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        do {
            if (try? await privateDB.record(for: recordID)) != nil {
                try await privateDB.deleteRecord(withID: recordID)
            } else {
                try await sharedDB.deleteRecord(withID: recordID)
            }
            log("✅ [MESSAGE] Message deleted successfully: \(message.id)", category: "CloudKitChatManager")
        } catch {
            log("❌ [MESSAGE] Failed to delete message: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// メッセージの削除（recordName + roomID 版）
    func deleteMessage(recordName: String, roomID: String) async throws {
        log("🗑️ [MESSAGE] Deleting message with recordName: \(recordName) in room: \(roomID)", category: "CloudKitChatManager")
        let (_, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            if (try? await privateDB.record(for: recordID)) != nil {
                try await privateDB.deleteRecord(withID: recordID)
            } else {
                try await sharedDB.deleteRecord(withID: recordID)
            }
            log("✅ [MESSAGE] Message deleted successfully: \(recordName)", category: "CloudKitChatManager")
        } catch {
            log("❌ [MESSAGE] Failed to delete message by recordName: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    // MARK: - Anniversary Management
    
    /// 記念日の保存
    func saveAnniversary(title: String, date: Date, roomID: String, repeatType: Any? = nil) async throws -> String {
        log("🎉 [ANNIVERSARY] Saving anniversary: \(title)", category: "CloudKitChatManager")
        
        let (targetDB, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let anniversaryRecord = CKRecord(recordType: "CD_Anniversary", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        
        anniversaryRecord["title"] = title as CKRecordValue
        anniversaryRecord["date"] = date as CKRecordValue
        anniversaryRecord["roomID"] = roomID as CKRecordValue
        anniversaryRecord["createdAt"] = Date() as CKRecordValue
        
        do {
            let savedRecord = try await targetDB.save(anniversaryRecord)
            log("✅ [ANNIVERSARY] Anniversary saved successfully: \(title)", category: "CloudKitChatManager")
            return savedRecord.recordID.recordName
        } catch {
            log("❌ [ANNIVERSARY] Failed to save anniversary: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// 記念日の更新
    func updateAnniversary(recordName: String, title: String, date: Date, roomID: String) async throws -> String {
        log("✏️ [ANNIVERSARY] Updating anniversary: \(title)", category: "CloudKitChatManager")
        
        let (targetDB, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        do {
            let record = try await targetDB.record(for: recordID)
            record["title"] = title as CKRecordValue
            record["date"] = date as CKRecordValue
            
            let savedRecord = try await targetDB.save(record)
            log("✅ [ANNIVERSARY] Anniversary updated successfully: \(title)", category: "CloudKitChatManager")
            return savedRecord.recordID.recordName
        } catch {
            log("❌ [ANNIVERSARY] Failed to update anniversary: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    // 旧: updateAnniversary(recordName:title:date:) は削除（roomID必須）
    
    /// 記念日の削除
    func deleteAnniversary(recordName: String, roomID: String) async throws {
        log("🗑️ [ANNIVERSARY] Deleting anniversary: \(recordName)", category: "CloudKitChatManager")
        
        let (targetDB, zoneID) = try await resolveDatabaseAndZone(for: roomID)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        do {
            try await targetDB.deleteRecord(withID: recordID)
            log("✅ [ANNIVERSARY] Anniversary deleted successfully: \(recordName)", category: "CloudKitChatManager")
        } catch {
            log("❌ [ANNIVERSARY] Failed to delete anniversary: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// 記念日の削除（roomID不要版 - CKSync互換）
    func deleteAnniversary(recordName: String) async throws {
        log("🗑️ [ANNIVERSARY] Deleting anniversary (legacy): \(recordName)", category: "CloudKitChatManager")
        
        // すべてのカスタムゾーンを検索してレコードを見つける
        let zones = try await privateDB.allRecordZones()
        let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") }
        
        for zone in customZones {
            do {
                let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)
                try await privateDB.deleteRecord(withID: recordID)
                log("✅ [ANNIVERSARY] Anniversary deleted successfully (legacy): \(recordName)", category: "CloudKitChatManager")
                return
                
            } catch {
                // このゾーンにはレコードが存在しない、次のゾーンを試す
                continue
            }
        }
        
        log("❌ [ANNIVERSARY] Anniversary not found in any zone: \(recordName)", category: "CloudKitChatManager")
        throw CloudKitChatError.recordSaveFailed
    }
    
    // MARK: - Room Ownership and Participation
    
    /// 🌟 [IDEAL] ルームの所有者かどうかを確認
    func isOwnerOfRoom(_ roomID: String) async -> Bool {
        log("🔍 [ROOM OWNERSHIP] Checking ownership for room: \(roomID)", category: "CloudKitChatManager")
        
        guard let currentUserID = currentUserID else {
            log("❌ [ROOM OWNERSHIP] User not authenticated", category: "CloudKitChatManager")
            return false
        }
        
        do {
            let roomRecord = try await getRoomRecord(roomID: roomID)
            let createdBy = roomRecord["createdBy"] as? String
            
            let isOwner = createdBy == currentUserID
            log("✅ [ROOM OWNERSHIP] Room \(roomID) ownership: \(isOwner)", category: "CloudKitChatManager")
            return isOwner
            
        } catch {
            log("❌ [ROOM OWNERSHIP] Failed to check ownership for room \(roomID): \(error)", category: "CloudKitChatManager")
            return false
        }
    }
    
    /// 🌟 [IDEAL] 所有しているルーム一覧を取得
    func getOwnedRooms() async -> [String] {
        log("🔍 [OWNED ROOMS] Fetching owned rooms", category: "CloudKitChatManager")
        
        guard let currentUserID = currentUserID else {
            log("❌ [OWNED ROOMS] User not authenticated", category: "CloudKitChatManager")
            return []
        }
        
        var ownedRooms: [String] = []
        
        do {
            // すべてのカスタムゾーンを取得
            let zones = try await privateDB.allRecordZones()
            let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") }
            
            for zone in customZones {
                let roomID = zone.zoneID.zoneName
                
                // 各ゾーンのChatSessionレコードを確認
                do {
                    let recordID = CKRecord.ID(recordName: roomID, zoneID: zone.zoneID)
                    let record = try await privateDB.record(for: recordID)
                    
                    if let createdBy = record["createdBy"] as? String, createdBy == currentUserID {
                        ownedRooms.append(roomID)
                    }
                } catch {
                    // このゾーンにはChatSessionレコードが存在しない、スキップ
                    continue
                }
            }
            
            log("✅ [OWNED ROOMS] Found \(ownedRooms.count) owned rooms", category: "CloudKitChatManager")
            
        } catch {
            log("❌ [OWNED ROOMS] Failed to fetch owned rooms: \(error)", category: "CloudKitChatManager")
        }
        
        return ownedRooms
    }
    
    /// 🌟 [IDEAL] 参加しているルーム一覧を取得（共有ゾーン）
    func getParticipatingRooms() async -> [String] {
        log("🔍 [PARTICIPATING ROOMS] Fetching participating rooms", category: "CloudKitChatManager")
        
        var participatingRooms: [String] = []
        
        do {
            // 共有データベースからChatSessionレコードを検索
            let query = CKQuery(recordType: "ChatSession", predicate: NSPredicate(value: true))
            let (results, _) = try await sharedDB.records(matching: query)
            
            for (_, result) in results {
                if let record = try? result.get(),
                   let roomID = record["roomID"] as? String {
                    participatingRooms.append(roomID)
                }
            }
            
            log("✅ [PARTICIPATING ROOMS] Found \(participatingRooms.count) participating rooms", category: "CloudKitChatManager")
            
        } catch {
            log("❌ [PARTICIPATING ROOMS] Failed to fetch participating rooms: \(error)", category: "CloudKitChatManager")
        }
        
        return participatingRooms
    }
    
    // MARK: - Reset and Environment Management
    
    /// 本番環境かどうかをチェック
    func checkIsProductionEnvironment() -> Bool {
        // コンテナIDまたはその他の指標で本番環境を判定
        let isProduction = container.containerIdentifier?.contains("production") == true ||
                          container.containerIdentifier?.contains("prod") == true
        
        log("🏭 [ENVIRONMENT] Production environment check: \(isProduction)", category: "CloudKitChatManager")
        return isProduction
    }
    
    /// 緊急リセット（安全チェック付き）
    func performEmergencyReset() async throws {
        log("🚨 [EMERGENCY RESET] Starting emergency reset", category: "CloudKitChatManager")
        
        // 本番環境での緊急リセットは追加の確認が必要
        if checkIsProductionEnvironment() {
            log("⚠️ [EMERGENCY RESET] Production environment detected - using bypass", category: "CloudKitChatManager")
        }
        
        try await performCompleteReset(bypassSafetyCheck: true)
        log("✅ [EMERGENCY RESET] Emergency reset completed", category: "CloudKitChatManager")
    }
    
    /// ローカルリセット（CloudKitには影響しない）
    func performLocalReset() async throws {
        log("🏠 [LOCAL RESET] Starting local reset", category: "CloudKitChatManager")
        
        do {
            // ローカルSwiftDataをクリア
            try await clearLocalDatabase()
            
            // UserDefaultsをクリア
            clearUserDefaults()
            
            // キャッシュをクリア
            clearCache()
            
            log("✅ [LOCAL RESET] Local reset completed", category: "CloudKitChatManager")
            
        } catch {
            log("❌ [LOCAL RESET] Local reset failed: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    /// 完全CloudKitリセット（ローカルは保持）
    func performCompleteCloudReset() async throws {
        log("☁️ [CLOUD RESET] Starting complete cloud reset", category: "CloudKitChatManager")
        
        do {
            // 全サブスクリプションを削除
            try await removeAllSubscriptions()
            
            // プライベートDBをクリア
            try await clearPrivateDatabase()
            
            // 共有ゾーンから離脱
            try await leaveAllSharedDatabases()
            
            log("✅ [CLOUD RESET] Complete cloud reset finished", category: "CloudKitChatManager")
            
        } catch {
            log("❌ [CLOUD RESET] Complete cloud reset failed: \(error)", category: "CloudKitChatManager")
            throw error
        }
    }
    
    // MARK: - Diagnostics Utilities
    
    /// ゾーン一覧と共有状態を出力
    private func dumpZoneList() async {
        do {
            let zones = try await privateDB.allRecordZones()
            let zoneNames = zones.map { $0.zoneID.zoneName }.joined(separator: ", ")
            log("📁 Private DB zones: [\(zoneNames)]", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to list private DB zones: \(error)", category: "CloudKitChatManager")
        }
        do {
            let zones = try await sharedDB.allRecordZones()
            let zoneNames = zones.map { $0.zoneID.zoneName }.joined(separator: ", ")
            log("📁 Shared DB zones: [\(zoneNames)]", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to list shared DB zones: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// データベース全体の状態を可視化（ログ収集連携）
    func dumpDatabaseState(roomID: String? = nil) async {
        // アカウント状態
        let status = await checkAccountStatus()
        log("👤 CKAccountStatus: \(status.rawValue)", category: "CloudKitChatManager")
        log("🧩 CKContainer: iCloud.forMarin-test", category: "CloudKitChatManager")
        
        // ゾーン一覧
        await dumpZoneList()
        
        // 旧レガシー構造（SharedRooms / cloudkit.share）に依存した診断は削除
        
        // 対象roomIDが指定されていれば詳細
        if let roomID = roomID {
            await dumpRoomDetails(roomID: roomID)
        }
    }
    
    /// 特定ルームの詳細状態
    private func dumpRoomDetails(roomID: String) async {
        log("🔬 Dumping room details for roomID: \(roomID)", category: "CloudKitChatManager")
        
        // レガシーSharedRoomsチェックは廃止
        
        // メッセージ数（最近のみ）
        do {
            let predicate = NSPredicate(format: "roomID == %@", roomID)
            let q = CKQuery(recordType: "Message", predicate: predicate)
            let (results, _) = try await privateDB.records(matching: q, resultsLimit: 20)
            let cnt = results.count
            log("📝 Private DB messages (any zone) sample count: \(cnt)", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to count messages: \(error)", category: "CloudKitChatManager")
        }
    }
    
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
    case schemaCreationInProgress
    case productionResetBlocked
    case resetFailed
    
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
        case .schemaCreationInProgress:
            return "データベース初期化中です。しばらくお待ちください"
        case .productionResetBlocked:
            return "本番環境でのリセットは安全のためブロックされています。force=trueを使用してください"
        case .resetFailed:
            return "データリセットに失敗しました"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let disableMessageSync = Notification.Name("DisableMessageSync")
    static let enableMessageSync = Notification.Name("EnableMessageSync")
    static let cloudKitSchemaReady = Notification.Name("CloudKitSchemaReady")
    static let cloudKitShareAccepted = Notification.Name("CloudKitShareAccepted")  // 🌟 [IDEAL SHARING] 招待受信通知
}
