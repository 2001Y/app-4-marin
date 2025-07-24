import SwiftUI
import SwiftData
import UIKit

@main
struct MarinEEApp: App {
    // UIApplicationDelegate for push and CloudKit
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage("remoteUserID") private var remoteUserID: String = ""

    // SwiftData container（必ず作成）
    private let sharedModelContainer: ModelContainer

    // DB リセットが発生したかを保持し、UI でアラート表示に使う
    @State private var showDBResetAlert: Bool = false
    
    // Reaction Store
    @State private var reactionStore = ReactionStore()

    init() {
        // makeContainer でリセット有無を inout で受け取る
        var didReset = false
        if let container = Self.makeContainer(resetOccurred: &didReset) {
            sharedModelContainer = container
        } else {
            // 最後の防衛策: 空スキーマでメモリストア
            let schema = Schema([Message.self, Anniversary.self])
            sharedModelContainer = try! ModelContainer(for: schema,
                                                       configurations: [.init(schema: schema,
                                                                              isStoredInMemoryOnly: true)])
            didReset = true
        }

        // アラート表示用 State を初期化
        self._showDBResetAlert = State(initialValue: didReset)
    }

    /// 既存ストアをそのまま開き、失敗時のみ削除してリセット。
    /// - Parameter resetOccurred: リセットが行われた場合 true がセットされる
    /// - Returns: 正常に作成できたコンテナ（失敗時は nil）
    private static func makeContainer(resetOccurred: inout Bool) -> ModelContainer? {
        let schema = Schema([Message.self, Anniversary.self])

        // Application Support のパス
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: appSupport,
                                                 withIntermediateDirectories: true)

        let url = appSupport.appendingPathComponent("MarinEE.sqlite")

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
                if remoteUserID.isEmpty {
                    PairingView()
                } else {
                    TabView {
                        ChatView()
                            .tag(0)
                        
                        CalendarView()
                            .tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .dismissKeyboardOnDrag()
                }
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
