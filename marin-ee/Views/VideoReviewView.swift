import SwiftUI
import AVKit
import Photos

struct VideoReviewView: View {
    let videoURL: URL
    let onAction: (Bool) -> Void // true: send, false: close

    @State private var player: AVPlayer = .init()
    @State private var isPlaying: Bool = true
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        VStack {
            VideoPlayer(player: player)
                .onAppear {
                    player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
                    player.play()
                }
                .onDisappear { player.pause() }
                .ignoresSafeArea(edges: .top)

            HStack(spacing: 40) {
                Button(role: .cancel) {
                    // 閉じる & 保存確認
                    confirmClose()
                } label: {
                    Label("閉じる", systemImage: "xmark")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(UIColor.systemGray5), in: RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    onAction(true)
                } label: {
                    Label("送信", systemImage: "paperplane.fill")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.white)
                }
            }
            .padding()
        }
        .background(Color.black)
        .alert("エラー", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func confirmClose() {
        // iOS 17+ confirmation dialog
        Task {
            let result = await withCheckedContinuation { cont in
                DispatchQueue.main.async {
                    UIApplication.shared.keyWindow?.rootViewController?.presentAlert(title: "保存しますか？",
                                                                                   message: "この動画をアルバムに保存しますか？",
                                                                                   yes: {
                        cont.resume(returning: true)
                    }, no: {
                        cont.resume(returning: false)
                    })
                }
            }
            if result {
                // 保存のみ
                Task {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                        }
                    } catch {
                        await MainActor.run {
                            errorMessage = "動画の保存に失敗しました: \(error.localizedDescription)"
                            showErrorAlert = true
                        }
                    }
                }
            }
            onAction(false)
        }
    }
}

// MARK: - UIKit Alert Helper
extension UIViewController {
    func presentAlert(title: String, message: String, yes: @escaping () -> Void, no: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "いいえ", style: .cancel, handler: { _ in no() }))
        alert.addAction(UIAlertAction(title: "はい", style: .default, handler: { _ in yes() }))
        present(alert, animated: true)
    }
}

extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }.first { $0.isKeyWindow }
    }
} 