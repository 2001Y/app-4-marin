import SwiftUI

struct ReactionBarView: View {
    let emojis: [String]
    let isMine: Bool
    
    private var uniqueEmojiCounts: [(emoji: String, count: Int)] {
        let counts = emojis.reduce(into: [:]) { dict, emoji in
            dict[emoji, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            if isMine {
                Spacer()
            }
            
            HStack(spacing: 2) {
                ForEach(uniqueEmojiCounts, id: \.emoji) { item in
                    HStack(spacing: 2) {
                        Text(item.emoji)
                            .font(.system(size: 14))
                        if item.count > 1 {
                            Text("\(item.count)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
                }
            }
            
            if !isMine {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, -4)
    }
} 