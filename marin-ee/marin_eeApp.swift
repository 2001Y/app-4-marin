import SwiftUI
import SwiftData
import UIKit

@main
struct MarinEEApp: App {
    // Schema versioning
    private static let currentSchemaVersion = 2
    @AppStorage("schemaVersion") private var schemaVersion = 0
    
    // UIApplicationDelegate for push and CloudKit
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // SwiftData container（必ず作成）
    private let sharedModelContainer: ModelContainer

    // DB リセットが発生したかを保持し、UI でアラート表示に使う
    @State private var showDBResetAlert: Bool = false
    
    // Reaction Store
    @State private var reactionStore = ReactionStore()

    init() {
        // Check schema version
        let needsReset = schemaVersion != Self.currentSchemaVersion
        
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
            schemaVersion = Self.currentSchemaVersion
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

        let url = appSupport.appendingPathComponent("MarinEE.sqlite")

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
            Group {
                TabView {
                    ChatListView()
                        .tag(0)
                        .tabItem {
                            Label("チャット", systemImage: "bubble.left.and.bubble.right")
                        }
                    
                    CalendarView()
                        .tag(1)
                        .tabItem {
                            Label("カレンダー", systemImage: "calendar")
                        }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .environment(reactionStore)
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
