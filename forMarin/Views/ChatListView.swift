import SwiftUI
import SwiftData

struct ChatListView: View {
    @Query(sort: \ChatRoom.lastMessageDate, order: .reverse) private var chatRooms: [ChatRoom]
    @Environment(\.modelContext) private var modelContext
    @State private var showingNewChatAlert = false
    @State private var newChatUserID = ""
    var onChatSelected: (ChatRoom) -> Void
    @State private var showingSettings = false
    @State private var selectedChatRoom: ChatRoom?
    
    init(onChatSelected: @escaping (ChatRoom) -> Void) {
        self.onChatSelected = onChatSelected
    }
    var totalUnreadCount: Int {
        chatRooms.reduce(0) { $0 + $1.unreadCount }
    }
    
    var body: some View {
        VStack(spacing: 0) {
                
                // カスタムヘッダー
                HStack {
                    // 左側：アイコンとアプリ名
                    HStack(spacing: 8) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                        
                        Text("4-Marin")
                            .font(.title2.bold())
                        
                        if totalUnreadCount > 0 {
                            Text("<\(totalUnreadCount)")
                                .font(.footnote)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Spacer()
                    
                    // 右側：新規追加と設定ボタン
                    HStack(spacing: 16) {
                        Button {
                            showingNewChatAlert = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.title3)
                        }
                        
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
                        }
                    }
                }
                .padding()
                
                Divider()
                
                // チャットリストの表示
                chatListContent
            }
            .alert("新しいチャット", isPresented: $showingNewChatAlert) {
                TextField("メールアドレス または 電話番号", text: $newChatUserID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                
                Button("キャンセル", role: .cancel) {
                    newChatUserID = ""
                }
                
                Button("追加") {
                    addNewChat()
                }
                .disabled(newChatUserID.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("相手のAppleアカウントを入力してください")
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
    }
    
    private var chatListContent: some View {
        List {
            ForEach(chatRooms) { chatRoom in
                Button {
                    // セルタップ時にコールバック
                    onChatSelected(chatRoom)
                    // 未読数リセット
                    chatRoom.unreadCount = 0
                } label: {
                    HStack {
                        // アバター
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Text(chatRoom.displayName?.prefix(1) ?? chatRoom.remoteUserID.prefix(1))
                                    .font(.title3)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(chatRoom.displayName ?? chatRoom.remoteUserID)
                                    .font(.headline)
                                Spacer()
                                if let date = chatRoom.lastMessageDate {
                                    Text(date, style: .time)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            if let last = chatRoom.lastMessageText {
                                Text(last)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if chatRoom.unreadCount > 0 {
                            Text("\(chatRoom.unreadCount)")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.red)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading) // 全幅をタップ可能に
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteChatRooms)
        }
        .listStyle(.plain)
    }
    
    private func addNewChat() {
        let trimmedID = newChatUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 既存のチャットルームをチェック
        if !chatRooms.contains(where: { $0.remoteUserID == trimmedID }) {
            let newRoom = ChatRoom(remoteUserID: trimmedID)
            modelContext.insert(newRoom)
            try? modelContext.save()
            // NavigationLinkが自動的に処理するため、ここでは何もしない
        }
        
        newChatUserID = ""
    }
    
    private func deleteChatRooms(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(chatRooms[index])
        }
    }
} 