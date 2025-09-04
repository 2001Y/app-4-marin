import SwiftUI
import CloudKit

/// 🌟 [IDEAL SHARING UI] UICloudSharingControllerの拡張版（URL共有ボタン付き）
struct EnhancedCloudSharingView: View {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void
    
    @State private var showShareSheet = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // UICloudSharingControllerの埋め込み
                CloudSharingControllerView(
                    share: share,
                    container: container,
                    onDismiss: onDismiss
                )
                .frame(maxHeight: .infinity)
                
                // 追加の共有オプション
                VStack(spacing: 12) {
                    Text("さらに他の人と共有")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // URL直接共有ボタン
                    Button {
                        showShareSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.accentColor)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("リンクをコピー／共有")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                
                                Text("チャット招待URLを直接共有")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("4-Marinチャット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        onDismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL = share.url {
                CloudKitShareSheet(items: [shareURL, "4-Marinチャットに招待されました！"]) {
                    showShareSheet = false
                }
            }
        }
    }
}

/// 🌟 [IDEAL SHARING UI] システム標準の共有シート
struct CloudKitShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDismiss: () -> Void
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss()
        }
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // アップデート処理なし
    }
}

#Preview {
    // プレビューでは実際のCKShareは使用できないため、スタブとして空のViewを返す
    Text("EnhancedCloudSharingView Preview")
        .foregroundColor(.gray)
}
