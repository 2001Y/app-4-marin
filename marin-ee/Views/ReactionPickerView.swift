import SwiftUI

struct ReactionPickerView: View {
    @Environment(ReactionStore.self) private var store
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var showEmojiPicker = false
    @State private var pickerSize: CGSize = .zero
    @State private var pickedEmoji: String = ""
    
    private var recentEmojis: [String] {
        store.recentEmojisArray
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
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        pickerSize = geometry.size
                    }
            }
        )
        .coordinateSpace(name: "picker")
        .gesture(reactionGesture)
        .sheet(isPresented: $showEmojiPicker) {
            MCEmojiPickerSheet(selectedEmoji: $pickedEmoji)
                .onDisappear {
                    if !pickedEmoji.isEmpty, let messageID = store.reactingMessageID {
                        store.addReaction(pickedEmoji, to: messageID)
                        store.reactingMessageID = nil
                        pickedEmoji = ""
                    }
                }
        }
    }
    
    private var reactionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                // convert location in picker space
                let loc = value.location
                updateHighlight(at: loc)
                // adjust opacity
                let absYcg = abs(value.translation.height)
                let ratio = absYcg / 150.0
                let opacityCG = max(CGFloat(0.2), CGFloat(1.0) - ratio)
                store.opacity = Double(opacityCG)
            }
            .onEnded { value in
                let absYcg = abs(value.translation.height)
                if absYcg > 60 {
                    store.reactingMessageID = nil
                } else {
                    confirmSelection()
                }
                store.opacity = 1.0
                store.highlightedIndex = 0
            }
    }
    
    private func updateHighlight(at location: CGPoint) {
        guard pickerSize.width > 0 else { return }
        
        // アイテムの総数（絵文字3つ + プラスボタン）
        let totalItems = min(recentEmojis.count, 3) + 1
        let itemWidth = pickerSize.width / CGFloat(totalItems)
        
        // タップ位置からインデックスを計算
        let index = Int(location.x / itemWidth)
        let clampedIndex = max(0, min(index, totalItems - 1))
        
        if store.highlightedIndex != clampedIndex {
            store.highlightedIndex = clampedIndex
            // Haptic feedback
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    
    private func confirmSelection() {
        guard let messageID = store.reactingMessageID else { return }
        
        if store.highlightedIndex < recentEmojis.count {
            // 絵文字選択
            let emoji = recentEmojis[store.highlightedIndex]
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                store.addReaction(emoji, to: messageID)
                store.reactingMessageID = nil
            }
            
            // Haptic feedback
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else if store.highlightedIndex == 3 || store.highlightedIndex == recentEmojis.count {
            // プラスボタン
            showEmojiPicker = true
        }
    }
} 