import Foundation

/// Centralised helper for managing cached image files (downloaded from CloudKit).
/// - Stores files in the Caches directory (same as current implementation).
/// - Enforces an upper limit (default 100 MB) by deleting oldest files first.
/// - Provides utilities for computing current cache size and clearing the cache.
struct ImageCacheManager {
    /// Directory that stores cached images.
    /// Caches ディレクトリはシステムや Xcode の再インストール時に削除されるため、
    /// 永続性を確保するために Application Support/Images 配下へ保存する。
    static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Images", isDirectory: true)
        // Ensure directory exists (ignore errors)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Maximum cache size in bytes (100 MiB).
    static var maxCacheBytes: UInt64 = 100 * 1024 * 1024

    /// Returns total size of image files currently stored in cache.
    static func currentCacheSize() -> UInt64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                                       options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for url in files where isImage(url) {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        }
        return total
    }

    /// Remove oldest files until cache is below the max threshold.
    static func enforceLimit() {
        var size = currentCacheSize()
        guard size > maxCacheBytes else { return }

        guard var files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                                      options: [.skipsHiddenFiles]) else { return }
        // sort by oldest modification date first
        files.sort { (lhs, rhs) -> Bool in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return lDate < rDate
        }
        for file in files where isImage(file) {
            size = (size > 0) ? size : currentCacheSize()
            if size <= maxCacheBytes { break }
            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
            try? FileManager.default.removeItem(at: file)
            if size > fileSize { size -= fileSize }
            else { size = currentCacheSize() }
        }
    }

    /// Clears the entire image cache.
    static func clearCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for url in files where isImage(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers
    private static func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "heic", "png"].contains(url.pathExtension.lowercased())
    }
} 