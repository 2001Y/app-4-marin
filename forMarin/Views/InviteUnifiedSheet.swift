import SwiftUI
import CloudKit

struct InviteUnifiedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // 呼び出し元へ部屋作成通知（一覧側を即時更新したいケース用）
    let onChatCreated: (ChatRoom) -> Void
    // 参加完了時のコールバック（必要なら一覧をリフレッシュ）
    var onJoined: (() -> Void)?
    // 次のモーダル（QRスキャナ）を親側で開くためのフック
    var onOpenQR: (() -> Void)? = nil

    @State private var isCreatingRoom = false
    @State private var errorMessage: String? = nil
    @State private var shareURLString: String? = nil
    @State private var createdRoomID: String? = nil

    // このビュー自身ではQRを直接出さず、親に委譲して排他を担保する

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("招待/参加")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 20) {
            if let url = shareURLString {
                // 作成後：同モーダル内にQRコードを表示
                Text("このQRを相手に読み取ってもらって参加してもらいます")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                QRCodeView(content: url)

                VStack(spacing: 8) {
                    Text(url)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = url
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Label("リンクをコピー", systemImage: "doc.on.doc")
                        }

                        ShareLink(item: URL(string: url)!) {
                            Label("共有", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let roomID = createdRoomID {
                    Text("作成したチャットID: \(roomID)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)
            } else {
                // 初期：二択
                VStack(spacing: 16) {
                    Button {
                        Task { await createChat() }
                    } label: {
                        HStack(spacing: 12) {
                            if isCreatingRoom { ProgressView().tint(.white) } else { Image(systemName: "person.2.badge.plus") }
                            Text(isCreatingRoom ? "チャット作成中…" : "新しいチャットを作成する")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                    }
                    .disabled(isCreatingRoom)

                    Button {
                        // 親へ通知して親側でQRモーダルを開く（このビューは閉じる）
                        onOpenQR?()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                            Text("QRを読み込んで招待を受ける")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(
                            Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .padding(.top, 8)
                }

                Spacer(minLength: 8)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(.horizontal)
    }

    @MainActor
    private func createChat() async {
        isCreatingRoom = true
        errorMessage = nil
        defer { isCreatingRoom = false }

        do {
            let roomID = "chat-\(UUID().uuidString.prefix(8))"
            let cloudKitManager = CloudKitChatManager.shared
            let share = try await cloudKitManager.createSharedChatRoom(roomID: roomID, invitedUserID: "pending")

            // ローカルのChatRoomを作成（相手未確定でも一覧に出す）
            let newRoom = ChatRoom(roomID: roomID, remoteUserID: "", displayName: nil)
            modelContext.insert(newRoom)
            try? modelContext.save()
            onChatCreated(newRoom)

            createdRoomID = roomID
            shareURLString = share.url?.absoluteString
        } catch {
            errorMessage = "チャット作成に失敗しました: \(error.localizedDescription)"
        }
    }
}
