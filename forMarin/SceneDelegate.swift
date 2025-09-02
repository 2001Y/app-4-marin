import UIKit
import CloudKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // iOS 13+ での CloudKit 共有受諾エントリポイント（UIWindowSceneDelegate の正しいシグネチャ）
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        log("🚨 [INVITATION RECEIVED] === CloudKit Share Invitation Received in SceneDelegate ===", category: "SceneDelegate")
        log("🚨 [INVITATION RECEIVED] Container ID: \(metadata.containerIdentifier)", category: "SceneDelegate")
        log("🚨 [INVITATION RECEIVED] Share RecordID: \(metadata.share.recordID.recordName)", category: "SceneDelegate")
        CloudKitShareHandler.shared.acceptShare(from: metadata)
    }

    // シーン接続時の引数（URLContexts等）を可視化し、必要に応じて受諾を実施
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let meta = connectionOptions.cloudKitShareMetadata {
            log("[WILL CONNECT] Found CKShare.Metadata in connectionOptions. Container=\(meta.containerIdentifier)", category: "SceneDelegate")
            CloudKitShareHandler.shared.acceptShare(from: meta)
        } else if connectionOptions.urlContexts.isEmpty == false {
            for ctx in connectionOptions.urlContexts {
                log("[WILL CONNECT] URL context: \(ctx.url)", category: "SceneDelegate")
                if ctx.url.host?.contains("icloud.com") == true {
                    Task { @MainActor in
                        let ok = await InvitationManager.shared.acceptInvitation(from: ctx.url)
                        log("[WILL CONNECT] In-app accept result: \(ok)", category: "SceneDelegate")
                    }
                }
            }
        } else {
            log("[WILL CONNECT] No URL contexts", category: "SceneDelegate")
        }
    }

    // URLオープンの経路可視化（OSがURLを渡すケース）
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for ctx in URLContexts {
            log("[URL OPEN] SceneDelegate received URL: \(ctx.url)", category: "SceneDelegate")
        }
    }
}
