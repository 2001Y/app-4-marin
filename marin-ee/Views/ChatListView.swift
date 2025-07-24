import SwiftUI
import SwiftData

struct ChatListView: View {
    @Query(sort: \ChatRoom.lastMessageDate, order: .reverse) private var chatRooms: [ChatRoom]
    @Environment(\.modelContext) private var modelContext
    @State private var showingNewChatAlert = false
    @State private var newChatUserID = ""
    @State private var selectedChatRoom: ChatRoom?
    @State private var showingSettings = false
    
    var totalUnreadCount: Int {
        chatRooms.reduce(0) { $0 + $1.unreadCount }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // カスタムヘッダー
                HStack {
                    // 左側：アイコンとアプリ名
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        
                        Text("Marin-ee")
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
                
                // チャットリストまたは空の状態
                if chatRooms.isEmpty {
                    emptyStateView
                } else {
                    chatListContent
                }
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
            .navigationDestination(item: $selectedChatRoom) { chatRoom in
                ChatView(chatRoom: chatRoom)
            }
        }
    }
    
    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 72))
                    .foregroundColor(.accentColor)
                    .padding(.top, 40)

                Text("ようこそ！")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text("右上の＋ボタンから\n相手の連絡先を登録しよう。")
                    .font(.body)
                    .multilineTextAlignment(.center)

                Text("""
マリニーはAppleアカウント上(※)で動作するので、あなたはアカウントを作る必要はありません。

※Appleアカウントに紐付けられたメールアドレスまたは電話番号を連絡先として、画像を含むチャットのデータはあなたのiCloud上で管理されます。
""")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .padding()
        }
    }
    
    private var chatListContent: some View {
        List {
            ForEach(chatRooms) { chatRoom in
                Button {
                    selectedChatRoom = chatRoom
                    // 未読数をリセット
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
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if let date = chatRoom.lastMessageDate {
                                    Text(date, style: .time)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if let lastMessage = chatRoom.lastMessageText {
                                Text(lastMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        
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
                }
                .buttonStyle(PlainButtonStyle())
            }
            .onDelete(perform: deleteChatRooms)
        }
        .listStyle(PlainListStyle())
    }
    
    private func addNewChat() {
        let trimmedID = newChatUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 既存のチャットルームをチェック
        if !chatRooms.contains(where: { $0.remoteUserID == trimmedID }) {
            let newRoom = ChatRoom(remoteUserID: trimmedID)
            modelContext.insert(newRoom)
            selectedChatRoom = newRoom
        }
        
        newChatUserID = ""
    }
    
    private func deleteChatRooms(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(chatRooms[index])
        }
    }
} 