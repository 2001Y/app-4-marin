import SwiftUI
import SwiftData
import UserNotifications
import UIKit
import PhotosUI

extension Notification.Name {
    static let didUpdateNotifStatus = Notification.Name("didUpdateNotifStatus")
}

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("myDisplayName") private var myDisplayName: String = ""
    @AppStorage("myAvatarData") private var myAvatarData: Data = Data()
    @AppStorage("autoDownloadImages") private var autoDownloadImages: Bool = false
    @AppStorage("photosFavoriteSync") private var photosFavoriteSync: Bool = true
    @AppStorage("hasShownWelcome") private var hasShownWelcome: Bool = false
    @Environment(\.modelContext) private var modelContext
    @StateObject private var permissionManager = PermissionManager.shared

    @State private var showClearChatAlert = false
    @State private var showClearCacheImagesAlert = false
    @State private var showLogoutAlert = false
    @State private var showResetAlert = false
    @State private var showWelcomeModal = false
    // 特徴ページへの遷移はNavigationLinkで行う
    @State private var showImageDownloadModal = false
    @State private var versionTapCount = 0
    @State private var lastVersionTapTime = Date()

    @State private var cacheSizeBytes: UInt64 = 0
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var selectedImage: UIImage? = nil
    @State private var tempDisplayName: String = ""
    @State private var myUserID: String = ""
    @State private var isRebuildingSchema = false
    @State private var showSchemaRebuildAlert = false
    @State private var showCompleteResetAlert = false
    @State private var showProductionResetConfirm = false
    @State private var showEmergencyResetAlert = false
    @State private var isPerformingReset = false
    @State private var resetErrorMessage = ""
    
    // 統合リセット機能用の状態変数
    @State private var showLocalResetAlert = false
    @State private var showCompleteCloudResetAlert = false
    @State private var isPerformingLocalReset = false
    @State private var isPerformingCloudReset = false
    
    // テスト機能用
    @StateObject private var connectivityManager = ConnectivityManager.shared
    
    // ログ共有機能用
    @State private var isCollectingLogs = false
    @State private var showLogShareSheet = false
    @State private var logFileURL: URL?
    
    // テストモード終了時刻を計算
    private var testModeEndTime: Date? {
        let testUntil = UserDefaults.standard.double(forKey: "testModeScheduledUntil")
        return testUntil > 0 && Date().timeIntervalSince1970 < testUntil ? Date(timeIntervalSince1970: testUntil) : nil
    }

    // CKSyncEngine 簡易状態
    @State private var enginePendingTotal: Int = 0
    @State private var enginePendingRecord: Int = 0
    @State private var enginePendingDB: Int = 0

    private func refreshEngineStats() {
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                let stats = await CKSyncEngineManager.shared.pendingStats()
                self.enginePendingTotal = stats.total
                self.enginePendingRecord = stats.recordChanges
                self.enginePendingDB = stats.databaseChanges
            }
        }
    }
    
    var body: some View {
        ZStack {
            NavigationStack {
                content
            }
            .onAppear {
                // Initialize temp name from stored value
                tempDisplayName = myDisplayName
                // Load avatar image from data
                if !myAvatarData.isEmpty {
                    selectedImage = UIImage(data: myAvatarData)
                }
                // 権限状態を更新
                refreshPermissionStatuses()
                // ユーザーIDを取得（CloudKitの単一ソース）
                Task {
                    if let userID = try? await CloudKitChatManager.shared.ensureCurrentUserID() {
                        await MainActor.run { myUserID = userID }
                    }
                }
            }
            
            // ウェルカムモーダル（経緯）オーバーレイ
            WelcomeReasonModalOverlay(isPresented: $showWelcomeModal) {
                // 「つづける」ボタンが押された時の処理（何もしない）
            }
            
            // 画像ダウンロード設定案内ハーフモーダル
            ImageDownloadModalOverlay(isPresented: $showImageDownloadModal)
        }
    }

    @ViewBuilder
    private var content: some View {
        Form {
            profileSection
            userIDSection
            permissionsSection
            imageSettingsSection
            infoSection
            testSection
            debugShareAcceptSection
            dangerSection
        }
        .navigationTitle("設定")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .modifier(
            PrimaryAlertsModifier(
                showClearChatAlert: $showClearChatAlert,
                showClearCacheImagesAlert: $showClearCacheImagesAlert,
                showLogoutAlert: $showLogoutAlert,
                onClearMessages: clearMessages,
                onClearCacheConfirmed: clearImageCache,
                onLogout: logout
            )
        )
        .modifier(
            ResetAlertsModifier(
                showResetAlert: $showResetAlert,
                showSchemaRebuildAlert: $showSchemaRebuildAlert,
                showCompleteResetAlert: $showCompleteResetAlert,
                onResetApp: resetAppCompletely,
                onCompleteCloudReset: performCompleteCloudReset
            )
        )
        .modifier(
            EmergencyAlertsModifier(
                showProductionResetConfirm: $showProductionResetConfirm,
                showEmergencyResetAlert: $showEmergencyResetAlert,
                resetErrorMessage: resetErrorMessage,
                onPerformProductionEmergencyReset: performProductionEmergencyReset,
                onPerformEmergencyReset: performEmergencyReset
            )
        )
        .modifier(
            UnifiedResetAlertsModifier(
                showLocalResetAlert: $showLocalResetAlert,
                showCompleteCloudResetAlert: $showCompleteCloudResetAlert,
                onPerformLocalReset: performLocalReset,
                onPerformCompleteCloudReset: performCompleteCloudReset
            )
        )
        // ページ遷移に統一（シートは使用しない）
        .sheet(isPresented: $showLogShareSheet) {
            if let url = logFileURL {
                ShareSheet(items: [url])
            }
        }
        // Lifecycle
        .onAppear {
            cacheSizeBytes = ImageCacheManager.currentCacheSize()
            // 権限状態は PermissionManager により自動更新
        }
    }

    @ViewBuilder @MainActor private var profileSection: some View {
        Section(header: Text("プロフィール")) {
            HStack(spacing: 16) {
                // Avatar picker
                Button {
                    // PhotosPicker用のボタンアクション - 何もしない
                } label: {
                    Group {
                        if let image = selectedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                        } else {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .background(
                    PhotosPicker(selection: $photosPickerItem,
                                matching: .images,
                                photoLibrary: .shared()) {
                        Color.clear
                    }
                )
                
                // Name input
                VStack(alignment: .leading, spacing: 4) {
                    Text("表示名")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("名前を入力", text: $tempDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            myDisplayName = tempDisplayName
                            syncProfileToCloudKit()
                        }
                }
            }
            .padding(.vertical, 8)
            
            // Sync status
            HStack {
                Text("プロフィール同期")
                Spacer()
                Button("今すぐ同期") {
                    syncProfileToCloudKit()
                }
                .font(.caption)
            }
        }
        .onChange(of: photosPickerItem) { _, newItem in
            Task { @MainActor in
                if let item = newItem,
                   let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    // Resize and save
                    let resized = uiImage.resized(to: CGSize(width: 200, height: 200))
                    selectedImage = resized
                    if let jpegData = resized.jpegData(compressionQuality: 0.8) {
                        myAvatarData = jpegData
                        syncProfileToCloudKit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var userIDSection: some View {
        Section(header: Text("あなたの ID"), footer: Text("相手がチャットを開始するために必要なIDです。タップでコピーできます。")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ユーザーID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(myUserID.isEmpty ? "取得中..." : myUserID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                }
                
                Spacer()
                
                Button {
                    if !myUserID.isEmpty {
                        UIPasteboard.general.string = myUserID
                        // 触覚フィードバック
                        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                        impactFeedback.impactOccurred()
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                }
                .disabled(myUserID.isEmpty)
            }
            .padding(.vertical, 4)
            
            Button {
                presentInviteShareSheet()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                    Text("招待メッセージをシェア")
                    Spacer()
                }
                .foregroundColor(.accentColor)
            }
            .disabled(myUserID.isEmpty)
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        Section(header: Text("アプリ権限"), footer: Text("アプリの機能を正常に利用するために必要な権限です。拒否された権限は設定アプリから変更できます。")) {
            // カメラ権限
            HStack {
                Label("カメラ", systemImage: "camera")
                Spacer()
                Text(cameraStatusText)
                    .foregroundColor(cameraStatusColor)
                    .fontWeight(.medium)
            }
            
            // 通知権限  
            HStack {
                Label("通知", systemImage: "bell")
                Spacer()
                Text(notificationStatusText)
                    .foregroundColor(notificationStatusColor)
                    .fontWeight(.medium)
            }
            
            // マイク権限
            HStack {
                Label("マイク", systemImage: "mic")
                Spacer()
                Text(microphoneStatusText)
                    .foregroundColor(microphoneStatusColor)
                    .fontWeight(.medium)
            }
            
            // 写真保存権限
            HStack {
                Label("写真保存", systemImage: "photo.badge.plus")
                Spacer()
                Text(photoLibraryStatusText)
                    .foregroundColor(photoLibraryStatusColor)
                    .fontWeight(.medium)
            }
            
            // 拒否された権限がある場合の設定ボタン
            if hasAnyDeniedPermissions {
                Button {
                    permissionManager.openAppSettings()
                } label: {
                    Label("設定アプリで権限を変更", systemImage: "gear")
                }
                .foregroundColor(.blue)
            }
            
            // 未確認の権限がある場合の申請ボタン
            if hasAnyUndeterminedPermissions {
                Button {
                    requestAllPermissions()
                } label: {
                    Label("権限を申請", systemImage: "checkmark.shield")
                }
                .foregroundColor(.green)
            }
        }
    }

    // MARK: - Debug: CloudKit共有URL受諾
    @State private var debugShareURLText: String = ""
    @State private var isAcceptingShareURL: Bool = false
    @State private var acceptResultMessage: String = ""

    @ViewBuilder private var debugShareAcceptSection: some View {
        Section(header: Text("デバッグ: 招待リンクから参加"), footer: Text("CloudKit共有URL（https://www.icloud.com/share/...）を貼り付けて参加を試行します。")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://www.icloud.com/share/...", text: $debugShareURLText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button {
                        Task { await acceptShareFromPastedURL() }
                    } label: {
                        HStack {
                            if isAcceptingShareURL {
                                ProgressView().scaleEffect(0.8)
                                Text("参加処理中…")
                            } else {
                                Image(systemName: "checkmark.circle")
                                Text("リンクで参加")
                            }
                            Spacer()
                        }
                    }
                    .disabled(debugShareURLText.isEmpty || isAcceptingShareURL)
                }
                
                if !acceptResultMessage.isEmpty {
                    Text(acceptResultMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
    
    @ViewBuilder private var imageSettingsSection: some View {
        Section(header: Text("画像設定")) {
            Button {
                showImageDownloadModal = true
            } label: {
                HStack {
                    Text("画像を自動ダウンロード")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            
            Toggle("写真アプリのお気に入りと同期", isOn: $photosFavoriteSync)
        }
    }

    @ViewBuilder private var infoSection: some View {
        Section(header: Text("情報")) {
            NavigationLink(destination: FeaturesPage(showWelcomeModalOnAppear: false, onChatCreated: { _ in }, onDismiss: {})) {
                HStack {
                    Text("このアプリについて")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            
            Button {
                handleVersionTap()
            } label: {
                HStack {
                    Text("App Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            .buttonStyle(.plain)
            Button("画像キャッシュを削除", role: .destructive) { 
                // 触覚フィードバック
                let selectionFeedback = UISelectionFeedbackGenerator()
                selectionFeedback.selectionChanged()
                showClearCacheImagesAlert = true 
            }
            HStack {
                Text("使用容量")
                Spacer()
                Text(byteFormatter.string(fromByteCount: Int64(cacheSizeBytes))).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var testSection: some View {
        if versionTapCount >= 3 {
            Section(header: Text("開発者機能")) {
                HStack {
                    Label("オフライン状態", systemImage: "wifi.slash")
                    Spacer()
                    Text(connectivityManager.isConnected ? "オンライン" : "オフライン")
                        .foregroundColor(connectivityManager.isConnected ? .green : .red)
                        .fontWeight(.medium)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("バックグラウンドタスク", systemImage: "clock")
                        Spacer()
                    }
                    if let nextDate = BackgroundTaskManager.shared.getNextScheduledDate() {
                        Text("次回実行: \(nextDate, style: .relative)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(nextDate, formatter: dateTimeFormatter)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("未スケジュール")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("デバッグ通知モード", isOn: .init(
                        get: { UserDefaults.standard.bool(forKey: "debugNotificationsEnabled") },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: "debugNotificationsEnabled")
                            // デバッグモード変更時にフラグをリセット
                            UserDefaults.standard.set(false, forKey: "didNotifyThisOfflineEpisode")
                            log("デバッグ通知モード: \(newValue ? "有効" : "無効")", category: "DEBUG")
                        }
                    ))
                    Text("有効にするとオンライン状態でもバックグラウンドタスクから通知が送信されます")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Button {
                    Task {
                        await NotificationManager.shared.sendDebugNotification(
                            title: "通知テスト",
                            body: "テスト通知が正常に動作しています"
                        )
                    }
                } label: {
                    HStack {
                        Label("通知テスト", systemImage: "bell.badge")
                        Spacer()
                    }
                }
                .foregroundColor(.blue)
                
                Button {
                    Task {
                        await BackgroundTaskManager.shared.forceExecuteBackgroundTask()
                    }
                } label: {
                    HStack {
                        Label("バックグラウンドタスク強制実行", systemImage: "play.circle")
                        Spacer()
                    }
                }
                .foregroundColor(.green)
                
                Button {
                    connectivityManager.showOfflineModalFromNotification()
                } label: {
                    HStack {
                        Label("オフラインモーダルを表示", systemImage: "exclamationmark.triangle")
                        Spacer()
                    }
                }
                .foregroundColor(.orange)

                // CKSyncEngine 状態
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("CKSyncEngine", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text("pending: \(enginePendingTotal)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("records: \(enginePendingRecord)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("db: \(enginePendingDB)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Button {
                            if #available(iOS 17.0, *) { Task { await CKSyncEngineManager.shared.kickSyncNow() } }
                            refreshEngineStats()
                        } label: {
                            Label("同期キック", systemImage: "paperplane")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            if #available(iOS 17.0, *) { Task { await CKSyncEngineManager.shared.resetEngines() } }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshEngineStats() }
                        } label: {
                            Label("状態リセット", systemImage: "arrow.counterclockwise")
                        }
                        Spacer()
                        Button { refreshEngineStats() } label: {
                            Label("更新", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .onAppear { refreshEngineStats() }
                
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        BackgroundTaskManager.shared.scheduleNextRefresh(after: 30, isTestMode: true) // 30秒後
                    } label: {
                        HStack {
                            Label("バックグラウンドタスクをテスト", systemImage: "arrow.clockwise")
                            Spacer()
                            Text("30秒後")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.purple)
                    
                    if let testEndTime = testModeEndTime {
                        HStack {
                            Text("テストモード終了: \(testEndTime, style: .relative)")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Spacer()
                            Button("停止") {
                                UserDefaults.standard.removeObject(forKey: "testModeScheduledUntil")
                                log("テストモードを手動停止", category: "DEBUG")
                            }
                            .font(.caption2)
                            .foregroundColor(.red)
                        }
                    }
                }
                
                Button {
                    collectAndShareLogs()
                } label: {
                    HStack {
                        if isCollectingLogs {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                                .scaleEffect(0.8)
                            Text("ログ収集中...")
                        } else {
                            Label("ログを共有", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                    }
                }
                .foregroundColor(.accentColor)
                .disabled(isCollectingLogs)
                
                // 統合リセット（CloudKit含む完全初期化）
                Button {
                    showCompleteCloudResetAlert = true
                } label: {
                    HStack {
                        if isPerformingCloudReset {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .red))
                                .scaleEffect(0.8)
                            Text("完全初期化中...")
                        } else {
                            Label("完全初期化（CloudKit含む）", systemImage: "trash")
                        }
                        Spacer()
                    }
                }
                .foregroundColor(.red)
                .disabled(isPerformingCloudReset)
            }
        }
    }

    @ViewBuilder private var dangerSection: some View {
        Section(header: Text("デンジャーゾーン")) {
            Button("全メッセージを削除", role: .destructive) { showClearChatAlert = true }
            Button("ログアウト", role: .destructive) { showLogoutAlert = true }
        }
    }

    // MARK: - Actions
    private func clearMessages() {
        // 触覚フィードバック
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        do {
            let all = try modelContext.fetch(FetchDescriptor<Message>())
            for m in all { modelContext.delete(m) }
        } catch { log("Error: \(error)", category: "App") }
    }

    private func clearImageCache() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()

        ImageCacheManager.clearCache()
        cacheSizeBytes = 0
    }

    private func logout() {
        // 全てのチャットルームを削除
        do {
            let allRooms = try modelContext.fetch(FetchDescriptor<ChatRoom>())
            for room in allRooms { modelContext.delete(room) }
        } catch { log("Error: \(error)", category: "App") }
        
        clearMessages()
        ImageCacheManager.clearCache()
    }

    private func requestNotificationPermission() {
        Task {
            do {
                try await permissionManager.requestNotificationPermission()
            } catch {
                log("Failed to request notification permission: \(error)", category: "App")
            }
        }
    }
    
    private func requestAllPermissions() {
        Task {
            do {
                // チャット用権限を申請
                try await permissionManager.requestChatPermissions()
                log("Chat permissions granted", category: "App")
            } catch {
                log("Failed to request chat permissions: \(error)", category: "App")
            }
            
            do {
                // デュアルカメラ用権限を申請
                try await permissionManager.requestDualCameraPermissions()
                log("Dual camera permissions granted", category: "App")
            } catch {
                log("Failed to request dual camera permissions: \(error)", category: "App")
            }
            
            // 権限申請後に状態を更新
            refreshPermissionStatuses()
        }
    }

    // 統合リセット実行
    // unifiedResetAll は役割重複のため削除（performCompleteCloudReset に統一）
    
    private func refreshPermissionStatuses() {
        Task { @MainActor in
            // PermissionManagerの状態を更新
            await permissionManager.updateStatuses()
        }
    }

    // 共有URLの受諾（デバッグ）
    private func acceptShareFromPastedURL() async {
        guard let url = URL(string: debugShareURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            acceptResultMessage = "不正なURLです"
            return
        }
        isAcceptingShareURL = true
        acceptResultMessage = ""
        defer { isAcceptingShareURL = false }
        
        // アプリ内で受諾を実行
        let ok = await InvitationManager.shared.acceptInvitation(from: url)
        if ok {
            acceptResultMessage = "共有の受諾に成功しました。チャットを読み込みます…"
            // 受諾後、Shared DBからローカルChatRoomを生成
            await CloudKitChatManager.shared.bootstrapSharedRooms(modelContext: modelContext)
        } else {
            acceptResultMessage = "共有の受諾に失敗しました。ログをご確認ください。"
        }
    }

    private func handleVersionTap() {
        let now = Date()
        
        // 前回のタップから2秒以内かどうかチェック
        if now.timeIntervalSince(lastVersionTapTime) < 2.0 {
            versionTapCount += 1
        } else {
            versionTapCount = 1
        }
        
        lastVersionTapTime = now
    }
    
    private func clearAllChatRooms() {
        do {
            let allRooms = try modelContext.fetch(FetchDescriptor<ChatRoom>())
            for room in allRooms {
                modelContext.delete(room)
            }
            try modelContext.save()
        } catch {
            log("Failed to clear chat rooms: \(error)", category: "App")
        }
    }
    
    private func resetAppCompletely() {
        // @AppStorage のリセット
        hasShownWelcome = false
        myDisplayName = ""
        myAvatarData = Data()
        autoDownloadImages = false
        photosFavoriteSync = true
        
        // 他のファイルの@AppStorageもリセット
        UserDefaults.standard.removeObject(forKey: "recentEmojis")
        UserDefaults.standard.removeObject(forKey: "schemaVersion")
        UserDefaults.standard.removeObject(forKey: "nextBackgroundTaskScheduled")
        UserDefaults.standard.removeObject(forKey: "debugNotificationsEnabled")
        UserDefaults.standard.removeObject(forKey: "didNotifyThisOfflineEpisode")
        UserDefaults.standard.removeObject(forKey: "lastOnlineAt")
        UserDefaults.standard.removeObject(forKey: "showOfflineModal")
        
        // UI状態のリセット
        selectedImage = nil
        tempDisplayName = ""
        versionTapCount = 0
        
        // 触覚フィードバック
        let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
        impactFeedback.impactOccurred()
        
        // 設定画面を閉じる
        dismiss()
        
        log("アプリ完全初期化: 全ての設定とデータをリセットしました", category: "DEBUG")
        log("ウェルカムモーダルを表示するにはアプリを再起動してください", category: "DEBUG")
    }

    private func syncProfileToCloudKit() {
        myDisplayName = tempDisplayName
        Task {
            try? await CloudKitChatManager.shared.saveMasterProfile(
                name: myDisplayName,
                avatarData: myAvatarData
            )
            // 共有中の全ゾーンへ同報
            await CloudKitChatManager.shared.updateParticipantProfileInAllZones(
                name: myDisplayName,
                avatarData: myAvatarData
            )
        }
    }
    
    // MARK: - CloudKit Reset Functions
    
    private func performCompleteReset() {
        Task {
            await MainActor.run {
                isPerformingReset = true
            }
            
            do {
                // 本番環境かどうかを確認
                let isProduction = CloudKitChatManager.shared.checkIsProductionEnvironment()
                if isProduction {
                    // 本番環境の場合は確認ダイアログを表示
                    await MainActor.run {
                        isPerformingReset = false
                        showProductionResetConfirm = true
                    }
                    return
                }
                
                // 開発環境での完全リセット実行
                try await CloudKitChatManager.shared.performCompleteReset(bypassSafetyCheck: false)
                
                await MainActor.run {
                    isPerformingReset = false
                    resetAppCompletely() // アプリローカルデータもリセット
                }
                
                log("CloudKit完全リセットが完了しました", category: "DEBUG")
                
            } catch {
                await MainActor.run {
                    isPerformingReset = false
                    resetErrorMessage = "リセットに失敗しました: \(error.localizedDescription)"
                    log("CloudKit完全リセット失敗: \(error)", category: "ERROR")
                }
            }
        }
    }
    
    private func performProductionEmergencyReset() {
        Task {
            await MainActor.run {
                isPerformingReset = true
            }
            
            do {
                // 本番環境での強制リセット実行
                try await CloudKitChatManager.shared.performCompleteReset(bypassSafetyCheck: true)
                
                await MainActor.run {
                    isPerformingReset = false
                    resetAppCompletely() // アプリローカルデータもリセット
                }
                
                log("本番環境でのCloudKit緊急リセットが完了しました", category: "DEBUG")
                
            } catch {
                await MainActor.run {
                    isPerformingReset = false
                    resetErrorMessage = "緊急リセットに失敗しました: \(error.localizedDescription)"
                    log("本番環境CloudKit緊急リセット失敗: \(error)", category: "ERROR")
                }
            }
        }
    }
    
    private func performEmergencyReset() {
        Task {
            await MainActor.run {
                isPerformingReset = true
            }
            
            do {
                // 緊急リセット実行（エラー状況の詳細を取得）
                try await CloudKitChatManager.shared.performEmergencyReset()
                
                await MainActor.run {
                    isPerformingReset = false
                    resetAppCompletely() // アプリローカルデータもリセット
                }
                
                log("CloudKit緊急リセットが完了しました", category: "DEBUG")
                
            } catch {
                await MainActor.run {
                    isPerformingReset = false
                    resetErrorMessage = "緊急リセットに失敗しました: \(error.localizedDescription)"
                    log("CloudKit緊急リセット失敗: \(error)", category: "ERROR")
                }
            }
        }
    }

    // MARK: - Helpers
    
    // 権限状態のテキスト
    private var cameraStatusText: String {
        switch permissionManager.cameraStatus {
        case .authorized:
            return "許可済み"
        case .denied, .restricted:
            return "拒否"
        case .notDetermined:
            return "未確認"
        @unknown default:
            return "-"
        }
    }
    
    private var notificationStatusText: String {
        switch permissionManager.notificationStatus {
        case .authorized, .provisional:
            return "許可済み"
        case .ephemeral:
            return "一時許可"
        case .denied:
            return "拒否"
        case .notDetermined:
            return "未確認"
        @unknown default:
            return "-"
        }
    }
    
    private var microphoneStatusText: String {
        switch permissionManager.microphoneStatus {
        case .authorized:
            return "許可済み"
        case .denied, .restricted:
            return "拒否"
        case .notDetermined:
            return "未確認"
        @unknown default:
            return "-"
        }
    }
    
    private var photoLibraryStatusText: String {
        switch permissionManager.photoLibraryStatus {
        case .authorized:
            return "許可済み"
        case .limited:
            return "制限付き"
        case .denied, .restricted:
            return "拒否"
        case .notDetermined:
            return "未確認"
        @unknown default:
            return "-"
        }
    }
    
    // 権限状態の色
    private var cameraStatusColor: Color {
        switch permissionManager.cameraStatus {
        case .authorized: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        @unknown default: return .gray
        }
    }
    
    private var notificationStatusColor: Color {
        switch permissionManager.notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        @unknown default: return .gray
        }
    }
    
    private var microphoneStatusColor: Color {
        switch permissionManager.microphoneStatus {
        case .authorized: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        @unknown default: return .gray
        }
    }
    
    private var photoLibraryStatusColor: Color {
        switch permissionManager.photoLibraryStatus {
        case .authorized, .limited: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        @unknown default: return .gray
        }
    }
    
    // 拒否された権限があるか
    private var hasAnyDeniedPermissions: Bool {
        permissionManager.cameraStatus == .denied ||
        permissionManager.notificationStatus == .denied ||
        permissionManager.microphoneStatus == .denied ||
        [.denied, .restricted].contains(permissionManager.photoLibraryStatus)
    }
    
    // 未確認の権限があるか
    private var hasAnyUndeterminedPermissions: Bool {
        permissionManager.cameraStatus == .notDetermined ||
        permissionManager.notificationStatus == .notDetermined ||
        permissionManager.microphoneStatus == .notDetermined ||
        permissionManager.photoLibraryStatus == .notDetermined
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB]
        f.countStyle = .file
        return f
    }
    
    private var dateTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        f.locale = Locale.current
        return f
    }
    
    // MARK: - Log Sharing
    
    private func collectAndShareLogs() {
        Task {
            await MainActor.run {
                isCollectingLogs = true
            }
            
            // ログを収集
            if let fileURL = await LogCollector.shared.collectLogsAsFile() {
                await MainActor.run {
                    logFileURL = fileURL
                    isCollectingLogs = false
                    showLogShareSheet = true
                }
            } else {
                await MainActor.run {
                    isCollectingLogs = false
                    // エラーハンドリング（必要に応じて）
                    log("ログファイルの作成に失敗しました", category: "SettingsView")
                }
            }
        }
    }

    // Image cache helpers removed in favour of global ImageCacheManager

    // MARK: - 統合リセット機能
    /// ローカルリセット：CloudKitデータに触れずにローカルキャッシュと設定のみクリア
    private func performLocalReset() {
        Task {
            await MainActor.run {
                isPerformingLocalReset = true
            }
            
            do {
                // 1. CloudKitChatManagerのローカルリセット
                try await CloudKitChatManager.shared.performLocalReset()
                
                await MainActor.run {
                    isPerformingLocalReset = false
                    log("ローカルリセットが完了しました", category: "SettingsView")
                }
                
            } catch {
                await MainActor.run {
                    isPerformingLocalReset = false
                    log("ローカルリセットエラー: \(error)", category: "SettingsView")
                }
            }
        }
    }
    
    /// クラウドを含めた完全リセット：CloudKitデータを含む全データを削除
    private func performCompleteCloudReset() {
        Task {
            await MainActor.run {
                isPerformingCloudReset = true
            }
            
            do {
                // 1. CloudKitChatManagerの完全クラウドリセット
                try await CloudKitChatManager.shared.performCompleteCloudReset()
                
                // 2. ローカルアプリデータも完全初期化
                await MainActor.run {
                    resetAppCompletely()
                    isPerformingCloudReset = false
                    log("完全クラウドリセットが完了しました", category: "SettingsView")
                }
                
            } catch {
                await MainActor.run {
                    isPerformingCloudReset = false
                    log("完全クラウドリセットエラー: \(error)", category: "SettingsView")
                }
            }
        }
    }
    
    // Extracted function to reduce complexity in view builder
    // MARK: - View Modifiers
    private struct PrimaryAlertsModifier: ViewModifier {
        @Binding var showClearChatAlert: Bool
        @Binding var showClearCacheImagesAlert: Bool
        @Binding var showLogoutAlert: Bool
        let onClearMessages: () -> Void
        let onClearCacheConfirmed: () -> Void
        let onLogout: () -> Void

        func body(content: Content) -> some View {
            content
                .alert("本当に削除しますか？", isPresented: $showClearChatAlert) {
                    Button("削除", role: .destructive, action: onClearMessages)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("このデバイスに保存されているメッセージが全て消えます。")
                }
                .alert("画像キャッシュを削除しますか？", isPresented: $showClearCacheImagesAlert) {
                    Button("削除", role: .destructive, action: onClearCacheConfirmed)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("キャッシュフォルダ内の画像ファイルが削除されます。CloudKit から再取得可能です。")
                }
                .alert("ログアウトしますか？", isPresented: $showLogoutAlert) {
                    Button("ログアウト", role: .destructive, action: onLogout)
                    Button("キャンセル", role: .cancel) {}
                }
        }
    }

    private struct ResetAlertsModifier: ViewModifier {
        @Binding var showResetAlert: Bool
        @Binding var showSchemaRebuildAlert: Bool
        @Binding var showCompleteResetAlert: Bool
        let onResetApp: () -> Void
        let onCompleteCloudReset: () -> Void

        func body(content: Content) -> some View {
            content
                .alert("アプリ完全初期化", isPresented: $showResetAlert) {
                    Button("初期化", role: .destructive, action: onResetApp)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("アプリを初回起動状態にリセットし、全てのデータが削除されます。初期化後、アプリを手動で再起動してください。")
                }
                .alert("スキーマ再構築完了", isPresented: $showSchemaRebuildAlert) {
                    Button("OK") {}
                } message: {
                    Text("CloudKitスキーマの再構築が完了しました。アプリを再起動して変更を反映してください。")
                }
                .alert("CloudKit完全リセット", isPresented: $showCompleteResetAlert) {
                    Button("リセット", role: .destructive, action: onCompleteCloudReset)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("CloudKitデータベースを完全にリセットします。全てのチャットデータ、プロフィール、設定が削除されます。この操作は取り消せません。")
                }
        }
    }

    private struct EmergencyAlertsModifier: ViewModifier {
        @Binding var showProductionResetConfirm: Bool
        @Binding var showEmergencyResetAlert: Bool
        let resetErrorMessage: String
        let onPerformProductionEmergencyReset: () -> Void
        let onPerformEmergencyReset: () -> Void

        func body(content: Content) -> some View {
            content
                .alert("本番環境での緊急リセット", isPresented: $showProductionResetConfirm) {
                    Button("強制実行", role: .destructive, action: onPerformProductionEmergencyReset)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("本番環境で緊急リセットを実行します。全てのユーザーデータが失われます。本当に実行しますか？")
                }
                .alert("緊急リセット", isPresented: $showEmergencyResetAlert) {
                    Button("実行", role: .destructive, action: onPerformEmergencyReset)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("データ破損などの緊急時にリセットを実行します。\n\n\(resetErrorMessage)")
                }
        }
    }

    private struct UnifiedResetAlertsModifier: ViewModifier {
        @Binding var showLocalResetAlert: Bool
        @Binding var showCompleteCloudResetAlert: Bool
        let onPerformLocalReset: () -> Void
        let onPerformCompleteCloudReset: () -> Void

        func body(content: Content) -> some View {
            content
                .alert("ローカルリセット", isPresented: $showLocalResetAlert) {
                    Button("リセット", role: .destructive, action: onPerformLocalReset)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("ローカルキャッシュ、画像キャッシュ、設定をクリアします。\nCloudKitのデータは保持されます。")
                }
                .alert("完全初期化（CloudKit含む）", isPresented: $showCompleteCloudResetAlert) {
                    Button("完全初期化", role: .destructive, action: onPerformCompleteCloudReset)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("CloudKit・ローカルを含む全てのデータを削除します。\n⚠️ この操作は取り消せません")
                }
        }
    }

    private func presentInviteShareSheet() {
        let shareText = """
        4-Marinで一緒にチャットしませんか？ 🌊
        
        私のID: \(myUserID)
        
        アプリをダウンロードして、上記のIDを追加してください！
        遠距離でも、一緒に開いてる時は顔が見える特別なメッセージアプリです。
        
        https://apps.apple.com/app/4-marin/id123456789
        """

        let activityVC = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            activityVC.popoverPresentationController?.sourceView = window
            rootVC.present(activityVC, animated: true)
        }
    }
}
    
// MARK: - 画像ダウンロード設定案内ハーフモーダル
struct ImageDownloadModalView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // ドラッグインジケーター
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)
            
            VStack(spacing: 24) {
                // アイコン
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 50))
                    .foregroundColor(.accentColor)
                
                // タイトル
                Text("個別設定をご利用ください")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                // 説明文
                VStack(spacing: 16) {
                    Text("画像の自動ダウンロード設定は、相手ごとに個別で設定できるようになりました。")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                    
                    Text("各チャット画面から相手のプロフィールを開いて設定してください。")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                
                // 分かりましたボタン
                Button {
                    dismiss()
                } label: {
                    Text("分かりました")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .cornerRadius(20, corners: [.topLeft, .topRight])
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: -2)
    }
}

// 画像ダウンロード設定案内ハーフモーダル表示用のオーバーレイ
struct ImageDownloadModalOverlay: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            if isPresented {
                // 背景のディミング
                Color.black.opacity(0.4)
                    .ignoresSafeArea(.all, edges: .all)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                    }
                
                // モーダル本体
                VStack {
                    Spacer()
                    ImageDownloadModalView()
                        .onDisappear {
                            isPresented = false
                        }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isPresented)
    }
}
