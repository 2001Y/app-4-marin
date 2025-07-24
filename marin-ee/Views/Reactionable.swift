import SwiftUI
import UIKit

/// Invisible overlay that attaches a UILongPressGesture and presents
/// EmojisReactionKit when triggered.
struct Reactionable: UIViewRepresentable {
    let message: Message
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(message: message, onSelect: onSelect) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handle(_:)))
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Nothing to update
    }

    final class Coordinator: NSObject {
        let message: Message
        let onSelect: (String) -> Void
        init(message: Message, onSelect: @escaping (String) -> Void) {
            self.message = message
            self.onSelect = onSelect
        }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view else { return }
            ReactionKitWrapper.shared.present(for: message, anchorView: view) { emoji in
                self.onSelect(emoji)
            }
        }
    }
} 