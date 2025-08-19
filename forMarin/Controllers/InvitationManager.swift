import Foundation
import CloudKit
import UIKit
import SwiftUI

/// CloudKit招待URL管理クラス
/// UICloudSharingControllerを使用してチャットルームの招待機能を提供
@MainActor
class InvitationManager: NSObject, ObservableObject {
    static let shared = InvitationManager()
    
    private let container = CKContainer(identifier: "iCloud.forMarin-test")
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
            
            // 1. 共有チャットルームを作成
            let (roomRecord, share) = try await chatManager.createSharedChatRoom(with: remoteUserID)
            
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
            guard let roomRecord = await chatManager.getRoomRecord(for: roomID) else {
                throw InvitationError.roomNotFound
            }
            
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
    
    /// 招待URLから直接チャットルームに参加
    func acceptInvitation(from url: URL) async -> Bool {
        do {
            log("Accepting invitation from URL: \(url)", category: "InvitationManager")
            
            // 1. CloudKit招待URLからCKShareMetadataを取得
            let metadata = try await container.shareMetadata(for: url)
            
            // 2. CKShareを受け入れ（現代的なアプローチ）
            if #available(iOS 15.0, *) {
                let share = try await container.accept(metadata)
                log("Successfully accepted share: \(share.recordID)", category: "InvitationManager")
                return true
            } else {
                // iOS 14以下のフォールバック
                let acceptShareOperation = CKAcceptSharesOperation(shareMetadatas: [metadata])
                
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    acceptShareOperation.perShareCompletionBlock = { shareMetadata, share, error in
                        if let error = error {
                            log("Failed to accept share: \(error)", category: "InvitationManager")
                            continuation.resume(returning: false)
                        } else if share != nil {
                            log("Successfully accepted share", category: "InvitationManager")
                            continuation.resume(returning: true)
                        } else {
                            log("Unknown result when accepting share", category: "InvitationManager")
                            continuation.resume(returning: false)
                        }
                    }
                    
                    container.add(acceptShareOperation)
                }
            }
            
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
        let cloudSharingController = UICloudSharingController(
            share: share,
            container: container
        )
        
        cloudSharingController.delegate = self
        cloudSharingController.availablePermissions = [.allowReadWrite]
        cloudSharingController.modalPresentationStyle = .formSheet
        
        // メインスレッドでUI表示
        viewController.present(cloudSharingController, animated: true)
    }
    
    /// ルームレコードに関連するCKShareを検索
    private func findShareForRoom(roomRecord: CKRecord) async throws -> CKShare {
        let shareQuery = CKQuery(
            recordType: "cloudkit.share",
            predicate: NSPredicate(format: "rootRecord == %@", roomRecord.recordID)
        )
        
        let (results, _) = try await container.privateCloudDatabase.records(matching: shareQuery)
        
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

struct InvitationView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowReadWrite]
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {
        // 更新処理は不要
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let parent: InvitationView
        
        init(_ parent: InvitationView) {
            self.parent = parent
        }
        
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            parent.isPresented = false
        }
        
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            parent.isPresented = false
        }
        
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            log("Failed to save share: \(error)", category: "InvitationView")
            parent.isPresented = false
        }
        
        func itemTitle(for csc: UICloudSharingController) -> String? {
            return "4-Marin チャット招待"
        }
    }
}