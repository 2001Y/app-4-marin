import SwiftUI
import SwiftData
import UIKit

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
    
    init() {
        // Check schema version - UserDefaultsから直接読み取る
        let currentVersion = UserDefaults.standard.integer(forKey: "schemaVersion")
        let needsReset = currentVersion != Self.currentSchemaVersion
        
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

        // アラート表示用 State を初期化
        self._showDBResetAlert = State(initialValue: didReset)
        
        // Update schema version after successful init
        if didReset {
            UserDefaults.standard.set(Self.currentSchemaVersion, forKey: "schemaVersion")
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

        // まず既存ファイルをそのまま開く試み
        if let disk = try? ModelContainer(for: schema,
                                          configurations: [.init(schema: schema, url: url)]) {
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
    }
}

struct RootView: View {
    // チャット一覧を取得（最後のメッセージ日時で降順）
    @Query(sort: \ChatRoom.lastMessageDate, order: .reverse) private var chatRooms: [ChatRoom]
    // NavigationStack 用のパス
    @State private var navigationPath = NavigationPath()
    // 初回アプリ起動判定（単一チャット時の自動遷移に使用）
    @State private var isFirstLaunch = true

    var body: some View {
        NavigationStack(path: $navigationPath) {
            contentView
                // ChatRoom を値として遷移
                .navigationDestination(for: ChatRoom.self) { room in
                    ChatView(chatRoom: room)
                }
        }
        // 単一チャットのみ存在する場合、初回起動時に自動遷移
        .onAppear {
            if isFirstLaunch, let first = chatRooms.first, chatRooms.count == 1 {
                navigationPath.append(first)
            }
            isFirstLaunch = false
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
}
