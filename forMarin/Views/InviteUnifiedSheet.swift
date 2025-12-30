import SwiftUI
import CloudKit
import UIKit

struct InviteUnifiedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // 呼び出し元へ部屋作成通知（一覧側を即時更新したいケース用）
    let onChatCreated: (ChatRoom) -> Void
    // 参加完了時のコールバック（必要なら一覧をリフレッシュ）
    var onJoined: (() -> Void)?
    var existingRoomID: String? = nil
    var allowCreatingNewChat: Bool = true

    @State private var isCreatingRoom = false
    @State private var errorMessage: String? = nil
    @State private var shareURLString: String? = nil
    @State private var createdRoomID: String? = nil
    @State private var detentSelection: PresentationDetent = .fraction(0.55)
    @State private var isLoadingShare = false
    @State private var didLoadExistingShare = false
    @State private var showQRScanner = false

    private let compactDetent: PresentationDetent = .fraction(0.55)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let url = shareURLString {
                        shareDetailView(link: url)
                    } else if existingRoomID != nil {
                        shareLoadingPlaceholder
                    } else {
                        inviteOptionsIntro
                    }

                    if let roomID = createdRoomID {
                        Text("作成したチャットID: \(roomID)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let message = errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("招待/参加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .presentationDetents([compactDetent, .large], selection: $detentSelection)
        .presentationDragIndicator(.visible)
        .safeAreaInset(edge: .bottom) {
            bottomActionArea
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet(isPresented: $showQRScanner) {
                // 受諾後の最新状態を反映
                MessageSyncPipeline.shared.checkForUpdates()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
            }
        }
        .task {
            await loadExistingShareIfNeeded()
        }
    }

    private func createChat() async {
        guard allowCreatingNewChat else { return }

        await MainActor.run {
            isCreatingRoom = true
            errorMessage = nil
            shareURLString = nil
            createdRoomID = nil
        }

        do {
            let roomID = CKSchema.makeZoneName()
            let descriptor = try await CloudKitChatManager.shared.createSharedChatRoom(roomID: roomID, invitedUserID: nil)
            let ownerID = try? await CloudKitChatManager.shared.ensureCurrentUserID()

            await MainActor.run {
                let newRoom = ChatRoom(roomID: roomID)
                modelContext.insert(newRoom)
                let participant = ChatRoom.Participant(userID: (ownerID ?? ""),
                                                        isLocal: true,
                                                        role: .owner,
                                                        displayName: nil,
                                                        avatarData: nil,
                                                        lastUpdatedAt: Date())
                newRoom.participants.append(participant)
                try? modelContext.save()
                onChatCreated(newRoom)
                createdRoomID = roomID
                shareURLString = descriptor.shareURL.absoluteString
                detentSelection = .large
                isCreatingRoom = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "チャット作成に失敗しました: \(error.localizedDescription)"
                isCreatingRoom = false
            }
        }
    }

    private var inviteOptionsIntro: some View {
        VStack(alignment: .leading, spacing: 16) {
            if allowCreatingNewChat {
                Text("相手と共有する準備をしましょう")
                    .font(.headline)

                Text("チャットを作成すると共有URLが発行されます。QRコードを相手に見せるか、リンクを共有してください（メールアドレスの入力は不要です）。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("招待リンクを共有しましょう")
                    .font(.headline)

                Text("このチャットにはまだ相手が参加していません。下の共有オプションから、リンクやQRコードを送って招待してください。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func shareDetailView(link: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("このQRを相手に読み取ってもらって参加してもらいます")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                QRCodeView(content: link)
                    .frame(width: 200, height: 200)
                Spacer()
            }

            if let url = URL(string: link) {
                HStack {
                    Spacer()
                    ShareLink(item: url) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }

            Text(link)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }

    private var shareLoadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("共有リンクを取得しています…")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                Spacer()
            }
        }
    }

    private var bottomActionArea: some View {
        VStack(spacing: 12) {
            if isLoadingShare {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if shareURLString == nil, allowCreatingNewChat {
                Button {
                    Task { await createChat() }
                } label: {
                    HStack(spacing: 8) {
                        if isCreatingRoom {
                            // 小さめのローディングで高さを固定
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "person.2.badge.plus")
                                .font(.system(size: 20))
                        }
                        Text(isCreatingRoom ? "チャット作成中…" : "新しいチャットを作成する")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isCreatingRoom)

                Button {
                    showQRScanner = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("QRを読み込んで招待を受ける")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else if !allowCreatingNewChat {
                // 既存チャットの共有URLがまだ取得できていない場合のみ「再取得」を出す（取得済みなら上部の共有UIで十分）
                if shareURLString == nil {
                    Button {
                        didLoadExistingShare = false
                        Task { await loadExistingShareIfNeeded() }
                    } label: {
                        Label("リンクを再取得", systemImage: "arrow.clockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .shadow(color: Color.black.opacity(0.08), radius: 16, y: -2)
    }

    private func copyLink(_ link: String) {
        UIPasteboard.general.string = link
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func loadExistingShareIfNeeded() async {
        guard let roomID = existingRoomID, !didLoadExistingShare else { return }
        didLoadExistingShare = true
        await MainActor.run {
            isLoadingShare = true
            errorMessage = nil
            detentSelection = compactDetent
            createdRoomID = roomID
        }
        do {
            let descriptor = try await CloudKitChatManager.shared.fetchShare(for: roomID)
            await MainActor.run {
                shareURLString = descriptor.shareURL.absoluteString
                createdRoomID = roomID
                isLoadingShare = false
            }
        } catch {
            await MainActor.run {
                isLoadingShare = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
