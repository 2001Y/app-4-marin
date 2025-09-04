import SwiftUI

struct MessageActionSheet: View {
    let message: Message
    let isMine: Bool
    var onReact: (String) -> Void
    var onEdit: () -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onDismiss: () -> Void

    @StateObject private var reactionManager = ReactionManager.shared
    @State private var showEmojiPicker = false
    @State private var pickerEmoji: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            // 上部: 絵文字（横スクロールなし、画面幅に入る数のみ）
            GeometryReader { geo in
                let all = reactionManager.getSuggestedEmojis()
                let itemSize: CGFloat = 44
                let spacing: CGFloat = 10
                let extraButtonWidth: CGFloat = 44 // 右端のピッカーボタン
                let horizontalPadding: CGFloat = 16 * 2
                let available = max(0, geo.size.width - horizontalPadding - extraButtonWidth - spacing)
                let perItem = itemSize + spacing
                let maxCount = max(0, Int(floor(available / perItem)))
                let shown = Array(all.prefix(maxCount))
                HStack(spacing: spacing) {
                    ForEach(shown, id: \.self) { emoji in
                        Button(action: { onReact(emoji) }) {
                            Text(emoji)
                                .font(.system(size: 28))
                                .frame(width: itemSize, height: itemSize)
                                .background(Color.gray.opacity(0.12))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    Button(action: { showEmojiPicker = true }) {
                        Image(systemName: "smiley")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: itemSize, height: itemSize)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
            .frame(height: 44)
            .padding(.bottom, 4)

            Divider()

            // 下部: アクション
            VStack(spacing: 8) {
                if isMine {
                    Button(action: onEdit) {
                        Label("メッセージを編集", systemImage: "pencil")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }

                if (message.body?.isEmpty == false) {
                    Button(action: onCopy) {
                        Label("テキストをコピー", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("メッセージを削除", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showEmojiPicker, onDismiss: {
            pickerEmoji = ""
        }) {
            MCEmojiPickerSheet(selectedEmoji: $pickerEmoji)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: pickerEmoji) { newValue, _ in
            guard !newValue.isEmpty else { return }
            onReact(newValue)
            onDismiss()
        }
    }
}
