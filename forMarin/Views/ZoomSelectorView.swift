import SwiftUI

struct ZoomSelectorView: View {
    @Binding var selectedZoom: Double
    let availableZooms: [Double]
    let minZoom: Double
    let maxZoom: Double
    let onZoomChanged: (Double) -> Void

    @State private var dragStartZoom: Double = 1.0

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
        // チップ列の上をドラッグして連続ズーム（プレビュー側では行わない）
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartZoom == 1.0 && selectedZoom != 1.0 {
                        dragStartZoom = selectedZoom
                    }
                    let pointsPerDoubling: CGFloat = 160
                    let dx = value.translation.width
                    let mul = pow(2.0 as CGFloat, dx / pointsPerDoubling)
                    let target = max(minZoom, min(maxZoom, Double(CGFloat(dragStartZoom) * mul)))
                    selectedZoom = target
                    onZoomChanged(target)
                }
                .onEnded { _ in
                    dragStartZoom = selectedZoom
                }
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
        availableZooms: [0.5, 1.0, 3.0],
        minZoom: 0.5,
        maxZoom: 10.0
    ) { zoom in
        log("Zoom changed to: \(zoom)", category: "App")
    }
    .background(Color.black)
}
