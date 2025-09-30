import SwiftUI
import BackgroundTasks
import Network
import UserNotifications
import Foundation

// MARK: - Constants
enum BGTaskIDs {
    static let offlineCheck = "com.formarin.app.offline-check"
}

enum UserDefaultsKeys {
    static let lastOnlineAt = "lastOnlineAt"
    static let didNotifyThisEpisode = "didNotifyThisOfflineEpisode"
    static let showOfflineModal = "showOfflineModal"
    static let nextBackgroundTaskScheduled = "nextBackgroundTaskScheduled"
    static let debugNotificationsEnabled = "debugNotificationsEnabled"
    static let testModeScheduledUntil = "testModeScheduledUntil"
}

enum OfflinePolicy {
    /// これ以上オフラインが続いていたら通知
    static let minSecondsToNotify: TimeInterval = 60
    /// 次の起床希望（あくまで"希望"）
    static let refreshInterval: TimeInterval = 30 * 60
}

// MARK: - Connectivity Manager
@MainActor
class ConnectivityManager: ObservableObject {
    static let shared = ConnectivityManager()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ConnectivityMonitor")
    
    @Published var isConnected: Bool = true
    @Published var showOfflineModal: Bool = false
    
    private init() {
        // 前回オンラインだった時刻を復元
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.lastOnlineAt) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastOnlineAt)
        }
        
        // オフラインモーダル表示状態を復元
        showOfflineModal = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showOfflineModal)
        
        startMonitoring()
        setupNotificationObserver()
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: .showOfflineModal,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showOfflineModalFromNotification()
            }
        }
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let connected = path.status == .satisfied
                self?.isConnected = connected
                
                if connected {
                    // オンラインになったら時刻を更新し、通知フラグをリセット
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastOnlineAt)
                    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.didNotifyThisEpisode)
                    
                    // オンラインになったらモーダルを閉じる
                    self?.showOfflineModal = false
                    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.showOfflineModal)
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    func isCurrentlyOffline() -> Bool {
        return monitor.currentPath.status != .satisfied
    }
    
    func lastOnlineAt() -> Date {
        let timeInterval = UserDefaults.standard.double(forKey: UserDefaultsKeys.lastOnlineAt)
        return timeInterval > 0 ? Date(timeIntervalSince1970: timeInterval) : .distantPast
    }
    
    func showOfflineModalFromNotification() {
        showOfflineModal = true
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.showOfflineModal)
    }
    
    func hideOfflineModal() {
        showOfflineModal = false
        UserDefaults.standard.set(false, forKey: UserDefaultsKeys.showOfflineModal)
    }
}

// MARK: - Notification Manager
class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            log("通知許可の取得に失敗: \(error)", category: "App")
        }
    }
    
    func notifyOfflineIfNeeded() async {
        // 同一エピソードでの多重通知を抑止
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.didNotifyThisEpisode) { 
            log("通知スキップ: 同一エピソードで既に通知済み", category: "DEBUG")
            return 
        }
        
        do {
            let content = UNMutableNotificationContent()
            content.title = "ネットワーク接続が切れています"
            content.body = "タップして詳細を確認してください"
            content.threadIdentifier = "offline"
            content.categoryIdentifier = "OFFLINE_CATEGORY"
            content.userInfo = ["action": "showOfflineModal"]
            
            // すぐ1回だけ
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "offline-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            
            try await UNUserNotificationCenter.current().add(request)
            UserDefaults.standard.set(true, forKey: UserDefaultsKeys.didNotifyThisEpisode)
            log("オフライン通知を送信しました", category: "DEBUG")
        } catch {
            log("通知の送信に失敗: \(error)", category: "App")
        }
    }
    
    // デバッグ用: 強制的に通知を送信
    func sendDebugNotification(title: String = "デバッグ通知", body: String) async {
        do {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "debug-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            
            try await UNUserNotificationCenter.current().add(request)
            log("デバッグ通知を送信: \(body)", category: "DEBUG")
        } catch {
            log("デバッグ通知の送信に失敗: \(error)", category: "App")
        }
    }
}

// MARK: - Background Task Manager
class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    
    private var isTaskRegistered = false
    
    private init() {}
    
    /// テストモード中かどうかをチェック
    private var isInTestMode: Bool {
        let testUntil = UserDefaults.standard.double(forKey: UserDefaultsKeys.testModeScheduledUntil)
        let isInTest = testUntil > 0 && Date().timeIntervalSince1970 < testUntil
        
        // テスト期間が終了していたらフラグをクリア
        if testUntil > 0 && Date().timeIntervalSince1970 >= testUntil {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.testModeScheduledUntil)
            log("テストモード期間終了 - フラグをクリア", category: "DEBUG")
        }
        
        return isInTest
    }
    
    /// 次回バックグラウンドタスク実行予定時刻を取得
    func getNextScheduledDate() -> Date? {
        let timeInterval = UserDefaults.standard.double(forKey: UserDefaultsKeys.nextBackgroundTaskScheduled)
        return timeInterval > 0 ? Date(timeIntervalSince1970: timeInterval) : nil
    }
    
    func scheduleNextRefresh(after seconds: TimeInterval = OfflinePolicy.refreshInterval, isTestMode: Bool = false) {
        let req = BGAppRefreshTaskRequest(identifier: BGTaskIDs.offlineCheck)
        let nextRunDate = Date().addingTimeInterval(seconds)
        req.earliestBeginDate = nextRunDate
        
        // テストモードの管理
        if isTestMode {
            // テスト終了予定時刻を設定（スケジュール時刻 + 5分のバッファ）
            let testEndTime = nextRunDate.addingTimeInterval(300) // 5分間のテスト期間
            UserDefaults.standard.set(testEndTime.timeIntervalSince1970, forKey: UserDefaultsKeys.testModeScheduledUntil)
        }
        
        do {
            try BGTaskScheduler.shared.submit(req)
            // 次回実行予定時刻を保存
            UserDefaults.standard.set(nextRunDate.timeIntervalSince1970, forKey: UserDefaultsKeys.nextBackgroundTaskScheduled)
            
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            formatter.locale = Locale.current
            let modeText = isTestMode ? "[テスト]" : "[通常]"
            log("\(modeText) バックグラウンドタスクをスケジュール: \(formatter.string(from: nextRunDate))", category: "bg.task")
        } catch {
            log("バックグラウンドタスクのスケジュールに失敗: \(error)", category: "bg.task")
        }
    }
    
    /// 自動スケジュール（テスト中はスキップ）
    func scheduleNextRefreshIfNotInTestMode() {
        if isInTestMode {
            log("テストモード中のため自動スケジュールをスキップ", category: "DEBUG")
            return
        }
        scheduleNextRefresh()
    }
    
    func handleAppRefresh() async {
        defer { 
            // テストモード中でも継続的にスケジュールする
            if isInTestMode {
                log("テストモード中 - 継続的にスケジュール", category: "DEBUG")
                scheduleNextRefresh(after: 30, isTestMode: true) // テストモードで30秒後に再スケジュール
            } else {
                scheduleNextRefreshIfNotInTestMode()
            }
        }

        log("バックグラウンドタスク実行開始 - \(Date())", category: "bg.task")

        if #available(iOS 17.0, *) {
            let triggered = await CKSyncEngineManager.shared.fetchChanges(reason: "bg:app_refresh")
            log("[BG] CKSyncEngine fetch triggered=\(triggered)", category: "CKSyncEngine")
        }

        await MainActor.run {
            log("Thread: \(Thread.current)", category: "bg.task")
            log("アプリ状態: \(UIApplication.shared.applicationState.rawValue)", category: "bg.task")
            let connectivityManager = ConnectivityManager.shared
            let offline = connectivityManager.isCurrentlyOffline()
            let lastOnline = connectivityManager.lastOnlineAt()
            let offlineDuration = Date().timeIntervalSince(lastOnline)
            let longEnough = offlineDuration >= OfflinePolicy.minSecondsToNotify
            let debugMode = UserDefaults.standard.bool(forKey: UserDefaultsKeys.debugNotificationsEnabled)
            
            log("バックグラウンド実行 - オフライン: \(offline), 継続時間: \(offlineDuration)秒, デバッグモード: \(debugMode), テストモード: \(isInTestMode)", category: "bg.task")
            
            // デバッグモードでは常に通知、通常モードではオフラインかつ時間経過時のみ
            if debugMode || (offline && longEnough) {
                Task {
                    log("通知送信を開始", category: "bg.task")
                    if debugMode {
                        let status = offline ? "オフライン" : "オンライン"
                        log("デバッグ通知を送信: \(status)", category: "bg.task")
                        await NotificationManager.shared.sendDebugNotification(
                            title: "バックグラウンドタスク実行",
                            body: "\(status) - 継続時間: \(Int(offlineDuration))秒"
                        )
                    } else {
                        log("オフライン通知を送信", category: "bg.task")
                        await NotificationManager.shared.notifyOfflineIfNeeded()
                    }
                    log("通知送信完了", category: "bg.task")
                }
            } else {
                log("通知条件を満たさないためスキップ", category: "bg.task")
            }
        }
    }
    
    // デバッグ用: 強制的にバックグラウンドタスクを実行
    func forceExecuteBackgroundTask() async {
        log("強制的にバックグラウンドタスクを実行", category: "DEBUG")
        await handleAppRefresh()
    }
    
    // NOTE: SwiftUIの.backgroundTaskモディファイアを使用しているため、
    // 手動でBGTaskSchedulerに登録する必要はありません
    func registerBackgroundTask() {
        // SwiftUIの.backgroundTaskモディファイアが自動的に登録を行うため、
        // このメソッドは使用しません
        log("注意: SwiftUIの.backgroundTaskモディファイアを使用中のため、手動登録は不要です", category: "App")
    }
    
    func registerBackgroundTasks() {
        // SwiftUIの.backgroundTaskモディファイアを使用するため、何もしません
        log("バックグラウンドタスクはSwiftUIにより自動管理されています", category: "App")
    }
}
