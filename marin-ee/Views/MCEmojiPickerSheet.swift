import SwiftUI

#if canImport(MCEmojiPicker)
import MCEmojiPicker

/// SwiftUI sheet wrapper for MCEmojiPickerViewController
struct MCEmojiPickerSheet: UIViewControllerRepresentable {
    /// Selected emoji code point(s) – updated when user taps an emoji
    @Binding var selectedEmoji: String

    func makeCoordinator() -> Coordinator { Coordinator(selectedEmoji: $selectedEmoji) }

    func makeUIViewController(context: Context) -> MCEmojiPickerViewController {
        let picker = MCEmojiPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MCEmojiPickerViewController, context: Context) {}

    // MARK: - Coordinator
    final class Coordinator: NSObject, MCEmojiPickerDelegate {
        @Binding var selectedEmoji: String

        init(selectedEmoji: Binding<String>) {
            self._selectedEmoji = selectedEmoji
        }

        // Required by MCEmojiPickerDelegate (v1.2+)
        @objc(didGetEmoji:)
        func didGetEmoji(emoji: String) {
            selectedEmoji = emoji
        }

        // Optional legacy callback (pre-1.2.0)
        @objc(emojiPicker:didSelect:)
        func emojiPicker(_ picker: MCEmojiPickerViewController, didSelect emoji: String) {
            selectedEmoji = emoji
            picker.dismiss(animated: true)
        }
    }
}
#endif 