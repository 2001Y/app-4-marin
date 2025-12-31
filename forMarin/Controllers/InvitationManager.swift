import Foundation
import CloudKit
import UIKit
import SwiftUI

/// CloudKit招待URL管理クラス
/// CKShareのURLを生成してシェアシートへ橋渡しする
@MainActor
class InvitationManager: NSObject, ObservableObject, UICloudSharingControllerDelegate {
    static let shared = InvitationManager()
    
    private let container = CloudKitChatManager.shared.containerForSharing
    private let chatManager = CloudKitChatManager.shared
    
    @Published var lastInvitationURL: URL?
    @Published var lastError: Error?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// 既存チャットルームの共有URLを取得してシェアシートを表示
    func reshareExistingInvitation(
        roomID: String,
        from viewController: UIViewController
    ) async {
        lastError = nil
        do {
            let descriptor = try await chatManager.fetchShare(for: roomID)
            lastInvitationURL = descriptor.shareURL
            presentCloudShareController(descriptor: descriptor, from: viewController)
            log("✅ [InvitationManager] Reshared invitation roomID=\(roomID)", category: "InvitationManager")
        } catch {
            lastError = error
            log("❌ [InvitationManager] Failed to reshare invitation roomID=\(roomID): \(error)", category: "InvitationManager")
        }
    }
    
    /// 新しいチャットルームを作成し、共有URLを生成してシェアシートを表示
    func createAndShareInvitation(
        for contactIdentifier: String,
        from viewController: UIViewController
    ) async {
        lastError = nil
        let trimmed = contactIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = CloudKitChatManager.CloudKitChatError.invalidUserID
            log("⚠️ [InvitationManager] Empty invitee identifier", category: "InvitationManager")
            return
        }
        do {
            let roomID = CKSchema.makeZoneName()
            let descriptor = try await chatManager.createSharedChatRoom(roomID: roomID, invitedUserID: trimmed)
            lastInvitationURL = descriptor.shareURL
            presentCloudShareController(descriptor: descriptor, from: viewController)
            log("✅ [InvitationManager] Created invitation roomID=\(roomID)", category: "InvitationManager")
        } catch {
            lastError = error
            log("❌ [InvitationManager] Failed to create invitation: \(error)", category: "InvitationManager")
        }
    }
    
    /// 招待URLから直接チャットルームに参加
    /// ★整理: 受諾処理はCloudKitShareHandlerに統一（重複実行を防止）
    func acceptInvitation(from url: URL) async -> Bool {
        do {
            log("⬇️ [InvitationManager] Accepting invitation from URL: \(url)", category: "InvitationManager")
            let metadata = try await container.shareMetadata(for: url)
            log("📋 [InvitationManager] Delegating to CloudKitShareHandler", category: "InvitationManager")
            
            // ★CloudKitShareHandlerに委譲（受諾処理を一本化）
            await CloudKitShareHandler.shared.acceptShare(from: metadata)
            return true
        } catch {
            log("❌ [InvitationManager] Failed to get share metadata: \(error)", category: "InvitationManager")
            lastError = error
            return false
        }
    }

    /// ローカルに保持している招待参照（URL）が既に無効な場合にクリーンアップ（冪等）
    func cleanupOrphanedInviteReferences() async {
        guard let url = lastInvitationURL else { return }
        do {
            _ = try await container.shareMetadata(for: url)
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                lastInvitationURL = nil
                log("🧹 [InvitationManager] Removed orphaned local invite reference (unknownItem)", category: "InvitationManager")
            } else {
                log("⚠️ [InvitationManager] Failed to validate local invite reference: \(error)", category: "InvitationManager")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func presentCloudShareController(
        descriptor: CloudKitChatManager.ChatShareDescriptor,
        from viewController: UIViewController
    ) {
        let controller = UICloudSharingController(share: descriptor.share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = self
        controller.modalPresentationStyle = .formSheet
        viewController.present(controller, animated: true)
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

// MARK: - UICloudSharingControllerDelegate

extension InvitationManager {
    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        log("✅ [InvitationManager] Share dialog completed", category: "InvitationManager")
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        log("ℹ️ [InvitationManager] Share dialog dismissed", category: "InvitationManager")
    }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        lastError = error
        log("❌ [InvitationManager] Share dialog failed: \(error)", category: "InvitationManager")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        "4-Marinチャット"
    }
}
