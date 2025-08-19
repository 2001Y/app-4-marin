import UIKit
import UserNotifications
import CloudKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        
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
            log("CloudKitChatManager initialized with shared DB subscriptions", category: "AppDelegate")
        }
        
        // Initialize MessageSyncService for iOS 17+
        if #available(iOS 17.0, *) {
            _ = MessageSyncService.shared
            log("MessageSyncService initialized", category: "AppDelegate")
        }
        
        // Register for remote notifications
        application.registerForRemoteNotifications()
        
        return true
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
        // フォアグラウンド時も通知を表示
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    @MainActor
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any]) async -> UIBackgroundFetchResult {
        log("Received remote notification: \(userInfo)", category: "AppDelegate")
        
        // Handle CloudKit notifications
        if let cloudKitNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            log("CloudKit notification type: \(cloudKitNotification.notificationType)", category: "AppDelegate")
            
            // Handle with MessageSyncService for iOS 17+
            if #available(iOS 17.0, *) {
                MessageSyncService.shared.checkForUpdates()
                log("Triggered MessageSyncService update", category: "AppDelegate")
                return .newData
            } else {
                // For older iOS versions, return newData to indicate we processed the notification
                log("Processed CloudKit notification for legacy iOS", category: "AppDelegate")
                return .newData
            }
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