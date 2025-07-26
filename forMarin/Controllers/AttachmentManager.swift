import Foundation
import UIKit

/// アプリの永続領域 (Application Support/attachments) にメディアファイルを保存・取得するヘルパ。
struct AttachmentManager {
    /// attachments フォルダの絶対 URL
    private static var baseURL: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = sup.appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 新しいランダムファイル名 URL を生成 (.ext 付き)
    static func makeFileURL(ext: String) -> URL {
        baseURL.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// App の再インストール時にも残したくない場合は clear() を呼び出す
    static func clear() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

extension AttachmentManager {
    /// Saves UIImage as optimized JPEG and returns file URL in cache directory.
    static func saveImageToCache(_ image: UIImage) -> URL? {
        // アルファチャンネル問題を回避するため、RGB形式で保存
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true // アルファチャンネルを無効化
        
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let optimizedImage = renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        
        guard let data = optimizedImage.jpegData(compressionQuality: 0.9) else { return nil }
        let url = makeFileURL(ext: "jpg")
        do { try data.write(to: url); return url } catch { print("[AttachmentManager] save error", error); return nil }
    }
    
    /// Saves video file to cache directory and returns file URL.
    static func saveVideoToCache(_ videoURL: URL) -> URL? {
        let ext = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension
        let dstURL = makeFileURL(ext: ext)
        do {
            try FileManager.default.copyItem(at: videoURL, to: dstURL)
            return dstURL
        } catch {
            print("[AttachmentManager] video save error", error)
            return nil
        }
    }
    
    /// Compresses video if it's too large for CloudKit (over 50MB)
    static func compressVideoIfNeeded(_ videoURL: URL) -> URL? {
        // ファイルサイズをチェック
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
              let fileSize = attributes[.size] as? Int64 else {
            print("[AttachmentManager] Could not get file size")
            return videoURL
        }
        
        let maxSize: Int64 = 50 * 1024 * 1024 // 50MB
        if fileSize <= maxSize {
            print("[AttachmentManager] Video size (\(fileSize / 1024 / 1024)MB) is within limits, no compression needed")
            return videoURL
        }
        
        print("[AttachmentManager] Video size (\(fileSize / 1024 / 1024)MB) exceeds limit, attempting compression")
        
        // 圧縮処理（簡易版 - 実際の実装では AVAssetExportSession を使用）
        // ここでは一旦元のファイルを返す（圧縮処理は後で実装）
        return videoURL
    }
}