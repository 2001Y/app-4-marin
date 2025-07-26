import SwiftUI

extension ChatView {
    
    // MARK: - Editing Overlay
    @ViewBuilder 
    func EditingOverlay(message: Message) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("メッセージを編集")
                    .font(.headline)
                    .foregroundColor(.white)
                TextEditor(text: $editTextOverlay)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear { editTextOverlay = message.body ?? "" }
            }
            .padding()

            Button {
                let trimmed = editTextOverlay.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { return }
                message.body = trimmed
                if let recName = message.ckRecordName {
                    Task { try? await CKSync.updateMessageBody(recordName: recName, newBody: trimmed) }
                }
                editingMessage = nil
            } label: {
                Label("確定", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .padding(16)
                    .background(Color.accentColor, in: Circle())
                    .foregroundColor(.white)
                    .shadow(radius: 4)
            }
            .padding([.trailing, .bottom], 24)
        }
    }
} 