import SwiftUI
import UIKit
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
    
    // ズーム管理
    @State private var selectedZoom: Double = 0.5
    @State private var dragStartZoom: CGFloat = 1.0
    @State private var didBeginZoomDrag: Bool = false
    private let pointsPerDoubling: CGFloat = 160 // ネイティブに近い感度（1オクターブ=~160pt）
    @State private var pinchBaseline: Double = 1.0
    @State private var isPinching: Bool = false

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
                                    log("VideoPlayer appeared with URL: \(videoURL)", category: "DualCamRecorderView")
                                    log("Video file exists: \(FileManager.default.fileExists(atPath: videoURL.path))", category: "DualCamRecorderView")
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
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            guard recorder.state == .previewing || recorder.state == .recording else { return }
                            let dx = value.translation.width
                            let dy = value.translation.height
                            let corner: DualCameraRecorder.OverlayCorner
                            if dx >= 0 && dy >= 0 {
                                corner = .bottomRight
                            } else if dx < 0 && dy >= 0 {
                                corner = .bottomLeft
                            } else if dx < 0 && dy < 0 {
                                corner = .topLeft
                            } else {
                                corner = .topRight
                            }
                            recorder.setOverlayCorner(corner)
                        }
                )
                .frame(width: previewWidth, height: previewHeight)
                // プレビュー上でのピンチ連続ズーム（終端スナップ＋ハプティクス）
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            if !isPinching {
                                pinchBaseline = selectedZoom
                                isPinching = true
                            }
                            let target = clampDisplayZoom(Double(scale) * pinchBaseline)
                            selectedZoom = target
                            handleZoomChange(target)
                        }
                        .onEnded { _ in
                            // スナップせず、指を離した倍率で固定
                            handleZoomChange(selectedZoom)
                            isPinching = false
                        }
                )

                Spacer()

                // ズーム選択UI（プレビューモードでないときのみ表示）
                if !isInPreviewMode && !recorder.availableZoomFactors.isEmpty {
                    ZoomSelectorView(
                        selectedZoom: $selectedZoom,
                        availableZooms: recorder.availableZoomFactors,
                        minZoom: recorder.minDisplayZoom,
                        maxZoom: recorder.maxDisplayZoom
                    ) { zoom in
                        handleZoomChange(zoom)
                    }
                    .padding(.bottom, 20)
                }

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
                    // log("Starting recorder session...", category: "DualCamRecorderView")
                    try await recorder.startSession()
                    // log("Session started successfully", category: "DualCamRecorderView")
                } catch {
                    log("Failed to start session: \(error)", category: "DualCamRecorderView")
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
        .onChange(of: recorder.state) { _, newState in
            // 録画終了時の処理は削除（isVideoModeをリセットしない）
        }
        .onChange(of: recorder.currentDisplayZoom) { _, newZoom in
            selectedZoom = newZoom
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
        // log("Entering preview mode, isVideo: \(isVideo), URL: \(url)", category: "DualCamRecorderView")
        // log("File exists: \(FileManager.default.fileExists(atPath: url.path))", category: "DualCamRecorderView")
        // let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        // log("File size: \(fileSize)", category: "DualCamRecorderView")
        
        if isVideo {
            previewVideoURL = url
            previewImage = nil
            videoPlayer = AVPlayer(url: url)
            // log("Set previewVideoURL to: \(url)", category: "DualCamRecorderView")
            // log("Created AVPlayer for video", category: "DualCamRecorderView")
        } else {
            previewImage = UIImage(contentsOfFile: url.path)
            previewVideoURL = nil
            videoPlayer = nil
            log("Set previewImage, size: \(previewImage?.size ?? .zero)", category: "DualCamRecorderView")
        }
        isInPreviewMode = true
        // log("Preview mode entered, isInPreviewMode: \(isInPreviewMode)", category: "DualCamRecorderView")
    }
    
    private func exitPreviewMode() {
        log("Exiting preview mode", category: "DualCamRecorderView")
        
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
        // log("handleSend called. isInPreviewMode: \(isInPreviewMode)", category: "DualCamRecorderView")
        if let videoURL = previewVideoURL {
            // log("Sending video: \(videoURL)", category: "DualCamRecorderView")
            saveAndPostVideo(url: videoURL)
            dismiss()
        } else if let image = previewImage {
            log("Sending image.", category: "DualCamRecorderView")
            Task {
                if let photoURL = saveImageToTempFile(image) {
                    saveAndPostPhoto(url: photoURL)
                    dismiss()
                } else {
                    log("Failed to save image to temp file for sending.", category: "DualCamRecorderView")
                }
            }
        } else {
            log("handleSend called but no videoURL or image found.", category: "DualCamRecorderView")
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
        log("DualCamRecorderView: saveAndPostVideo called for URL: \(url)", category: "DEBUG")
        log("DualCamRecorderView: File exists: \(FileManager.default.fileExists(atPath: url.path))", category: "DEBUG")
        
        // ファイルサイズをチェック
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            log("DualCamRecorderView: Video file size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)", category: "DEBUG")
        }
        
        // 写真ライブラリへ保存 (失敗しても送信は継続)
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                log("DualCamRecorderView: Video saved to photo library.", category: "DEBUG")
            } catch {
                log("DualCamRecorderView: Failed to save video to photo library: \(error.localizedDescription)", category: "DEBUG")
            }
        }
        // ChatView へ通知
        log("DualCamRecorderView: Posting .didFinishDualCamRecording notification", category: "DEBUG")
        NotificationCenter.default.post(name: .didFinishDualCamRecording,
                                        object: nil,
                                        userInfo: ["videoURL": url])
        log("DualCamRecorderView: Posted .didFinishDualCamRecording notification.", category: "DEBUG")
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
    
    // ズーム変更ハンドラ
    private func handleZoomChange(_ zoom: Double) {
        log("Zoom changed (display) to \(zoom)", category: "DualCamRecorderView")
        recorder.setDisplayZoom(zoom)
    }
    
    private func clampDisplayZoom(_ z: Double) -> Double {
        min(max(z, recorder.minDisplayZoom), recorder.maxDisplayZoom)
    }
    
    private func nearestDisplayStop(to z: Double) -> Double {
        guard !recorder.availableZoomFactors.isEmpty else { return z }
        return recorder.availableZoomFactors.min(by: { abs($0 - z) < abs($1 - z) }) ?? z
    }
} 
