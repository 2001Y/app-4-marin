import Foundation
import AVFoundation
import SwiftUI
import UIKit
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
    enum OverlayCorner { case topLeft, topRight, bottomLeft, bottomRight }
    @Published private(set) var state: State = .idle
    @Published var timerText: String = "00:00"
    @Published var isFlipped: Bool = false
    /// デバイスの生 videoZoomFactor
    @Published var currentZoomFactor: Double = 1.0
    /// 表示用倍率（0.5/1/3/5 等）。UI 表示と同じ値。
    @Published var availableZoomFactors: [Double] = [1.0]
    /// 表示用の現在倍率（wide 基準の正規化値）
    @Published var currentDisplayZoom: Double = 1.0
    @Published private(set) var minZoomFactor: Double = 1.0
    @Published private(set) var maxZoomFactor: Double = 1.0
    /// 表示空間での最小/最大（wide 基準）
    @Published private(set) var minDisplayZoom: Double = 1.0
    @Published private(set) var maxDisplayZoom: Double = 1.0
    
    // プレビュー用の合成画像
    @Published var previewImage: CGImage?

    /// 最終書き出し URL（一時ファイル）
    private var outputURL: URL?

    // MARK: - Private Vars
    private let session = AVCaptureMultiCamSession()
    
    // カメラデバイス参照（ズーム制御用）
    private var backCameraDevice: AVCaptureDevice?
    private var frontCameraDevice: AVCaptureDevice?
    private var backLensObservation: NSKeyValueObservation?
    // 仮想デバイスのスイッチオーバーしきい値（ログ・ハプティクス用）
    private var switchOverZoomFactors: [Double] = []
    private var lastZoomForHaptics: Double?
    
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
    /// 現在の PiP 角（内部状態）
    private var overlayCorner: OverlayCorner = .bottomRight
    /// wide 基準の生ズーム（hasUltraWide なら switchOver 最小値、無ければ 1.0）
    private var wideBaselineRawZoom: Double = 1.0
    
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
        
        // デフォルトズーム（表示倍率）を設定（calculateAvailableZoomFactors 内で currentDisplayZoom を決定済み）
        let defaultDisplay = await MainActor.run { currentDisplayZoom }
        setDisplayZoom(defaultDisplay)
        
        // log("State changed to previewing", category: "DualCameraRecorder")
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // マルチカムでは .hd 系プリセットは使用できないため .inputPriority を指定
        session.sessionPreset = .inputPriority

        // --- Video Inputs ---
        // 同時使用できるデバイスの組み合わせは端末により異なるため、
        // supportedMultiCamDeviceSets を必ず参照して選択する。
        // （仮想デバイス .builtInTripleCamera 等はフロントと同時使用不可な場合がある）
        let allTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInUltraWideCamera,
            .builtInTrueDepthCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInTripleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: allTypes,
            mediaType: .video,
            position: .unspecified
        )

        // 端末が許可する同時使用セット（デバイスの集合）を取得
        let supportedSets = discovery.supportedMultiCamDeviceSets

        // フロント×バックの2台構成を優先して選ぶ
        let preferredBackTypes: [AVCaptureDevice.DeviceType] = [
            // マルチカム併用で広く安定する順に選択（tripleは最後に回す）
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
            .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera
        ]
        let preferredFrontTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTrueDepthCamera, .builtInWideAngleCamera
        ]

        var selectedBack: AVCaptureDevice?
        var selectedFront: AVCaptureDevice?

        // まずフロント×バックを含むセットを抽出
        let frontBackSets = supportedSets.filter { set in
            let hasFront = set.contains { $0.position == .front }
            let hasBack  = set.contains { $0.position == .back }
            return hasFront && hasBack
        }

        // 希望順で最適な組み合わせを選ぶ
        outer: for set in frontBackSets {
            for bt in preferredBackTypes {
                guard let b = set.first(where: { $0.position == .back && $0.deviceType == bt }) else { continue }
                for ft in preferredFrontTypes {
                    if let f = set.first(where: { $0.position == .front && $0.deviceType == ft }) {
                        selectedBack = b
                        selectedFront = f
                        break outer
                    }
                }
            }
        }

        // それでも決まらない場合、セット内の任意の front/back を使用
        if selectedBack == nil || selectedFront == nil, let anySet = frontBackSets.first {
            selectedBack = anySet.first(where: { $0.position == .back })
            selectedFront = anySet.first(where: { $0.position == .front })
        }

        guard let backCam = selectedBack, let frontCam = selectedFront else {
            throw NSError(domain: "DualCameraRecorder", code: -4, userInfo: [NSLocalizedDescriptionKey: "同時使用可能なカメラ組み合わせが見つかりません"])
        }
        
        // デバイス参照を保存（ズーム制御用）
        backCameraDevice = backCam
        frontCameraDevice = frontCam
        
        //（後で activeFormat 適用後に算出する）

        // 仮想デバイス利用時のしきい値と現在の主レンズをログ出力
        if backCam.isVirtualDevice {
            let switchOvers = backCam.virtualDeviceSwitchOverVideoZoomFactors
            log("Back camera is virtual: \(backCam.deviceType.rawValue). SwitchOver factors=\(switchOvers)", category: "DualCameraRecorder")
            // しきい値を保持（Double化・昇順ソート）
            switchOverZoomFactors = switchOvers.map { Double(truncating: $0) }.sorted()
            backLensObservation = backCam.observe(\.activePrimaryConstituent, options: [.new]) { _, change in
                // change.newValue は AVCaptureDevice??（二重Optional）になり得るため、内側までアンラップ
                if let d = change.newValue ?? nil {
                    log("Active primary constituent switched to: \(d.deviceType.rawValue) (\(d.localizedName))", category: "DualCameraRecorder")
                } else {
                    log("Active primary constituent switched to: nil", category: "DualCameraRecorder")
                }
            }
        } else {
            log("Back camera is physical: \(backCam.deviceType.rawValue)", category: "DualCameraRecorder")
            switchOverZoomFactors = []
        }
        
        // log("Back camera = \(backCam.localizedName), Front camera = \(frontCam.localizedName)", category: "DualCameraRecorder")
        // log("Back camera connected = \(backCam.isConnected), Front camera connected = \(frontCam.isConnected)", category: "DualCameraRecorder")

        // --- マルチカム対応フォーマット選択 (420f, ≤30fps) ---
        func selectMultiCam30fpsFormat(device: AVCaptureDevice) throws {
            // MultiCam対応の420f/30fpsを優先
            let candidates = device.formats.filter { f in
                let is420f = CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                let supports30 = f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 && $0.minFrameRate <= 30 }
                return f.isMultiCamSupported && is420f && supports30
            }
            guard let format = candidates.first ?? device.formats.first(where: { $0.isMultiCamSupported }) else {
                throw NSError(domain: "DualCameraRecorder", code: -10, userInfo: [NSLocalizedDescriptionKey: "30fps マルチカムフォーマットが見つかりません"])
            }
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            log("Active format set for \(device.localizedName). FOV=\(format.videoFieldOfView), 30fps, MultiCam=\(format.isMultiCamSupported)", category: "DualCameraRecorder")
        }

        try selectMultiCam30fpsFormat(device: backCam)
        try selectMultiCam30fpsFormat(device: frontCam)
        // フォーマット確定後にレンズ構成・しきい値に基づく表示ズーム候補を算出
        calculateAvailableZoomFactors(for: backCam)

        let backInput = try AVCaptureDeviceInput(device: backCam)
        let frontInput = try AVCaptureDeviceInput(device: frontCam)
        // 念のため、選択済みデバイスの組み合わせがサポート対象か最終確認
        do {
            let chosenSet: Set<AVCaptureDevice> = [backCam, frontCam]
            let isAllowed = supportedSets.contains { chosenSet.isSubset(of: $0) }
            if !isAllowed {
                // フロントとの同時使用不可：安全にシングルカムへフォールバック
                log("[DualCam] Selected pair not allowed; falling back to single back camera", category: "DualCameraRecorder")
                // バックのみ
                guard session.canAddInput(backInput) else {
                    throw NSError(domain: "DualCameraRecorder", code: -5, userInfo: [NSLocalizedDescriptionKey: "入力追加に失敗（single）"])
                }
                session.addInput(backInput)
                // 出力・接続はこの後の共通処理でback側のみ活性化
                // フロント入出力の追加はスキップ
                try configureOutputsForSingleBackOnly()
                return
            }
        }
        guard session.canAddInput(backInput) && session.canAddInput(frontInput) else {
            // 片方のみ追加できる場合もシングルにフォールバック
            log("[DualCam] Cannot add both inputs; fallback to single back camera", category: "DualCameraRecorder")
            if session.canAddInput(backInput) {
                session.addInput(backInput)
                try configureOutputsForSingleBackOnly()
                return
            }
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

        if !(session.canAddOutput(backVideoOutput) && session.canAddOutput(frontVideoOutput)) {
            // どちらかが不可ならバックのみで継続
            if session.canAddOutput(backVideoOutput) {
                session.addOutput(backVideoOutput)
                // front は未追加
            } else {
                throw NSError(domain: "DualCameraRecorder", code: -6, userInfo: [NSLocalizedDescriptionKey: "ビデオ出力追加に失敗"])
            }
        }
        if session.outputs.contains(backVideoOutput) == false { session.addOutput(backVideoOutput) }
        if session.canAddOutput(frontVideoOutput) { session.addOutput(frontVideoOutput) }
        
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

    /// バックカメラ単体の出力設定にフォールバック（フロントは追加しない）
    private func configureOutputsForSingleBackOnly() throws {
        let yuvSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        backVideoOutput.videoSettings  = yuvSettings
        backVideoOutput.alwaysDiscardsLateVideoFrames = false
        backVideoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(backVideoOutput) else {
            throw NSError(domain: "DualCameraRecorder", code: -6, userInfo: [NSLocalizedDescriptionKey: "ビデオ出力追加に失敗（single）"]) }
        session.addOutput(backVideoOutput)
        if let backConn = backVideoOutput.connection(with: .video) {
            backConn.videoRotationAngle = 90
            backConn.isEnabled = true
        }
        // オーディオ出力
        audioOutput.setSampleBufferDelegate(self, queue: processingQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
    }

    /// PiP（フロント）を配置するコーナーを指定
    func setOverlayCorner(_ corner: OverlayCorner) {
        overlayCorner = corner
        log("Overlay corner set: \(corner)", category: "DualCameraRecorder")
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
    
    /// デバイスが対応するズーム倍率を計算（Apple 推奨の仮想デバイス/ネイティブ要素に基づく）
    private func calculateAvailableZoomFactors(for device: AVCaptureDevice) {
        let minZoom = Double(device.minAvailableVideoZoomFactor)
        let maxZoom = Double(device.maxAvailableVideoZoomFactor)

        // 仮想デバイスのレンズ切替しきい値（光学スイッチポイント）
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
        // センサー等倍クロップ等のネイティブ中間点（例: 2x など）。iOS17+ のみ。
        var secondary: [Double] = []
        if #available(iOS 17.0, *) {
            // プラットフォームにより型が [NSNumber] または [CGFloat] として見えることがある
            // Double へ安全にブリッジ
            let raw = device.activeFormat.secondaryNativeResolutionZoomFactors
            secondary = raw.map { Double($0) }
        }

        // レンズ構成から wide の生ズーム係数を特定（Apple推奨：constituentDevices の順と switchOver の対応）
        let hasUltra = device.isVirtualDevice && device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let stopsRaw: [Double] = [1.0] + switchOvers
        if let wideIndex = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
           wideIndex < stopsRaw.count {
            wideBaselineRawZoom = max(stopsRaw[wideIndex], 1e-6)
        } else {
            // フォールバック：超広角がなければ 1.0、あるなら最小しきい値
            let fallback = hasUltra ? (switchOvers.min() ?? 1.0) : 1.0
            wideBaselineRawZoom = max(fallback, 1e-6)
        }

        // 生ズーム候補（min + しきい値 + ネイティブポイント）
        var rawCandidates = [minZoom] + switchOvers + secondary
        rawCandidates = rawCandidates.filter { $0 >= minZoom && $0 <= maxZoom }
        rawCandidates = Array(Set(rawCandidates)).sorted()

        // 表示用に wide 基準で正規化（小数1桁に丸め）
        func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        var display = rawCandidates.map { round1($0 / wideBaselineRawZoom) }
        // 近接の重複（±0.05）を除去
        var uniq: [Double] = []
        for v in display.sorted() {
            if uniq.last.map({ abs($0 - v) < 0.05 }) ?? false { continue }
            uniq.append(v)
        }
        if uniq.isEmpty { uniq = [1.0] }

        Task { @MainActor in
            self.minZoomFactor = minZoom
            self.maxZoomFactor = maxZoom
            self.minDisplayZoom = minZoom / self.wideBaselineRawZoom
            self.maxDisplayZoom = maxZoom / self.wideBaselineRawZoom
            self.availableZoomFactors = uniq

            // デフォルトは 0.5 があれば 0.5、なければ 1.0（表示倍率）
            let defaultDisplay = uniq.contains(0.5) ? 0.5 : 1.0
            self.currentDisplayZoom = defaultDisplay

            // 生ズームへ反映（即時適用は startSession 終了時に setDisplayZoom で）
            self.currentZoomFactor = max(minZoom, min(maxZoom, defaultDisplay * self.wideBaselineRawZoom))
        }

        log("Device zoom range: \(minZoom) - \(maxZoom)", category: "DualCameraRecorder")
        log("SwitchOver factors(raw): \(switchOvers)", category: "DualCameraRecorder")
        if !secondary.isEmpty { log("Secondary native factors(raw): \(secondary)", category: "DualCameraRecorder") }
        log("wideBaseline(raw) = \(wideBaselineRawZoom)", category: "DualCameraRecorder")
        log("Available display zooms: \(uniq)", category: "DualCameraRecorder")
    }
    
    /// ズームファクターを設定する（アウトカメラのみ）
    func setZoomFactor(_ factor: Double) {
        guard let device = backCameraDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // デバイスがサポートするズーム範囲内に収める
            let clampedFactor = max(device.minAvailableVideoZoomFactor,
                                    min(factor, device.maxAvailableVideoZoomFactor))
            
            let old = lastZoomForHaptics ?? Double(device.videoZoomFactor)
            device.videoZoomFactor = clampedFactor
            let actual = device.videoZoomFactor
            device.unlockForConfiguration()
            
            Task { @MainActor in
                currentZoomFactor = actual
                currentDisplayZoom = max(0.0, Double(actual) / max(wideBaselineRawZoom, 1e-6))
            }
            
            log("Zoom factor set to \(actual)", category: "DualCameraRecorder")
            // スイッチオーバーしきい値跨ぎを検出して軽いハプティクス
            checkAndHapticIfCrossed(from: old, to: Double(actual))
            lastZoomForHaptics = Double(actual)
        } catch {
            log("Failed to set zoom factor: \(error)", category: "DualCameraRecorder")
        }
    }

    /// 連続ズーム（ランプ）を開始
    func rampZoom(to factor: Double, rate: Float = 0.7) {
        guard let device = backCameraDevice else { return }
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor,
                               min(factor, device.maxAvailableVideoZoomFactor))
            device.ramp(toVideoZoomFactor: clamped, withRate: rate)
            device.unlockForConfiguration()
            // 進行中のランプ中は実値を参照
            let actual = device.videoZoomFactor
            Task { @MainActor in
                currentZoomFactor = actual
                currentDisplayZoom = max(0.0, Double(actual) / max(wideBaselineRawZoom, 1e-6))
            }
            log("Ramp zoom toward \(clamped) @rate=\(rate)", category: "DualCameraRecorder")
        } catch {
            log("Failed to ramp zoom: \(error)", category: "DualCameraRecorder")
        }
    }

    /// 連続ズーム（ランプ）を停止
    func cancelZoomRamp() {
        guard let device = backCameraDevice else { return }
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            let z = device.videoZoomFactor
            device.unlockForConfiguration()
            Task { @MainActor in
                self.currentZoomFactor = z
                self.currentDisplayZoom = max(0.0, Double(z) / max(self.wideBaselineRawZoom, 1e-6))
            }
            log("Cancel zoom ramp at \(z)", category: "DualCameraRecorder")
        } catch {
            log("Failed to cancel zoom ramp: \(error)", category: "DualCameraRecorder")
        }
    }

    /// 表示倍率（0.5/1/3 等）でズームを設定
    func setDisplayZoom(_ display: Double) {
        let raw = display * max(wideBaselineRawZoom, 1e-6)
        setZoomFactor(raw)
    }

    private func cleanup() {
        session.stopRunning()
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        pixelBufferAdaptor = nil
        timer = nil
        didStartSession = false
        backLensObservation = nil
        switchOverZoomFactors = []
        lastZoomForHaptics = nil
        Task { @MainActor in
            state = .idle
        }
    }
    
    // MARK: - Haptics
    private func checkAndHapticIfCrossed(from old: Double, to new: Double) {
        guard !switchOverZoomFactors.isEmpty else { return }
        for t in switchOverZoomFactors {
            // old と new が異なる側にある場合、しきい値を跨いだとみなす
            if (old - t) * (new - t) < 0 {
                DispatchQueue.main.async {
                    let gen = UISelectionFeedbackGenerator()
                    gen.prepare()
                    gen.selectionChanged()
                }
                log("Haptic: crossed threshold \(t). old=\(old), new=\(new)", category: "DualCameraRecorder")
                break
            }
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
        guard var overlay = overlay else { return base }
        // 1) スケールダウン（PIPサイズ）
        let scale: CGFloat = 0.28
        let baseExtent = base.extent
        overlay = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let overlayExtent = overlay.extent
        
        // 2) 配置（コーナーベース）
        let margin: CGFloat = 24
        let x: CGFloat
        let y: CGFloat
        switch overlayCorner {
        case .topLeft:
            x = margin; y = baseExtent.height - overlayExtent.height - margin
        case .topRight:
            x = baseExtent.width - overlayExtent.width - margin; y = baseExtent.height - overlayExtent.height - margin
        case .bottomLeft:
            x = margin; y = margin
        case .bottomRight:
            x = baseExtent.width - overlayExtent.width - margin; y = margin
        }
        let translated = overlay.transformed(by: CGAffineTransform(translationX: x, y: y))

        // 3) 角丸マスクを作って合成（CIRoundedRectangleGenerator + CIBlendWithAlphaMask）
        let radius: CGFloat = 12
        let maskFilter = CIFilter.roundedRectangleGenerator()
        maskFilter.radius = Float(radius)
        maskFilter.extent = CGRect(x: x, y: y, width: overlayExtent.width, height: overlayExtent.height)
        guard let mask = maskFilter.outputImage?.cropped(to: baseExtent) else {
            return translated.composited(over: base)
        }
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = translated
        blend.backgroundImage = base
        blend.maskImage = mask
        return blend.outputImage ?? translated.composited(over: base)
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
