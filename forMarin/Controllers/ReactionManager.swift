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
        guard let recordName = message.ckRecordName else {
            log("Cannot add reaction: message has no CloudKit record name", category: "ReactionManager")
            return false
        }
        
        do {
            // CloudKitでリアクションを追加
            try await CloudKitChatManager.shared.addReactionToMessage(recordName: recordName, emoji: emoji)
            
            // 使用頻度を更新
            incrementEmojiUsage(emoji)
            updateRecentEmojis(emoji)
            
            log("Reaction added successfully: \(emoji)", category: "ReactionManager")
            return true
            
        } catch {
            log("Failed to add reaction: \(error)", category: "ReactionManager")
            lastError = error
            return false
        }
    }
    
    // MARK: - Emoji Management
    
    /// おすすめの絵文字を取得（最近使用した絵文字 + 人気の絵文字）
    func getSuggestedEmojis() -> [String] {
        let combined = recentEmojis + popularEmojis
        return Array(NSOrderedSet(array: combined)) as! [String] // 重複除去
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

struct ReactionPickerView: View {
    let message: Message
    @State private var selectedCategory: EmojiCategory = .recent
    @StateObject private var reactionManager = ReactionManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // カテゴリ選択
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(EmojiCategory.allCases, id: \.self) { category in
                            Button(action: { selectedCategory = category }) {
                                VStack(spacing: 4) {
                                    Text(category.icon)
                                        .font(.title2)
                                    Text(category.rawValue)
                                        .font(.caption)
                                        .foregroundColor(selectedCategory == category ? .blue : .secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedCategory == category ? Color.blue.opacity(0.1) : Color.clear)
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
                
                Divider()
                
                // 絵文字グリッド
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(reactionManager.getEmojisByCategory(selectedCategory), id: \.self) { emoji in
                            Button(action: {
                                Task {
                                    let success = await reactionManager.addReaction(emoji, to: message)
                                    if success {
                                        dismiss()
                                    }
                                }
                            }) {
                                Text(emoji)
                                    .font(.title)
                                    .frame(width: 44, height: 44)
                                    .background(Color.gray.opacity(0.1))
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("リアクションを選択")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("閉じる") { dismiss() })
        }
    }
}