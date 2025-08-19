import SwiftUI
import AVFoundation

struct VideoThumbnailView: View {
    let videoURL: URL
    @State private var thumbnail: UIImage? = nil
    @State private var hasError = false

    var body: some View {
        Group {
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .overlay(alignment: .center) {
                        // 再生アイコンオーバーレイ
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .background(Circle().fill(.black.opacity(0.6)))
                    }
            } else if hasError {
                // エラー時のプレースホルダー
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 4) {
                        Text("動画")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("サムネイルを生成できませんでした")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                )
            } else {
                // 読み込み中
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        VStack(spacing: 8) {
                        ProgressView()
                                .scaleEffect(0.8)
                            Text("読み込み中...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
            }
        }
        .onAppear(perform: generateThumbnail)
    }

    private func generateThumbnail() {
        log("VideoThumbnailView: Starting thumbnail generation for URL: \(videoURL)", category: "DEBUG")
        
        // ファイル存在チェック
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            log("VideoThumbnailView: Video file does not exist: \(videoURL.path)", category: "DEBUG")
            hasError = true
            return
        }
        
        // ファイルサイズをチェック
        if let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
           let fileSize = attributes[.size] as? Int64 {
            log("VideoThumbnailView: Video file size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)", category: "DEBUG")
        }
        
        // ファイル拡張子チェック
        let pathExtension = videoURL.pathExtension.lowercased()
        log("VideoThumbnailView: File extension: \(pathExtension)", category: "DEBUG")
        guard ["mov", "mp4", "m4v", "3gp", "avi"].contains(pathExtension) else {
            log("VideoThumbnailView: Unsupported video format: \(pathExtension)", category: "DEBUG")
            hasError = true
            return
        }
        
        // 簡素化されたサムネイル生成
        Task {
            do {
                log("VideoThumbnailView: Creating AVAsset", category: "DEBUG")
                let asset = AVAsset(url: videoURL)
                
                // アセットの読み込み可能性をチェック（iOS 16以降の新しいAPI）
                let isReadable = try await asset.load(.isReadable)
                log("VideoThumbnailView: Asset is readable: \(isReadable)", category: "DEBUG")
                
                if !isReadable {
                    log("VideoThumbnailView: Asset is not readable, cannot generate thumbnail", category: "DEBUG")
                    await MainActor.run {
                        hasError = true
                    }
                    return
                }
                
                log("VideoThumbnailView: Creating AVAssetImageGenerator", category: "DEBUG")
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                
                // 動画の長さを取得して真ん中からサムネイルを生成
                let duration = try await asset.load(.duration)
                let middleTime = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
                log("VideoThumbnailView: Video duration: \(duration.seconds) seconds", category: "DEBUG")
                log("VideoThumbnailView: Generating thumbnail at middle time: \(middleTime)", category: "DEBUG")
                let cgImage = try gen.copyCGImage(at: middleTime, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                
                log("VideoThumbnailView: Successfully generated thumbnail: \(image.size)", category: "DEBUG")
                await MainActor.run {
                    self.thumbnail = image
                }
            } catch {
                log("VideoThumbnailView: Simple thumbnail generation failed: \(error)", category: "DEBUG")
                await MainActor.run {
                    hasError = true
                }
            }
        }
    }
    

} 