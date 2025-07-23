import SwiftUI
import AVFoundation

struct VideoThumbnailView: View {
    let videoURL: URL
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Group {
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .onAppear(perform: generateThumbnail)
    }

    private func generateThumbnail() {
        let asset = AVAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        DispatchQueue.global(qos: .userInitiated).async {
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let cgImage = try? gen.copyCGImage(at: time, actualTime: nil) {
                let uiImg = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    self.thumbnail = uiImg
                }
            }
        }
    }
} 