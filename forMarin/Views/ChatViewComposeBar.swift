import SwiftUI
import PhotosUI

extension ChatView {
    
    // MARK: - Compose Bar Views
    @ViewBuilder 
    func composeBarView() -> some View {
        HStack(spacing: 6) {
            composeLeadingTools()
            composeTextField()
            composeTrailingTools()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    // 以下 composeBarView のパーツをさらに分解
    @ViewBuilder 
    func composeLeadingTools() -> some View {
        let hasText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        HStack(spacing: 8) {
            if editingMessage == nil && !hasText {
                // 写真/動画ピッカー（テキスト未入力時のみ）
                PhotosPicker(selection: $photosPickerItems, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20))
                }
                // デュアルカメラ起動
                Button {
                    showDualCameraRecorder = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                }
            } else {
                // 折りたたみインジケータ（表示のみ）
                Image(systemName: "chevron.right")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder 
    func composeTextField() -> some View {
        TextField("Message", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(18)
            .lineLimit(1...5)
            .focused($isTextFieldFocused)
            .onChange(of: isTextFieldFocused) { _, focused in
                withAnimation { attachmentsExpanded = !focused }
                log("ComposeBar: focus=\(focused) (scroll stays enabled; keyboard dismiss by input drag)", category: "ChatView")
            }
            // 入力欄の下スワイプでのみキーボードを閉じる
            .dismissKeyboardOnDrag()
    }

    @ViewBuilder 
    func composeTrailingTools() -> some View {
        let hasText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        HStack(spacing: 8) {
            // 最近使った絵文字・ピッカーはテキスト未入力時のみ表示
            if editingMessage == nil && !hasText {
                HStack(spacing: 6) {
                    ForEach(Array(recentEmojis.prefix(3)), id: \.self) { emoji in
                        Button {
                            // 1タップで絵文字メッセージ送信 + 最近の絵文字更新
                            commitSend(with: emoji)
                            updateRecentEmoji(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 28, height: 28)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("絵文字送信: \(emoji)"))
                    }
                }
                // 絵文字ピッカー
                Button {
                    isEmojiPickerShown = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                }
            }
            // 送信/完了ボタン（テキストが空でない時）
            if hasText {
                if editingMessage != nil {
                    // 編集モード時は「完了」チェックアイコン
                    Button {
                        commitSend(with: text)
                        // commitSend 内で text はクリアされる
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                    }
                    .accessibilityLabel(Text("編集を完了"))
                    .buttonStyle(.plain)
                } else {
                    // 通常送信（紙飛行機）
                    Button {
                        commitSend(with: text)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .accessibilityLabel(Text("送信"))
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
