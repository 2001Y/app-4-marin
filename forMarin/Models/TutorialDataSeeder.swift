import UIKit
import SwiftData

/// 各チャットルームでメッセージ履歴が空の場合に
/// デモ／チュートリアル用メッセージを自動で挿入するヘルパ。
/// - 画像を含むメッセージはランダムカラーのシンプルなサンプル画像を動的生成して保存する。
struct TutorialDataSeeder {
    /// メッセージを挿入する。
    /// 各ルームごとに `didSeedTutorial_<roomID>` フラグを立て、重複を防ぐ。
    static func seed(into context: ModelContext, roomID: String, myID: String, partnerID: String) {
        let now = Date()
        
        print("[DEBUG] TutorialDataSeeder: Starting seed for roomID: \(roomID)")
        
        // 既にこのルームでシード済みならスキップ
        let tutorialKey = "didSeedTutorial_\(roomID)"
        guard !UserDefaults.standard.bool(forKey: tutorialKey) else { 
            print("[DEBUG] TutorialDataSeeder: Already seeded for roomID: \(roomID)")
            return 
        }
        
        let messages: [(String, String?, String?, Date)] = [
            (partnerID, "4-Marinへようこそ！🌊", nil, now.addingTimeInterval(-300)),
            (partnerID, "大切な人と2人だけの空間です", nil, now.addingTimeInterval(-280)),
            (myID, "😊", nil, now.addingTimeInterval(-260)),
            (partnerID, "画像も送れます📸", nil, now.addingTimeInterval(-240)),
            (partnerID, nil, createDemoImagePath(text: "🌸", color: .systemPink), now.addingTimeInterval(-220)),
            (myID, "きれい！", nil, now.addingTimeInterval(-200)),
            (partnerID, "リアクションもできるよ", nil, now.addingTimeInterval(-180)),
            (myID, "👍", nil, now.addingTimeInterval(-160)),
            (partnerID, "長押しで編集もできます", nil, now.addingTimeInterval(-140)),
            (myID, "便利だね", nil, now.addingTimeInterval(-120)),
            (partnerID, "ビデオ通話やカレンダー共有も", nil, now.addingTimeInterval(-100)),
            (myID, "楽しみ！", nil, now.addingTimeInterval(-80)),
            (partnerID, "2人だけの思い出を作ろう💕", nil, now.addingTimeInterval(-60)),
        ]

        print("[DEBUG] TutorialDataSeeder: Creating \(messages.count) messages")
        
        for (index, (senderID, body, assetPath, createdAt)) in messages.enumerated() {
            print("[DEBUG] TutorialDataSeeder: Creating message \(index + 1): \(body ?? "image")")
            
            let message = Message(
                roomID: roomID,
                senderID: senderID,
                body: body,
                assetPath: assetPath
            )
            message.createdAt = createdAt
            message.isSent = true
            // Add sample reactions to some messages
            if body == "リアクションもできるよ" {
                message.reactionEmoji = "❤️"
            } else if body == "👍" {
                message.reactionEmoji = "🎉"
            }
            context.insert(message)
        }
        
        do {
            try context.save()
            print("[DEBUG] TutorialDataSeeder: Successfully saved messages")
        } catch {
            print("[ERROR] TutorialDataSeeder: Failed to save context: \(error)")
        }

        UserDefaults.standard.set(true, forKey: tutorialKey)
        print("[DEBUG] TutorialDataSeeder: Completed seed for roomID: \(roomID)")
    }

    /// ランダムカラー or 指定カラーのシンプルなデモ画像を生成し、キャッシュディレクトリに保存。
    /// 生成に失敗した場合は `nil` を返す。
    @discardableResult
    private static func createDemoImagePath(text: String, color: UIColor) -> String? {
        print("[DEBUG] TutorialDataSeeder: Creating demo image with text: \(text)")
        
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        do {
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
            
            guard let data = image.pngData() else { 
                print("[ERROR] TutorialDataSeeder: Failed to create PNG data")
                return nil 
            }
            
            let url = ImageCacheManager.cacheDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")
            
            print("[DEBUG] TutorialDataSeeder: Saving image to: \(url.path)")
            
            try data.write(to: url)
            print("[DEBUG] TutorialDataSeeder: Successfully created demo image")
            return url.path
        } catch {
            print("[ERROR] TutorialDataSeeder: Failed to create demo image: \(error)")
            return nil
        }
    }
} 