import SwiftUI

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HeightReaderModifier: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(HeightPreferenceKey.self) { newValue in
                if abs(height - newValue) > 0.5 { // 小さな揺れは無視
                    height = newValue
                }
            }
    }
}

extension View {
    func readHeight(_ height: Binding<CGFloat>) -> some View {
        modifier(HeightReaderModifier(height: height))
    }
}

