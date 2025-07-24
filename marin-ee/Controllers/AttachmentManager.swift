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
        guard let data = image.optimizedData() ?? image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = makeFileURL(ext: "jpg")
        do { try data.write(to: url); return url } catch { print("[AttachmentManager] save error", error); return nil }
    }
}