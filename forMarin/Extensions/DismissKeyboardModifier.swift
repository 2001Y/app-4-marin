import SwiftUI

struct DismissKeyboardOnDrag: ViewModifier {
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onChanged { value in
                    // 縦方向 (下方向) のみでキーボードを閉じる。横移動は無視し、ページスワイプを阻害しない。
                    if value.translation.height > abs(value.translation.width) && value.translation.height > 0 {
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