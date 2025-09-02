import SwiftUI
import CloudKit

/// 🌟 [IDEAL SHARING UI] UICloudSharingControllerのSwiftUIラッパー
struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void
    
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        
        // 🌟 [IDEAL SHARING UI] 包括的な共有設定（UIでの権限切替は許可しない）
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowReadWrite]
        controller.modalPresentationStyle = .formSheet
        
        // 共有オプション設定（標準的な設定）
        // UICloudSharingControllerには既にURL共有機能が内蔵されている
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {
        // アップデート処理（必要な場合）
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(share: share, container: container, onDismiss: onDismiss)
    }
    
    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let share: CKShare
        let container: CKContainer
        let onDismiss: () -> Void
        
        init(share: CKShare, container: CKContainer, onDismiss: @escaping () -> Void) {
            self.share = share
            self.container = container
            self.onDismiss = onDismiss
        }
        
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("❌ [IDEAL SHARING UI] Failed to save share: \(error)")
            log("❌ [IDEAL SHARING UI] CloudKit share save failed: \(error.localizedDescription)", category: "CloudSharingController")
            onDismiss()
        }
        
        func itemTitle(for csc: UICloudSharingController) -> String? {
            return "4-Marinチャット"
        }
        
        func itemType(for csc: UICloudSharingController) -> String? {
            return "com.2001y.4-Marin.chatroom"
        }
        
        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            // アプリアイコンや適切なサムネイルがあれば返す
            // 現在はnilでシステムデフォルトを使用
            return nil
        }
        
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            print("✅ [IDEAL SHARING UI] CloudKit share saved successfully")
            log("✅ [IDEAL SHARING UI] CloudKit share invitation sent successfully", category: "CloudSharingController")
            // 共有後の参加者/権限をログに出す（オーナー側確認用）
            let db = container.privateCloudDatabase
            let op = CKFetchRecordsOperation(recordIDs: [share.recordID])
            op.perRecordResultBlock = { [weak self] id, result in
                guard let self = self else { return }
                switch result {
                case .success(let rec):
                    if let fetchedShare = rec as? CKShare {
                        let perm = fetchedShare.currentUserParticipant?.permission
                        log("🔍 [OWNER VERIFY] Share publicPermission=\(self.share.publicPermission.rawValue)", category: "CloudSharingController")
                        log("🔍 [OWNER VERIFY] Owner permission=\(String(describing: perm))", category: "CloudSharingController")
                        for p in fetchedShare.participants {
                            let name = p.userIdentity.nameComponents?.formatted() ?? "<unknown>"
                            log("🔍 [OWNER VERIFY] Participant name=\(name), role=\(p.role), perm=\(p.permission), status=\(p.acceptanceStatus)", category: "CloudSharingController")
                        }
                    }
                case .failure(let error):
                    log("⚠️ [OWNER VERIFY] Failed to fetch share after save: \(error)", category: "CloudSharingController")
                }
            }
            db.add(op)
        }
        
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            print("🔄 [IDEAL SHARING UI] CloudKit sharing stopped")
            log("🔄 [IDEAL SHARING UI] CloudKit sharing stopped by user", category: "CloudSharingController")
            onDismiss()
        }
        
        func cloudSharingController(_ csc: UICloudSharingController, didFailToSaveShareWithError error: Error) {
            print("❌ [IDEAL SHARING UI] Failed to save share: \(error)")
            log("❌ [IDEAL SHARING UI] CloudKit share save failed: \(error.localizedDescription)", category: "CloudSharingController")
            onDismiss()
        }
    }
}

// MARK: - Logging Helper
private func log(_ message: String, category: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(timestamp)] [\(category)] \(message)")
}

#Preview {
    // プレビューでは実際のCKShareは使用できないため、スタブとして空のViewを返す
    Text("CloudSharingController Preview")
        .foregroundColor(.gray)
}
