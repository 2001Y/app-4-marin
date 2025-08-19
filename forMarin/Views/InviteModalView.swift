import SwiftUI
import SwiftData

struct InviteModalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showShareSheet = false
    @State private var showAirDropSheet = false
    @State private var myInviteURL = ""
    @State private var selectedTab = 0
    
    let onChatCreated: (ChatRoom) -> Void
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // カスタムヘッダー
                VStack(spacing: 12) {
                    Text("4-Marinをはじめよう")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("大切な人と2人だけの特別な空間")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                .padding(.horizontal)
                
                // タブ選択
                Picker("", selection: $selectedTab) {
                    Text("招待を受ける").tag(0)
                    Text("招待を送る").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.top, 24)
                
                // タブコンテンツ
                TabView(selection: $selectedTab) {
                    // 招待を受ける側
                    receiveInviteView
                        .tag(0)
                    
                    // 招待を送る側
                    sendInviteView
                        .tag(1)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: selectedTab)
            }
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
        .onAppear {
            generateMyInviteURL()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [myInviteURL])
        }
        .sheet(isPresented: $showAirDropSheet) {
            AirDropFocusedShareSheet(items: [myInviteURL]) { success in
                if success {
                    // AirDrop成功時の処理（現在の実装に合わせて）
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - 招待を受ける側のView
    
    private var receiveInviteView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 20) {
                // アイコン
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                VStack(spacing: 12) {
                    Text("招待リンクをお待ちください")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("大切な人から招待リンクが送られてきたら、\nそのリンクをタップしてください")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                }
            }
            
            // 招待リンクの例
            VStack(alignment: .leading, spacing: 12) {
                Text("📱 招待リンクの例：")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                
                HStack {
                    Text("fourmarin://invite?userID=_abc123...")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    Spacer()
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // 注意事項
            VStack(alignment: .leading, spacing: 8) {
                Text("💡 ヒント")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("• リンクをタップすると自動的にチャットが作成されます")
                    Text("• 相手が4-Marinアプリを使用している必要があります")
                    Text("• 一度作成されたチャットは永続化されます")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            
            Spacer()
        }
    }
    
    // MARK: - 招待を送る側のView
    
    private var sendInviteView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 20) {
                // アイコン
                Image(systemName: "person.badge.plus.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                
                VStack(spacing: 12) {
                    Text("大切な人を招待しよう")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("あなたの招待リンクを\n大切な人に送ってください")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                }
            }
            
            // 招待リンク表示
            VStack(spacing: 16) {
                Text("あなたの招待リンク")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                VStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(myInviteURL)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxHeight: 40)
                    
                    Button {
                        UIPasteboard.general.string = myInviteURL
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                            Text("コピー")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
            
            // 共有ボタン（2つに分割）
            VStack(spacing: 16) {
                // AirDrop専用ボタン
                Button {
                    showAirDropSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi")
                            .font(.system(size: 18, weight: .semibold))
                        Text("AirDropで送信")
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
                
                // その他の共有方法ボタン
                Button {
                    showShareSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                        Text("その他の方法で共有")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.green,
                                Color.green.opacity(0.8)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: Color.green.opacity(0.3), radius: 8, x: 0, y: 4)
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // 注意事項
            VStack(alignment: .leading, spacing: 8) {
                Text("💡 共有方法")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("• AirDropで送信（推奨）")
                    Text("• メッセージアプリで送信")
                    Text("• メールで送信")
                    Text("• その他お好みの方法で")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            
            Spacer()
        }
    }
    
    // MARK: - Helper Methods
    
    private func generateMyInviteURL() {
        Task {
            if let userID = await UserIDManager.shared.getCurrentUserIDAsync() {
                await MainActor.run {
                    myInviteURL = URLManager.shared.generateInviteURL(userID: userID)
                }
            }
        }
    }
}

#Preview {
    InviteModalView { _ in }
}