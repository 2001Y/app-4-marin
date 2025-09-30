import Foundation
import CloudKit
import UIKit
import SwiftData

/// ユーザーID統一管理クラス
/// CloudKit UserIDとデバイスIDの統合管理を行い、アプリ全体で一貫したユーザー識別を提供
@MainActor
class UserIDManager: ObservableObject {
    static let shared = UserIDManager()
    
    private let container = CloudKitChatManager.shared.containerForSharing
    
    @Published private(set) var unifiedUserID: String?
    @Published private(set) var isInitialized: Bool = false
    @Published private(set) var initializationError: Error?
    
    // UserDefaults keys
    private enum Keys {
        static let unifiedUserID = "UnifiedUserID"
        static let legacyDeviceID = "LegacyDeviceID" 
        static let cloudKitUserID = "CloudKitUserID"
        static let migrationCompleted = "UserIDMigrationCompleted_v1"
    }
    
    private init() {
        // 保存されたユーザーIDを復元
        if let savedID = UserDefaults.standard.string(forKey: Keys.unifiedUserID) {
            unifiedUserID = savedID
            isInitialized = true
        }
        
        Task {
            await initializeUserID()
        }
    }
    
    // MARK: - Initialization
    
    /// ユーザーIDを初期化（CloudKit優先、フォールバックでデバイスID）
    func initializeUserID() async {
        do {
            // 1. CloudKit UserIDを取得を試行
            let cloudKitUserID = try await fetchCloudKitUserID()
            
            // 2. 既存の統一IDと比較
            if let existingID = unifiedUserID {
                // 既存IDがCloudKit IDと異なる場合、マイグレーションが必要
                if existingID != cloudKitUserID {
                    log("CloudKit ID changed: \(existingID) -> \(cloudKitUserID)", category: "UserIDManager")
                    await performUserIDMigration(from: existingID, to: cloudKitUserID)
                }
            } else {
                // 初回起動時
                setUnifiedUserID(cloudKitUserID)
            }
            
            // 3. CloudKit UserIDを保存
            UserDefaults.standard.set(cloudKitUserID, forKey: Keys.cloudKitUserID)
            
            initializationError = nil
            isInitialized = true
            
            log("Successfully initialized with CloudKit UserID: \(cloudKitUserID)", category: "UserIDManager")
            
        } catch {
            log("⚠️ [AUTO FIX] CloudKit UserID fetch failed: \(error)", category: "UserIDManager")
            log("CloudKit is required - no fallback to device ID", category: "UserIDManager")
            
            initializationError = error
            isInitialized = true
        }
        
        // マイグレーション処理（必要に応じて）
        await performLegacyMigrationIfNeeded()
    }
    
    private func fetchCloudKitUserID() async throws -> String {
        let recordID = try await container.userRecordID()
        return recordID.recordName
    }
    
    
    private func setUnifiedUserID(_ userID: String) {
        unifiedUserID = userID
        UserDefaults.standard.set(userID, forKey: Keys.unifiedUserID)
        log("Set unified UserID: \(userID)", category: "UserIDManager")
    }
    
    // MARK: - Migration
    
    /// ユーザーIDマイグレーション処理
    private func performUserIDMigration(from oldID: String, to newID: String) async {
        log("Starting UserID migration: \(oldID) -> \(newID)", category: "UserIDManager")
        
        // 新しいIDを設定
        setUnifiedUserID(newID)
        
        // CloudKitChatManagerに通知してルームIDを再生成
        NotificationCenter.default.post(
            name: .userIDMigrationRequired,
            object: nil,
            userInfo: [
                "oldUserID": oldID,
                "newUserID": newID
            ]
        )
        
        log("UserID migration completed", category: "UserIDManager")
    }
    
    /// 旧バージョンからのマイグレーション処理
    private func performLegacyMigrationIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Keys.migrationCompleted) else {
            return
        }
        
        log("Performing legacy migration...", category: "UserIDManager")
        
        // 旧デバイスIDベースのデータを検出
        let oldDeviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        UserDefaults.standard.set(oldDeviceID, forKey: Keys.legacyDeviceID)
        
        // CloudKitChatManagerに旧データクリアを通知
        NotificationCenter.default.post(
            name: .legacyDataMigrationRequired,
            object: nil,
            userInfo: ["legacyDeviceID": oldDeviceID]
        )
        
        UserDefaults.standard.set(true, forKey: Keys.migrationCompleted)
        log("Legacy migration completed", category: "UserIDManager")
    }
    
    // MARK: - Public API
    
    /// 現在の統一ユーザーIDを取得
    func getCurrentUserID() -> String? {
        return unifiedUserID
    }
    
    /// 統一ユーザーIDを取得（非同期、初期化完了まで待機）
    func getCurrentUserIDAsync() async -> String? {
        // 初期化完了まで待機
        while !isInitialized {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒待機
        }
        return unifiedUserID
    }
    
    /// 強制的にユーザーIDを再初期化
    func forceReinitialize() async {
        isInitialized = false
        unifiedUserID = nil
        UserDefaults.standard.removeObject(forKey: Keys.unifiedUserID)
        
        await initializeUserID()
    }
    
    /// デバッグ情報取得
    func getDebugInfo() -> [String: Any] {
        return [
            "unifiedUserID": unifiedUserID ?? "nil",
            "isInitialized": isInitialized,
            "cloudKitUserID": UserDefaults.standard.string(forKey: Keys.cloudKitUserID) ?? "nil",
            "legacyDeviceID": UserDefaults.standard.string(forKey: Keys.legacyDeviceID) ?? "nil",
            "migrationCompleted": UserDefaults.standard.bool(forKey: Keys.migrationCompleted),
            "initializationError": initializationError?.localizedDescription ?? "nil"
        ]
    }
    
    /// ユーザーIDリセット（テスト用）
    func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: Keys.unifiedUserID)
        UserDefaults.standard.removeObject(forKey: Keys.cloudKitUserID)
        UserDefaults.standard.removeObject(forKey: Keys.legacyDeviceID)
        UserDefaults.standard.removeObject(forKey: Keys.migrationCompleted)
        
        unifiedUserID = nil
        isInitialized = false
        initializationError = nil
        
        log("Reset completed for testing", category: "UserIDManager")
    }
    
    
    // MARK: - CloudKit Account Status
    
    /// CloudKitアカウント状態を確認
    func checkCloudKitAccountStatus() async -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            log("Failed to check CloudKit account status: \(error)", category: "UserIDManager")
            return .couldNotDetermine
        }
    }
    
    /// CloudKitが利用可能かチェック
    func isCloudKitAvailable() async -> Bool {
        let status = await checkCloudKitAccountStatus()
        return status == .available
    }
}

// MARK: - Error Types

enum UserIDError: LocalizedError {
    case cloudKitUnavailable
    case invalidUserID
    
    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            return "CloudKitが利用できません"
        case .invalidUserID:
            return "無効なユーザーIDです"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let userIDMigrationRequired = Notification.Name("UserIDMigrationRequired")
    static let legacyDataMigrationRequired = Notification.Name("LegacyDataMigrationRequired")
    static let userIDInitialized = Notification.Name("UserIDInitialized")
}

// MARK: - Migration Helper

struct UserIDMigrationInfo {
    let oldUserID: String
    let newUserID: String
    let migrationDate: Date
    
    init(oldUserID: String, newUserID: String) {
        self.oldUserID = oldUserID
        self.newUserID = newUserID
        self.migrationDate = Date()
    }
}
