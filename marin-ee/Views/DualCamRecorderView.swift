import SwiftUI
import Photos

/// デュアルカメラ同時録画モーダル。
/// DualCameraRecorder を用いてプレビュー→録画→レビュー→送信までを完結させる。
struct DualCamRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = DualCameraRecorder()

    @State private var isShowingReview = false
    @State private var recordedURL: URL? = nil
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            // プレビュー
            if recorder.state != .idle {
                DualCamPreviewView(recorder: recorder)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // --- トップバー ---
            VStack {
                HStack {
                    // 閉じる
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .padding()
                    }

                    Spacer()

                    // PIP 反転
                    Button {
                        recorder.flipPIP()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }

            // --- ボトムコントロール ---
            VStack {
                Spacer()
                Text(recorder.timerText)
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

                Button {
                    handleRecordButton()
                } label: {
                    Circle()
                        .fill(recorder.state == .recording ? Color.red : Color.white)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                        )
                }
                .padding(.bottom, 40)
            }
        }
        // セッション起動
        .onAppear {
            Task {
                do {
                    print("DualCamRecorderView: Starting recorder session...")
                    try await recorder.startSession()
                    print("DualCamRecorderView: Session started successfully")
                } catch {
                    print("DualCamRecorderView: Failed to start session: \(error)")
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
        // 録画後のレビュー画面
        .fullScreenCover(isPresented: $isShowingReview, onDismiss: {
            recordedURL = nil
        }) {
            if let url = recordedURL {
                VideoReviewView(videoURL: url) { send in
                    if send {
                        saveAndPost(url: url)
                    }
                    dismiss()
                }
            }
        }
        // エラーダイアログ
        .alert("エラー", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                dismiss()
            }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Private Helpers
    private func handleRecordButton() {
        switch recorder.state {
        case .previewing:
            do {
                try recorder.startRecording()
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        case .recording:
            recorder.stopRecording { url in
                guard let url else { return }
                recordedURL = url
                isShowingReview = true
            }
        default:
            break
        }
    }

    private func saveAndPost(url: URL) {
        // 写真ライブラリへ保存 (失敗しても送信は継続)
        Task {
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
        // ChatView へ通知
        NotificationCenter.default.post(name: .didFinishDualCamRecording,
                                        object: nil,
                                        userInfo: ["videoURL": url])
    }
} 