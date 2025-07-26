import SwiftUI
import SwiftData

struct PairingView: View {
    @State private var partnerID: String = ""
    @Environment(\.modelContext) private var modelContext
    var onChatCreated: (ChatRoom) -> Void
    
    init(onChatCreated: @escaping (ChatRoom) -> Void) {
        self.onChatCreated = onChatCreated
    }

    var body: some View {
        ScrollView {
            
            VStack(spacing: 24) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(.top, 40)

                Text("4-Marin")
                    .font(.largeTitle.bold())

                Text("大切な人との\n特別な時間を始めよう")
                    .font(.title2)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)

                Text("2人が同時にチャットを開くと\n自動で顔が見える特別なアプリ")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 6) {
                    Text("📱 2人が同時にチャットを開くと自動で顔が見える")
                    Text("📸 外の様子だけじゃなく、あなたの顔も一緒に録画")
                    Text("😊 お気に入りのリアクションでもっと楽しく")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("相手のAppleアカウント")
                        .font(.subheadline.weight(.semibold))

                    TextField("メールアドレス または 電話番号", text: $partnerID)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    addNewChat()
                } label: {
                    Text("登録して開始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(partnerID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }
    
    private func addNewChat() {
        let trimmedID = partnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRoom = ChatRoom(remoteUserID: trimmedID)
        modelContext.insert(newRoom)
        
        // モデルコンテキストを保存して即座に反映
        try? modelContext.save()
        
        print("[DEBUG] PairingView: Created new chat with ID: \(newRoom.id)")
        partnerID = ""
        onChatCreated(newRoom)
    }
} 