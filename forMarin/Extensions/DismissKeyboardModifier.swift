import SwiftUI

struct DismissKeyboardOnDrag: ViewModifier {
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onEnded { value in
                    // 縦方向 (下方向) のスワイプ確定時のみキーボードを閉じる（多重呼び出しを防止）
                    let dy = value.translation.height
                    let dx = value.translation.width
                    if dy > abs(dx) && dy > 10 { // 下方向かつ十分な距離
                        log("Keyboard: dismiss by input drag", category: "ChatView")
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
