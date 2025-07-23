import SwiftUI

struct ReactionBarView: View {
    let emojis: [String]
    let isMine: Bool
    var addHandler: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(emojis, id: \.self) { emo in
                Text(emo)
            }
            if let addHandler {
                Button(action: addHandler) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(isMine ? .trailing : .leading, 12)
    }
} 