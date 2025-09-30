import SwiftUI

struct ReactionListSheet: View {
    let message: Message
    let roomID: String
    let currentUserID: String

    @State private var isLoading: Bool = true
    @State private var errorMessage: String? = nil
    @State private var rows: [(userID: String, displayName: String, emojis: [String])] = []

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("このメッセージにはリアクションがありません")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(rows, id: \.userID) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(row.displayName)
                                    .font(.body)
                                Spacer(minLength: 8)
                                // まとめて横並び
                                Text(row.emojis.joined())
                                    .font(.title3)
                            }
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("リアクション一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) { Image(systemName: "xmark") }
                }
            }
        }
        .onAppear(perform: load)
    }

    @Environment(\.dismiss) private var dismiss

    private func load() {
        let recordName = message.ckRecordName ?? message.id.uuidString
        log("ReactionList: fetching for messageRecord=\(recordName)", category: "ReactionList")

        Task {
            do {
                let reactions = try await CloudKitChatManager.shared.getReactionsForMessage(messageRecordName: recordName, roomID: roomID)

                // 集計
                let summary = MessageReactionSummary(messageID: recordName, reactions: reactions)

                // ユーザーIDごとに表示名を取得
                var result: [(userID: String, displayName: String, emojis: [String])] = []
                for (userID, emojis) in summary.userReactions {
                    // CloudKit上のプロフィール名を試行、失敗時はフォールバック
                    var displayName: String = userID
                    let prof = await CloudKitChatManager.shared.fetchProfile(userID: userID)
                    if let name = prof?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                        displayName = name
                    } else {
                        displayName = (userID == currentUserID) ? "あなた" : userID
                    }
                    result.append((userID: userID, displayName: displayName, emojis: emojis))
                }

                // ソート: 自分を先頭、その後は表示名で昇順
                result.sort { a, b in
                    if a.userID == currentUserID && b.userID != currentUserID { return true }
                    if b.userID == currentUserID && a.userID != currentUserID { return false }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }

                // ログ: 件数要約
                let userSummaries = result.map { "\($0.displayName):\($0.emojis.count)" }.joined(separator: ", ")
                log("ReactionList: loaded users=\(result.count) {\(userSummaries)}", category: "ReactionList")

                await MainActor.run {
                    self.rows = result
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "リアクションの取得に失敗しました: \(error.localizedDescription)"
                    self.isLoading = false
                }
                log("ReactionList: fetch failed error=\(error)", category: "ReactionList")
            }
        }
    }
}
