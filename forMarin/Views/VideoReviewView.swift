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
    @State private var showCloseConfirmation: Bool = false
    
    // 共通の固定値（DualCamRecorderViewと同じ）
    private let previewWidth: CGFloat = UIScreen.main.bounds.width - 60
    private let previewHeight: CGFloat = (UIScreen.main.bounds.width - 60) * 16 / 9 // 16:9アスペクト比
    private let cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                // ヘッダー（写真プレビューと統一）
                HStack {
                    Button {
                        showCloseConfirmation = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    
                    Spacer()
                    
                    Text("動画プレビュー")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // 右側のスペーサー（バランス用）
                    Circle()
                        .fill(.clear)
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 20)
                .padding(.horizontal, 20)
                
                Spacer()
                
                // 動画プレビュー（共通の固定値を使用）
                ZStack {
                    // 背景（共通の固定値）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: previewWidth, height: previewHeight)
                    
                    // 動画プレイヤー
                    VideoPlayer(player: player)
                        .frame(width: previewWidth, height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .onAppear {
                            player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
                            player.play()
                        }
                        .onDisappear { player.pause() }
                }
                
                Spacer()
                
                // アクションボタン（写真プレビューと統一）
                HStack(spacing: 40) {
                    Button(role: .cancel) {
                        showCloseConfirmation = true
                    } label: {
                        VStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                                .overlay(
                                    Image(systemName: "trash")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                )
                            
                            Text("破棄")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                    
                    Button {
                        onAction(true)
                    } label: {
                        VStack(spacing: 8) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 60, height: 60)
                                .overlay(
                                    Image(systemName: "paperplane")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                )
                            
                            Text("送信")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .confirmationDialog("保存しますか？", isPresented: $showCloseConfirmation) {
            Button("はい") {
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
                onAction(false)
            }
            Button("いいえ", role: .cancel) {
                onAction(false)
            }
        } message: {
            Text("この動画をアルバムに保存しますか？")
        }
        .alert("エラー", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
} 