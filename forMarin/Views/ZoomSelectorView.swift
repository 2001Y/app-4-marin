import SwiftUI

struct ZoomSelectorView: View {
    @Binding var selectedZoom: Double
    let availableZooms: [Double]
    let onZoomChanged: (Double) -> Void
    
    var body: some View {
        HStack(spacing: 20) {
            ForEach(availableZooms, id: \.self) { zoom in
                Button {
                    selectedZoom = zoom
                    onZoomChanged(zoom)
                } label: {
                    Text(zoomText(for: zoom))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(selectedZoom == zoom ? .yellow : .white)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(
                            Circle()
                                .fill(selectedZoom == zoom ? .white.opacity(0.2) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.black.opacity(0.5))
        )
    }
    
    private func zoomText(for zoom: Double) -> String {
        if zoom == floor(zoom) {
            // 整数値の場合
            return "×\(Int(zoom))"
        } else {
            // 小数値の場合、適切な精度で表示
            return String(format: "×%.1f", zoom)
        }
    }
}

#Preview {
    ZoomSelectorView(
        selectedZoom: .constant(0.5),
        availableZooms: [0.5, 1.0, 3.0]
    ) { zoom in
        log("Zoom changed to: \(zoom)", category: "App")
    }
    .background(Color.black)
}