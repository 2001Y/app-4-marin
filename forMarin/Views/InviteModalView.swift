import SwiftUI
import SwiftData
import CloudKit

struct InviteModalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    // 🌟 [IDEAL SHARING UI] UICloudSharingController関連の状態
    @State private var showCloudSharingController = false
    @State private var shareToPresent: CKShare?
    @State private var isCreatingRoom = false
    @State private var errorMessage: String?
    
    let onChatCreated: (ChatRoom) -> Void
    
    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                // ヘッダー
                VStack(spacing: 12) {
                    Text("4-Marinをはじめよう")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("🌟 CloudKitによる安全な招待")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                .padding(.horizontal)
                
                Spacer()
                
                // 🌟 [IDEAL SHARING UI] CloudKit招待ボタン
                VStack(spacing: 16) {
                    Button {
                        createChatAndShare()
                    } label: {
                        HStack(spacing: 12) {
                            if isCreatingRoom {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "icloud.and.arrow.up")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            Text(isCreatingRoom ? "チャットルーム作成中..." : "🌟 CloudKit招待を送信")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.blue,
                                    Color.blue.opacity(0.8)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .disabled(isCreatingRoom)
                    
                    Text("理想実装: ゾーン共有によるネイティブ招待")
                        .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }
                .padding(.horizontal)
                
                Spacer()
                
                // エラー表示
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                }
                
                Spacer()
            }
            .navigationTitle("4-Marin招待")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .medium))
                }
            }
        }
        // 🌟 [IDEAL SHARING UI] 拡張版CloudKit共有コントローラー（URL共有ボタン付き）
        .sheet(isPresented: $showCloudSharingController) {
            if let shareToPresent = shareToPresent {
                EnhancedCloudSharingView(
                    share: shareToPresent,
                    container: CloudKitChatManager.shared.containerForSharing,
                    onDismiss: {
                        showCloudSharingController = false
                        dismiss() // 共有完了時にモーダルも閉じる
                    }
                )
            }
        }
    }
    
    /// 🌟 [IDEAL SHARING UI] チャットルーム作成とCloudKit招待
    private func createChatAndShare() {
        Task {
            await MainActor.run {
                isCreatingRoom = true
                errorMessage = nil
            }
            
            do {
                // 1. 一意なroomIDを生成
                let roomID = "chat-\(UUID().uuidString.prefix(8))"
                
                // 2. CloudKitChatManagerを通じてゾーン共有チャットを作成
                let cloudKitManager = CloudKitChatManager.shared
                let ckShare = try await cloudKitManager.createSharedChatRoom(
                    roomID: roomID,
                    invitedUserID: "pending" // 招待対象は後でCKShareで指定
                )
                
                // 3. ローカルのチャットルームを作成してリストに反映（参加者未承認でも残す）
                await MainActor.run {
                    let newRoom = ChatRoom(roomID: roomID, remoteUserID: "", displayName: nil)
                    modelContext.insert(newRoom)
                    try? modelContext.save()
                    onChatCreated(newRoom)
                }

                await MainActor.run {
                    // 4. UICloudSharingControllerに必要な情報を設定
                    self.shareToPresent = ckShare
                    self.isCreatingRoom = false
                    // 5. 共有モーダルを表示
                    self.showCloudSharingController = true
                }
                
                print("🌟 [IDEAL SHARING UI] ChatRoom created and ready for CloudKit sharing: \(roomID)")
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "チャットルーム作成に失敗しました: \(error.localizedDescription)"
                    self.isCreatingRoom = false
                }
                print("❌ [IDEAL SHARING UI] Failed to create chat room: \(error)")
            }
        }
    }
}

#Preview {
    InviteModalView { _ in }
}
