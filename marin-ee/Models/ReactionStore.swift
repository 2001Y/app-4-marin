import SwiftUI
import Foundation

@Observable
final class ReactionStore {
    // メッセージごとのリアクション
    var reactions: [UUID: String] = [:]

    // 最近使った絵文字（最大3つ）
    @AppStorage("recentReactionEmojis")
    var recentEmojis: String = "👍,❤️,😂"

    // リアクション表示中のメッセージID
    var reactingMessageID: UUID? = nil

    // ドラッグ中のハイライトインデックス
    var highlightedIndex: Int = 0

    // 上下ドラッグによる透明度
    var opacity: Double = 1.0

    func addReaction(_ emoji: String, to messageID: UUID) {
        reactions[messageID] = emoji
        updateRecentEmojis(with: emoji)
    }

    private func updateRecentEmojis(with emoji: String) {
        var recent = recentEmojis.split(separator: ",").map(String.init)
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        recentEmojis = recent.prefix(3).joined(separator: ",")
    }
} 