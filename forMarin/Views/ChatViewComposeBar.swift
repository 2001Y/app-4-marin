import SwiftUI
import PhotosUI

extension ChatView {
    
    // MARK: - Compose Bar Views
    @ViewBuilder 
    func composeBarView() -> some View {
        HStack(spacing: 6) {
            composeLeadingTools()
            composeTextField()
            composeTrailingTools()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    // 以下 composeBarView のパーツをさらに分解
    @ViewBuilder 
    func composeLeadingTools() -> some View {
        if attachmentsExpanded {
            PhotosPicker(selection: $photosPickerItems,
                            maxSelectionCount: 10,
                            matching: .any(of: [.images, .videos]),
                            photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .onChange(of: photosPickerItems) { _, _ in sendSelectedMedia() }

            CameraDualButton()
        } else {
            Button { withAnimation { attachmentsExpanded = true } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 20))
            }
        }
    }

    @ViewBuilder 
    func composeTextField() -> some View {
        TextField("Message", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(18)
            .lineLimit(1...5)
            .focused($isTextFieldFocused)
            .onChange(of: isTextFieldFocused) { _, focused in
                withAnimation { attachmentsExpanded = !focused }
            }
    }

    @ViewBuilder 
    func composeTrailingTools() -> some View {
        if isTextFieldFocused {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { isEmojiPickerShown = true } label: {
                    Image(systemName: "smiley")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
            } else {
                Button { commitSend(with: text); text = "" } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
            }
        } else {
            QuickEmojiBar(recentEmojis: Array(recentEmojis.prefix(3))) { emoji in
                commitSend(with: emoji)
                updateRecentEmoji(emoji)
            } onShowPicker: { isEmojiPickerShown = true }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Button { commitSend(with: text); text = "" } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
            }
        }
    }
} 