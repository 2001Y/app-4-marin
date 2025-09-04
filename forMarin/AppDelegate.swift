import UIKit
import UserNotifications
import CloudKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let launchOptions {
            let keys = launchOptions.keys.map { "\($0.rawValue)" }.joined(separator: ", ")
            log("[LAUNCH] LaunchOptions keys: [\(keys)]", category: "AppDelegate")
            if let meta = launchOptions[.cloudKitShareMetadata] as? CKShare.Metadata {
                log("[LAUNCH] Found CKShare.Metadata in launchOptions. Container=\(meta.containerIdentifier)", category: "AppDelegate")
                CloudKitShareHandler.shared.acceptShare(from: meta)
            }
        }
        
        // オフライン検知機能の初期化（通知権限のみ）
        Task {
            await NotificationManager.shared.requestAuthorizationIfNeeded()
        }
        
        // 権限取得後にremote notification登録は自動で行われる
        // 他アプリのオーディオ再生を止めない AVAudioSession 設定
        AudioSessionManager.configureForAmbient()
        
        // CloudKit subscriptions setup (共有DB使用)
        Task {
            // CloudKitChatManagerの初期化と共有データベースサブスクリプション設定
            _ = CloudKitChatManager.shared
            try? await CloudKitChatManager.shared.setupSharedDatabaseSubscriptions()
            try? await CloudKitChatManager.shared.setupPrivateDatabaseSubscription()
            log("CloudKitChatManager initialized with DB subscriptions (shared/private)", category: "AppDelegate")

            // Start CKSyncEngine (iOS 17+)
            if #available(iOS 17.0, *) {
                await CKSyncEngineManager.shared.start()
                log("CKSyncEngine started (private/shared)", category: "AppDelegate")
            }
        }
        
        // Initialize MessageSyncService (iOS 17+ 前提)
        _ = MessageSyncService.shared
        log("MessageSyncService initialized", category: "AppDelegate")
        
        // Register for remote notifications
        application.registerForRemoteNotifications()
        
        return true
    }

    // MARK: - UIScene configuration (to ensure share acceptance callback on iOS 13+)
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        log("Configuring UIScene with our SceneDelegate", category: "AppDelegate")
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        // SceneDelegate で share 受諾コールバックを確実に受ける
        config.delegateClass = SceneDelegate.self
        return config
    }

    // 追加ログ: URLオープン経路の可視化（CloudKit招待URLならフォールバック受諾も実行）
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        log("[URL OPEN] AppDelegate received URL: \(url)", category: "AppDelegate")
        if url.host?.contains("icloud.com") == true {
            Task { @MainActor in
                let ok = await InvitationManager.shared.acceptInvitation(from: url)
                log("[URL OPEN] In-app accept result: \(ok)", category: "AppDelegate")
            }
            return true
        }
        return false
    }

    // MARK: - CloudKit Share Acceptance (Zone Sharing)
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        log("🚨 [INVITATION RECEIVED] === CloudKit Share Invitation Received in AppDelegate ===", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] This method is called when user taps a CloudKit share URL", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] Share URL: \(cloudKitShareMetadata.share.url?.absoluteString ?? "nil")", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] Container ID: \(cloudKitShareMetadata.containerIdentifier)", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] Owner: \(cloudKitShareMetadata.ownerIdentity.nameComponents?.formatted() ?? "nil")", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] Share RecordID: \(cloudKitShareMetadata.share.recordID.recordName)", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] Share ZoneID: \(cloudKitShareMetadata.share.recordID.zoneID.zoneName)", category: "AppDelegate")
        
        if let rootRecord = cloudKitShareMetadata.rootRecord {
            log("🚨 [INVITATION RECEIVED] Root Record Type: \(rootRecord.recordType)", category: "AppDelegate")
            log("🚨 [INVITATION RECEIVED] Root Record ID: \(rootRecord.recordID.recordName)", category: "AppDelegate")
            log("🚨 [INVITATION RECEIVED] Root Record Zone: \(rootRecord.recordID.zoneID.zoneName)", category: "AppDelegate")
        }
        
        log("➡️ [INVITATION RECEIVED] Delegating to CloudKitShareHandler for processing", category: "AppDelegate")
        log("🚨 [INVITATION RECEIVED] === End AppDelegate Invitation Analysis ===", category: "AppDelegate")
        
        CloudKitShareHandler.shared.acceptShare(from: cloudKitShareMetadata)
        
        log("✅ [INVITATION RECEIVED] Delegation completed - monitoring CloudKitShareHandler logs", category: "AppDelegate")
    }
    
    // 通知がタップされたときの処理
    func userNotificationCenter(_ center: UNUserNotificationCenter, 
                              didReceive response: UNNotificationResponse, 
                              withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let action = userInfo["action"] as? String, action == "showOfflineModal" {
            // メインスレッドでモーダル表示
            DispatchQueue.main.async {
                // ConnectivityManagerのシングルトンインスタンスに通知
                NotificationCenter.default.post(name: .showOfflineModal, object: nil)
            }
        }
        
        completionHandler()
    }
    
    // アプリがフォアグラウンドにあるときの通知処理
    func userNotificationCenter(_ center: UNUserNotificationCenter, 
                              willPresent notification: UNNotification, 
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // フォアグラウンド時も通知を表示（iOS 17+ 前提）
        completionHandler([.banner, .list, .sound, .badge])
    }

    @MainActor
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any]) async -> UIBackgroundFetchResult {
        log("Received remote notification: \(userInfo)", category: "AppDelegate")
        
        // Handle CloudKit notifications
        if let cloudKitNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            log("CloudKit notification type: \(cloudKitNotification.notificationType)", category: "AppDelegate")
            
            // iOS 17+: 可能ならルーム限定の再フェッチ（Query/Zone通知）に切替
            // iOS17+ 前提: 可能ならルーム限定の再フェッチ（Query/Zone通知）に切替
            if let queryNotif = cloudKitNotification as? CKQueryNotification,
               let zoneID = queryNotif.recordID?.zoneID {
                let roomID = zoneID.zoneName
                log("Targeted sync via CKQueryNotification for roomID: \(roomID)", category: "AppDelegate")
                MessageSyncService.shared.checkForUpdates(roomID: roomID)
                // P2Pシグナリングも即時確認（ゾーン変化＝RTCSignalの可能性）
                P2PController.shared.onZoneChanged(roomID: roomID)
                return .newData
            }
            if let zoneNotif = cloudKitNotification as? CKRecordZoneNotification,
               let zoneID = zoneNotif.recordZoneID {
                let roomID = zoneID.zoneName
                log("Targeted sync via CKRecordZoneNotification for roomID: \(roomID)", category: "AppDelegate")
                MessageSyncService.shared.checkForUpdates(roomID: roomID)
                P2PController.shared.onZoneChanged(roomID: roomID)
                return .newData
            }
            // Database通知など（共有DB）は対象不明 → 全体チェック
            MessageSyncService.shared.checkForUpdates()
            log("Triggered MessageSyncService global update (database notification)", category: "AppDelegate")
            // 共有DBのDatabase通知には 'ck.met.zid' が含まれることがあるため、可能ならP2Pにも転送
            if let ck = userInfo["ck"] as? [String: Any],
               let met = ck["met"] as? [String: Any],
               let zid = met["zid"] as? String, !zid.isEmpty {
                P2PController.shared.onZoneChanged(roomID: zid)
            }
            return .newData
        }
        
        // No CloudKit notification found
        return .noData
    }
    
    // MARK: - Push Notification Registration
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log("Successfully registered for remote notifications", category: "AppDelegate")
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        log("Device token: \(tokenString)", category: "AppDelegate")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log("Failed to register for remote notifications: \(error)", category: "AppDelegate")
    }
} 
