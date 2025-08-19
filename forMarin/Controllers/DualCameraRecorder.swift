import Foundation
import AVFoundation
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog

private let dcLogger = Logger(subsystem: "DualCameraRecorder", category: "Debug")

enum RecorderError: Error, LocalizedError {
    case sessionSetup
    case deviceNotFound
    case inputCreation
    case outputCreation
    case writerCreation
    case outputPathGeneration
    case recordingNotStarted
    case invalidState
    case imageConversion
    
    var errorDescription: String? {
        switch self {
        case .sessionSetup: return "セッションのセットアップに失敗しました"
        case .deviceNotFound: return "カメラデバイスが見つかりません"
        case .inputCreation: return "入力の作成に失敗しました"
        case .outputCreation: return "出力の作成に失敗しました"
        case .writerCreation: return "ライターの作成に失敗しました"
        case .outputPathGeneration: return "出力パスの生成に失敗しました"
        case .recordingNotStarted: return "録画が開始されていません"
        case .invalidState: return "無効な状態です"
        case .imageConversion: return "画像の変換に失敗しました"
        }
    }
}

/// マルチカメラ同時録画 + リアルタイム PIP 合成を司るレコーダークラス。
/// - 利用方法:
///   1. `let recorder = DualCameraRecorder()`
///   2. `try await recorder.startSession()` → 権限確認 & プレビュー開始
///   3. `recorder.startRecording()`
///   4. `recorder.stopRecording { url in ... }`
///
/// H.265 + AAC ステレオで書き出し、一時ファイル URL を返す。
final class DualCameraRecorder: NSObject, ObservableObject, @unchecked Sendable {
    enum State { case idle, previewing, recording, finished }
    @Published private(set) var state: State = .idle
    @Published var timerText: String = "00:00"
    @Published var isFlipped: Bool = false
    @Published var currentZoomFactor: Double = 0.5
    @Published var availableZoomFactors: [Double] = [1.0] // デフォルト値
    
    // プレビュー用の合成画像
    @Published var previewImage: CGImage?

    /// 最終書き出し URL（一時ファイル）
    private var outputURL: URL?

    // MARK: - Private Vars
    private let session = AVCaptureMultiCamSession()
    
    // カメラデバイス参照（ズーム制御用）
    private var backCameraDevice: AVCaptureDevice?
    private var frontCameraDevice: AVCaptureDevice?
    
    // 各出力は初期化時に生成
    private let backVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    
    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var recordingStartTime: Date?
    private var timer: Timer?

    /// startSession(atSourceTime:) が呼ばれたかどうか
    private var didStartSession = false

    // Video processing
    private let processingQueue = DispatchQueue(label: "dualcam.processing")
    private let ciContext = CIContext()

    // Latest front frame for compositing
    private var latestFrontImage: CIImage?
    private var latestBackImage: CIImage?
    
    override init() {
        super.init()
        
        // --- Notification 監視 ---
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleSessionError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleSessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleSessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)

        // Video output settings
        let videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        backVideoOutput.videoSettings = videoSettings
        backVideoOutput.alwaysDiscardsLateVideoFrames = true
        
        frontVideoOutput.videoSettings = videoSettings
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true
    }

    // MARK: - Runtime エラー / 中断 ハンドラ
    @objc private func handleSessionError(_ notif: Notification) {
        if let err = notif.userInfo?[AVCaptureSessionErrorKey] as? NSError {
            dcLogger.error("Session runtime error: \(err, privacy: .public)")
        } else {
            dcLogger.error("Session runtime error (unknown)")
        }
    }

    @objc private func handleSessionInterrupted(_ notif: Notification) {
        dcLogger.warning("Session was interrupted: \(notif.userInfo ?? [:])")
    }

    @objc private func handleSessionInterruptionEnded(_ notif: Notification) {
        dcLogger.info("Session interruption ended")
    }

    private func dumpSessionStatus(context: String) {
        dcLogger.debug("--- Session Status (\(context)) ---")
        dcLogger.debug("isRunning = \(self.session.isRunning), isInterrupted = \(self.session.isInterrupted)")
        for (idx, conn) in self.session.connections.enumerated() {
            let mType = conn.inputPorts.first?.mediaType.rawValue ?? "n/a"
            dcLogger.debug("Conn[\(idx)] active=\(conn.isActive) enabled=\(conn.isEnabled) inputPorts=\(conn.inputPorts.count) firstPortType=\(mType)")
        }
        let backHas = self.backVideoOutput.connection(with: .video) != nil
        let frontHas = self.frontVideoOutput.connection(with: .video) != nil
        dcLogger.debug("Outputs: backHasConn=\(backHas), frontHasConn=\(frontHas)")
        dcLogger.debug("-------------------------------")
    }

    // MARK: - Setup & Preview
    /// カメラ / マイク権限を確認し、セッションを起動。呼び出しはメインスレッドで。  
    /// 失敗時は例外送出。
    func startSession() async throws {
        guard state == .idle else { return }
        // log("Starting session...", category: "DualCameraRecorder")
        
        // マルチカムサポート確認
        let isMultiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
        // log("Multi-cam supported = \(isMultiCamSupported)", category: "DualCameraRecorder")
        
        if !isMultiCamSupported {
            // マルチカム非対応の場合はエラーを投げる（後でシングルカム実装も検討）
            throw NSError(domain: "DualCameraRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "このデバイスはマルチカメラ同時撮影に対応していません"])
        }
        
        // カメラ権限チェック（チャット画面で既に申請済みのはず）
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        // log("Video auth status = \(videoStatus.rawValue)", category: "DualCameraRecorder")
        
        guard videoStatus == .authorized else {
            throw NSError(domain: "DualCameraRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "カメラの権限が必要です。設定アプリで権限を許可してください。"])
        }

        try configureSession()
        
        // セッション開始
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                // log("About to start session...", category: "DualCameraRecorder")
                self.session.startRunning()
                dcLogger.debug("startRunning() called, isRunning = \(self.session.isRunning)")
                self.dumpSessionStatus(context: "after startRunning")

                // 1 秒後に再度状態確認
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.dumpSessionStatus(context: "+1s")
                }
                
                continuation.resume()
            }
        }
        
        await MainActor.run {
            state = .previewing
        }
        
        // デフォルトズームを設定（calculateAvailableZoomFactorsで決定された値）
        let defaultZoom = await MainActor.run { currentZoomFactor }
        setZoomFactor(defaultZoom)
        
        // log("State changed to previewing", category: "DualCameraRecorder")
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // マルチカムでは .hd 系プリセットは使用できないため .inputPriority を指定
        session.sessionPreset = .inputPriority

        // --- Video Inputs ---
        guard let backCam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let frontCam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw NSError(domain: "DualCameraRecorder", code: -4, userInfo: [NSLocalizedDescriptionKey: "カメラが取得できません"])
        }
        
        // デバイス参照を保存（ズーム制御用）
        backCameraDevice = backCam
        frontCameraDevice = frontCam
        
        // 利用可能なズーム倍率を計算
        calculateAvailableZoomFactors(for: backCam)
        
        // log("Back camera = \(backCam.localizedName), Front camera = \(frontCam.localizedName)", category: "DualCameraRecorder")
        // log("Back camera connected = \(backCam.isConnected), Front camera connected = \(frontCam.isConnected)", category: "DualCameraRecorder")

        // --- マルチカム対応フォーマット選択 (420f, ≤30fps) ---
        func selectMultiCam30fpsFormat(device: AVCaptureDevice) throws {
            let candidates = device.formats.filter { f in
                f.isMultiCamSupported &&
                CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
                f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 && $0.minFrameRate <= 30 }
            }
            guard let format = candidates.first else {
                throw NSError(domain: "DualCameraRecorder", code: -10, userInfo: [NSLocalizedDescriptionKey: "30fps マルチカムフォーマットが見つかりません"])
            }
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            // log("set \(device.localizedName) format=\(format) 30fps", category: "DualCameraRecorder")
        }

        try selectMultiCam30fpsFormat(device: backCam)
        try selectMultiCam30fpsFormat(device: frontCam)

        let backInput = try AVCaptureDeviceInput(device: backCam)
        let frontInput = try AVCaptureDeviceInput(device: frontCam)
        guard session.canAddInput(backInput) && session.canAddInput(frontInput) else {
            throw NSError(domain: "DualCameraRecorder", code: -5, userInfo: [NSLocalizedDescriptionKey: "入力追加に失敗"])
        }
        session.addInput(backInput)
        session.addInput(frontInput)
        
        // log("Added camera inputs", category: "DualCameraRecorder")

        // --- Audio Input ---
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                // log("Added audio input", category: "DualCameraRecorder")
            }
        }

        // --- Video Data Outputs ---
        let yuvSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        backVideoOutput.videoSettings  = yuvSettings
        frontVideoOutput.videoSettings = yuvSettings

        backVideoOutput.alwaysDiscardsLateVideoFrames = false
        frontVideoOutput.alwaysDiscardsLateVideoFrames = false

        backVideoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        frontVideoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        guard session.canAddOutput(backVideoOutput) && session.canAddOutput(frontVideoOutput) else {
            throw NSError(domain: "DualCameraRecorder", code: -6, userInfo: [NSLocalizedDescriptionKey: "ビデオ出力追加に失敗"])
        }
        session.addOutput(backVideoOutput)
        session.addOutput(frontVideoOutput)
        
        // log("Added video outputs", category: "DualCameraRecorder")
        
        // ★ AVCaptureSession が自動生成する connection を利用する（iOS 17 以降はこちらが安定）
        if let backConn = backVideoOutput.connection(with: .video) {
            backConn.videoRotationAngle = 90
            backConn.isEnabled = true
        }
        if let frontConn = frontVideoOutput.connection(with: .video) {
            frontConn.videoRotationAngle = 90
            frontConn.automaticallyAdjustsVideoMirroring = false
            frontConn.isVideoMirrored = true
            frontConn.isEnabled = true
        }
        
        // Configure preview connections (optional)
        if let backConn = backVideoOutput.connection(with: .video) {
            backConn.videoRotationAngle = 90
        }
        if let frontConn = frontVideoOutput.connection(with: .video) {
            frontConn.videoRotationAngle = 90
            frontConn.automaticallyAdjustsVideoMirroring = false
            frontConn.isVideoMirrored = true
        }
        
        // Configure audio output
        audioOutput.setSampleBufferDelegate(self, queue: processingQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            // log("Added audio output", category: "DualCameraRecorder")
        }

        session.commitConfiguration()
        // log("Session configuration completed", category: "DualCameraRecorder")

                  // connection 状態を確認
          for (_, _) in session.connections.enumerated() {
              // log("conn[\(idx)] active=\(c.isActive) enabled=\(c.isEnabled) outputs=\(c.output != nil ? 1 : 0)", category: "DualCameraRecorder")
          }
    }

    /// 現在のプレビュー画像を写真として撮影・保存
    func capturePhoto() async throws -> URL? {
        guard state == .previewing, let cgImage = previewImage else {
            throw RecorderError.invalidState
        }
        
        // UIImageに変換
        let uiImage = UIImage(cgImage: cgImage)
        
        // 一時ファイルに保存
        guard let imageData = uiImage.jpegData(compressionQuality: 0.9) else {
            throw RecorderError.imageConversion
        }
        
        let tmpDir = FileManager.default.temporaryDirectory
        let photoURL = tmpDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        
        try imageData.write(to: photoURL)
        
        return photoURL
    }

    func startRecording() async throws {
        guard state == .previewing else { return }
        
        // 一時出力先を生成
        let tmpDir = FileManager.default.temporaryDirectory
        outputURL = tmpDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        guard let url = outputURL else { throw RecorderError.outputPathGeneration }

        // --- AVAssetWriter 構築 ---
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard let writer = writer else { throw RecorderError.writerCreation }

        // HEVC ビデオ設定
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 480,
            AVVideoHeightKey: 640,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        writerVideoInput = videoInput

        // AAC 音声設定
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) { writer.add(audioInput) }
        writerAudioInput = audioInput

        // --- Pixel Buffer Adaptor ---
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                                  sourcePixelBufferAttributes: [
                                                                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                    kCVPixelBufferWidthKey as String: 480,
                                                                    kCVPixelBufferHeightKey as String: 640
                                                                  ])

        // writer は最初のフレーム受信時に startWriting() する

        writer.startWriting()
        // writer.startSession(atSourceTime: .zero) // This line is removed as per the edit hint

        // タイマー開始（0.01秒間隔で更新）
        recordingStartTime = Date()
        
        // タイマーをメインスレッドで作成
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                self?.updateTimer()
            }
        }
        
        await MainActor.run {
            state = .recording
        }
    }

    private func updateTimer() {
        guard let start = recordingStartTime else { return }
        
        let elapsed = Date().timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let centiseconds = Int((elapsed - Double(Int(elapsed))) * 100)
        
        let newTimerText = String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
        
        // MainActorで直接更新（Taskは不要）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timerText = newTimerText
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard state == .recording else { completion(nil); return }
        
        // タイマーをメインスレッドで停止
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        
        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        let finishedURL = self.outputURL // capture once
        writer?.finishWriting {
            if let finishedURL = finishedURL {
                let fileExists = FileManager.default.fileExists(atPath: finishedURL.path)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: finishedURL.path)[.size] as? Int64) ?? 0
                
                if self.writer?.status == .completed && fileExists && fileSize > 0 {
                    Task { @MainActor in
                        self.state = .finished
                        completion(finishedURL)
                        // カテゴリを元に戻す
                        AudioSessionManager.endRecording()
                        self.cleanup()
                    }
                } else {
                    Task { @MainActor in
                        self.state = .finished
                        completion(nil)
                        // カテゴリを元に戻す
                        AudioSessionManager.endRecording()
                        self.cleanup()
                    }
                }
            } else {
                Task { @MainActor in
                    self.state = .finished
                    completion(nil)
                    AudioSessionManager.endRecording()
                    self.cleanup()
                }
            }
        }
    }

    func flipPIP() {
        isFlipped.toggle()
    }
    
    /// デバイスが対応するズーム倍率を計算
    private func calculateAvailableZoomFactors(for device: AVCaptureDevice) {
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        
        // 一般的なズーム倍率の候補
        let candidateFactors: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
        
        // デバイスがサポートする範囲内の倍率を選択
        let supportedFactors = candidateFactors.filter { factor in
            factor >= minZoom && factor <= maxZoom
        }
        
        // 最低でも1.0は含める
        let finalFactors = supportedFactors.isEmpty ? [1.0] : supportedFactors
        
        Task { @MainActor in
            availableZoomFactors = finalFactors
            
            // デフォルトズーム倍率を更新（0.5が利用可能なら0.5、そうでなければ最初の倍率）
            let defaultZoom = finalFactors.contains(0.5) ? 0.5 : finalFactors.first ?? 1.0
            currentZoomFactor = defaultZoom
        }
        
        log("Device zoom range: \(minZoom) - \(maxZoom)", category: "DualCameraRecorder")
        log("Available zoom factors: \(finalFactors)", category: "DualCameraRecorder")
    }
    
    /// ズームファクターを設定する（アウトカメラのみ）
    func setZoomFactor(_ factor: Double) {
        guard let device = backCameraDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // デバイスがサポートするズーム範囲内に収める
            let clampedFactor = max(device.minAvailableVideoZoomFactor, 
                                   min(factor, device.maxAvailableVideoZoomFactor))
            
            device.videoZoomFactor = clampedFactor
            device.unlockForConfiguration()
            
            Task { @MainActor in
                currentZoomFactor = clampedFactor
            }
            
            log("Zoom factor set to \(clampedFactor)", category: "DualCameraRecorder")
        } catch {
            log("Failed to set zoom factor: \(error)", category: "DualCameraRecorder")
        }
    }

    private func cleanup() {
        session.stopRunning()
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        pixelBufferAdaptor = nil
        timer = nil
        didStartSession = false
        Task { @MainActor in
            state = .idle
        }
    }
} // end class

// MARK: - Capture Delegate
extension DualCameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // デバッグ: フレーム受信確認
        if output === backVideoOutput {
            // log("Received back camera frame", category: "DualCameraRecorder")
        } else if output === frontVideoOutput {
            // log("Received front camera frame", category: "DualCameraRecorder")
        } else if output === audioOutput {
            // log("Received audio frame", category: "DualCameraRecorder")
        }
        
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if output === backVideoOutput {
            handleBack(sampleBuffer)
        } else if output === frontVideoOutput {
            handleFront(sampleBuffer)
        } else if output === audioOutput && state == .recording {
            handleAudio(sampleBuffer)
        }
    }

    private func handleFront(_ sample: CMSampleBuffer) {
        // log("Processing front camera frame", category: "DualCameraRecorder")
        guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
        let frontImage = CIImage(cvPixelBuffer: buf)
        latestFrontImage = frontImage

        // If flipped (front is large), composite and write now
        if isFlipped {
            let output = compose(base: frontImage, overlay: latestBackImage)
            
            // プレビュー更新（録画中でなくても）
            if state == .previewing || state == .recording {
                if let cgImage = ciContext.createCGImage(output, from: output.extent) {
                    // log("Updating preview image from front camera", category: "DualCameraRecorder")
                    Task { @MainActor in
                        self.previewImage = cgImage
                    }
                }
            }
            
            // 録画中のみ書き込み
            if state == .recording {
                appendToWriter(ciImage: output, sampleBuffer: sample)
            }
        }
    }

    private func handleBack(_ sample: CMSampleBuffer) {
        // log("Processing back camera frame", category: "DualCameraRecorder")
        guard let baseBuf = CMSampleBufferGetImageBuffer(sample) else { return }
        let backImage = CIImage(cvPixelBuffer: baseBuf)
        latestBackImage = backImage

        if isFlipped {
            // back acts as small overlay; do nothing, will be composed on next front frame
            return
        }

        let output = compose(base: backImage, overlay: latestFrontImage)
        
        // プレビュー更新（録画中でなくても）
        if state == .previewing || state == .recording {
            if let cgImage = ciContext.createCGImage(output, from: output.extent) {
                // log("Updating preview image from back camera", category: "DualCameraRecorder")
                Task { @MainActor in
                    self.previewImage = cgImage
                }
            }
        }
        
        // 録画中のみ書き込み
        if state == .recording {
            appendToWriter(ciImage: output, sampleBuffer: sample)
        }
    }

    private func compose(base: CIImage, overlay: CIImage?) -> CIImage {
        guard let overlay = overlay else { return base }
        let scale: CGFloat = 0.28
        let baseExtent = base.extent
        let overlayImg = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let overlayExtent = overlayImg.extent
        let x = baseExtent.width - overlayExtent.width - 24
        let y = baseExtent.height - overlayExtent.height - 24
        let translated = overlayImg.transformed(by: CGAffineTransform(translationX: x, y: y))
        return translated.composited(over: base)
    }

    private func appendToWriter(ciImage: CIImage, sampleBuffer: CMSampleBuffer) {
        guard let adaptor = pixelBufferAdaptor,
              let input = writerVideoInput,
              let w = writer,
              let pool = adaptor.pixelBufferPool else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 初回のビデオフレームでセッションを開始
        if !didStartSession {
            if w.status == .unknown {
                w.startWriting()
            }
            w.startSession(atSourceTime: time)
            didStartSession = true
            // log("writer startSession at PTS \(time.value)", category: "DualCameraRecorder")
            recordingStartTime = Date()
            // このフレームの append はスキップして次フレームから書き込み
            return
        }

        // writing 状態で、input が受け付け可能か確認
        guard w.status == .writing, input.isReadyForMoreMediaData else { return }

        var pixBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixBuf)
        guard let buffer = pixBuf else { return }

        ciContext.render(ciImage, to: buffer)

        if adaptor.append(buffer, withPresentationTime: time) {
            // log("frame appended at \(time.value)/\(time.timescale)", category: "DualCameraRecorder")
        } else {
            log("FAILED to append frame at \(time.value)/\(time.timescale)", category: "DualCameraRecorder")
        }
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        guard didStartSession,
              let input = writerAudioInput,
              let w = writer,
              w.status == .writing,
              input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }
} 