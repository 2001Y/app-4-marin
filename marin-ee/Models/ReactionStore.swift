import SwiftUI
import SwiftData

@Observable
final class ReactionStore {
    // メッセージごとのリアクション
    var reactions: [UUID: String] = [:]
    
    // 最近使った絵文字（最大3つ）
    @ObservationIgnored
    @AppStorage("recentReactionEmojis")
    var recentEmojis: String = "👍,❤️,😂"
    
    // リアクション表示中のメッセージID
    var reactingMessageID: UUID? = nil
    
    // ドラッグ中のハイライトインデックス
    var highlightedIndex: Int = 0
    
    // 上下ドラッグによる透明度
    var opacity: Double = 1.0
    
    // 最近使った絵文字の配列
    var recentEmojisArray: [String] {
        recentEmojis.split(separator: ",").map(String.init)
    }
    
    func addReaction(_ emoji: String, to messageID: UUID) {
        var current = reactions[messageID] ?? ""
        current.append(emoji)
        // 最大 20 文字に制限（先頭を切り詰める）
        if current.count > 20 {
            current = String(current.suffix(20))
        }
        reactions[messageID] = current
        updateRecentEmojis(with: emoji)
    }
    
    func removeReaction(from messageID: UUID) {
        reactions.removeValue(forKey: messageID)
    }
    
    private func updateRecentEmojis(with emoji: String) {
        var recent = recentEmojis.split(separator: ",").map(String.init)
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        recentEmojis = recent.prefix(3).joined(separator: ",")
    }
} 