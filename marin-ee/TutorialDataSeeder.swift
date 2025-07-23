import UIKit
import SwiftData

/// 初回起動時、メッセージ履歴が空の場合に
/// デモ／チュートリアル用メッセージを自動で挿入するヘルパ。
/// - 画像を含むメッセージはランダムカラーのシンプルなサンプル画像を動的生成して保存する。
struct TutorialDataSeeder {
    /// メッセージを挿入する。
    /// 挿入完了後は UserDefaults の `didSeedTutorial` フラグを立て、重複を防ぐ。
    static func seed(into context: ModelContext, roomID: String, myID: String, partnerID: String) {
        let now = Date()
        let messages: [(String, String?, [URL], Date)] = [
            (partnerID, "4-Marinへようこそ！🌊", [], now.addingTimeInterval(-300)),
            (partnerID, "大切な人と2人だけの空間です", [], now.addingTimeInterval(-280)),
            (myID, "😊", [], now.addingTimeInterval(-260)),
            (partnerID, "画像も送れます📸", [], now.addingTimeInterval(-240)),
            (partnerID, nil, [createDemoImage(text: "🌸", color: .systemPink)].compactMap { $0 }, now.addingTimeInterval(-220)),
            (myID, "きれい！", [], now.addingTimeInterval(-200)),
            (partnerID, "リアクションもできるよ", [], now.addingTimeInterval(-180)),
            (myID, "👍", [], now.addingTimeInterval(-160)),
            (partnerID, "長押しで編集もできます", [], now.addingTimeInterval(-140)),
            (myID, "便利だね", [], now.addingTimeInterval(-120)),
            (partnerID, "ビデオ通話やカレンダー共有も", [], now.addingTimeInterval(-100)),
            (myID, "楽しみ！", [], now.addingTimeInterval(-80)),
            (partnerID, "2人だけの思い出を作ろう💕", [], now.addingTimeInterval(-60)),
        ]

        // 既にシード済みならスキップ
        guard !UserDefaults.standard.bool(forKey: "didSeedTutorial") else { return }

        // 生成時刻を少しずつ遅らせて順序を分かりやすくする
        var base = Date().addingTimeInterval(-7 * 60) // 7分前を起点
        func nextTimestamp() -> Date {
            defer { base.addTimeInterval(60) } // 1 分ずつ進める
            return base
        }

        for (senderID, body, imageLocalURLs, createdAt) in messages {
            let message = Message(roomID: roomID,
                                  senderID: senderID,
                                  body: body,
                                  imageLocalURLs: imageLocalURLs,
                                  createdAt: createdAt,
                                  isSent: true)
            // Add sample reactions to some messages
            if body == "リアクションもできるよ" {
                message.reactionEmoji = "❤️"
            } else if body == "👍" {
                message.reactionEmoji = "🎉"
            }
            context.insert(message)
        }
        try? context.save()

        UserDefaults.standard.set(true, forKey: "didSeedTutorial")
    }

    /// ランダムカラー or 指定カラーのシンプルなデモ画像を生成し、キャッシュディレクトリに保存。
    /// 生成に失敗した場合は `nil` を返す。
    @discardableResult
    private static func createDemoImage(text: String, color: UIColor) -> URL? {
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // 背景
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // テキスト描画
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 120),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let textRect = CGRect(x: 0,
                                   y: (size.height - 120) / 2,
                                   width: size.width,
                                   height: 120)
            attrStr.draw(in: textRect)
        }
        guard let data = image.pngData() else { return nil }
        let url = ImageCacheManager.cacheDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
} 