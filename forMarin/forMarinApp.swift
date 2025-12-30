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

        ModelContainerBroker.shared.register(container)

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

        let url = appSupport.appendingPathComponent("forMarin_v2.sqlite")

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
    // 表示名（CloudKitから取得して判定）
    @State private var myDisplayNameCloud: String? = nil
    // NavigationStack 用のパス
    @State private var navigationPath = NavigationPath()
    @State private var lastOpenedChatRoomID: String? = nil
    // ウェルカムモーダルの表示管理
    @AppStorage("hasShownWelcome") private var hasShownWelcomeStorage = false
    @State private var shouldShowWelcome: Bool
    @State private var showWelcomeModal = false
    // オフライン検知機能
    @StateObject private var connectivityManager = ConnectivityManager.shared
    // CloudKit管理
    @StateObject private var cloudKitManager = CloudKitChatManager.shared
    @State private var showCloudKitResetAlert = false
    // ローディング（OS標準ProgressViewを全画面オーバーレイ表示）
    @State private var isLoadingOverlayVisible = false
    @State private var loadingOverlayTitle: String? = nil
    // 環境変数
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    // URL管理
    @StateObject private var urlManager = URLManager.shared
    // 特徴ページの初回表示管理
    
    init() {
        // ウェルカムモーダルの初期表示判定をストレージから読み取り
        self._shouldShowWelcome = State(initialValue: !UserDefaults.standard.bool(forKey: "hasShownWelcome"))
        // Cloud名の取得は .task で行う（init内のEscapingクロージャでselfをキャプチャしない）
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
            .task(id: myDisplayNameCloud == nil) {
                if myDisplayNameCloud == nil {
                    let name = await CloudKitChatManager.shared.fetchMyDisplayNameFromCloud()
                    await MainActor.run { self.myDisplayNameCloud = name }
                }
            }
            // 表示名更新の通知を受けて、即座にルートの表示判定を切り替える
            .onReceive(NotificationCenter.default.publisher(for: .displayNameUpdated)) { notif in
                if let name = notif.userInfo?["name"] as? String {
                    myDisplayNameCloud = name
                } else {
                    // name未添付ならクラウド再フェッチ
                    Task {
                        let name = await CloudKitChatManager.shared.fetchMyDisplayNameFromCloud()
                        await MainActor.run { self.myDisplayNameCloud = name }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openChatRoom)) { notif in
                // QR読み取りなどからの遷移要求を受け取って対象チャットへ遷移
                if let room = notif.userInfo?["room"] as? ChatRoom {
                    openChat(room)
                    isLoadingOverlayVisible = false
                } else if let roomID = notif.userInfo?["roomID"] as? String {
                    do {
                        let descriptor = FetchDescriptor<ChatRoom>(
                            predicate: #Predicate<ChatRoom> { $0.roomID == roomID }
                        )
                        if let found = try? modelContext.fetch(descriptor).first {
                            openChat(found)
                            isLoadingOverlayVisible = false
                        }
                    }
                }
            }
            // ローディングの表示指示（通知名は生文字列で最小実装）
            .onReceive(NotificationCenter.default.publisher(for: .showGlobalLoading)) { notif in
                loadingOverlayTitle = (notif.userInfo?["title"] as? String) ?? nil
                isLoadingOverlayVisible = true
                log("UI: showGlobalLoading (title=\(loadingOverlayTitle ?? "nil"))", category: "UI")
            }
            .onReceive(NotificationCenter.default.publisher(for: .hideGlobalLoading)) { _ in
                isLoadingOverlayVisible = false
                log("UI: hideGlobalLoading", category: "UI")
            }
            .onChange(of: scenePhase) { newPhase, _ in
                if newPhase == .active {
                    Task {
                        if #available(iOS 17.0, *) {
                            _ = await CKSyncEngineManager.shared.fetchChanges(reason: "scene:active")
                        }
                    }
                    Task { @MainActor in
                        await CloudKitChatManager.shared.bootstrapOwnedRooms(modelContext: modelContext)
                        await CloudKitChatManager.shared.bootstrapSharedRooms(modelContext: modelContext)
                    }
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

                // 起動直後のみ自動オープン（フラグは使わず、初回タスクで一度だけ評価）
            }
            .task {
                do {
                    try await PermissionManager.shared.requestCameraPermissionIfNeeded()
                } catch {
                    log("Camera permission request failed: \(error)", category: "Permissions")
                }
            }
            .task {
                if chatRooms.count == 1 && navigationPath.isEmpty {
                    openChat(chatRooms[0])
                }
            }
            
            // ウェルカムモーダル（経緯）オーバーレイ
            WelcomeReasonModalOverlay(isPresented: $showWelcomeModal) {
                hasShownWelcomeStorage = true
                shouldShowWelcome = false
            }
            
            // オフラインモーダルオーバーレイ
            OfflineModalOverlay(connectivityManager: connectivityManager)

            // ローディングオーバーレイ（最小・OS標準）
            if isLoadingOverlayVisible {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        if let t = loadingOverlayTitle, !t.isEmpty {
                            Text(t).foregroundStyle(.white).font(.system(size: 13, weight: .medium, design: .rounded))
                        }
                    }
                }
                .transition(.opacity)
                .accessibilityLabel(Text(loadingOverlayTitle ?? "読み込み中"))
            }
        }
        .onChange(of: navigationPath.count) { oldCount, newCount in
            guard oldCount != newCount else { return }
            if newCount == 0, let roomID = lastOpenedChatRoomID {
                P2PController.shared.closeIfCurrent(roomID: roomID, reason: "navigation-pop")
                lastOpenedChatRoomID = nil
            }
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
            if newPhase == .background || newPhase == .inactive {
                P2PController.shared.closeIfCurrent(roomID: lastOpenedChatRoomID, reason: "scenePhase-\(newPhase)")
            }
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
                if let ckError = error as? CloudKitChatManager.CloudKitChatError,
                   case .roomNotFound = ckError {
                    showCloudKitResetAlert = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudKitResetPerformed)) { _ in
            log("CloudKit reset detected, showing alert", category: "RootView")
            showCloudKitResetAlert = true
        }
        .onOpenURL { url in
            // 🌟 [IDEAL SHARING] CloudKit招待URLとレガシー招待URLの処理
            log("📩 [IDEAL SHARING] Received URL: \(url)", category: "RootView")
            Task {
                await handleIncomingURL(url)
            }
        }
        // グローバルアクセントカラー（iOS 15+ 推奨の .tint）
        .tint(Color("AccentColor"))
    }

    // MARK: - ルートごとのコンテンツ
    @ViewBuilder
    private var contentView: some View {
        // 表示名（Cloud）未設定ならウェルカム（特徴）ページを表示
        if (myDisplayNameCloud?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            FeaturesPage(
                showWelcomeModalOnAppear: false,
                onChatCreated: { room in
                    openChat(room)
                },
                onDismiss: {
                    // 読み込み完了などの合図でチャットリストへ
                }
            )
        } else {
            ChatListView { selected in
                openChat(selected)
            }
        }
    }
    
    // MARK: - URL Handling
    
    /// 🌟 [IDEAL SHARING] 受信したURLを処理（CloudKit招待URL + レガシー招待URL）
    private func handleIncomingURL(_ url: URL) async {
        log("📩 [IDEAL SHARING] Processing incoming URL: \(url)", category: "RootView")
        log("📩 [IDEAL SHARING] URL scheme: \(url.scheme ?? "nil")", category: "RootView")
        log("📩 [IDEAL SHARING] URL host: \(url.host ?? "nil")", category: "RootView")
        log("📩 [IDEAL SHARING] URL path: \(url.path)", category: "RootView")
        
        // CloudKit招待URLかどうかを判定（icloud.comドメイン）
        if url.host?.contains("icloud.com") == true {
            await handleCloudKitInviteURL(url)
        }
        // レガシー招待URLかどうかを判定
        else if urlManager.isInviteURL(url) {
            await handleInviteURL(url)
        } else {
            log("❌ [IDEAL SHARING] Unknown URL scheme: \(url)", category: "RootView")
        }
    }
    
    /// 🌟 [IDEAL SHARING] CloudKit招待URLを処理
    private func handleCloudKitInviteURL(_ url: URL) async {
        log("📩 [IDEAL SHARING] CloudKit invite URL detected: \(url)", category: "RootView")
        
        // 期待通りならOSが App/SceneDelegate 経由で受諾を渡すが、
        // 渡らないケースのためにアプリ内でも受諾を試みる（iOS 17+）。
        let accepted = await InvitationManager.shared.acceptInvitation(from: url)
        if accepted {
            log("✅ [IDEAL SHARING] Accepted CloudKit share via in-app fallback", category: "RootView")
            // 共有ゾーンからローカルをブートストラップして一覧に反映
            do {
                await CloudKitChatManager.shared.bootstrapSharedRooms(modelContext: modelContext)
                log("✅ [IDEAL SHARING] bootstrapSharedRooms completed successfully", category: "RootView")
            } catch {
                log("❌ [IDEAL SHARING] bootstrapSharedRooms failed: \(error)", category: "RootView")
            }
            // ウェルカム表示判定は部屋数で行うため、フラグ更新は不要
        } else {
            log("⚠️ [IDEAL SHARING] In-app acceptance failed (OS may still complete later)", category: "RootView")
            // エラーが発生した場合でも、OSが後で処理する可能性があるため、bootstrapSharedRoomsを試みる
            do {
                await CloudKitChatManager.shared.bootstrapSharedRooms(modelContext: modelContext)
                log("✅ [IDEAL SHARING] bootstrapSharedRooms completed (after failed acceptance)", category: "RootView")
            } catch {
                log("❌ [IDEAL SHARING] bootstrapSharedRooms failed (after failed acceptance): \(error)", category: "RootView")
            }
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
                openChat(newRoom)
            }
        } else {
            await MainActor.run {
                log("Failed to create chat from invite", category: "RootView")
                // エラー処理（必要に応じてアラート表示）
            }
        }
    }

    // MARK: - Unified Chat Open
    private func openChat(_ room: ChatRoom) {
        // 共通ロジック: 未読数クリア + 画面遷移（ログ付き）
        log("UI: openChat room=\(room.roomID)", category: "RootView")
        room.unreadCount = 0
        lastOpenedChatRoomID = room.roomID
        navigationPath.append(room)
    }
    
}
