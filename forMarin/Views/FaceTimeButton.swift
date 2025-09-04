import SwiftUI

import SwiftUI
import UIKit

struct FaceTimeButton: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("myFaceTimeID") private var myFaceTimeID: String = ""
    let callee: String   // remoteUserID（CloudKitの相手ID）
    let roomID: String

    private func currentTopVC() -> UIViewController? {
        InvitationManager.shared.getCurrentViewController()
    }

    private func resolveTargetAddress() -> String {
        // 受信済みのFaceTimeIDマップ（senderID -> FaceTimeID）
        if let dict = UserDefaults.standard.dictionary(forKey: "FaceTimeIDs") as? [String: String],
           let mapped = dict[callee], !mapped.isEmpty {
            return mapped
        }
        return callee
    }

    private func promptForMyFaceTimeIfNeeded(completion: @escaping () -> Void) {
        guard myFaceTimeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(); return
        }
        guard let vc = currentTopVC() else { completion(); return }
        let alert = UIAlertController(title: "あなたのApple IDは？",
                                      message: "FaceTimeで使うメールアドレス（または番号）を入力してください",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "example@icloud.com"
            tf.keyboardType = .emailAddress
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel, handler: { _ in
            log("FaceTime prompt cancelled", category: "FaceTime")
        }))
        alert.addAction(UIAlertAction(title: "保存", style: .default, handler: { _ in
            let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return }
            myFaceTimeID = value
            Task { try? await CloudKitChatManager.shared.saveFaceTimeID(value) }
            NotificationCenter.default.post(name: .faceTimeIDRegistered, object: nil, userInfo: ["faceTimeID": value, "roomID": roomID])
            log("📞 Saved my FaceTimeID and posted system notification", category: "FaceTime")
            completion()
        }))
        vc.present(alert, animated: true)
    }

    private func showPeerNotRegisteredAlert() {
        guard let vc = currentTopVC() else { return }
        let alert = UIAlertController(title: "相手がメールアドレスを入力してません。",
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    var body: some View {
        Button {
            P2PController.shared.close() // エコー抑止
            promptForMyFaceTimeIfNeeded {
                if let dict = UserDefaults.standard.dictionary(forKey: "FaceTimeIDs") as? [String: String],
                   let mapped = dict[callee], !mapped.isEmpty {
                    let target = mapped
                    if let url = URL(string: "facetime://\(target)") {
                        openURL(url)
                    } else {
                        log("Invalid FaceTime URL target=\(target)", category: "FaceTime")
                    }
                } else {
                    showPeerNotRegisteredAlert()
                }
            }
        } label: {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 24))
        }
    }
}

/// FaceTime Audio call button
struct FaceTimeAudioButton: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("myFaceTimeID") private var myFaceTimeID: String = ""
    let callee: String   // remoteUserID
    let roomID: String

    private func resolveTargetAddress() -> String {
        if let dict = UserDefaults.standard.dictionary(forKey: "FaceTimeIDs") as? [String: String],
           let mapped = dict[callee], !mapped.isEmpty {
            return mapped
        }
        return callee
    }

    private func promptForMyFaceTimeIfNeeded(completion: @escaping () -> Void) {
        guard myFaceTimeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(); return }
        guard let vc = InvitationManager.shared.getCurrentViewController() else { completion(); return }
        let alert = UIAlertController(title: "あなたのApple IDは？",
                                      message: "FaceTimeで使うメールアドレス（または番号）を入力してください",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "example@icloud.com"
            tf.keyboardType = .emailAddress
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default, handler: { _ in
            let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return }
            myFaceTimeID = value
            Task { try? await CloudKitChatManager.shared.saveFaceTimeID(value) }
            NotificationCenter.default.post(name: .faceTimeIDRegistered, object: nil, userInfo: ["faceTimeID": value, "roomID": roomID])
            log("📞 Saved my FaceTimeID and posted system notification (audio)", category: "FaceTime")
            completion()
        }))
        vc.present(alert, animated: true)
    }

    var body: some View {
        Button {
            P2PController.shared.close()
            promptForMyFaceTimeIfNeeded {
                if let dict = UserDefaults.standard.dictionary(forKey: "FaceTimeIDs") as? [String: String],
                   let mapped = dict[callee], !mapped.isEmpty {
                    let target = mapped
                    if let url = URL(string: "facetime-audio://\(target)") {
                        openURL(url)
                    } else {
                        log("Invalid FaceTime audio URL target=\(target)", category: "FaceTime")
                    }
                } else {
                    if let vc = InvitationManager.shared.getCurrentViewController() {
                        let alert = UIAlertController(title: "相手がメールアドレスを入力してません。",
                                                      message: nil,
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        vc.present(alert, animated: true)
                    }
                }
            }
        } label: {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 24))
        }
    }
}
