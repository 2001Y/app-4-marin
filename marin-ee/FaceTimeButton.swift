import SwiftUI

struct FaceTimeButton: View {
    @Environment(\.openURL) private var openURL
    let callee: String

    var body: some View {
        Button {
            P2PController.shared.close() // エコー抑止
            if let url = URL(string: "facetime://\(callee)") {
                openURL(url)
            }
        } label: {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 24))
        }
    }
} 

/// FaceTime Audio call button
struct FaceTimeAudioButton: View {
    @Environment(\.openURL) private var openURL
    let callee: String

    var body: some View {
        Button {
            P2PController.shared.close()
            if let url = URL(string: "facetime-audio://\(callee)") {
                openURL(url)
            }
        } label: {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 24))
        }
    }
} 