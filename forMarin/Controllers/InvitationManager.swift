import Foundation
import CloudKit
import UIKit
import SwiftUI

/// CloudKit招待URL管理クラス
/// UICloudSharingControllerを使用してチャットルームの招待機能を提供
@MainActor
class InvitationManager: NSObject, ObservableObject {
    static let shared = InvitationManager()
    
    private let container = CloudKitChatManager.shared.containerForSharing
    private let chatManager = CloudKitChatManager.shared
    
    @Published var isShowingShareSheet = false
    @Published var lastInvitationURL: URL?
    @Published var lastError: Error?
    
    // 現在処理中の共有情報
    private var currentShare: CKShare?
    private var currentRoomRecord: CKRecord?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// チャットルームの招待URLを生成してシェアシートを表示
    func createAndShareInvitation(
        for remoteUserID: String,
        from viewController: UIViewController
    ) async {
        do {
            log("Creating invitation for user: \(remoteUserID)", category: "InvitationManager")
            
            // 1. 共有チャットルームを作成（ゾーン名=roomID を先に確定）
            let roomID = "chat-\(UUID().uuidString.prefix(8))"
            let share = try await chatManager.createSharedChatRoom(roomID: roomID, invitedUserID: remoteUserID)
            let roomRecord = try await chatManager.getRoomRecord(roomID: roomID)
            
            // 2. 現在の共有情報を保存
            currentRoomRecord = roomRecord
            currentShare = share
            
            // 3. UICloudSharingControllerを表示
            await presentCloudSharingController(
                share: share,
                container: container,
                from: viewController
            )
            
            log("Invitation created successfully", category: "InvitationManager")
            
        } catch {
            log("Failed to create invitation: \(error)", category: "InvitationManager")
            lastError = error
        }
    }
    
    /// 既存のチャットルームの招待URLを再共有
    func reshareExistingInvitation(
        roomID: String,
        from viewController: UIViewController
    ) async {
        do {
            log("Resharing existing invitation for room: \(roomID)", category: "InvitationManager")
            
            // 1. 既存のルームレコードを取得
            let roomRecord = try await chatManager.getRoomRecord(roomID: roomID)
            
            // 2. 関連するCKShareを検索
            let share = try await findShareForRoom(roomRecord: roomRecord)
            
            // 3. 現在の共有情報を保存
            currentRoomRecord = roomRecord
            currentShare = share
            
            // 4. UICloudSharingControllerを表示
            await presentCloudSharingController(
                share: share,
                container: container,
                from: viewController
            )
            
            log("Existing invitation reshared successfully", category: "InvitationManager")
            
        } catch {
            log("Failed to reshare invitation: \(error)", category: "InvitationManager")
            lastError = error
        }
    }
    
    /// 招待URLから直接チャットルームに参加（iOS 17+ 前提: モダンAPIのみ）
    func acceptInvitation(from url: URL) async -> Bool {
        do {
            log("Accepting invitation from URL: \(url)", category: "InvitationManager")
            let metadata = try await container.shareMetadata(for: url)
            let share = try await container.accept(metadata)
            log("Successfully accepted share: \(share.recordID)", category: "InvitationManager")
            return true
        } catch {
            log("Failed to accept invitation: \(error)", category: "InvitationManager")
            lastError = error
            return false
        }
    }
    
    // MARK: - Private Methods
    
    /// UICloudSharingControllerを表示
    private func presentCloudSharingController(
        share: CKShare,
        container: CKContainer,
        from viewController: UIViewController
    ) async {
        // SwiftUIの統一モーダル（EnhancedCloudSharingView）で表示
        let hosting = UIHostingController(
            rootView: EnhancedCloudSharingView(
                share: share,
                container: container,
                onDismiss: { viewController.dismiss(animated: true) }
            )
        )
        hosting.modalPresentationStyle = .formSheet
        viewController.present(hosting, animated: true)
    }
    
    /// ルームレコードに関連するCKShareを検索
    private func findShareForRoom(roomRecord: CKRecord) async throws -> CKShare {
        // ゾーン共有に統一: ゾーン内の cloudkit.share を検索
        let zoneID = roomRecord.recordID.zoneID
        let query = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
        let (results, _) = try await container.privateCloudDatabase.records(matching: query, inZoneWith: zoneID)
        for (_, result) in results {
            if let share = try? result.get() as? CKShare {
                return share
            }
        }
        throw InvitationError.shareNotFound
    }
    
    /// SwiftUI用のビューコントローラーを取得
    func getCurrentViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return nil
        }
        
        return window.rootViewController?.topMostViewController()
    }
}

// MARK: - UICloudSharingControllerDelegate

extension InvitationManager: UICloudSharingControllerDelegate {
    
    func cloudSharingController(
        _ csc: UICloudSharingController,
        failedToSaveShareWithError error: Error
    ) {
        log("Failed to save share: \(error)", category: "InvitationManager")
        lastError = error
        csc.dismiss(animated: true)
    }
    
    func itemTitle(for csc: UICloudSharingController) -> String? {
        return "4-Marinチャット招待"
    }
    
    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        // アプリアイコンのサムネイルデータを返す（オプション）
        return nil
    }
    
    func itemType(for csc: UICloudSharingController) -> String? {
        return "com.formarin.chat.invitation"
    }
    
    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        log("Share saved successfully", category: "InvitationManager")
        
        // 共有URLを保存
        if let share = currentShare {
            lastInvitationURL = share.url
        }
        
        csc.dismiss(animated: true)
    }
    
    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        log("Sharing stopped", category: "InvitationManager")
        csc.dismiss(animated: true)
    }
}

// MARK: - Error Types

enum InvitationError: LocalizedError {
    case roomNotFound
    case shareNotFound
    case invalidURL
    case shareAcceptanceFailed
    case userNotAuthenticated
    
    var errorDescription: String? {
        switch self {
        case .roomNotFound:
            return "チャットルームが見つかりません"
        case .shareNotFound:
            return "共有情報が見つかりません"
        case .invalidURL:
            return "無効な招待URLです"
        case .shareAcceptanceFailed:
            return "招待の受け入れに失敗しました"
        case .userNotAuthenticated:
            return "ユーザー認証が必要です"
        }
    }
}

// MARK: - UIViewController Extension

extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }
        
        if let nav = self as? UINavigationController {
            return nav.visibleViewController?.topMostViewController() ?? self
        }
        
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? self
        }
        
        return self
    }
}

// MARK: - SwiftUI Integration

// InvitationView は未使用のため削除しました（CloudSharingControllerView/EnhancedCloudSharingView を使用）
