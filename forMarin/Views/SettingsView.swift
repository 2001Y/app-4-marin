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
    @Environment(\.modelContext) private var modelContext
    @StateObject private var permissionManager = PermissionManager.shared

    @State private var showClearChatAlert = false
    @State private var showClearCacheImagesAlert = false
    @State private var showLogoutAlert = false
    @State private var showResetAlert = false

    @State private var cacheSizeBytes: UInt64 = 0
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var selectedImage: UIImage? = nil
    @State private var tempDisplayName: String = ""
    
    var body: some View {
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
        }
    }

    @ViewBuilder
    private var content: some View {
        Form {
            profileSection
            permissionsSection
            imageSettingsSection
            infoSection
            dangerSection
        }
        .navigationTitle("設定")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        // Alerts
        .alert("本当に削除しますか？", isPresented: $showClearChatAlert) {
            Button("削除", role: .destructive) { clearMessages() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このデバイスに保存されているメッセージが全て消えます。")
        }
        .alert("画像キャッシュを削除しますか？", isPresented: $showClearCacheImagesAlert) {
            Button("削除", role: .destructive) {
                ImageCacheManager.clearCache()
                cacheSizeBytes = 0
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("キャッシュフォルダ内の画像ファイルが削除されます。CloudKit から再取得可能です。")
        }
        .alert("ログアウトしますか？", isPresented: $showLogoutAlert) {
            Button("ログアウト", role: .destructive) { logout() }
            Button("キャンセル", role: .cancel) {}
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
    
    @ViewBuilder private var imageSettingsSection: some View {
        Section(header: Text("画像設定")) {
            Toggle("画像を自動ダウンロード", isOn: $autoDownloadImages)
            Toggle("写真アプリのお気に入りと同期", isOn: $photosFavoriteSync)
        }
    }

    @ViewBuilder private var infoSection: some View {
        Section(header: Text("情報")) {
            HStack {
                Text("App Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .foregroundColor(.secondary)
            }
            Button("画像キャッシュを削除", role: .destructive) { showClearCacheImagesAlert = true }
            HStack {
                Text("使用容量")
                Spacer()
                Text(byteFormatter.string(fromByteCount: Int64(cacheSizeBytes))).foregroundColor(.secondary)
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
        do {
            let all = try modelContext.fetch(FetchDescriptor<Message>())
            for m in all { modelContext.delete(m) }
        } catch { print(error) }
    }

    private func logout() {
        // 全てのチャットルームを削除
        do {
            let allRooms = try modelContext.fetch(FetchDescriptor<ChatRoom>())
            for room in allRooms { modelContext.delete(room) }
        } catch { print(error) }
        
        clearMessages()
        ImageCacheManager.clearCache()
    }

    private func requestNotificationPermission() {
        Task {
            do {
                try await permissionManager.requestNotificationPermission()
            } catch {
                print("Failed to request notification permission: \(error)")
            }
        }
    }
    
    private func requestAllPermissions() {
        Task {
            do {
                // チャット用権限を申請
                try await permissionManager.requestChatPermissions()
                print("Chat permissions granted")
            } catch {
                print("Failed to request chat permissions: \(error)")
            }
            
            do {
                // デュアルカメラ用権限を申請
                try await permissionManager.requestDualCameraPermissions()
                print("Dual camera permissions granted")
            } catch {
                print("Failed to request dual camera permissions: \(error)")
            }
            
            // 権限申請後に状態を更新
            refreshPermissionStatuses()
        }
    }
    
    private func refreshPermissionStatuses() {
        Task { @MainActor in
            // PermissionManagerの状態を更新
            await permissionManager.updateStatuses()
        }
    }

    private func syncProfileToCloudKit() {
        myDisplayName = tempDisplayName
        Task {
            await CKSync.saveProfile(name: myDisplayName, avatarData: myAvatarData)
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

    // Image cache helpers removed in favour of global ImageCacheManager
} 