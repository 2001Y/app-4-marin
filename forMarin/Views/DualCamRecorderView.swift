import SwiftUI
import AVKit
import Photos

/// デュアルカメラ同時録画モーダル。
/// DualCameraRecorder を用いてプレビュー→録画→レビュー→送信までを完結させる。
struct DualCamRecorderView: View {
    @StateObject private var recorder = DualCameraRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var recordedURL: URL?
    @State private var capturedPhotoURL: URL?
    @State private var isShowingReview = false
    @State private var isShowingPhotoReview = false
    @State private var errorMessage = ""
    @State private var showErrorAlert = false
    
    // ドラッグ状態
    @GestureState private var dragState: CGSize = .zero
    private let dismissThreshold: CGFloat = 120
    
    // アクションボタン表示
    @State private var showActions: Bool = false
    
    // 共通の固定値（アスペクト比対応）
    private let previewWidth: CGFloat = UIScreen.main.bounds.width - 60
    private let previewHeight: CGFloat = (UIScreen.main.bounds.width - 60) * 4 / 3 // 4:3アスペクト比（保存時のサイズ）
    private let cornerRadius: CGFloat = 12
    
    // 写真/動画モード管理
    @State private var isVideoMode: Bool = false
    @State private var isLongPressing: Bool = false
    
    // プレビューモード管理
    @State private var isInPreviewMode: Bool = false
    @State private var previewImage: UIImage?
    @State private var previewVideoURL: URL?
    @State private var videoPlayer: AVPlayer?

    private var dragProgress: CGFloat {
        let dy = abs(dragState.height)
        return min(dy / dismissThreshold, 1)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                // ヘッダー
                HStack {
                    Button {
                        if isInPreviewMode {
                            // プレビューモードから戻る
                            exitPreviewMode()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }

                    Spacer()

                    // プレビューモードでない時のみカメラ切替ボタンを表示
                    if !isInPreviewMode {
                        Button {
                            recorder.flipPIP()
                        } label: {
                            Image(systemName: "camera.rotate")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Circle().fill(.black.opacity(0.5)))
                        }
                    }
                }
                .padding(.top, 20)
                .padding(.horizontal, 20)

                Spacer()

                // 統合プレビュー（カメラ・画像・動画）
                ZStack {
                    // 背景
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: previewWidth, height: previewHeight)
                    
                    // プレビューコンテンツ
                    if isInPreviewMode {
                        // 画像・動画プレビュー
                        if let image = previewImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: previewWidth, height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        } else if let videoURL = previewVideoURL, let player = videoPlayer {
                            VideoPlayer(player: player)
                                .frame(width: previewWidth, height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                                .background(Color.purple.opacity(0.5)) // デバッグ用背景色
                                .onAppear {
                                    print("DualCamRecorderView: VideoPlayer appeared with URL: \(videoURL)")
                                    print("DualCamRecorderView: Video file exists: \(FileManager.default.fileExists(atPath: videoURL.path))")
                                    player.play()
                                }
                                .onDisappear {
                                    player.pause()
                                }
                        } else {
                            // プレビューコンテンツが利用できない場合のフォールバック
                            Rectangle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: previewWidth, height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                                .overlay(
                                    Text("プレビューを読み込み中...")
                                        .foregroundColor(.white)
                                )
                        }
                    } else {
                        // カメラプレビューまたはローディング
                        if let previewImage = recorder.previewImage {
                            Image(decorative: previewImage, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: previewWidth, height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        } else {
                            // ローディング状態
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                    .tint(.white)
                                
                                Text("カメラを起動中...")
                                    .foregroundColor(.white)
                                    .font(.system(size: 16, weight: .medium))
                            }
                        }
                    }
                }
                .frame(width: previewWidth, height: previewHeight)

                Spacer()

                // 録画タイマー（録画中のみ表示）
                if recorder.state == .recording {
                    VStack(spacing: 4) {
                        Text("RECORDING")
                            .font(.caption)
                            .foregroundColor(.red)
                            .fontWeight(.bold)
                        
                        Text(recorder.timerText)
                            .font(.title2)
                            .foregroundColor(.white)
                            .fontWeight(.bold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.black.opacity(0.8))
                    )
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut(duration: 0.2), value: recorder.state)
                }

                // 統合ボタン（撮影・送信）
                ZStack {
                    Circle()
                        .fill(isInPreviewMode ? Color.blue : buttonColor)
                        .frame(width: 80, height: 80)
                    
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 80, height: 80)
                    
                    // アイコン
                    if isInPreviewMode {
                        Image(systemName: "paperplane")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
                .scaleEffect(isInPreviewMode ? 1.0 : buttonScale)
                .animation(.easeInOut(duration: 0.1), value: recorder.state)
                .animation(.easeInOut(duration: 0.1), value: isLongPressing)
                .animation(.easeInOut(duration: 0.2), value: isInPreviewMode)
                .onTapGesture {
                    if isInPreviewMode {
                        handleSend()
                    } else if !isLongPressing && recorder.state == .previewing && !isVideoMode {
                        // 写真モードで録画状態でない場合のみ写真撮影
                        handlePhotoCapture()
                    }
                }
                .onLongPressGesture(minimumDuration: 0.05) {
                    if !isInPreviewMode && !isLongPressing && recorder.state == .previewing {
                        isLongPressing = true
                        isVideoMode = true
                        // 長押し開始時に録画開始
                        Task {
                            do {
                                try await recorder.startRecording()
                            } catch {
                                errorMessage = error.localizedDescription
                                showErrorAlert = true
                            }
                        }
                    }
                } onPressingChanged: { isPressing in
                    if !isPressing && isLongPressing {
                        isLongPressing = false
                        // 長押し終了時に録画停止
                        if recorder.state == .recording {
                            recorder.stopRecording { url in
                                guard let url else { return }
                                enterPreviewMode(with: url, isVideo: true)
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            // 初回起動時は写真モード
            isVideoMode = false
        }
        .onAppear {
            // アクションボタンを遅延表示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showActions = true
                }
            }
        }
        // セッション起動
        .task {
            Task {
                do {
                    // print("DualCamRecorderView: Starting recorder session...")
                    try await recorder.startSession()
                    // print("DualCamRecorderView: Session started successfully")
                } catch {
                    print("DualCamRecorderView: Failed to start session: \(error)")
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
        .onChange(of: recorder.state) { _, newState in
            // 録画終了時の処理は削除（isVideoModeをリセットしない）
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
    
    // MARK: - プレビューモード管理
    
    private func enterPreviewMode(with url: URL, isVideo: Bool) {
        // print("DualCamRecorderView: Entering preview mode, isVideo: \(isVideo), URL: \(url)")
        // print("DualCamRecorderView: File exists: \(FileManager.default.fileExists(atPath: url.path))")
        // let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        // print("DualCamRecorderView: File size: \(fileSize)")
        
        if isVideo {
            previewVideoURL = url
            previewImage = nil
            videoPlayer = AVPlayer(url: url)
            // print("DualCamRecorderView: Set previewVideoURL to: \(url)")
            // print("DualCamRecorderView: Created AVPlayer for video")
        } else {
            previewImage = UIImage(contentsOfFile: url.path)
            previewVideoURL = nil
            videoPlayer = nil
            print("DualCamRecorderView: Set previewImage, size: \(previewImage?.size ?? .zero)")
        }
        isInPreviewMode = true
        // print("DualCamRecorderView: Preview mode entered, isInPreviewMode: \(isInPreviewMode)")
    }
    
    private func exitPreviewMode() {
        print("DualCamRecorderView: Exiting preview mode")
        
        // 動画プレビューを閉じた場合はチャットに戻る
        if previewVideoURL != nil {
            dismiss()
            return
        }
        
        // 写真プレビューの場合は通常通り処理
        isInPreviewMode = false
        previewImage = nil
        previewVideoURL = nil
        videoPlayer = nil
        recordedURL = nil
        capturedPhotoURL = nil
    }
    
    private func handleSend() {
        // print("DualCamRecorderView: handleSend called. isInPreviewMode: \(isInPreviewMode)")
        if let videoURL = previewVideoURL {
            // print("DualCamRecorderView: Sending video: \(videoURL)")
            saveAndPostVideo(url: videoURL)
            dismiss()
        } else if let image = previewImage {
            print("DualCamRecorderView: Sending image.")
            Task {
                if let photoURL = saveImageToTempFile(image) {
                    saveAndPostPhoto(url: photoURL)
                    dismiss()
                } else {
                    print("DualCamRecorderView: Failed to save image to temp file for sending.")
                }
            }
        } else {
            print("DualCamRecorderView: handleSend called but no videoURL or image found.")
        }
    }
    
    private func saveImageToTempFile(_ image: UIImage) -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }
    
    // MARK: - Private Helpers
    
    private func handlePhotoCapture() {
        guard recorder.state == .previewing else { return }
        
        // 写真撮影時は確実にビデオモードをオフにする
        isVideoMode = false
        isLongPressing = false
        
        Task {
            do {
                if let photoURL = try await recorder.capturePhoto() {
                    enterPreviewMode(with: photoURL, isVideo: false)
                }
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }
    
    private func saveAndPostVideo(url: URL) {
        print("[DEBUG] DualCamRecorderView: saveAndPostVideo called for URL: \(url)")
        print("[DEBUG] DualCamRecorderView: File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        // ファイルサイズをチェック
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            print("[DEBUG] DualCamRecorderView: Video file size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)")
        }
        
        // 写真ライブラリへ保存 (失敗しても送信は継続)
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                print("[DEBUG] DualCamRecorderView: Video saved to photo library.")
            } catch {
                print("[DEBUG] DualCamRecorderView: Failed to save video to photo library: \(error.localizedDescription)")
            }
        }
        // ChatView へ通知
        print("[DEBUG] DualCamRecorderView: Posting .didFinishDualCamRecording notification")
        NotificationCenter.default.post(name: .didFinishDualCamRecording,
                                        object: nil,
                                        userInfo: ["videoURL": url])
        print("[DEBUG] DualCamRecorderView: Posted .didFinishDualCamRecording notification.")
    }
    
    private func saveAndPostPhoto(url: URL) {
        // 写真ライブラリへ保存 (失敗しても送信は継続)
        Task {
            if let image = UIImage(contentsOfFile: url.path) {
                try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
        }
        // ChatView へ通知
        NotificationCenter.default.post(name: .didFinishDualCamPhoto,
                                        object: nil,
                                        userInfo: ["photoURL": url])
    }
    
    // ボタンの色を計算
    private var buttonColor: Color {
        if recorder.state == .recording {
            return .red
        } else if isLongPressing {
            return .orange
        } else {
            return .white
        }
    }
    
    // ボタンのスケールを計算
    private var buttonScale: CGFloat {
        if recorder.state == .recording || isLongPressing {
            return 0.8
        } else {
            return 1.0
        }
    }
} 