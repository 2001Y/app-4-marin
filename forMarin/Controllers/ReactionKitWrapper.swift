import UIKit
import EmojisReactionKit

/// Bridge singleton that presents EmojisReactionKit on a given UIView and
/// returns the selected emoji via completion handler.
final class ReactionKitWrapper: NSObject {
    static let shared = ReactionKitWrapper()
    private override init() {}

    // Store callbacks keyed by message UUID
    private var callbacks: [UUID: (String) -> Void] = [:]
}

// MARK: - Public API
extension ReactionKitWrapper {
    /// Presents the emoji reaction popup on the specified `anchorView`.
    /// - Parameters:
    ///   - message: The message model whose id is used as the identifier.
    ///   - anchorView: Any UIView (typically inside the SwiftUI bubble) that
    ///                 should become the source of the reaction popup.
    ///   - completion: Called with the selected emoji string.
    func present(for message: Message,
                 anchorView: UIView,
                 completion: @escaping (String) -> Void) {
        callbacks[message.id] = completion

        // Standard emoji set – replace / localize freely
        let emojis = ["👍", "😂", "❤️", "👌", "🔥"]
        let config = ReactionConfig(
            itemIdentifier: message.id,
            emojis: emojis,
            menu: nil,               // 追加アクション不要の場合 nil
            startFrom: .center       // アニメーション開始位置
        )
        // we don’t need the returned preview handle
        _ = anchorView.react(with: config, delegate: self)
    }
}

// MARK: - ReactionDelegate
// EmojisReactionKit delegates are Objective-C exposed; conform using the
// correct protocol name defined in the library.
extension ReactionKitWrapper: ReactionPreviewDelegate {
    @objc func didDismiss(on identifier: Any?,
                          action: UIAction?,
                          emoji: String?,
                          moreButton: Bool) {
        // `identifier` は config.itemIdentifier で渡した値（UUID）
        guard let id = identifier as? UUID,
              let emoji = emoji,
              let cb = callbacks[id] else { return }
        cb(emoji)
        callbacks.removeValue(forKey: id)
    }
} 