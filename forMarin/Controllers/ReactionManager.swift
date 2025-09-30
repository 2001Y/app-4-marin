import Foundation
import SwiftUI
import CloudKit
import Combine

/// リアクション管理統一クラス
/// メッセージリアクションの一元管理とUI連携を提供
@MainActor
class ReactionManager: ObservableObject {
    static let shared = ReactionManager()
    
    @Published var recentEmojis: [String] = []
    @Published var lastError: Error?
    
    // 人気の絵文字（デフォルト）
    private let popularEmojis = ["👍", "❤️", "😂", "😊", "😍", "👏", "🔥", "😢", "😮", "😡"]
    
    // UserDefaults keys
    private enum Keys {
        static let recentEmojis = "ReactionManager_RecentEmojis"
        static let emojiUsageCount = "ReactionManager_EmojiUsageCount"
    }
    
    private init() {
        loadRecentEmojis()
    }
    
    // MARK: - Public API
    
    /// メッセージにリアクション絵文字を追加
    func addReaction(_ emoji: String, to message: Message) async -> Bool {
        guard let userID = CloudKitChatManager.shared.currentUserID else { return false }
        await CKSyncEngineManager.shared.queueReaction(messageRecordName: message.ckRecordName ?? message.id.uuidString,
                                                      roomID: message.roomID,
                                                      emoji: emoji,
                                                      userID: userID)
        return true
    }
    
    // MARK: - Emoji Management
    
    /// おすすめの絵文字を取得（最近使用した絵文字 + 人気の絵文字）
    func getSuggestedEmojis() -> [String] {
        // 安全に順序を保った重複排除
        var seen = Set<String>()
        var result: [String] = []
        for e in (recentEmojis + popularEmojis) {
            if seen.insert(e).inserted { result.append(e) }
        }
        return result
    }
    
    /// 特定のカテゴリの絵文字を取得
    func getEmojisByCategory(_ category: EmojiCategory) -> [String] {
        switch category {
        case .recent:
            return recentEmojis
        case .popular:
            return popularEmojis
        case .smileys:
            return ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚"]
        case .hearts:
            return ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "❤️‍🩹", "💕", "💞", "💓", "💗", "💖", "💘", "💝"]
        case .gestures:
            return ["👍", "👎", "👏", "🙌", "👐", "🤲", "🤝", "🙏", "✍️", "👌", "🤌", "🤏", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "👋", "🤚", "🖐", "✋", "🖖", "👊", "✊", "🤛", "🤜"]
        case .all:
            return getSuggestedEmojis()
        }
    }
    
    /// 最近使用した絵文字を更新
    private func updateRecentEmojis(_ emoji: String) {
        // 既存の絵文字を削除
        recentEmojis.removeAll { $0 == emoji }
        
        // 先頭に追加
        recentEmojis.insert(emoji, at: 0)
        
        // 最大10個に制限
        if recentEmojis.count > 10 {
            recentEmojis = Array(recentEmojis.prefix(10))
        }
        
        saveRecentEmojis()
    }
    
    /// 絵文字使用回数を増加
    private func incrementEmojiUsage(_ emoji: String) {
        let key = "\(Keys.emojiUsageCount)_\(emoji)"
        let currentCount = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(currentCount + 1, forKey: key)
    }
    
    /// 絵文字使用回数を取得
    func getEmojiUsageCount(_ emoji: String) -> Int {
        let key = "\(Keys.emojiUsageCount)_\(emoji)"
        return UserDefaults.standard.integer(forKey: key)
    }
    
    // MARK: - Persistence
    
    private func loadRecentEmojis() {
        if let data = UserDefaults.standard.data(forKey: Keys.recentEmojis),
           let emojis = try? JSONDecoder().decode([String].self, from: data) {
            recentEmojis = emojis
        }
    }
    
    private func saveRecentEmojis() {
        if let data = try? JSONEncoder().encode(recentEmojis) {
            UserDefaults.standard.set(data, forKey: Keys.recentEmojis)
        }
    }
    
    /// データをクリア（テスト用）
    func clearData() {
        recentEmojis.removeAll()
        UserDefaults.standard.removeObject(forKey: Keys.recentEmojis)
        
        // 使用回数データもクリア
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix(Keys.emojiUsageCount) {
                defaults.removeObject(forKey: key)
            }
        }
        
        log("Data cleared", category: "ReactionManager")
    }
    
}

// MARK: - Supporting Types

enum EmojiCategory: String, CaseIterable {
    case recent = "最近使用"
    case popular = "人気"
    case smileys = "スマイリー"
    case hearts = "ハート"
    case gestures = "ジェスチャー"
    case all = "すべて"
    
    var icon: String {
        switch self {
        case .recent: return "🕒"
        case .popular: return "⭐"
        case .smileys: return "😊"
        case .hearts: return "❤️"
        case .gestures: return "👍"
        case .all: return "🌟"
        }
    }
}

// MARK: - SwiftUI Integration

// 旧 ReactionPickerView は未使用となったため削除
