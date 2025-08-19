import SwiftUI

struct OfflineStatusView: View {
    @ObservedObject var connectivityManager: ConnectivityManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // アイコン
            Image(systemName: "wifi.slash")
                .font(.system(size: 60))
                .foregroundColor(.red)
                .padding(.top, 20)
            
            // タイトル
            Text("オフライン状態")
                .font(.title2)
                .fontWeight(.bold)
            
            // 説明
            VStack(spacing: 12) {
                Text("現在ネットワークに接続されていません")
                    .font(.body)
                    .multilineTextAlignment(.center)
                
                Text("以下の機能が一時的に利用できません：")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("メッセージの送受信", systemImage: "message.fill")
                    Label("メディアの同期", systemImage: "photo.fill")
                    Label("クラウド同期", systemImage: "icloud.fill")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            Spacer()
            
            // 接続状態
            HStack {
                Circle()
                    .fill(connectivityManager.isConnected ? .green : .red)
                    .frame(width: 10, height: 10)
                
                Text(connectivityManager.isConnected ? "オンライン" : "オフライン")
                    .font(.subheadline)
                    .foregroundColor(connectivityManager.isConnected ? .green : .red)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            // 閉じるボタン
            Button("閉じる") {
                connectivityManager.hideOfflineModal()
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onChange(of: connectivityManager.isConnected) { _, isConnected in
            if isConnected {
                // オンラインになったら自動的にモーダルを閉じる
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    connectivityManager.hideOfflineModal()
                }
            }
        }
    }
}

// MARK: - ハーフモーダル用の背景とジェスチャー
struct OfflineModalOverlay: View {
    @ObservedObject var connectivityManager: ConnectivityManager
    
    var body: some View {
        if connectivityManager.showOfflineModal {
            ZStack {
                // 背景
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        connectivityManager.hideOfflineModal()
                    }
                
                // モーダル内容
                VStack {
                    Spacer()
                    
                    OfflineStatusView(connectivityManager: connectivityManager)
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                        .background(Color(.systemBackground))
                        .cornerRadius(20, corners: [.topLeft, .topRight])
                        .shadow(radius: 10)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: connectivityManager.showOfflineModal)
        }
    }
}

#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()
        OfflineModalOverlay(connectivityManager: ConnectivityManager.shared)
    }
}