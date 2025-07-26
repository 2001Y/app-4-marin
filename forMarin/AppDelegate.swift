import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 権限取得後にremote notification登録は自動で行われる
        // 他アプリのオーディオ再生を止めない AVAudioSession 設定
        AudioSessionManager.configureForAmbient()
        Task {
            try? await CKSync.installSubscriptions()
        }
        return true
    }

    @MainActor
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any]) async -> UIBackgroundFetchResult {
        return await CKSync.handlePush(userInfo)
    }
} 