import SwiftUI

struct CameraDualButton: View {
    @State private var showDualCameraRecorder = false
    
    var body: some View {
        Button {
            showDualCameraRecorder = true
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showDualCameraRecorder) {
            DualCamRecorderView()
        }
    }
} 