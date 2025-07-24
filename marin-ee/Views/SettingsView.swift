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

    @State private var showClearChatAlert = false
    @State private var showClearCacheImagesAlert = false
    @State private var showLogoutAlert = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
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
        }
    }

    @ViewBuilder
    private var content: some View {
        Form {
            profileSection
            notificationsSection
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
            Task { await refreshNotificationStatus() }
        }
        // Notification status updates
        .onReceive(NotificationCenter.default.publisher(for: .didUpdateNotifStatus)) { note in
            if let status = note.object as? UNAuthorizationStatus {
                notificationStatus = status
            }
        }
    }

    @ViewBuilder private var profileSection: some View {
        Section(header: Text("プロフィール")) {
            HStack(spacing: 16) {
                // Avatar picker
                PhotosPicker(selection: $photosPickerItem,
                            matching: .images,
                            photoLibrary: .shared()) {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
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
                .buttonStyle(.plain)
                
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
            Task {
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

    @ViewBuilder private var notificationsSection: some View {
        Section(header: Text("通知")) {
            HStack {
                Text("通知許可")
                Spacer()
                Text(statusText).foregroundColor(.secondary)
            }
            if notificationStatus == .notDetermined {
                Button("通知を許可") { requestNotificationPermission() }
            } else if notificationStatus == .denied {
                Button("設定を開く") { openAppSettings() }
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
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            NotificationCenter.default.post(name: .didUpdateNotifStatus, object: settings.authorizationStatus)
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    private func syncProfileToCloudKit() {
        myDisplayName = tempDisplayName
        Task {
            await CKSync.saveProfile(name: myDisplayName, avatarData: myAvatarData)
        }
    }

    // MARK: - Helpers
    private var statusText: String {
        switch notificationStatus {
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

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB]
        f.countStyle = .file
        return f
    }

    // Image cache helpers removed in favour of global ImageCacheManager
} 