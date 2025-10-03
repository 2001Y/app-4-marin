import UIKit
import UserNotifications
import CloudKit
import Network
import os.log
import os.signpost
import CryptoKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let pushLog = OSLog(subsystem: "com.fourmarin.app", category: "push.receive")
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.fourmarin.app.pushPathMonitor")
    private var latestPath: NWPath?

    override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.latestPath = path
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

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
            await CloudKitChatManager.shared.bootstrapIfNeeded()

            // Start CKSyncEngine (iOS 17+)
            if #available(iOS 17.0, *) {
                await CKSyncEngineManager.shared.start()
                log("CKSyncEngine started (private/shared)", category: "AppDelegate")
            }
        }
        
        // Initialize MessageSyncPipeline (iOS 17+ 前提)
        _ = MessageSyncPipeline.shared
        log("MessageSyncPipeline initialized", category: "AppDelegate")
        
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
        let startedAt = Date()
        let signpostID = OSSignpostID(log: pushLog)
        let appStateDescription = appStateString(for: application.applicationState)
        let (connectionDescription, constrained) = currentNetworkSummary()
        let messageID = Self.messageID(from: userInfo)

        os_signpost(.begin,
                    log: pushLog,
                    name: "remote_notification",
                    signpostID: signpostID,
                    "state=%{public}@ connection=%{public}@ constrained=%{public}@ messageID=%{public}@",
                    appStateDescription,
                    connectionDescription,
                    constrained ? "true" : "false",
                    messageID ?? "nil")

        log("[PUSH] Received remote notification state=\(appStateDescription) connection=\(connectionDescription) constrained=\(constrained) messageID=\(messageID ?? "nil")", category: "AppDelegate")

        guard let cloudKitNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_signpost(.end,
                        log: pushLog,
                        name: "remote_notification",
                        signpostID: signpostID,
                        "result=%{public}@",
                        "ignored")
            return .noData
        }

        log("CloudKit notification type: \(cloudKitNotification.notificationType)", category: "push.receive")

        var fetchResult: UIBackgroundFetchResult = .noData

        if #available(iOS 17.0, *) {
            let handled = await CKSyncEngineManager.shared.handleRemoteNotification(userInfo: userInfo)
            fetchResult = handled ? .newData : .noData
        }

        if let roomID = extractRoomID(from: cloudKitNotification, userInfo: userInfo) {
            log("Targeted CloudKit push for roomID: \(roomID)", category: "push.receive")
            P2PController.shared.onZoneChanged(roomID: roomID)
        } else {
            log("CloudKit push without specific room hint — relying on database-wide refresh", category: "push.receive")
        }

        os_signpost(.end,
                    log: pushLog,
                    name: "remote_notification",
                    signpostID: signpostID,
                    "result=%{public}@ fetch=%{public}@",
                    "completed",
                    fetchResult.description)

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        log("[PUSH] Completed handling. result=\(fetchResult.description) duration_ms=\(durationMs)", category: "push.receive")

        return fetchResult
    }
    
    private func extractRoomID(from notification: CKNotification, userInfo: [AnyHashable: Any]) -> String? {
        if let query = notification as? CKQueryNotification, let zoneID = query.recordID?.zoneID {
            return zoneID.zoneName
        }
        if let zoneNotification = notification as? CKRecordZoneNotification, let zoneID = zoneNotification.recordZoneID {
            return zoneID.zoneName
        }
        if let ckPayload = userInfo["ck"] as? [String: Any] {
            if let met = ckPayload["met"] as? [String: Any], let zid = met["zid"] as? String, !zid.isEmpty {
                return zid
            }
            if let fet = ckPayload["fet"] as? [String: Any], let zid = fet["zid"] as? String, !zid.isEmpty {
                return zid
            }
        }
        return nil
    }

    // MARK: - Push Notification Registration
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log("Successfully registered for remote notifications", category: "push.register")
        // 生トークンは記録しない。SHA-256 をログ用に計測
        let tokenHash = SHA256.hash(data: deviceToken).compactMap { String(format: "%02x", $0) }.joined()
        let env = CloudKitChatManager.shared.checkIsProductionEnvironment() ? "prod" : "nonprod"
        let ts = ISO8601DateFormatter().string(from: Date())
        let bg = application.backgroundRefreshStatus
        let bgText: String = {
            switch bg {
            case .available: return "available"
            case .denied: return "denied"
            case .restricted: return "restricted"
            @unknown default: return "unknown"
            }
        }()
        // 通知権限の詳細を取得して追記
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let auth: String
            switch settings.authorizationStatus {
            case .authorized: auth = "authorized"
            case .denied: auth = "denied"
            case .notDetermined: auth = "undetermined"
            case .provisional: auth = "provisional"
            case .ephemeral: auth = "ephemeral"
            @unknown default: auth = "unknown"
            }
            log("[PUSH.REG] env=\(env) tokenHash=\(tokenHash) ts=\(ts) auth=\(auth) alert=\(settings.alertSetting.rawValue) badge=\(settings.badgeSetting.rawValue) sound=\(settings.soundSetting.rawValue) bgRefresh=\(bgText)", category: "push.register")
        }
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log("Failed to register for remote notifications: \(error)", category: "AppDelegate")
    }
}

private extension UIBackgroundFetchResult {
    var description: String {
        switch self {
        case .newData: return "newData"
        case .noData: return "noData"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }
}

private extension AppDelegate {
    static func messageID(from userInfo: [AnyHashable: Any]) -> String? {
        if let ckPayload = userInfo["ck"] as? [String: Any] {
            if let notificationID = ckPayload["nid"] as? String, !notificationID.isEmpty {
                return notificationID
            }
            if let subscriptionID = ckPayload["sid"] as? String, !subscriptionID.isEmpty {
                return subscriptionID
            }
        }
        return nil
    }

    static func cloudKitIDs(from userInfo: [AnyHashable: Any]) -> (sid: String?, nid: String?) {
        guard let ckPayload = userInfo["ck"] as? [String: Any] else { return (nil, nil) }
        let sid = ckPayload["sid"] as? String
        let nid = ckPayload["nid"] as? String
        return (sid, nid)
    }

    func appStateString(for state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .background: return "background"
        case .inactive: return "inactive"
        @unknown default: return "unknown"
        }
    }

    func currentNetworkSummary() -> (String, Bool) {
        if let path = latestPath {
            let type: String
            if path.usesInterfaceType(.wifi) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                type = "ethernet"
            } else if path.usesInterfaceType(.loopback) {
                type = "loopback"
            } else {
                type = "other"
            }
            return (type, path.isConstrained)
        }
        return ("unknown", false)
    }
}
