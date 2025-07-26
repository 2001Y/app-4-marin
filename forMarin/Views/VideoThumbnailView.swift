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
        print("[DEBUG] VideoThumbnailView: Starting thumbnail generation for URL: \(videoURL)")
        
        // ファイル存在チェック
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            print("[DEBUG] VideoThumbnailView: Video file does not exist: \(videoURL.path)")
            hasError = true
            return
        }
        
        // ファイルサイズをチェック
        if let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
           let fileSize = attributes[.size] as? Int64 {
            print("[DEBUG] VideoThumbnailView: Video file size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)")
        }
        
        // ファイル拡張子チェック
        let pathExtension = videoURL.pathExtension.lowercased()
        print("[DEBUG] VideoThumbnailView: File extension: \(pathExtension)")
        guard ["mov", "mp4", "m4v", "3gp", "avi"].contains(pathExtension) else {
            print("[DEBUG] VideoThumbnailView: Unsupported video format: \(pathExtension)")
            hasError = true
            return
        }
        
        // 簡素化されたサムネイル生成
        Task {
            do {
                print("[DEBUG] VideoThumbnailView: Creating AVAsset")
                let asset = AVAsset(url: videoURL)
                
                // アセットの読み込み可能性をチェック（iOS 16以降の新しいAPI）
                let isReadable = try await asset.load(.isReadable)
                print("[DEBUG] VideoThumbnailView: Asset is readable: \(isReadable)")
                
                if !isReadable {
                    print("[DEBUG] VideoThumbnailView: Asset is not readable, cannot generate thumbnail")
                    await MainActor.run {
                        hasError = true
                    }
                    return
                }
                
                print("[DEBUG] VideoThumbnailView: Creating AVAssetImageGenerator")
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                
                let time = CMTime(seconds: 0.1, preferredTimescale: 600)
                print("[DEBUG] VideoThumbnailView: Generating thumbnail at time: \(time)")
                let cgImage = try gen.copyCGImage(at: time, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                
                print("[DEBUG] VideoThumbnailView: Successfully generated thumbnail: \(image.size)")
                await MainActor.run {
                    self.thumbnail = image
                }
            } catch {
                print("[DEBUG] VideoThumbnailView: Simple thumbnail generation failed: \(error)")
                await MainActor.run {
                    hasError = true
                }
            }
        }
    }
    

} 