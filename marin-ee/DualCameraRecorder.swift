import Foundation
import AVFoundation
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog

private let dcLogger = Logger(subsystem: "DualCameraRecorder", category: "Debug")

/// マルチカメラ同時録画 + リアルタイム PIP 合成を司るレコーダークラス。
/// - 利用方法:
///   1. `let recorder = DualCameraRecorder()`
///   2. `try await recorder.startSession()` → 権限確認 & プレビュー開始
///   3. `recorder.startRecording()`
///   4. `recorder.stopRecording { url in ... }`
///
/// H.265 + AAC ステレオで書き出し、一時ファイル URL を返す。
final class DualCameraRecorder: NSObject, ObservableObject {
    enum State { case idle, previewing, recording, finished }
    @Published private(set) var state: State = .idle
    @Published var timerText: String = "00:00"
    @Published var isFlipped: Bool = false
    
    // プレビュー用の合成画像
    @Published var previewImage: CGImage?

    /// 最終書き出し URL（一時ファイル）
    private var outputURL: URL?

    // MARK: - Private Vars
    private let session = AVCaptureMultiCamSession()
    
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
        print("DualCameraRecorder: Starting session...")
        
        // マルチカムサポート確認
        let isMultiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
        print("DualCameraRecorder: Multi-cam supported = \(isMultiCamSupported)")
        
        if !isMultiCamSupported {
            // マルチカム非対応の場合はエラーを投げる（後でシングルカム実装も検討）
            throw NSError(domain: "DualCameraRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "このデバイスはマルチカメラ同時撮影に対応していません"])
        }
        
        // 権限チェック
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        print("DualCameraRecorder: Video auth status = \(videoStatus.rawValue), Audio auth status = \(audioStatus.rawValue)")
        
        if videoStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw NSError(domain: "DualCameraRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "カメラの権限が必要です"])
            }
        } else if videoStatus != .authorized {
            throw NSError(domain: "DualCameraRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "カメラの権限が必要です"])
        }
        
        if audioStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw NSError(domain: "DualCameraRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: "マイクの権限が必要です"])
            }
        } else if audioStatus != .authorized {
            throw NSError(domain: "DualCameraRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: "マイクの権限が必要です"])
        }

        try configureSession()
        
        // セッション開始
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                print("DualCameraRecorder: About to start session...")
                self.session.startRunning()
                dcLogger.debug("startRunning() called, isRunning = \(self.session.isRunning)")
                self.dumpSessionStatus(context: "after startRunning")

                // 1 秒後に再度状態確認
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.dumpSessionStatus(context: "+1s")
                }
                
                continuation.resume()
            }
        }
        
        state = .previewing
        print("DualCameraRecorder: State changed to previewing")
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
        
        print("DualCameraRecorder: Back camera = \(backCam.localizedName), Front camera = \(frontCam.localizedName)")
        print("DualCameraRecorder: Back camera connected = \(backCam.isConnected), Front camera connected = \(frontCam.isConnected)")

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
            print("DualCameraRecorder: set \(device.localizedName) format=\(format) 30fps")
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
        
        print("DualCameraRecorder: Added camera inputs")

        // --- Audio Input ---
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                print("DualCameraRecorder: Added audio input")
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
        
        print("DualCameraRecorder: Added video outputs")
        
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
            print("DualCameraRecorder: Added audio output")
        }

        session.commitConfiguration()
        print("DualCameraRecorder: Session configuration completed")

        // connection 状態を確認
        for (idx, c) in session.connections.enumerated() {
            print("DualCameraRecorder: conn[\(idx)] active=\(c.isActive) enabled=\(c.isEnabled) outputs=\(c.output != nil ? 1 : 0)")
        }
    }

    // MARK: - Recording Control
    func startRecording() throws {
        guard state == .previewing else { return }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        self.outputURL = fileURL
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
        self.writer = writer

        // --- Video Input --- (Placeholder: 実際には PIP 合成したピクセルバッファを書き込む)
        // ポートレート映像に合わせ、幅480×高さ640でエンコード
        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 480,
            AVVideoHeightKey: 640,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "DualCameraRecorder", code: -6, userInfo: [NSLocalizedDescriptionKey: "writer に videoInput 追加失敗"])
        }
        writer.add(videoInput)
        writerVideoInput = videoInput

        // --- Audio Input ---
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
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

        // タイマー開始
        recordingStartTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
        state = .recording
    }

    private func updateTimer() {
        guard let start = recordingStartTime else { return }
        let sec = Int(Date().timeIntervalSince(start))
        timerText = String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard state == .recording else { completion(nil); return }
        timer?.invalidate()
        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        let finishedURL = self.outputURL // capture once
        writer?.finishWriting {
            print("DualCameraRecorder: finishWriting status=\(self.writer?.status.rawValue ?? -1) error=\(String(describing: self.writer?.error))")
            Task { @MainActor in
                self.state = .finished
                completion(finishedURL)
                self.cleanup()
            }
        }
    }

    func flipPIP() {
        isFlipped.toggle()
    }

    private func cleanup() {
        session.stopRunning()
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        pixelBufferAdaptor = nil
        timer = nil
        didStartSession = false
        state = .idle
    }
} // end class

// MARK: - Capture Delegate
extension DualCameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // デバッグ: フレーム受信確認
        if output === backVideoOutput {
            print("DualCameraRecorder: Received back camera frame")
        } else if output === frontVideoOutput {
            print("DualCameraRecorder: Received front camera frame")
        } else if output === audioOutput {
            print("DualCameraRecorder: Received audio frame")
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
        print("DualCameraRecorder: Processing front camera frame")
        guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
        let frontImage = CIImage(cvPixelBuffer: buf)
        latestFrontImage = frontImage

        // If flipped (front is large), composite and write now
        if isFlipped {
            let output = compose(base: frontImage, overlay: latestBackImage)
            
            // プレビュー更新（録画中でなくても）
            if state == .previewing || state == .recording {
                if let cgImage = ciContext.createCGImage(output, from: output.extent) {
                    print("DualCameraRecorder: Updating preview image from front camera")
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
        print("DualCameraRecorder: Processing back camera frame")
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
                print("DualCameraRecorder: Updating preview image from back camera")
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
            print("DualCameraRecorder: writer startSession at PTS \(time.value)")
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
            print("DualCameraRecorder: frame appended at \(time.value)/\(time.timescale)")
        } else {
            print("DualCameraRecorder: FAILED to append frame at \(time.value)/\(time.timescale)")
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