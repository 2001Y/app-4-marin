import SwiftUI
import AVFoundation
import VisionKit
import CloudKit

@MainActor
struct QRScannerSheet: View {
    @Binding var isPresented: Bool
    var onAccepted: (() -> Void)? = nil
    @State private var useVisionKit = false
    @State private var torchOn = false
    @State private var isRunning = true
    @State private var lastDetectionAt = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QRを読み取る")
                    .font(.headline)
                Spacer()
                Button(action: { torchOn.toggle() }) {
                    Image(systemName: torchOn ? "flashlight.off.fill" : "flashlight.on.fill")
                }
                .buttonStyle(.bordered)
                .disabled(useVisionKit) // VisionKitではトーチ制御は非対応
            }
            .padding(.horizontal)
            .padding(.top, 8)

            GeometryReader { geo in
                let roi = normalizedROI(in: geo.size)
                ZStack {
                    if useVisionKit {
                        DataScannerView(isRunning: isRunning, torchOn: torchOn, regionOfInterest: roi) { text in
                            handleScan(text)
                        }
                        .ignoresSafeArea(edges: .bottom)
                    } else {
                        AVQRScannerView(isRunning: isRunning, torchOn: torchOn, regionOfInterest: roi) { text in
                            handleScan(text)
                        }
                        .ignoresSafeArea(edges: .bottom)
                    }

                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.9), style: .init(lineWidth: 2, dash: [6,6]))
                        .frame(width: geo.size.width * 0.8, height: geo.size.height * 0.22)
                        .allowsHitTesting(false)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await prepare() }
    }

    private func prepare() async {
        let granted = await ensureCameraPermission()
        guard granted else { return }
        useVisionKit = DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        isRunning = true
    }

    private func handleScan(_ value: String) {
        guard Date().timeIntervalSince(lastDetectionAt) > 1 else { return }
        lastDetectionAt = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let url = URL(string: value) {
            Task { @MainActor in
                let ok = await InvitationManager.shared.acceptInvitation(from: url)
                if ok {
                    MessageSyncService.shared.checkForUpdates()
                    isPresented = false
                    onAccepted?()
                }
            }
        }
    }

    private func normalizedROI(in size: CGSize) -> CGRect {
        let w: CGFloat = 0.8, h: CGFloat = 0.22
        return CGRect(x: (1-w)/2, y: 0.15, width: w, height: h)
    }
}

@MainActor
private func ensureCameraPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined:
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
        }
    default: return false
    }
}

// MARK: - VisionKit Wrapper
struct DataScannerView: UIViewControllerRepresentable {
    var isRunning: Bool
    var torchOn: Bool
    var regionOfInterest: CGRect?
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        // regionOfInterestはVisionKit側では不安定になることがあるため使用しない（全面スキャン）
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        // ROIは設定しない
        if isRunning {
            try? vc.startScanning()
        } else {
            vc.stopScanning()
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: DataScannerView
        init(_ parent: DataScannerView) { self.parent = parent }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let s = barcode.payloadStringValue {
                    parent.onFound(s)
                }
            }
        }
    }
}

// MARK: - AVFoundation Fallback
struct AVQRScannerView: UIViewControllerRepresentable {
    var isRunning: Bool
    var torchOn: Bool
    var regionOfInterest: CGRect?
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> CamVC { CamVC(onFound: onFound) }
    func updateUIViewController(_ vc: CamVC, context: Context) {
        vc.regionOfInterest = regionOfInterest
        vc.setTorch(on: torchOn)
        isRunning ? vc.start() : vc.stop()
    }

    final class CamVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let preview = AVCaptureVideoPreviewLayer()
        let onFound: (String)->Void
        var regionOfInterest: CGRect? { didSet { updateROI() } }
        private var lastAt = Date.distantPast
        private let sessionQueue = DispatchQueue(label: "qr.session")

        init(onFound: @escaping (String)->Void) {
            self.onFound = onFound
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            preview.session = session
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            sessionQueue.async { [weak self] in self?.configureSession() }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview.frame = view.bounds
            CATransaction.commit()
            updateROI()
        }
        private func configureSession() {
            session.beginConfiguration(); defer { session.commitConfiguration() }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        func start() { guard !session.isRunning else { return }; sessionQueue.async { self.session.startRunning() } }
        func stop()  { guard  session.isRunning else { return }; sessionQueue.async { self.session.stopRunning() } }
        func setTorch(on: Bool) {
            guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device, device.hasTorch else { return }
            do { try device.lockForConfiguration(); device.torchMode = on ? .on : .off; device.unlockForConfiguration() } catch {}
        }
        private func updateROI() {
            guard let output = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first else { return }
            // レイアウト前はboundsが0の可能性があるためガード
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            guard let roi = regionOfInterest else { output.rectOfInterest = .init(x:0,y:0,width:1,height:1); return }
            let layerRect = CGRect(x: roi.origin.x * view.bounds.width,
                                   y: roi.origin.y * view.bounds.height,
                                   width: roi.size.width * view.bounds.width,
                                   height: roi.size.height * view.bounds.height)
            output.rectOfInterest = preview.metadataOutputRectConverted(fromLayerRect: layerRect)
        }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject, obj.type == .qr, let s = obj.stringValue else { return }
            guard Date().timeIntervalSince(lastAt) > 1 else { return }
            lastAt = Date(); UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound(s)
        }
    }
}
