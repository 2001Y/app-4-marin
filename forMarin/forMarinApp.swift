import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import CloudKit

@main
struct forMarinApp: App {
    // Schema versioning
    private static let currentSchemaVersion = 2
    @AppStorage("schemaVersion") private var schemaVersion = 0
    
    // UIApplicationDelegate for push and CloudKit
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // SwiftData container（必ず作成）
    private let sharedModelContainer: ModelContainer

    // DB リセットが発生したかを保持し、UI でアラート表示に使う
    @State private var showDBResetAlert: Bool = false
    // CloudKit リセットが発生したかを保持
    @State private var showCloudKitResetAlert: Bool = false
    
    init() {
        // Check schema version - UserDefaultsから直接読み取る
        let currentVersion = UserDefaults.standard.integer(forKey: "schemaVersion")
        let needsReset = currentVersion != Self.currentSchemaVersion
        let isFirstLaunch = currentVersion == 0 // 初回起動の判定
        
        // makeContainer でリセット有無を inout で受け取る
        var didReset = needsReset
        let container: ModelContainer
        
        if let validContainer = Self.makeContainer(resetOccurred: &didReset) {
            container = validContainer
        } else {
            // 最後の防衛策: 空スキーマでメモリストア
            let schema = Schema([Message.self, Anniversary.self, ChatRoom.self])
            container = try! ModelContainer(for: schema,
                                          configurations: [.init(schema: schema,
                                                                 isStoredInMemoryOnly: true)])
            didReset = true
        }
        
        // 一度だけ初期化
        sharedModelContainer = container

        // アラート表示用 State を初期化（初回起動時は表示しない）
        self._showDBResetAlert = State(initialValue: didReset && !isFirstLaunch)
        
        // Update schema version after successful init
        if didReset {
            UserDefaults.standard.set(Self.currentSchemaVersion, forKey: "schemaVersion")
        }
        
        // CloudKit初期化とリセット検出を非同期で実行
        Task {
            // CloudKitChatManagerの初期化を待つ
            while !CloudKitChatManager.shared.isInitialized {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒待機
            }
            
            // 旧データ検出によるリセットが実行されたかチェック
            // CloudKitChatManagerのresetIfLegacyDataDetected()が既に実行済みなので、
            // 結果を確認するためのフラグを設定
            log("CloudKit initialization completed", category: "forMarinApp")
        }
    }

    /// 既存ストアをそのまま開き、失敗時のみ削除してリセット。
    /// - Parameter resetOccurred: リセットが行われた場合 true がセットされる
    /// - Returns: 正常に作成できたコンテナ（失敗時は nil）
    private static func makeContainer(resetOccurred: inout Bool) -> ModelContainer? {
        let schema = Schema([Message.self, Anniversary.self, ChatRoom.self])

        // Application Support のパス
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: appSupport,
                                                 withIntermediateDirectories: true)

        let url = appSupport.appendingPathComponent("forMarin.sqlite")

        // If reset requested, delete existing DB
        if resetOccurred {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("-shm"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("-wal"))
        }

        // まず既存ファイルをそのまま開く試み（CloudKit自動同期を無効化）
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if let disk = try? ModelContainer(for: schema, configurations: [config]) {
            return disk // 正常に開けた
        }

        // 失敗した場合は破損とみなし、ファイル削除 → 再生成
        try? FileManager.default.removeItem(at: url)
        // WAL/SHM も一応削除
        try? FileManager.default.removeItem(at: url.appendingPathExtension("-shm"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("-wal"))

        if let disk = try? ModelContainer(for: schema,
                                          configurations: [.init(schema: schema, url: url)]) {
            resetOccurred = true
            return disk
        }

        // ディスク作成も失敗 → 呼び出し元でメモリストアへフォールバック
        resetOccurred = true
        return nil
    }

    var body: some Scene {
        WindowGroup {
            RootView()
            // DB リセット時のみアラートを表示
            .alert("データベースをリセットしました", isPresented: $showDBResetAlert) {
                Button("OK", role: .cancel) { showDBResetAlert = false }
            } message: {
                Text("保存データが破損していたため、ローカルデータベースを初期化しました。")
            }
        }
        .modelContainer(sharedModelContainer)
        .backgroundTask(.appRefresh(BGTaskIDs.offlineCheck)) {
            await BackgroundTaskManager.shared.handleAppRefresh()
        }
    }
}

struct RootView: View {
    // チャット一覧を取得（最後のメッセージ日時で降順）
    @Query(sort: \ChatRoom.lastMessageDate, order: .reverse) private var chatRooms: [ChatRoom]
    // NavigationStack 用のパス
    @State private var navigationPath = NavigationPath()
    // 初回アプリ起動判定（単一チャット時の自動遷移に使用）
    @State private var isFirstLaunch = true
    // ウェルカムモーダルの表示管理
    @AppStorage("hasShownWelcome") private var hasShownWelcomeStorage = false
    @State private var shouldShowWelcome: Bool
    @State private var showWelcomeModal = false
    // オフライン検知機能
    @StateObject private var connectivityManager = ConnectivityManager.shared
    // CloudKit管理
    @StateObject private var cloudKitManager = CloudKitChatManager.shared
    @State private var showCloudKitResetAlert = false
    // 環境変数
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    // URL管理
    @StateObject private var urlManager = URLManager.shared
    
    init() {
        // ウェルカムモーダルの初期表示判定をストレージから読み取り
        self._shouldShowWelcome = State(initialValue: !UserDefaults.standard.bool(forKey: "hasShownWelcome"))
    }

    var body: some View {
        ZStack {
            NavigationStack(path: $navigationPath) {
                contentView
                    // ChatRoom を値として遷移
                    .navigationDestination(for: ChatRoom.self) { room in
                        ChatView(chatRoom: room)
                    }
            }
            // 単一チャットのみ存在する場合、初回起動時に自動遷移
            .onAppear {
                // ウェルカムモーダルの表示判定
                if shouldShowWelcome {
                    // 少し遅延を入れてアニメーションを自然にする
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showWelcomeModal = true
                    }
                    shouldShowWelcome = false
                }
                
                if isFirstLaunch, let first = chatRooms.first, chatRooms.count == 1 {
                    navigationPath.append(first)
                }
                isFirstLaunch = false
            }
            
            // ウェルカムモーダルオーバーレイ
            WelcomeModalOverlay(isPresented: $showWelcomeModal) {
                hasShownWelcomeStorage = true
                shouldShowWelcome = false
            }
            
            // オフラインモーダルオーバーレイ
            OfflineModalOverlay(connectivityManager: connectivityManager)
        }
        // CloudKitリセットアラート
        .alert("CloudKitデータをリセットしました", isPresented: $showCloudKitResetAlert) {
            Button("OK", role: .cancel) { 
                showCloudKitResetAlert = false 
            }
        } message: {
            Text("旧形式のCloudKitデータが検出されたため、クラウドデータを初期化しました。新しい共有チャット機能をお楽しみください。")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // バックグラウンドに移行時にタスクをスケジュール（テスト中は除く）
                BackgroundTaskManager.shared.scheduleNextRefreshIfNotInTestMode()
            }
        }
        .onChange(of: hasShownWelcomeStorage) { _, newValue in
            // 開発者初期化時にウェルカムモーダルを表示
            if !newValue {
                shouldShowWelcome = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showWelcomeModal = true
                }
            }
        }
        .onChange(of: cloudKitManager.lastError?.localizedDescription) { _, _ in
            // CloudKitエラーの監視とリセットアラート表示
            if let error = cloudKitManager.lastError {
                log("CloudKit error detected: \(error)", category: "RootView")
                // 特定のエラーの場合はリセットアラートを表示
                if let ckError = error as? CloudKitChatError,
                   case .roomNotFound = ckError {
                    showCloudKitResetAlert = true
                }
            }
        }
        .onChange(of: cloudKitManager.hasPerformedReset) { _, hasReset in
            // CloudKitリセット実行の監視
            if hasReset {
                log("CloudKit reset detected, showing alert", category: "RootView")
                showCloudKitResetAlert = true
                // フラグをリセット（一度だけ表示するため）
                cloudKitManager.hasPerformedReset = false
            }
        }
        .onOpenURL { url in
            // 招待URLの処理
            Task {
                await handleIncomingURL(url)
            }
        }
    }

    // MARK: - ルートごとのコンテンツ
    @ViewBuilder
    private var contentView: some View {
        if chatRooms.isEmpty {
            // チャットが無い＝ペアリング画面
            PairingView { newRoom in
                navigationPath.append(newRoom)
            }
        } else {
            // チャットリスト
            ChatListView { selected in
                navigationPath.append(selected)
            }
        }
    }
    
    // MARK: - URL Handling
    
    /// 受信したURLを処理（招待URL）
    private func handleIncomingURL(_ url: URL) async {
        log("Received URL: \(url)", category: "RootView")
        
        // 招待URLかどうかを判定
        if urlManager.isInviteURL(url) {
            await handleInviteURL(url)
        } else {
            log("Unknown URL scheme: \(url)", category: "RootView")
        }
    }
    
    /// 招待URLを処理
    private func handleInviteURL(_ url: URL) async {
        log("Processing invite URL", category: "RootView")
        
        guard let userID = urlManager.parseInviteURL(url) else {
            log("Failed to parse userID from URL", category: "RootView")
            return
        }
        
        // チャットを作成
        if let newRoom = await urlManager.createChatFromInvite(userID: userID, modelContext: modelContext) {
            await MainActor.run {
                log("Successfully created chat from invite", category: "RootView")
                // 新しいチャットルームに遷移
                navigationPath.append(newRoom)
            }
        } else {
            await MainActor.run {
                log("Failed to create chat from invite", category: "RootView")
                // エラー処理（必要に応じてアラート表示）
            }
        }
    }
}
