import Foundation
import UIKit
import AVFoundation
import UserNotifications
import Photos

/// アプリの権限申請を段階的に管理するクラス
/// - チャット画面: カメラ・通知権限
/// - デュアルカメラ: 写真保存・マイク権限
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()
    
    @Published var cameraStatus: AVAuthorizationStatus = .notDetermined
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var photoLibraryStatus: PHAuthorizationStatus = .notDetermined
    @Published var microphoneStatus: AVAuthorizationStatus = .notDetermined
    
    private init() {
        initialUpdateStatuses()
    }
    
    // MARK: - Status Updates
    
    func updateStatuses() async {
        await MainActor.run {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        }
        
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            notificationStatus = settings.authorizationStatus
        }
    }
    
    private func initialUpdateStatuses() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationStatus = settings.authorizationStatus
            }
        }
    }
    
    // MARK: - Chat Screen Permissions (カメラ・通知)
    
    /// チャット画面表示時に呼ぶ - カメラと通知権限を申請
    func requestChatPermissions() async throws {
        try await requestCameraPermissionIfNeeded()
        try await requestNotificationPermission()
    }
    
    func requestCameraPermissionIfNeeded() async throws {
        switch cameraStatus {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
            if !granted {
                throw PermissionError.cameraAccessDenied
            }
        case .denied, .restricted:
            throw PermissionError.cameraAccessDenied
        case .authorized:
            break
        @unknown default:
            throw PermissionError.cameraAccessDenied
        }
    }
    
    func requestNotificationPermission() async throws {
        switch notificationStatus {
        case .notDetermined:
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationStatus = settings.authorizationStatus
            }
            if !granted {
                throw PermissionError.notificationAccessDenied
            }
            // Remote notification登録はAppDelegate側で一元管理
        case .denied:
            throw PermissionError.notificationAccessDenied
        case .authorized, .provisional, .ephemeral:
            // Remote notification登録はAppDelegate側で一元管理
            break
        @unknown default:
            throw PermissionError.notificationAccessDenied
        }
    }
    
    // MARK: - Dual Camera Permissions (写真保存・マイク)
    
    /// デュアルカメラ録画開始時に呼ぶ - 写真保存とマイク権限を申請
    func requestDualCameraPermissions() async throws {
        try await requestPhotoLibraryPermission()
        try await requestMicrophonePermission()
    }
    
    private func requestPhotoLibraryPermission() async throws {
        switch photoLibraryStatus {
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            await MainActor.run {
                photoLibraryStatus = status
            }
            if status != .authorized && status != .limited {
                throw PermissionError.photoLibraryAccessDenied
            }
        case .denied, .restricted:
            throw PermissionError.photoLibraryAccessDenied
        case .authorized, .limited:
            break
        @unknown default:
            throw PermissionError.photoLibraryAccessDenied
        }
    }
    
    private func requestMicrophonePermission() async throws {
        switch microphoneStatus {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            }
            if !granted {
                throw PermissionError.microphoneAccessDenied
            }
        case .denied, .restricted:
            throw PermissionError.microphoneAccessDenied
        case .authorized:
            break
        @unknown default:
            throw PermissionError.microphoneAccessDenied
        }
    }
    
    // MARK: - Helper Methods
    
    /// カメラ権限が取得済みかどうか
    var isCameraAuthorized: Bool {
        cameraStatus == .authorized
    }
    
    /// すべての必要な権限が取得済みかどうか
    var areAllPermissionsGranted: Bool {
        cameraStatus == .authorized &&
        notificationStatus == .authorized &&
        photoLibraryStatus == .authorized &&
        microphoneStatus == .authorized
    }
    
    /// アプリ設定画面を開く
    func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Permission Errors

enum PermissionError: LocalizedError {
    case cameraAccessDenied
    case microphoneAccessDenied
    case photoLibraryAccessDenied
    case notificationAccessDenied
    
    var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            return "カメラへのアクセスが必要です。設定アプリで権限を許可してください。"
        case .microphoneAccessDenied:
            return "マイクへのアクセスが必要です。設定アプリで権限を許可してください。"
        case .photoLibraryAccessDenied:
            return "写真への保存権限が必要です。設定アプリで権限を許可してください。"
        case .notificationAccessDenied:
            return "通知の権限が必要です。設定アプリで権限を許可してください。"
        }
    }
} 
