import SwiftUI
import UIKit

struct ReactionPickerView: View {
    @Environment(ReactionStore.self) private var store
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var showEmojiPicker = false

    private var recentEmojis: [String] {
        store.recentEmojis.split(separator: ",").map(String.init)
    }

    var body: some View {
        HStack(spacing: 20) {
            // 最近使った絵文字
            ForEach(Array(recentEmojis.enumerated()), id: \.offset) { index, emoji in
                Text(emoji)
                    .font(.system(size: 28))
                    .scaleEffect(store.highlightedIndex == index ? 1.3 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7),
                              value: store.highlightedIndex)
            }

            // プラスボタン
            Image(systemName: "plus.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .scaleEffect(store.highlightedIndex == 3 ? 1.3 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7),
                          value: store.highlightedIndex)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .opacity(store.opacity)
        .gesture(reactionGesture)
        .sheet(isPresented: $showEmojiPicker) {
            MCEmojiPickerSheet { selectedEmoji in
                if let messageID = store.reactingMessageID {
                    store.addReaction(selectedEmoji, to: messageID)
                }
                store.reactingMessageID = nil
            }
        }
    }

    private var reactionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                // 横位置からインデックスを計算
                updateHighlight(at: value.location)

                // 縦移動で透明度を調整
                let absY = abs(value.translation.height)
                store.opacity = max(0.2, 1 - (absY / 150))
            }
            .onEnded { value in
                let absY = abs(value.translation.height)

                if absY > 60 {
                    // キャンセル
                    store.reactingMessageID = nil
                } else {
                    // 選択確定
                    confirmSelection()
                }

                // 状態リセット
                store.opacity = 1.0
                store.highlightedIndex = 0
            }
    }

    private func updateHighlight(at location: CGPoint) {
        // HStackの幅を4等分（3つの絵文字 + プラスボタン）
        let width = location.x
        let itemWidth: CGFloat = 60 // 推定値
        let index = Int(width / itemWidth)
        store.highlightedIndex = max(0, min(3, index))
    }

    private func confirmSelection() {
        guard let messageID = store.reactingMessageID else { return }

        if store.highlightedIndex < recentEmojis.count {
            // 絵文字選択
            let emoji = recentEmojis[store.highlightedIndex]
            store.addReaction(emoji, to: messageID)
            store.reactingMessageID = nil

            // Haptic feedback
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if store.highlightedIndex == 3 {
            // プラスボタン
            showEmojiPicker = true
        }
    }
} 