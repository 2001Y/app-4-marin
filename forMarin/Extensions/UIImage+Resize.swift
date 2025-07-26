import UIKit
import AVFoundation

extension UIImage {
    /// 最大辺を maxLength 以下に収め、HEIC (iOS 11+) または JPEG でエンコードして Data を返す。
    /// - Parameters:
    ///   - maxLength: 長辺の最大ピクセル。既定 1280。
    ///   - jpegQuality: JPEG 圧縮率。
    /// - Returns: エンコード済みデータ
    func optimizedData(maxLength: CGFloat = 1280,
                       jpegQuality: CGFloat = 0.75) -> Data? {
        // --- リサイズ ---
        let longer = max(size.width, size.height)
        let scale  = (longer > maxLength) ? maxLength / longer : 1
        let newSize = CGSize(width: size.width * scale,
                             height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized  = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }

        // --- HEIC 優先、無ければ JPEG ---
        if #available(iOS 11.0, *),
           let heic = resized.heicData(quality: jpegQuality) {
            return heic
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }

    /// 指定サイズにアスペクトフィットでリサイズ
    func resized(to target: CGSize) -> UIImage {
        let scale = min(target.width / size.width, target.height / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Private
    @available(iOS 11.0, *)
    private func heicData(quality: CGFloat) -> Data? {
        guard let cgimg = cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, AVFileType.heic as CFString, 1, nil) else { return nil }
        let options: NSDictionary = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgimg, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
} 