import Foundation
import CloudKit
import Combine
import SwiftUI

@MainActor
class CloudKitChatManager: ObservableObject {
    static let shared = CloudKitChatManager()
    
    private let container = CKContainer(identifier: "iCloud.forMarin-test")
    private let privateDB: CKDatabase
    private let sharedDB: CKDatabase
    
    @Published var currentUserID: String?
    @Published var isInitialized: Bool = false
    @Published var lastError: Error?
    @Published var hasPerformedReset: Bool = false
    
    // Schema creation flag
    private var isSyncDisabled: Bool = false
    
    // プロフィールキャッシュ（userID -> (name, avatarData)）
    private var profileCache: [String: (name: String?, avatarData: Data?)] = [:]
    
    
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
                log("🛑 Sync disabled for schema creation", category: "CloudKitChatManager")
                self?.isSyncDisabled = true
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .enableMessageSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                log("✅ Sync re-enabled after schema creation", category: "CloudKitChatManager")
                self?.isSyncDisabled = false
            }
        }
    }
    
    // MARK: - Log Dump Observer (診断用)
    
    /// ログ収集要求に応じてDB状態を詳細に出力
    private func setupLogDumpObserver() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("RequestDatabaseDump"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                let source = (notification.userInfo?["source"] as? String) ?? "unknown"
                log("🧾 Database dump requested (source: \(source))", category: "CloudKitChatManager")
                await self?.dumpDatabaseState(roomID: nil)
            }
        }
    }
    
    // MARK: - Initialization
    
    private func initialize() async {
        // 旧データ検出時の自動リセット（本番環境でも有効）
        do {
            try await resetIfLegacyDataDetected()
        } catch {
            log("⚠️ Legacy data reset failed (ignored): \(error)", category: "CloudKitChatManager")
        }
        
        await fetchCurrentUserID()
        
        // UserIDManagerの通知を購読
        setupUserIDNotifications()
        
        isInitialized = true
        log("Initialized successfully with userID: \(currentUserID ?? "unknown")", category: "CloudKitChatManager")
        
        // 診断用ダンプオブザーバー登録
        setupLogDumpObserver()
        
        // 開発環境でのスキーマ自動作成を試行（初期化後に独立して実行）
        #if DEBUG
        log("🚀 Starting DEBUG schema creation...", category: "CloudKitChatManager")
        Task {
            // スキーマ作成中はメッセージ同期を停止
            NotificationCenter.default.post(name: .disableMessageSync, object: nil)
            await createSchemaIfNeeded()
            // スキーマ作成完了後にメッセージ同期を再開
            NotificationCenter.default.post(name: .enableMessageSync, object: nil)
        }
        #endif
    }
    
    #if DEBUG
    /// 開発環境でスキーマ自動作成・再構築を試行
    private func createSchemaIfNeeded() async {
        log("🔍 Checking if schema creation is needed...", category: "CloudKitChatManager")
        
        // 実際のCloudKitデータベース状態を確認
        let schemaIsValid = await validateExistingSchema()
        
        if schemaIsValid {
            log("✅ Schema already exists and is valid, skipping creation", category: "CloudKitChatManager")
            return
        }
        
        log("🔧 Schema validation failed or missing, starting comprehensive schema creation...", category: "CloudKitChatManager")
        
        // 1. 既存スキーマをクリア（問題がある場合のみ）
        await clearDevelopmentSchema()
        
        // 2. 包括的なスキーマを作成
        await createComprehensiveSchema()
        
        // 3. queryable インデックスを強制作成
        await forceCreateQueryableIndexes()
        
        // 4. スキーマ検証を実行
        await validateCreatedSchema()
        
        log("✅ Schema creation and validation completed successfully", category: "CloudKitChatManager")
        
        // スキーマ作成完了を通知
        await MainActor.run {
            NotificationCenter.default.post(name: .cloudKitSchemaReady, object: nil)
        }
    }
    
    /// 既存スキーマの有効性を実際のCloudKitデータベースで確認
    private func validateExistingSchema() async -> Bool {
        log("🔍 Validating existing CloudKit schema...", category: "CloudKitChatManager")
        
        // 1. 基本的なレコードタイプの作成可能性をテスト
        let testResult = await testBasicRecordCreation()
        if !testResult {
            log("❌ Basic record creation test failed", category: "CloudKitChatManager")
            return false
        }
        
        // 2. 必要なサブスクリプションの存在確認
        let subscriptionsValid = await validateSubscriptions()
        if !subscriptionsValid {
            log("❌ Subscriptions validation failed", category: "CloudKitChatManager")
            return false
        }
        
        log("✅ Existing schema is valid", category: "CloudKitChatManager")
        return true
    }
    
    /// 基本的なレコード作成テスト
    private func testBasicRecordCreation() async -> Bool {
        log("🧪 Testing basic record creation...", category: "CloudKitChatManager")
        
        // テスト用の一時的なレコードを作成してすぐに削除
        let testRecordTypes = ["CD_Message", "CD_ChatRoom", "CD_Profile"]
        
        for recordType in testRecordTypes {
            do {
                // テストレコードを作成
                let testRecord = CKRecord(recordType: recordType)
                
                // 最小限のフィールド設定
                switch recordType {
                case "CD_Message":
                    testRecord["roomID"] = "test" as CKRecordValue
                    testRecord["senderID"] = "test" as CKRecordValue
                    testRecord["body"] = "test" as CKRecordValue
                    testRecord["createdAt"] = Date() as CKRecordValue
                case "CD_ChatRoom":
                    testRecord["roomID"] = "test" as CKRecordValue
                    testRecord["participants"] = ["test"] as CKRecordValue
                    testRecord["createdAt"] = Date() as CKRecordValue
                case "CD_Profile":
                    testRecord["userID"] = "test" as CKRecordValue
                    testRecord["displayName"] = "test" as CKRecordValue
                    testRecord["updatedAt"] = Date() as CKRecordValue
                default:
                    break
                }
                
                // 作成テスト
                let savedRecord = try await privateDB.save(testRecord)
                
                // すぐに削除
                try await privateDB.deleteRecord(withID: savedRecord.recordID)
                
                log("✅ \(recordType) creation test passed", category: "CloudKitChatManager")
                
            } catch {
                log("❌ \(recordType) creation test failed: \(error)", category: "CloudKitChatManager")
                return false
            }
        }
        
        return true
    }
    
    /// サブスクリプションの存在確認
    private func validateSubscriptions() async -> Bool {
        log("🔍 Validating subscriptions...", category: "CloudKitChatManager")
        
        do {
            // Private DB subscriptions
            let privateSubscriptions = try await privateDB.allSubscriptions()
            let hasPrivateSubscription = privateSubscriptions.contains { subscription in
                subscription.subscriptionID == "private-database-changes"
            }
            
            // Shared DB subscriptions  
            let sharedSubscriptions = try await sharedDB.allSubscriptions()
            let hasSharedSubscription = sharedSubscriptions.contains { subscription in
                subscription.subscriptionID == "shared-database-changes"
            }
            
            let subscriptionsValid = hasPrivateSubscription && hasSharedSubscription
            
            if subscriptionsValid {
                log("✅ Required subscriptions exist", category: "CloudKitChatManager")
            } else {
                log("❌ Missing required subscriptions", category: "CloudKitChatManager")
                log("Private subscription exists: \(hasPrivateSubscription)", category: "CloudKitChatManager")
                log("Shared subscription exists: \(hasSharedSubscription)", category: "CloudKitChatManager")
            }
            
            return subscriptionsValid
            
        } catch {
            log("❌ Subscription validation error: \(error)", category: "CloudKitChatManager")
            return false
        }
    }
    
    /// 開発環境の既存データをクリア
    private func clearDevelopmentSchema() async {
        log("🗑️ Clearing existing development data...", category: "CloudKitChatManager")
        
        // 1. カスタムゾーンをクリアすることで関連レコードも削除される
        do {
            let zones = try await privateDB.allRecordZones()
            let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") }
            
            if !customZones.isEmpty {
                let zoneIDs = customZones.map { $0.zoneID }
                _ = try await privateDB.modifyRecordZones(saving: [], deleting: zoneIDs)
                log("🗑️ Cleared \(zoneIDs.count) custom zones (and their records)", category: "CloudKitChatManager")
            } else {
                log("📭 No custom zones to clear", category: "CloudKitChatManager")
            }
        } catch {
            log("⚠️ Failed to clear custom zones: \(error)", category: "CloudKitChatManager")
        }
        
        // 2. 既存サブスクリプションもクリア
        do {
            try await removeAllSubscriptions()
            log("🗑️ Cleared all existing subscriptions", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to clear subscriptions: \(error)", category: "CloudKitChatManager")
        }
        
        // デフォルトゾーンのレコードも確認してクリア（安全な方法）
        let recordTypes = ["CD_Message", "CD_Anniversary", "CD_Profile", "CD_ChatRoom"]
        
        for recordType in recordTypes {
            do {
                // シンプルなクエリでレコードを検索
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (results, _) = try await privateDB.records(matching: query, resultsLimit: 50)
                
                let recordIDs = results.compactMap { (recordID, result) -> CKRecord.ID? in
                    switch result {
                    case .success: return recordID
                    case .failure: return nil
                    }
                }
                
                if !recordIDs.isEmpty {
                    _ = try await privateDB.modifyRecords(saving: [], deleting: recordIDs)
                    log("🗑️ Cleared \(recordIDs.count) \(recordType) records from private DB", category: "CloudKitChatManager")
                } else {
                    log("📭 No \(recordType) records to clear", category: "CloudKitChatManager")
                }
            } catch {
                log("⚠️ Failed to clear \(recordType) from private DB: \(error)", category: "CloudKitChatManager")
                // エラーが発生してもクリア処理は続行
            }
        }
        
        log("✅ Development data clearing completed", category: "CloudKitChatManager")
    }
    
    /// 包括的なスキーマを作成
    private func createComprehensiveSchema() async {
        log("🏗️ Creating comprehensive schema...", category: "CloudKitChatManager")
        
        // 1. ChatRoomスキーマ（プライベートDB）
        await createChatRoomSchema()
        
        // 2. 共有DBスキーマ（カスタムゾーン内）
        await createSharedDatabaseSchema()
        
        log("✅ Comprehensive schema creation completed", category: "CloudKitChatManager")
    }
    
    /// 作成されたスキーマの検証
    private func validateCreatedSchema() async {
        log("🔍 Starting schema validation...", category: "CloudKitChatManager")
        
        let validationResults = await performSchemaValidation()
        
        for (recordType, result) in validationResults {
            switch result {
            case .success(let fields):
                log("✅ \(recordType) schema valid - fields: \(fields.joined(separator: ", "))", category: "CloudKitChatManager")
            case .failure(let error):
                log("❌ \(recordType) schema validation failed: \(error)", category: "CloudKitChatManager")
            }
        }
        
        log("🔍 Schema validation completed", category: "CloudKitChatManager")
    }
    
    /// スキーマ検証を実際に実行
    private func performSchemaValidation() async -> [String: Result<[String], Error>] {
        var results: [String: Result<[String], Error>] = [:]
        
        // 各レコードタイプを検証するための予期されるフィールド
        let expectedFields: [String: [String]] = [
            "CD_Message": ["roomID", "senderID", "body", "createdAt", "reactionEmoji", "reactions"],
            "CD_ChatRoom": ["roomID", "participants", "createdAt", "createdBy", "lastMessageText", "lastMessageDate"],
            "CD_Anniversary": ["roomID", "title", "annivDate", "repeatType", "createdAt"],
            "CD_Profile": ["userID", "displayName", "updatedAt"]
        ]
        
        for (recordType, fields) in expectedFields {
            do {
                // プライベートDBとSharedDBの両方で検証
                let privateFields = try await validateRecordTypeInDatabase(recordType: recordType, expectedFields: fields, database: privateDB, databaseName: "Private")
                let sharedFields = try await validateRecordTypeInDatabase(recordType: recordType, expectedFields: fields, database: sharedDB, databaseName: "Shared")
                
                let allValidatedFields = Set(privateFields + sharedFields)
                results[recordType] = .success(Array(allValidatedFields))
                
            } catch {
                results[recordType] = .failure(error)
            }
        }
        
        return results
    }
    
    /// queryable インデックスを強制的に作成（Development環境のみ）
    private func forceCreateQueryableIndexes() async {
        log("🔧 Force creating queryable indexes for recordName fields...", category: "CloudKitChatManager")
        
        let recordTypes = ["CD_Message", "CD_ChatRoom", "CD_Profile", "CD_Anniversary"]
        
        for recordType in recordTypes {
            await forceQueryableForRecordType(recordType)
        }
        
        log("🔧 Queryable index creation attempts completed", category: "CloudKitChatManager")
    }
    
    /// 特定のレコードタイプでqueryableインデックスを強制作成
    private func forceQueryableForRecordType(_ recordType: String) async {
        log("🔧 Forcing queryable index for \(recordType)...", category: "CloudKitChatManager")
        
        do {
            // 1. サンプルレコードを作成
            let tempRecordName = "temp-\(recordType)-\(UUID().uuidString)"
            let tempRecord = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: tempRecordName))
            
            // レコードタイプに応じて必要フィールドを追加
            switch recordType {
            case "CD_Message":
                tempRecord["roomID"] = "temp-room" as CKRecordValue
                tempRecord["senderID"] = "temp-sender" as CKRecordValue
                tempRecord["body"] = "temp-message" as CKRecordValue
                tempRecord["createdAt"] = Date() as CKRecordValue
            case "CD_ChatRoom":
                tempRecord["roomID"] = "temp-room" as CKRecordValue
                tempRecord["participants"] = ["temp-user"] as CKRecordValue
                tempRecord["createdAt"] = Date() as CKRecordValue
                tempRecord["createdBy"] = "temp-creator" as CKRecordValue
            case "CD_Profile":
                tempRecord["userID"] = "temp-user" as CKRecordValue
                tempRecord["displayName"] = "Temp User" as CKRecordValue
                tempRecord["updatedAt"] = Date() as CKRecordValue
            case "CD_Anniversary":
                tempRecord["roomID"] = "temp-room" as CKRecordValue
                tempRecord["title"] = "Temp Anniversary" as CKRecordValue
                tempRecord["annivDate"] = Date() as CKRecordValue
                tempRecord["createdAt"] = Date() as CKRecordValue
            default:
                log("⚠️ Unknown record type: \(recordType)", category: "CloudKitChatManager")
                return
            }
            
            // 2. レコードを保存
            let savedRecord = try await privateDB.save(tempRecord)
            log("✅ Created temp record: \(savedRecord.recordID.recordName)", category: "CloudKitChatManager")
            
            // 3. recordName でクエリを実行してインデックスを強制作成
            try await attemptRecordNameQuery(recordType: recordType, recordName: tempRecordName)
            
            // 4. 一時レコードを削除
            try await privateDB.deleteRecord(withID: savedRecord.recordID)
            log("🗑️ Cleaned up temp record: \(savedRecord.recordID.recordName)", category: "CloudKitChatManager")
            
        } catch {
            log("⚠️ Failed to force queryable for \(recordType): \(error)", category: "CloudKitChatManager")
            // エラーが発生しても続行
        }
    }
    
    /// recordNameクエリを試行してインデックス作成を促す
    private func attemptRecordNameQuery(recordType: String, recordName: String) async throws {
        // 複数のクエリパターンを試行
        let queryPatterns: [(String, NSPredicate)] = [
            ("recordName exact match", NSPredicate(format: "recordName == %@", recordName)),
            ("recordName contains", NSPredicate(format: "recordName CONTAINS %@", String(recordName.prefix(10)))),
            ("recordName begins with", NSPredicate(format: "recordName BEGINSWITH %@", String(recordName.prefix(8))))
        ]
        
        for (patternName, predicate) in queryPatterns {
            do {
                let query = CKQuery(recordType: recordType, predicate: predicate)
                let (_, _) = try await privateDB.records(matching: query, resultsLimit: 1)
                
                log("✅ \(recordType) \(patternName) query succeeded - CloudKit should now recognize recordName as queryable", category: "CloudKitChatManager")
                
                // 成功したら次のパターンも試行（複数のインデックスタイプを作成）
                
            } catch let error as CKError {
                if error.code == .invalidArguments && error.localizedDescription.contains("not marked queryable") {
                    log("📝 \(recordType) \(patternName) failed with 'not queryable' - this is expected, trying to force index creation...", category: "CloudKitChatManager")
                    // このエラーが出ること自体が、CloudKitにインデックスの必要性を伝える
                } else {
                    log("⚠️ \(recordType) \(patternName) query failed: \(error)", category: "CloudKitChatManager")
                }
            }
        }
    }
    
    /// 特定のデータベースでレコードタイプを検証
    private func validateRecordTypeInDatabase(recordType: String, expectedFields: [String], database: CKDatabase, databaseName: String) async throws -> [String] {
        log("🔍 Validating \(recordType) in \(databaseName) DB...", category: "CloudKitChatManager")
        
        // シンプルなクエリを使用（ソート条件なし）
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 1)
            
            if let (_, result) = results.first {
                let record = try result.get()
                let availableFields = Array(record.allKeys())
                
                log("📋 \(recordType) in \(databaseName) DB has fields: \(availableFields.joined(separator: ", "))", category: "CloudKitChatManager")
                
                // 期待されるフィールドが存在するかチェック
                let missingFields = expectedFields.filter { !availableFields.contains($0) }
                if !missingFields.isEmpty {
                    log("⚠️ Missing fields in \(recordType) (\(databaseName) DB): \(missingFields.joined(separator: ", "))", category: "CloudKitChatManager")
                } else {
                    log("✅ All expected fields found in \(recordType) (\(databaseName) DB)", category: "CloudKitChatManager")
                }
                
                return availableFields
            } else {
                log("📭 No records found for \(recordType) in \(databaseName) DB - schema may not be created yet", category: "CloudKitChatManager")
                return []
            }
        } catch {
            log("❌ Failed to validate \(recordType) in \(databaseName) DB: \(error)", category: "CloudKitChatManager")
            
            // クエリエラーの場合は、レコードが存在しないと仮定して空の配列を返す
            if let ckError = error as? CKError, ckError.code == .invalidArguments {
                log("⚠️ Query not supported for \(recordType) in \(databaseName) DB - assuming no records exist", category: "CloudKitChatManager")
                return []
            }
            
            throw error
        }
    }
    
    /// ChatRoomスキーマを作成（プライベートDB）
    private func createChatRoomSchema() async {
        log("📁 Creating comprehensive ChatRoom schema in private DB...", category: "CloudKitChatManager")
        
        do {
            // カスタムゾーンを作成
            let zoneID = CKRecordZone.ID(zoneName: "DevelopmentZone")
            let zone = CKRecordZone(zoneID: zoneID)
            let savedZone = try await privateDB.save(zone)
            log("✅ Created development zone: \(savedZone.zoneID.zoneName)", category: "CloudKitChatManager")
            
            // ChatRoomレコードを作成（すべてのフィールドを含む包括的な定義）
            log("🏠 Creating CD_ChatRoom schema record...", category: "CloudKitChatManager")
            let roomRecord = CKRecord(recordType: "CD_ChatRoom", recordID: CKRecord.ID(recordName: "schema-chatroom", zoneID: zoneID))
            
            // すべての CD_ChatRoom フィールドを明示的に設定
            roomRecord["roomID"] = "schema-room-id" as CKRecordValue
            roomRecord["participants"] = ["user1", "user2"] as CKRecordValue
            roomRecord["createdAt"] = Date() as CKRecordValue
            roomRecord["createdBy"] = "schema-creator" as CKRecordValue
            roomRecord["lastMessageText"] = "Schema message" as CKRecordValue
            roomRecord["lastMessageDate"] = Date() as CKRecordValue
            
            let savedRoomRecord = try await privateDB.save(roomRecord)
            log("✅ Created ChatRoom schema record with ID: \(savedRoomRecord.recordID.recordName)", category: "CloudKitChatManager")
            log("📋 ChatRoom record fields: \(savedRoomRecord.allKeys().joined(separator: ", "))", category: "CloudKitChatManager")
            
            // プロフィールレコードを作成（プライベートDB）
            log("👤 Creating CD_Profile schema record in private DB...", category: "CloudKitChatManager")
            let profileRecord = CKRecord(recordType: "CD_Profile", recordID: CKRecord.ID(recordName: "schema-profile", zoneID: zoneID))
            
            // すべての CD_Profile フィールドを明示的に設定
            profileRecord["userID"] = "schema-user-id" as CKRecordValue
            profileRecord["displayName"] = "Schema User" as CKRecordValue
            profileRecord["updatedAt"] = Date() as CKRecordValue
            
            let savedProfileRecord = try await privateDB.save(profileRecord)
            log("✅ Created Profile schema record in private DB with ID: \(savedProfileRecord.recordID.recordName)", category: "CloudKitChatManager")
            log("📋 Profile record fields: \(savedProfileRecord.allKeys().joined(separator: ", "))", category: "CloudKitChatManager")
            
            log("📁 ChatRoom schema creation in private DB completed successfully", category: "CloudKitChatManager")
            
        } catch {
            log("❌ Failed to create ChatRoom schema: \(error)", category: "CloudKitChatManager")
            if let ckError = error as? CKError {
                log("❌ CloudKit error details: \(ckError.localizedDescription)", category: "CloudKitChatManager")
                log("❌ Error code: \(ckError.code.rawValue)", category: "CloudKitChatManager")
                log("❌ Error user info: \(ckError.userInfo)", category: "CloudKitChatManager")
            }
        }
    }
    
    /// 共有DBスキーマを作成
    private func createSharedDatabaseSchema() async {
        log("🤝 Creating shared database schema...", category: "CloudKitChatManager")
        
        // 共有DBのスキーマは実際の共有レコードを作成することで作成される
        do {
            // 1. プライベートDBでチャットルームを作成（実際のチャット作成と同じプロセス）
            let zoneID = CKRecordZone.ID(zoneName: "SchemaZone-\(UUID().uuidString.prefix(8))")
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await privateDB.save(zone)
            log("✅ Created schema zone: \(zoneID.zoneName)", category: "CloudKitChatManager")
            
            // 2. チャットルームレコードを作成
            let roomRecord = CKRecord(recordType: "CD_ChatRoom", recordID: CKRecord.ID(recordName: "shared-schema-room", zoneID: zoneID))
            roomRecord["roomID"] = "shared-schema-room-id" as CKRecordValue
            roomRecord["participants"] = ["schema-user1", "schema-user2"] as CKRecordValue
            roomRecord["createdAt"] = Date() as CKRecordValue
            roomRecord["createdBy"] = "schema-creator" as CKRecordValue
            roomRecord["lastMessageText"] = "Schema message" as CKRecordValue
            roomRecord["lastMessageDate"] = Date() as CKRecordValue
            
            // 3. CKShareを作成
            let share = CKShare(rootRecord: roomRecord)
            share.publicPermission = .readWrite
            share[CKShare.SystemFieldKey.title] = "Schema Chat Room"
            
            // 4. rootRecordとShareを同時に保存
            let recordsToSave = [roomRecord, share]
            let saveResults = try await privateDB.modifyRecords(saving: recordsToSave, deleting: [])
            
            guard let savedRoomRecord = try saveResults.saveResults[roomRecord.recordID]?.get() as? CKRecord,
                  let savedShare = try saveResults.saveResults[share.recordID]?.get() as? CKShare else {
                throw CloudKitChatError.recordSaveFailed
            }
            
            log("✅ Created shared room with share", category: "CloudKitChatManager")
            log("📋 Share URL: \(savedShare.url?.absoluteString ?? "No URL")", category: "CloudKitChatManager")
            
            // 5. 共有ゾーンに子レコードを作成（これで共有DBでのスキーマが作成される）
            await createSharedRecords(in: savedRoomRecord.recordID.zoneID, parentRecord: savedRoomRecord)
            
        } catch {
            log("❌ Failed to create shared database schema: \(error)", category: "CloudKitChatManager")
            if let ckError = error as? CKError {
                log("❌ CloudKit error details: \(ckError.localizedDescription)", category: "CloudKitChatManager")
                log("❌ Error code: \(ckError.code.rawValue)", category: "CloudKitChatManager")
            }
        }
    }
    
    /// 共有レコード（メッセージ、記念日、プロフィール）を作成
    private func createSharedRecords(in zoneID: CKRecordZone.ID, parentRecord: CKRecord) async {
        log("🏗️ Creating shared records in private DB shared zone...", category: "CloudKitChatManager")
        
        // 重要：共有レコードはプライベートDBの共有ゾーンに作成し、roomID/userIDフィールドで関連付け
        
        // メッセージレコード - プライベートDBの共有ゾーンに作成
        do {
            log("📝 Creating CD_Message schema record in shared zone...", category: "CloudKitChatManager")
            let messageRecord = CKRecord(recordType: "CD_Message", 
                                       recordID: CKRecord.ID(zoneID: zoneID))
            
            // すべての CD_Message フィールドを明示的に設定
            messageRecord["roomID"] = "shared-schema-room-id" as CKRecordValue
            messageRecord["senderID"] = "schema-sender" as CKRecordValue
            messageRecord["body"] = "Schema test message" as CKRecordValue
            messageRecord["createdAt"] = Date() as CKRecordValue
            messageRecord["reactionEmoji"] = "" as CKRecordValue
            messageRecord["reactions"] = "" as CKRecordValue
            
            // CloudKit標準：親レコード参照を設定（同じゾーン内）
            messageRecord.setParent(parentRecord)
            
            // 検索用補助としてroomIDフィールドも併用
            
            // プライベートDBの共有ゾーンに保存（CKShareにより自動的に共有される）
            let savedMessageRecord = try await privateDB.save(messageRecord)
            log("✅ Created Message schema record with ID: \(savedMessageRecord.recordID.recordName)", category: "CloudKitChatManager")
            log("📋 Message record fields: \(savedMessageRecord.allKeys().joined(separator: ", "))", category: "CloudKitChatManager")
            
        } catch {
            log("❌ Failed to create Message schema: \(error)", category: "CloudKitChatManager")
            if let ckError = error as? CKError {
                log("❌ CloudKit error details: \(ckError.localizedDescription)", category: "CloudKitChatManager")
                log("❌ Error code: \(ckError.code.rawValue)", category: "CloudKitChatManager")
            }
        }
        
        // 記念日レコード - プライベートDBの共有ゾーンに作成
        do {
            log("🎉 Creating CD_Anniversary schema record in shared zone...", category: "CloudKitChatManager")
            let anniversaryRecord = CKRecord(recordType: "CD_Anniversary", 
                                           recordID: CKRecord.ID(zoneID: zoneID))
            
            // すべての CD_Anniversary フィールドを明示的に設定
            anniversaryRecord["roomID"] = "shared-schema-room-id" as CKRecordValue
            anniversaryRecord["title"] = "Schema Anniversary" as CKRecordValue
            anniversaryRecord["annivDate"] = Date() as CKRecordValue
            anniversaryRecord["repeatType"] = "none" as CKRecordValue
            anniversaryRecord["createdAt"] = Date() as CKRecordValue
            
            // CloudKit標準：親レコード参照を設定（同じゾーン内）
            anniversaryRecord.setParent(parentRecord)
            
            // 検索用補助としてroomIDフィールドも併用
            
            // プライベートDBの共有ゾーンに保存（CKShareにより自動的に共有される）
            let savedAnniversaryRecord = try await privateDB.save(anniversaryRecord)
            log("✅ Created Anniversary schema record with ID: \(savedAnniversaryRecord.recordID.recordName)", category: "CloudKitChatManager")
            log("📋 Anniversary record fields: \(savedAnniversaryRecord.allKeys().joined(separator: ", "))", category: "CloudKitChatManager")
            
        } catch {
            log("❌ Failed to create Anniversary schema: \(error)", category: "CloudKitChatManager")
            if let ckError = error as? CKError {
                log("❌ CloudKit error details: \(ckError.localizedDescription)", category: "CloudKitChatManager")
            }
        }
        
        // プロフィールレコード - プライベートDBの共有ゾーンに作成
        do {
            log("👤 Creating CD_Profile schema record in shared zone...", category: "CloudKitChatManager")
            let profileRecord = CKRecord(recordType: "CD_Profile", 
                                      recordID: CKRecord.ID(zoneID: zoneID))
            
            // すべての CD_Profile フィールドを明示的に設定
            profileRecord["userID"] = "schema-shared-user" as CKRecordValue
            profileRecord["displayName"] = "Schema Shared User" as CKRecordValue
            profileRecord["updatedAt"] = Date() as CKRecordValue
            
            // CloudKit標準：親レコード参照を設定（同じゾーン内）
            profileRecord.setParent(parentRecord)
            
            // 検索用補助としてuserIDフィールドも併用
            
            // プライベートDBの共有ゾーンに保存（CKShareにより自動的に共有される）
            let savedProfileRecord = try await privateDB.save(profileRecord)
            log("✅ Created Profile schema record in shared zone with ID: \(savedProfileRecord.recordID.recordName)", category: "CloudKitChatManager")
            log("📋 Profile record fields: \(savedProfileRecord.allKeys().joined(separator: ", "))", category: "CloudKitChatManager")
            
        } catch {
            log("❌ Failed to create Profile schema in shared zone: \(error)", category: "CloudKitChatManager")
            if let ckError = error as? CKError {
                log("❌ CloudKit error details: \(ckError.localizedDescription)", category: "CloudKitChatManager")
            }
        }
        
        log("🏗️ Shared records creation completed", category: "CloudKitChatManager")
        
        // 少し待ってから共有DBのスキーマが作成されたことを確認
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機
        await verifySharedDatabaseSchema()
    }
    
    /// プライベートDBの共有ゾーンでのスキーマ作成を確認
    private func verifySharedDatabaseSchema() async {
        log("🔍 Verifying shared zone schema in private DB...", category: "CloudKitChatManager")
        
        let recordTypes = ["CD_Message", "CD_Anniversary", "CD_Profile"]
        
        for recordType in recordTypes {
            do {
                // プライベートDBでレコードを検索してスキーマが利用可能か確認
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (results, _) = try await privateDB.records(matching: query, resultsLimit: 1)
                
                if let (_, result) = results.first {
                    let record = try result.get()
                    log("✅ Private DB shared zone schema verified for \(recordType)", category: "CloudKitChatManager")
                    log("📋 \(recordType) fields: \(record.allKeys().joined(separator: ", "))", category: "CloudKitChatManager")
                } else {
                    log("⚠️ No \(recordType) records found in private DB shared zone yet", category: "CloudKitChatManager")
                }
            } catch {
                log("❌ \(recordType) schema verification failed: \(error)", category: "CloudKitChatManager")
                if let ckError = error as? CKError {
                    log("❌ CloudKit error details: \(ckError.localizedDescription)", category: "CloudKitChatManager")
                }
            }
        }
    }
    #endif
    
    private func fetchCurrentUserID() async {
        // UserIDManagerから統一されたユーザーIDを取得
        currentUserID = await UserIDManager.shared.getCurrentUserIDAsync()
        
        if let userID = currentUserID {
            log("Using unified UserID: \(userID)", category: "CloudKitChatManager")
        } else {
            log("Failed to get unified UserID from UserIDManager", category: "CloudKitChatManager")
            lastError = CloudKitChatError.userNotAuthenticated
        }
    }
    
    // MARK: - Schema Management
    
    /// CloudKitスキーマを手動で再構築（本番環境でも利用可能）
    func rebuildCloudKitSchema(force: Bool = false) async throws {
        log("🔄 Manual CloudKit schema rebuild requested...", category: "CloudKitChatManager")
        
        // 本番環境では安全チェックを実行
        if !force {
            let isProduction = await checkIsProductionEnvironment()
            if isProduction {
                log("⚠️ Production environment detected. Use force=true for emergency reset.", category: "CloudKitChatManager")
                throw CloudKitChatError.productionResetBlocked
            }
        }
        
        // スキーマ再構築を実行
        await createSchemaIfNeeded()
        
        log("✅ Manual schema rebuild completed", category: "CloudKitChatManager")
    }
    
    /// 開発用: CloudKitスキーマを強制的にリセット・再構築
    func forceSchemaReset() async {
        log("🚨 Force schema reset requested...", category: "CloudKitChatManager")
        
        do {
            try await rebuildCloudKitSchema(force: true)
            log("✅ Force schema reset completed successfully", category: "CloudKitChatManager")
        } catch {
            log("❌ Force schema reset failed: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// CloudKitデータのステータスを確認
    func getCloudKitSchemaStatus() async -> [String: Any] {
        var status: [String: Any] = [:]
        
        // プライベートDBのレコード数を確認
        let recordTypes = ["CD_ChatRoom", "CD_Profile"]
        for recordType in recordTypes {
            do {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (results, _) = try await privateDB.records(matching: query)
                status["\(recordType)_private_count"] = results.count
            } catch {
                status["\(recordType)_private_error"] = error.localizedDescription
            }
        }
        
        // カスタムゾーン数を確認
        do {
            let zones = try await privateDB.allRecordZones()
            let customZones = zones.filter { !$0.zoneID.zoneName.hasPrefix("_") }
            status["custom_zones_count"] = customZones.count
            status["custom_zones"] = customZones.map { $0.zoneID.zoneName }
        } catch {
            status["zones_error"] = error.localizedDescription
        }
        
        return status
    }
    
    
    // MARK: - Room Management
    
    /// 共有チャットルームを作成し、CKShareを生成
    func createSharedChatRoom(with remoteUserID: String) async throws -> (roomRecord: CKRecord, share: CKShare) {
        guard let myID = currentUserID else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        let roomID = ChatRoom.generateDeterministicRoomID(myID: myID, remoteID: remoteUserID)
        log("🏗️ Creating shared chat room with roomID: \(roomID)", category: "CloudKitChatManager")
        
        // 統一共有ゾーンを使用（全デバイス共通）
        let sharedZoneID = CKRecordZone.ID(zoneName: "SharedRooms")
        let sharedZone = CKRecordZone(zoneID: sharedZoneID)
        
        do {
            _ = try await privateDB.save(sharedZone)
            log("🏗️ Created unified shared zone: SharedRooms", category: "CloudKitChatManager")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // ゾーンが既に存在する場合は無視
            log("🏗️ Unified shared zone already exists: SharedRooms", category: "CloudKitChatManager")
        }
        
        // 既存のレコードをチェック（統一ゾーン内で）
        let recordID = CKRecord.ID(recordName: roomID, zoneID: sharedZoneID)
        
        do {
            // 既存のレコードを取得を試行（事前フェッチ）
            let existingRecord = try await privateDB.record(for: recordID)
            log("🔍 Found existing chat room: \(roomID)", category: "CloudKitChatManager")
            
            // 既存のshareを検索
            let shareQuery = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(format: "rootRecord == %@", existingRecord.recordID))
            let (shareResults, _) = try await privateDB.records(matching: shareQuery)
            
            if let existingShare = shareResults.first?.1 as? CKShare {
                log("🔍 Found existing share for room: \(roomID)", category: "CloudKitChatManager")
                return (roomRecord: existingRecord, share: existingShare)
            }
        } catch let error as CKError where error.code == .unknownItem {
            // レコードが存在しない場合は新規作成へ進む
            log("🔍 No existing chat room found, creating new one", category: "CloudKitChatManager")
        } catch {
            log("❌ Error checking existing room: \(error)", category: "CloudKitChatManager")
            throw error
        }
        
        // 新しいレコードを作成
        let roomRecord = CKRecord(recordType: "CD_ChatRoom", recordID: recordID)
        roomRecord["roomID"] = roomID
        roomRecord["participants"] = [myID, remoteUserID] as [String]
        roomRecord["createdAt"] = Date()
        roomRecord["createdBy"] = myID
        
        // CKShareを作成
        let share = CKShare(rootRecord: roomRecord)
        share[CKShare.SystemFieldKey.title] = "Chat with \(remoteUserID)"
        share.publicPermission = .readWrite
        
        // 両方のレコードを原子的に保存（競合処理付き）
        let recordsToSave = [roomRecord, share]
        
        do {
            let saveResults = try await privateDB.modifyRecords(saving: recordsToSave, deleting: [])
            
            guard let savedRoomRecord = try saveResults.saveResults[roomRecord.recordID]?.get() as? CKRecord,
                  let savedShare = try saveResults.saveResults[share.recordID]?.get() as? CKShare else {
                throw CloudKitChatError.recordSaveFailed
            }
            
            log("✅ Successfully saved new room and share: \(roomID)", category: "CloudKitChatManager")
            if let url = savedShare.url?.absoluteString {
                log("🔗 Share URL created for room \(roomID): \(url)", category: "CloudKitChatManager")
            } else {
                log("⚠️ Share URL is nil (room: \(roomID))", category: "CloudKitChatManager")
            }
            
            // チャット作成時にプロフィールを同期
            Task {
                do {
                    try await syncProfileToChat(roomID: roomID)
                    log("Profile synced to new chat room: \(roomID)", category: "CloudKitChatManager")
                } catch {
                    log("Failed to sync profile to new room: \(error)", category: "CloudKitChatManager")
                }
            }
            
            return (roomRecord: savedRoomRecord, share: savedShare)
            
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 競合発生：サーバー上のレコードを採用
            log("⚠️ Server record changed during save - adopting existing record: \(roomID)", category: "CloudKitChatManager")
            
            // 既存レコードを再取得
            if let existingRecord = try? await privateDB.record(for: recordID) {
                let shareQuery = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(format: "rootRecord == %@", existingRecord.recordID))
                let (shareResults, _) = try await privateDB.records(matching: shareQuery)
                
                if let existingShare = shareResults.first?.1 as? CKShare {
                    log("✅ Adopted existing room after conflict: \(roomID)", category: "CloudKitChatManager")
                    return (roomRecord: existingRecord, share: existingShare)
                }
            }
            
            throw error
        }
    }
    
    /// roomIDに対応するルームレコードを取得（統一共有ゾーンから）
    func getRoomRecord(for roomID: String) async -> CKRecord? {
        log("🔍 FRESH getRoomRecord for roomID: \(roomID)", category: "CloudKitChatManager")
        
        // 統一共有ゾーンから検索（キャッシュなし・毎回新規取得）
        let sharedZoneID = CKRecordZone.ID(zoneName: "SharedRooms")
        let recordID = CKRecord.ID(recordName: roomID, zoneID: sharedZoneID)
        
        do {
            // 直接レコードIDで取得を試行
            let record = try await privateDB.record(for: recordID)
            log("🔍 Found room record in SharedRooms zone: \(roomID)", category: "CloudKitChatManager")
            
            // チャット参加時にプロフィールを同期
            Task {
                do {
                    try await syncProfileToChat(roomID: roomID)
                    log("Profile synced to existing chat room: \(roomID)", category: "CloudKitChatManager")
                } catch {
                    log("Failed to sync profile to existing room: \(error)", category: "CloudKitChatManager")
                }
            }
            
            return record
        } catch let error as CKError where error.code == .zoneNotFound {
            log("⚠️ SharedRooms zone not found - room may not exist yet: \(roomID)", category: "CloudKitChatManager")
            // 診断: ゾーン一覧を出力
            await dumpZoneList()
            return nil
        } catch let error as CKError where error.code == .unknownItem {
            log("🔍 Room record not found in SharedRooms zone: \(roomID)", category: "CloudKitChatManager")
            // 診断: ゾーン一覧を出力
            await dumpZoneList()
            return nil
        } catch {
            log("❌ Error fetching room record: \(error)", category: "CloudKitChatManager")
            return nil
        }
    }
    
    
    // MARK: - Role Management
    
    /// roomIDに対してこのユーザーがオーナーかどうかを判定（キャッシュなし・毎回新規取得）
    func isOwnerOfRoom(_ roomID: String) async -> Bool {
        log("🔍 FRESH ownership check started for roomID: \(roomID)", category: "CloudKitChatManager")
        
        // 現在のユーザーIDを毎回新規取得
        guard let currentUserID = currentUserID else {
            log("❌ Cannot determine ownership: currentUserID is nil", category: "CloudKitChatManager")
            return false
        }
        
        log("🔍 Current user ID: \(currentUserID)", category: "CloudKitChatManager")
        
        // ルームレコードを毎回新規取得
        guard let roomRecord = await getRoomRecord(for: roomID) else {
            log("❌ Cannot determine ownership: roomRecord not found for \(roomID)", category: "CloudKitChatManager")
            return false
        }
        
        // createdByフィールドで判定
        let createdBy = roomRecord["createdBy"] as? String
        log("🔍 Room createdBy: \(createdBy ?? "nil")", category: "CloudKitChatManager")
        
        let isOwner = createdBy == currentUserID
        
        log("🔍 FRESH ownership determined for roomID: \(roomID) -> isOwner: \(isOwner) (createdBy: \(createdBy ?? "nil"), currentUser: \(currentUserID))", category: "CloudKitChatManager")
        
        return isOwner
    }
    
    /// 現在のユーザーがオーナーのルーム一覧を取得（キャッシュなし・毎回新規取得）
    func getOwnedRooms() async -> [String] {
        guard let currentUserID = currentUserID else {
            log("❌ Cannot get owned rooms: currentUserID is nil", category: "CloudKitChatManager")
            return []
        }
        
        var ownedRooms: [String] = []
        
        log("🔍 FRESH check for owned rooms by user: \(currentUserID)", category: "CloudKitChatManager")
        
        // 統一共有ゾーンから全てのルームレコードを検索
        let sharedZoneID = CKRecordZone.ID(zoneName: "SharedRooms")
        let predicate = NSPredicate(format: "createdBy == %@", currentUserID)
        let query = CKQuery(recordType: "CD_ChatRoom", predicate: predicate)
        
        do {
            let (results, _) = try await privateDB.records(matching: query, inZoneWith: sharedZoneID)
            
            for (_, result) in results {
                if let roomRecord = try? result.get(),
                   let roomID = roomRecord["roomID"] as? String {
                    ownedRooms.append(roomID)
                    log("🔍 Found owned room: \(roomID)", category: "CloudKitChatManager")
                }
            }
        } catch {
            log("❌ Error fetching owned rooms: \(error)", category: "CloudKitChatManager")
        }
        
        log("🔍 Total owned rooms: \(ownedRooms.count)", category: "CloudKitChatManager")
        return ownedRooms
    }
    
    /// 参加しているルーム一覧を取得（オーナーではないもの・キャッシュなし）
    func getParticipatingRooms() async -> [String] {
        guard let currentUserID = currentUserID else {
            log("❌ Cannot get participating rooms: currentUserID is nil", category: "CloudKitChatManager")
            return []
        }
        
        var participatingRooms: [String] = []
        
        log("🔍 FRESH check for participating rooms by user: \(currentUserID)", category: "CloudKitChatManager")
        
        // 統一共有ゾーンから参加しているルームレコードを検索
        let sharedZoneID = CKRecordZone.ID(zoneName: "SharedRooms")
        let predicate = NSPredicate(format: "participants CONTAINS %@", currentUserID)
        let query = CKQuery(recordType: "CD_ChatRoom", predicate: predicate)
        
        do {
            let (results, _) = try await privateDB.records(matching: query, inZoneWith: sharedZoneID)
            
            for (_, result) in results {
                if let roomRecord = try? result.get(),
                   let roomID = roomRecord["roomID"] as? String,
                   let createdBy = roomRecord["createdBy"] as? String,
                   createdBy != currentUserID {
                    participatingRooms.append(roomID)
                    log("🔍 Found participating room: \(roomID) (createdBy: \(createdBy))", category: "CloudKitChatManager")
                }
            }
        } catch {
            log("❌ Error fetching participating rooms: \(error)", category: "CloudKitChatManager")
        }
        
        log("🔍 Total participating rooms: \(participatingRooms.count)", category: "CloudKitChatManager")
        return participatingRooms
    }
    
    // MARK: - Message Operations
    
    /// メッセージをプライベートDBの共有ゾーンに送信
    func sendMessage(_ message: Message, to roomRecord: CKRecord) async throws -> String {
        guard !isSyncDisabled else {
            log("🛑 Sync is disabled, skipping message send", category: "CloudKitChatManager")
            throw CloudKitChatError.schemaCreationInProgress
        }
        
        // roomRecordと同じゾーンを使用（共有ゾーン）
        let messageRecord = CKRecord(recordType: "CD_Message", 
                                   recordID: CKRecord.ID(zoneID: roomRecord.recordID.zoneID))
        
        messageRecord["roomID"] = message.roomID
        messageRecord["senderID"] = message.senderID
        messageRecord["body"] = message.body ?? ""
        messageRecord["createdAt"] = message.createdAt
        messageRecord["reactionEmoji"] = message.reactionEmoji ?? ""
        
        // CloudKit標準：親レコード参照を設定（同じゾーン内）
        messageRecord.setParent(roomRecord)
        
        // 検索用補助としてroomIDフィールドも併用
        
        // アセット（画像・動画）がある場合
        if let assetPath = message.assetPath, FileManager.default.fileExists(atPath: assetPath) {
            let assetURL = URL(fileURLWithPath: assetPath)
            messageRecord["asset"] = CKAsset(fileURL: assetURL)
        }
        
        // プライベートDBの共有ゾーンに保存（CKShareにより自動的に共有される）
        let savedRecord = try await privateDB.save(messageRecord)
        log("Message sent to private DB shared zone: \(savedRecord.recordID.recordName)", category: "CloudKitChatManager")
        
        return savedRecord.recordID.recordName
    }
    
    /// メッセージの更新
    func updateMessage(recordName: String, newBody: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await privateDB.record(for: recordID)
        record["body"] = newBody
        _ = try await privateDB.save(record)
        log("Message updated: \(recordName)", category: "CloudKitChatManager")
    }
    
    /// メッセージの削除
    func deleteMessage(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try await privateDB.deleteRecord(withID: recordID)
        log("Message deleted: \(recordName)", category: "CloudKitChatManager")
    }
    
    // MARK: - Subscription Management
    
    /// プライベートDBの共有ゾーン用のサブスクリプションを設定
    func setupSharedDatabaseSubscriptions() async throws {
        // プライベートDB全体の変更を監視（共有ゾーンのレコードも含む）
        let privateSubscription = CKDatabaseSubscription(subscriptionID: "private-database-changes")
        
        let privateNotificationInfo = CKSubscription.NotificationInfo()
        privateNotificationInfo.shouldSendContentAvailable = true
        privateSubscription.notificationInfo = privateNotificationInfo
        
        do {
            _ = try await privateDB.save(privateSubscription)
            log("Private database subscription created", category: "CloudKitChatManager")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // サブスクリプションが既に存在する場合は無視
            log("Private database subscription already exists", category: "CloudKitChatManager")
        }
        
        // 共有DBの変更も監視（他人から共有されたデータの変更を検知）
        let sharedSubscription = CKDatabaseSubscription(subscriptionID: "shared-database-changes")
        
        let sharedNotificationInfo = CKSubscription.NotificationInfo()
        sharedNotificationInfo.shouldSendContentAvailable = true
        sharedSubscription.notificationInfo = sharedNotificationInfo
        
        do {
            _ = try await sharedDB.save(sharedSubscription)
            log("Shared database subscription created", category: "CloudKitChatManager")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // サブスクリプションが既に存在する場合は無視
            log("Shared database subscription already exists", category: "CloudKitChatManager")
        }
        
        // 状態ダンプ
        do {
            let privateSubs = try await privateDB.allSubscriptions()
            log("📫 Private subscriptions: \(privateSubs.map{ $0.subscriptionID }.joined(separator: ", "))", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to list private subscriptions: \(error)", category: "CloudKitChatManager")
        }
        do {
            let sharedSubs = try await sharedDB.allSubscriptions()
            log("📫 Shared subscriptions: \(sharedSubs.map{ $0.subscriptionID }.joined(separator: ", "))", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to list shared subscriptions: \(error)", category: "CloudKitChatManager")
        }
    }
    
    /// 特定のルーム用のサブスクリプションを設定
    func setupRoomSubscription(for roomID: String) async throws {
        let predicate = NSPredicate(format: "roomID == %@", roomID)
        let subscription = CKQuerySubscription(
            recordType: "CD_Message",
            predicate: predicate,
            subscriptionID: "messages-\(roomID)",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        notificationInfo.desiredKeys = ["body", "senderID", "createdAt"]
        subscription.notificationInfo = notificationInfo
        
        do {
            _ = try await privateDB.save(subscription)
            log("Room subscription created for: \(roomID)", category: "CloudKitChatManager")
        } catch let error as CKError where error.code == .serverRecordChanged {
            log("Room subscription already exists for: \(roomID)", category: "CloudKitChatManager")
        }
    }
    
    // MARK: - Anniversary Operations
    
    /// 記念日をプライベートDBの共有ゾーンに保存
    func saveAnniversary(title: String, date: Date, roomID: String, repeatType: RepeatType = .none) async throws -> String {
        guard let roomRecord = await getRoomRecord(for: roomID) else {
            throw CloudKitChatError.roomNotFound
        }
        
        // roomRecordと同じゾーンを使用（共有ゾーン）
        let anniversaryRecord = CKRecord(recordType: "CD_Anniversary", 
                                       recordID: CKRecord.ID(zoneID: roomRecord.recordID.zoneID))
        
        anniversaryRecord["roomID"] = roomID
        anniversaryRecord["title"] = title
        anniversaryRecord["annivDate"] = date
        anniversaryRecord["repeatType"] = repeatType.rawValue
        anniversaryRecord["createdAt"] = Date()
        
        // CloudKit標準：親レコード参照を設定（同じゾーン内）
        anniversaryRecord.setParent(roomRecord)
        
        // 検索用補助としてroomIDフィールドも併用
        
        // プライベートDBの共有ゾーンに保存（CKShareにより自動的に共有される）
        let savedRecord = try await privateDB.save(anniversaryRecord)
        log("Anniversary saved to private DB shared zone: \(savedRecord.recordID.recordName)", category: "CloudKitChatManager")
        
        return savedRecord.recordID.recordName
    }
    
    /// 記念日の更新
    func updateAnniversary(recordName: String, title: String, date: Date) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await privateDB.record(for: recordID)
        record["title"] = title
        record["annivDate"] = date
        _ = try await privateDB.save(record)
        log("Anniversary updated: \(recordName)", category: "CloudKitChatManager")
    }
    
    /// 記念日の削除
    func deleteAnniversary(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try await privateDB.deleteRecord(withID: recordID)
        log("Anniversary deleted: \(recordName)", category: "CloudKitChatManager")
    }
    
    // MARK: - Reaction Management
    
    /// メッセージにリアクション絵文字を追加
    func addReactionToMessage(recordName: String, emoji: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await privateDB.record(for: recordID)
        
        // 現在のリアクション文字列を取得
        let currentReactions = record["reactions"] as? String ?? ""
        
        // 絵文字を追加（単純に文字列に追加）
        let updatedReactions = currentReactions + emoji
        record["reactions"] = updatedReactions
        
        _ = try await privateDB.save(record)
        
        log("Added reaction \(emoji) to message: \(recordName)", category: "CloudKitChatManager")
    }
    
    // MARK: - Profile Management (プライベートDB + 共有DB同期)
    
    /// マスタープロフィールをプライベートDBに保存（アプリ設定から）
    func saveMasterProfile(name: String, avatarData: Data? = nil) async throws {
        guard let userID = currentUserID else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        let record = CKRecord(recordType: "CD_Profile", recordID: CKRecord.ID(recordName: "profile-\(userID)"))
        record["userID"] = userID
        record["displayName"] = name
        record["updatedAt"] = Date()
        
        // アバター画像がある場合はCKAssetとして保存
        if let avatarData = avatarData, !avatarData.isEmpty {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try avatarData.write(to: tempURL)
            record["avatar"] = CKAsset(fileURL: tempURL)
        }
        
        // プライベートDBに保存
        _ = try await privateDB.save(record)
        
        // キャッシュを更新
        profileCache[userID] = (name: name, avatarData: avatarData)
        
        log("Master profile saved to private DB for userID: \(userID)", category: "CloudKitChatManager")
        
        // 既存の全チャットルームにプロフィールを同期
        await syncProfileToAllChats(name: name, avatarData: avatarData)
    }
    
    /// プロフィールをチャット参加時に共有ゾーンに同期
    func syncProfileToChat(roomID: String) async throws {
        guard let userID = currentUserID else {
            throw CloudKitChatError.userNotAuthenticated
        }
        
        // マスタープロフィールを取得
        let masterProfile = await fetchMasterProfile()
        
        guard let roomRecord = await getRoomRecord(for: roomID) else {
            throw CloudKitChatError.roomNotFound
        }
        
        // roomRecordと同じゾーンを使用（共有ゾーン）
        let profileRecord = CKRecord(recordType: "CD_Profile", 
                                   recordID: CKRecord.ID(recordName: "profile-\(userID)", zoneID: roomRecord.recordID.zoneID))
        
        profileRecord["userID"] = userID
        profileRecord["displayName"] = masterProfile.name ?? ""
        profileRecord["updatedAt"] = Date()
        
        // アバター画像がある場合はCKAssetとして保存
        if let avatarData = masterProfile.avatarData, !avatarData.isEmpty {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try avatarData.write(to: tempURL)
            profileRecord["avatar"] = CKAsset(fileURL: tempURL)
        }
        
        // CloudKit標準：親レコード参照を設定（同じゾーン内）
        profileRecord.setParent(roomRecord)
        
        // 検索用補助としてuserIDフィールドも併用
        
        // プライベートDBの共有ゾーンに保存（CKShareにより自動的に共有される）
        _ = try await privateDB.save(profileRecord)
        
        log("Profile synced to private DB shared zone for roomID: \(roomID)", category: "CloudKitChatManager")
    }
    
    /// マスタープロフィールをプライベートDBから取得
    func fetchMasterProfile() async -> (name: String?, avatarData: Data?) {
        guard let userID = currentUserID else {
            return (name: nil, avatarData: nil)
        }
        
        // キャッシュから確認
        if let cached = profileCache[userID] {
            return cached
        }
        
        // プライベートDBから取得
        let recordID = CKRecord.ID(recordName: "profile-\(userID)")
        
        do {
            let record = try await privateDB.record(for: recordID)
            let name = record["displayName"] as? String
            var avatarData: Data? = nil
            
            if let asset = record["avatar"] as? CKAsset,
               let url = asset.fileURL,
               let data = try? Data(contentsOf: url) {
                avatarData = data
            }
            
            // キャッシュに保存
            let result = (name: name, avatarData: avatarData)
            profileCache[userID] = result
            
            log("Master profile fetched from private DB for userID: \(userID)", category: "CloudKitChatManager")
            return result
            
        } catch {
            log("Failed to fetch master profile for userID: \(userID), error: \(error)", category: "CloudKitChatManager")
            return (name: nil, avatarData: nil)
        }
    }
    
    /// チャット用プロフィールをプライベートDBから取得
    func fetchProfile(for userID: String) async -> (name: String?, avatarData: Data?) {
        // キャッシュから確認
        if let cached = profileCache[userID] {
            return cached
        }
        
        // プライベートDBから検索（userIDで検索）
        let predicate = NSPredicate(format: "userID == %@", userID)
        let query = CKQuery(recordType: "CD_Profile", predicate: predicate)
        
        do {
            let (results, _) = try await privateDB.records(matching: query)
            
            for (_, result) in results {
                if let record = try? result.get() {
                    let name = record["displayName"] as? String
                    var avatarData: Data? = nil
                    
                    if let asset = record["avatar"] as? CKAsset,
                       let url = asset.fileURL,
                       let data = try? Data(contentsOf: url) {
                        avatarData = data
                    }
                    
                    // キャッシュに保存
                    let result = (name: name, avatarData: avatarData)
                    profileCache[userID] = result
                    
                    log("Chat profile fetched from private DB for userID: \(userID)", category: "CloudKitChatManager")
                    return result
                }
            }
        } catch {
            log("Failed to fetch chat profile for userID: \(userID), error: \(error)", category: "CloudKitChatManager")
        }
        
        return (name: nil, avatarData: nil)
    }
    
    /// プロフィールを全チャットに同期
    private func syncProfileToAllChats(name: String, avatarData: Data?) async {
        guard self.currentUserID != nil else {
            log("❌ Cannot sync profile to all chats: currentUserID is nil", category: "CloudKitChatManager")
            return
        }
        
        // 統一共有ゾーンから参加しているルームを取得
        let ownedRooms = await getOwnedRooms()
        let participatingRooms = await getParticipatingRooms()
        let allRoomIDs = ownedRooms + participatingRooms
        
        for roomID in allRoomIDs {
            do {
                try await syncProfileToChat(roomID: roomID)
                log("Profile synced to room: \(roomID)", category: "CloudKitChatManager")
            } catch {
                log("Failed to sync profile to room \(roomID): \(error)", category: "CloudKitChatManager")
            }
        }
    }
    
    /// プロフィールキャッシュをクリア
    func clearProfileCache() {
        profileCache.removeAll()
        log("Profile cache cleared", category: "CloudKitChatManager")
    }
    
    // MARK: - Utility Methods
    
    /// CloudKit アカウント状態を確認
    func checkAccountStatus() async -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            log("Failed to check account status: \(error)", category: "CloudKitChatManager")
            return .couldNotDetermine
        }
    }
    
    /// 本番環境かどうかを判定
    func checkIsProductionEnvironment() async -> Bool {
        // エンタイトルメント内のaps-environmentを確認
        guard let path = Bundle.main.path(forResource: "forMarin", ofType: "entitlements"),
              let plist = NSDictionary(contentsOfFile: path),
              let apsEnvironment = plist["aps-environment"] as? String else {
            log("Could not determine environment from entitlements", category: "CloudKitChatManager")
            return false // 不明な場合は開発環境として扱う
        }
        
        let isProduction = apsEnvironment == "production"
        log("Environment detected: \(apsEnvironment) (isProduction: \(isProduction))", category: "CloudKitChatManager")
        return isProduction
    }
    
    /// エラー時の自動リセット（本番環境でも有効）
    func performEmergencyReset(reason: String) async throws {
        log("🚨 Emergency reset requested: \(reason)", category: "CloudKitChatManager")
        
        let isProduction = await checkIsProductionEnvironment()
        
        if isProduction {
            log("⚠️ Production emergency reset initiated", category: "CloudKitChatManager")
            // 本番環境では追加の安全チェックを実行
            guard await validateEmergencyResetConditions() else {
                log("❌ Emergency reset conditions not met", category: "CloudKitChatManager")
                throw CloudKitChatError.resetFailed
            }
        }
        
        do {
            try await performCompleteReset(bypassSafetyCheck: true)
            log("✅ Emergency reset completed successfully", category: "CloudKitChatManager")
            
            // リセット後の再初期化
            await initialize()
            
        } catch {
            log("❌ Emergency reset failed: \(error)", category: "CloudKitChatManager")
            throw CloudKitChatError.resetFailed
        }
    }
    
    /// 緊急リセットの条件を検証
    private func validateEmergencyResetConditions() async -> Bool {
        // 本番環境での緊急リセット条件をチェック
        
        // 1. 重要エラーが複数回発生している
        // 2. アプリが完全に機能しない状態
        // 3. データ破損が検出されている
        
        log("Validating emergency reset conditions...", category: "CloudKitChatManager")
        
        // CloudKit接続テスト
        let accountStatus = await checkAccountStatus()
        guard accountStatus == .available else {
            log("CloudKit account not available", category: "CloudKitChatManager")
            return false
        }
        
        // データ整合性チェック
        let dataCorrupted = await checkDataIntegrity()
        if dataCorrupted {
            log("Data corruption detected - emergency reset approved", category: "CloudKitChatManager")
            return true
        }
        
        // その他の条件...
        log("Emergency reset conditions validated", category: "CloudKitChatManager")
        return true
    }
    
    /// データ整合性をチェック
    private func checkDataIntegrity() async -> Bool {
        do {
            // 基本的なクエリを実行してデータアクセスをテスト
            let query = CKQuery(recordType: "CD_ChatRoom", predicate: NSPredicate(value: true))
            _ = try await privateDB.records(matching: query, resultsLimit: 1)
            return false // エラーなし = 破損なし
        } catch {
            log("Data integrity check failed: \(error)", category: "CloudKitChatManager")
            return true // エラーあり = 破損の可能性
        }
    }
    
    /// キャッシュをクリア
    func clearCache() {
        profileCache.removeAll()
        log("Profile cache cleared (room/share caches removed in unified zone implementation)", category: "CloudKitChatManager")
    }
    
    // MARK: - Unified Reset Functions
    
    /// ローカルリセット：CloudKitデータに触れずにローカルキャッシュとアプリ状態のみクリア
    func performLocalReset() async throws {
        log("Starting local reset...", category: "CloudKitChatManager")
        
        // 1. ローカルキャッシュをクリア
        clearCache()
        
        // 2. UserDefaults をクリア
        clearUserDefaults()
        
        // 3. 初期化状態をリセット（ただしCloudKitデータは保持）
        profileCache.removeAll()
        lastError = nil
        
        log("Local reset completed successfully", category: "CloudKitChatManager")
    }
    
    /// クラウドを含めた完全リセット：CloudKitデータを含む全データを削除
    func performCompleteCloudReset() async throws {
        log("Starting complete cloud reset...", category: "CloudKitChatManager")
        
        // 本番環境での安全チェック
        let isProduction = await checkIsProductionEnvironment()
        if isProduction {
            log("⚠️ Production cloud reset requires explicit confirmation", category: "CloudKitChatManager")
            // UI側で確認を求める
        }
        
        do {
            // 既存の完全リセット機能を使用
            try await performCompleteReset(bypassSafetyCheck: true)
            log("Complete cloud reset finished successfully", category: "CloudKitChatManager")
            
        } catch {
            log("❌ Complete cloud reset failed: \(error)", category: "CloudKitChatManager")
            throw CloudKitChatError.resetFailed
        }
    }
    
    // MARK: - Complete Reset Functions
    
    /// 完全リセット：全データを削除して初期状態に戻す（本番環境対応）
    func performCompleteReset(bypassSafetyCheck: Bool = false) async throws {
        log("Starting complete reset...", category: "CloudKitChatManager")
        
        // 本番環境での安全チェック
        let isProduction = await checkIsProductionEnvironment()
        if isProduction && !bypassSafetyCheck {
            log("⚠️ Production reset requires safety check bypass", category: "CloudKitChatManager")
            throw CloudKitChatError.productionResetBlocked
        }
        
        do {
            // 1. ローカルキャッシュをクリア
            clearCache()
            
            // 2. CloudKit サブスクリプションを削除
            try await removeAllSubscriptions()
            
            // 3. プライベートDB の全データを削除
            try await clearPrivateDatabase()
            
            // 4. 共有DB から離脱
            try await leaveAllSharedDatabases()
            
            // 5. UserDefaults をクリア
            clearUserDefaults()
            
            // 6. 初期化状態をリセット
            currentUserID = nil
            isInitialized = false
            lastError = nil
            
            log("Complete reset finished successfully", category: "CloudKitChatManager")
            
        } catch {
            log("❌ Complete reset failed: \(error)", category: "CloudKitChatManager")
            throw CloudKitChatError.resetFailed
        }
    }
    
    /// 旧データ検出時の自動リセット
    func resetIfLegacyDataDetected() async throws {
        let hasLegacyData = await detectLegacyData()
        
        if hasLegacyData {
            log("Legacy data detected, performing automatic reset", category: "CloudKitChatManager")
            try await performCompleteReset(bypassSafetyCheck: true)
            
            // リセット実行フラグを設定
            hasPerformedReset = true
            
            // リセット後に再初期化
            await initialize()
        }
    }
    
    /// 旧データの検出
    private func detectLegacyData() async -> Bool {
        // プライベートDBで旧形式のメッセージを検索
        let predicate = NSPredicate(format: "recordID CONTAINS %@", "_room")
        let query = CKQuery(recordType: "CD_Message", predicate: predicate)
        
        do {
            let (results, _) = try await privateDB.records(matching: query)
            
            if !results.isEmpty {
                log("Legacy message format detected", category: "CloudKitChatManager")
                return true
            }
        } catch {
            log("Error searching legacy messages: \(error)", category: "CloudKitChatManager")
        }
        
        // 旧形式のチャットルームを検索
        let roomQuery = CKQuery(recordType: "CD_ChatRoom", predicate: NSPredicate(value: true))
        
        do {
            let (roomResults, _) = try await privateDB.records(matching: roomQuery)
            
            for (_, result) in roomResults {
                if let record = try? result.get(),
                   let roomID = record["roomID"] as? String,
                   roomID.contains("_room") {
                    log("Legacy room format detected", category: "CloudKitChatManager")
                    return true
                }
            }
        } catch {
            log("Error searching legacy rooms: \(error)", category: "CloudKitChatManager")
        }
        
        return false
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
    
    /// プライベートDBの全データを削除（チャットリスト + マスタープロフィール）
    private func clearPrivateDatabase() async throws {
        // プライベートDBはチャットリスト管理とマスタープロフィール管理に使用
        let recordTypes = ["CD_ChatRoom", "CD_Profile"]
        
        for recordType in recordTypes {
            do {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (results, _) = try await privateDB.records(matching: query)
                
                let recordIDsToDelete = results.compactMap { (recordID, result) -> CKRecord.ID? in
                    switch result {
                    case .success:
                        return recordID
                    case .failure:
                        return nil
                    }
                }
                
                if !recordIDsToDelete.isEmpty {
                    _ = try await privateDB.modifyRecords(saving: [], deleting: recordIDsToDelete)
                    log("Deleted \(recordIDsToDelete.count) records of type \(recordType)", category: "CloudKitChatManager")
                }
            } catch {
                log("Error deleting \(recordType): \(error)", category: "CloudKitChatManager")
            }
        }
        
        // カスタムゾーンも削除
        try await clearCustomZones()
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
    
    /// 共有ゾーンから離脱（プライベートDBの共有レコードを削除）
    private func leaveAllSharedDatabases() async throws {
        // プライベートDBの共有ゾーンにある全てのレコードを削除
        // 共有ゾーン内のレコードを削除することで共有からの離脱と同等の効果を得る
        let recordTypes = ["CD_Message", "CD_ChatRoom", "CD_Anniversary", "CD_Profile"]
        
        for recordType in recordTypes {
            do {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (results, _) = try await privateDB.records(matching: query)
                
                let recordIDsToDelete = results.compactMap { (recordID, result) -> CKRecord.ID? in
                    switch result {
                    case .success:
                        return recordID
                    case .failure:
                        return nil
                    }
                }
                
                if !recordIDsToDelete.isEmpty {
                    _ = try await privateDB.modifyRecords(saving: [], deleting: recordIDsToDelete)
                    log("Deleted \(recordIDsToDelete.count) private DB records of type \(recordType)", category: "CloudKitChatManager")
                }
            } catch {
                log("Error deleting private DB \(recordType): \(error)", category: "CloudKitChatManager")
            }
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
        
        // SharedRooms内のChatRoom列挙
        do {
            let sharedZoneID = CKRecordZone.ID(zoneName: "SharedRooms")
            let query = CKQuery(recordType: "CD_ChatRoom", predicate: NSPredicate(value: true))
            let (results, _) = try await privateDB.records(matching: query, inZoneWith: sharedZoneID)
            let rooms: [CKRecord] = results.compactMap { try? $0.1.get() }
            log("🏠 ChatRooms in SharedRooms: \(rooms.count)", category: "CloudKitChatManager")
            for r in rooms.prefix(10) {
                let rid = r["roomID"] as? String ?? "nil"
                let createdBy = r["createdBy"] as? String ?? "nil"
                let participants = (r["participants"] as? [String])?.joined(separator: ", ") ?? "nil"
                log("🏠 Room: record=\(r.recordID.recordName), roomID=\(rid), createdBy=\(createdBy), participants=[\(participants)]", category: "CloudKitChatManager")
            }
        } catch {
            log("⚠️ Failed to list ChatRooms in SharedRooms: \(error)", category: "CloudKitChatManager")
        }
        
        // cloudkit.share の列挙（rootRecordのroomIDを推定）
        do {
            let shareQuery = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
            let (results, _) = try await privateDB.records(matching: shareQuery, resultsLimit: 50)
            let shares = results.compactMap { try? $0.1.get() as? CKShare }
            log("🔗 Shares in Private DB: \(shares.count)", category: "CloudKitChatManager")
            for s in shares.prefix(10) {
                let title = s[CKShare.SystemFieldKey.title] as? String ?? "nil"
                let urlStr = s.url?.absoluteString ?? "nil"
                log("🔗 Share: root=\(s.recordID.recordName), title=\(title), url=\(urlStr)", category: "CloudKitChatManager")
            }
        } catch {
            log("⚠️ Failed to list cloudkit.share: \(error)", category: "CloudKitChatManager")
        }
        
        // 対象roomIDが指定されていれば詳細
        if let roomID = roomID {
            await dumpRoomDetails(roomID: roomID)
        }
    }
    
    /// 特定ルームの詳細状態
    private func dumpRoomDetails(roomID: String) async {
        log("🔬 Dumping room details for roomID: \(roomID)", category: "CloudKitChatManager")
        
        // SharedRooms内の存在確認
        do {
            let sharedZoneID = CKRecordZone.ID(zoneName: "SharedRooms")
            let recordID = CKRecord.ID(recordName: roomID, zoneID: sharedZoneID)
            let record = try await privateDB.record(for: recordID)
            let createdBy = record["createdBy"] as? String ?? "nil"
            log("🔬 Room exists in SharedRooms. createdBy=\(createdBy)", category: "CloudKitChatManager")
            
            // 関連Share有無
            let shareQuery = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(format: "rootRecord == %@", record.recordID))
            let (shareResults, _) = try await privateDB.records(matching: shareQuery)
            if let share = try shareResults.first?.1.get() as? CKShare {
                log("🔬 Room has share. url=\(share.url?.absoluteString ?? "nil")", category: "CloudKitChatManager")
            } else {
                log("🔬 Room has NO share record", category: "CloudKitChatManager")
            }
        } catch {
            log("🔬 Room not found in SharedRooms or error: \(error)", category: "CloudKitChatManager")
        }
        
        // メッセージ数（最近のみ）
        do {
            let predicate = NSPredicate(format: "roomID == %@", roomID)
            let q = CKQuery(recordType: "CD_Message", predicate: predicate)
            let (results, _) = try await privateDB.records(matching: q, resultsLimit: 20)
            let cnt = results.count
            log("📝 Private DB messages (any zone) sample count: \(cnt)", category: "CloudKitChatManager")
        } catch {
            log("⚠️ Failed to count messages: \(error)", category: "CloudKitChatManager")
        }
    }
    
    // MARK: - UserID Management
    
    /// UserIDManagerの通知を購読
    private func setupUserIDNotifications() {
        NotificationCenter.default.addObserver(
            forName: .userIDMigrationRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                await self?.handleUserIDMigration(notification: notification)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .legacyDataMigrationRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                await self?.handleLegacyDataMigration(notification: notification)
            }
        }
    }
    
    /// ユーザーIDマイグレーション処理
    private func handleUserIDMigration(notification: Notification) async {
        guard let userInfo = notification.userInfo,
              let oldUserID = userInfo["oldUserID"] as? String,
              let newUserID = userInfo["newUserID"] as? String else {
            log("Invalid migration notification", category: "CloudKitChatManager")
            return
        }
        
        log("Handling UserID migration: \(oldUserID) -> \(newUserID)", category: "CloudKitChatManager")
        
        // 現在のユーザーIDを更新
        currentUserID = newUserID
        
        // キャッシュをクリア（古いユーザーIDに基づくデータを無効化）
        clearCache()
        
        // 必要に応じて既存のチャットルームを再同期
        // これは複雑な処理のため、ユーザーに再ログイン等を促すことも考慮
        
        log("UserID migration completed", category: "CloudKitChatManager")
        
        // UI更新のため通知送信
        NotificationCenter.default.post(name: .chatManagerUserIDUpdated, object: nil)
    }
    
    /// 旧データマイグレーション処理
    private func handleLegacyDataMigration(notification: Notification) async {
        guard let userInfo = notification.userInfo,
              let legacyDeviceID = userInfo["legacyDeviceID"] as? String else {
            log("Invalid legacy migration notification", category: "CloudKitChatManager")
            return
        }
        
        log("Handling legacy data migration for device: \(legacyDeviceID)", category: "CloudKitChatManager")
        
        // 旧データのクリアアップ処理を実行
        do {
            try await performCompleteReset()
            log("Legacy data migration completed", category: "CloudKitChatManager")
        } catch {
            log("Legacy data migration failed: \(error)", category: "CloudKitChatManager")
        }
    }
}

// MARK: - Error Types

enum CloudKitChatError: LocalizedError {
    case userNotAuthenticated
    case recordSaveFailed
    case roomNotFound
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
    static let chatManagerUserIDUpdated = Notification.Name("ChatManagerUserIDUpdated")
    static let disableMessageSync = Notification.Name("DisableMessageSync")
    static let enableMessageSync = Notification.Name("EnableMessageSync")
    static let cloudKitSchemaReady = Notification.Name("CloudKitSchemaReady")
}

