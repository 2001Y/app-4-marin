import SwiftUI
import AVFoundation

/// DualCameraRecorder が生成する合成済みプレビュー画像を表示するビュー
struct DualCamPreviewView: View {
    @ObservedObject var recorder: DualCameraRecorder

    var body: some View {
        ZStack {
            if let cgImage = recorder.previewImage {
                Image(cgImage, scale: 1.0, label: Text("Preview"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .ignoresSafeArea()
    }
} 