import SwiftUI
import UIKit

/// ReactionKitWrapperを使用してEmojisReactionKitを表示するSwiftUIビュー
struct ReactionKitWrapperView: UIViewRepresentable {
    let message: Message
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(message: message, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 必要に応じて更新処理
    }

    final class Coordinator: NSObject {
        let message: Message
        let onSelect: (String) -> Void

        init(message: Message, onSelect: @escaping (String) -> Void) {
            self.message = message
            self.onSelect = onSelect
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view else { return }
            ReactionKitWrapper.shared.present(for: message, anchorView: view) { [weak self] emoji in
                self?.onSelect(emoji)
            }
        }
    }
} 