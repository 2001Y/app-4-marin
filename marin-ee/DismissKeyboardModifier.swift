import SwiftUI

struct DismissKeyboardOnDrag: ViewModifier {
    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onChanged { value in
                    if value.translation.height > 0 {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
        )
    }
}

extension View {
    func dismissKeyboardOnDrag() -> some View {
        modifier(DismissKeyboardOnDrag())
    }
} 