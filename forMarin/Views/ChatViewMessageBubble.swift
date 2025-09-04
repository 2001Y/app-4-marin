import SwiftUI
import Combine
import UIKit
import SwiftData
import PhotosUI
import CloudKit
import AVKit

enum AssetType {
    case image
    case video
}

extension ChatView {
    // CloudKitベースのリアクション表示（バブル右下/左下）。
    private struct ReactionOverlay: View {
        let message: Message
        let roomID: String
        let xOffset: CGFloat
        var onTap: () -> Void

        @State private var items: [(emoji: String, count: Int)] = []

        var body: some View {
            Group {
                if !items.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(items, id: \.emoji) { item in
                            HStack(spacing: 2) {
                                Text(item.emoji)
                                    .font(.system(size: 14))
                                if item.count > 1 {
                                    Text("\(item.count)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
                    .offset(x: xOffset, y: 12)
                }
            }
            .task {
                let recordName = message.ckRecordName ?? message.id.uuidString
                do {
                    let reactions = try await CloudKitChatManager.shared.getReactionsForMessage(messageRecordName: recordName, roomID: roomID)
                    let counts = reactions.reduce(into: [String: Int]()) { dict, r in
                        dict[r.emoji, default: 0] += 1
                    }
                    let sorted = counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
                    if sorted.count > 0 { log("ReactionOverlay: loaded count=\(sorted.count) for msg=\(recordName)", category: "ChatView") }
                    await MainActor.run { self.items = sorted }
                } catch {
                    // エラー時は表示しない（ログのみ）
                    log("ReactionOverlay: fetch failed error=\(error)", category: "ChatView")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reactionsUpdated)) { notif in
                let recName = message.ckRecordName ?? message.id.uuidString
                if let info = notif.userInfo as? [String: Any], let updated = info["recordName"] as? String, updated == recName {
                    Task { @MainActor in
                        do {
                            let reactions = try await CloudKitChatManager.shared.getReactionsForMessage(messageRecordName: recName, roomID: roomID)
                            let counts = reactions.reduce(into: [String: Int]()) { dict, r in
                                dict[r.emoji, default: 0] += 1
                            }
                            let sorted = counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
                            self.items = sorted
                        } catch {
                            log("ReactionOverlay: refresh fetch failed error=\(error)", category: "ChatView")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Message Bubble Views
    @ViewBuilder 
    func bubble(for message: Message) -> some View {
        // コンテンツ未確定（text空・asset未着）のメッセージは表示しない（iOS17+のモダン挙動）
        let hasBody = !(message.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasBody && message.assetPath == nil {
            EmptyView()
        } else if isMediaMessage(message) {
            mediaBubble(for: message)
        } else {
            textBubble(for: message)
        }
    }
    
    // メディアメッセージかどうかを判定
    private func isMediaMessage(_ message: Message) -> Bool {
        return message.assetPath != nil
    }
    
    // アセットの種別を判定
    private func getAssetType(_ assetPath: String) -> AssetType {
        let ext = URL(fileURLWithPath: assetPath).pathExtension.lowercased()
        switch ext {
        case "mov", "mp4", "m4v", "avi":
            return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif":
            return .image
        default:
            return .image // デフォルトは画像として扱う
        }
    }

    // 画像表示用ヘルパー関数
    @ViewBuilder
    private func imageContent(for assetPath: String) -> some View {
        let url = URL(fileURLWithPath: assetPath)
        let fileExtension = url.pathExtension.lowercased()
        
        // 動画ファイルが画像として処理されている場合の対応
        if ["mov", "mp4", "m4v", "avi"].contains(fileExtension) {
            missingMediaPlaceholder(type: .video, message: "動画ファイルが画像として処理されました")
        } else {
            let img = UIImage(contentsOfFile: assetPath)
            Button {
                if let validImg = img {
                    previewImages = [validImg]
                } else {
                    previewImages = []
                }
                previewStartIndex = 0
                isPreviewShown = true
            } label: {
                imageContentLabel(img: img, assetPath: assetPath)
            }
        }
    }
    
    // 画像コンテンツラベル用ヘルパー関数
    @ViewBuilder
    private func imageContentLabel(img: UIImage?, assetPath: String) -> some View {
        if let validImg = img {
            Image(uiImage: validImg)
                .resizable()
                .scaledToFit()
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .matchedGeometryEffect(id: "\(assetPath)_single", in: heroNS)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                
                Text("タップして詳細を確認")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 120, height: 120)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // 統一メディアバブル（画像・ビデオ対応）
    @ViewBuilder 
    func mediaBubble(for message: Message) -> some View {
        VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                if message.senderID != myID {
                    // 相手のメッセージ
                    ZStack(alignment: .bottomTrailing) {
                        // メディアコンテンツ表示
                        if let assetPath = message.assetPath {
                            let assetType = getAssetType(assetPath)
                            let url = URL(fileURLWithPath: assetPath)
                            let fileExists = FileManager.default.fileExists(atPath: assetPath)
                            
                            if fileExists {
                                switch assetType {
                                case .image:
                                    imageContent(for: assetPath)
                                case .video:
                                    VideoThumbnailView(videoURL: url)
                                        .frame(width: 160, height: 284)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .matchedGeometryEffect(id: "\(assetPath)_video", in: heroNS)
                                        .onTapGesture {
                                            videoPlayerURL = url
                                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                                                isVideoPlayerShown = true
                                            }
                                        }
                                }
                            } else {
                                // ファイルが存在しない場合でも画像スライダーを開く
                                if assetType == .image {
                                    Button {
                                        // 画像スライダーでエラー表示を制御
                                        previewImages = [] // ファイル不存在でもスライダーを開く
                                        previewStartIndex = 0
                                        isPreviewShown = true
                                    } label: {
                                        VStack(spacing: 8) {
                                            Image(systemName: "photo")
                                                .font(.system(size: 32))
                                                .foregroundColor(.secondary)
                                            
                                            Text("タップして詳細を確認")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 120, height: 120)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                    }
                                } else {
                                    // 動画ファイルが見つからない場合
                                    missingMediaPlaceholder(type: assetType, message: "動画ファイルが見つかりません")
                                }
                            }
                        } else {
                            // assetPathがnil
                            missingMediaPlaceholder(type: .image, message: "メディアパスが無効です")
                        }
                        
                        // リアクション表示（CloudKit集計に置換）
                        ReactionOverlay(
                            message: message,
                            roomID: roomID,
                            xOffset: 4,
                            onTap: {
                                if actionSheetMessage == nil && reactionPickerMessage == nil {
                                    isTextFieldFocused = false
                                    reactionPickerMessage = message
                                } else {
                                    log("Reaction: skip open (another sheet active)", category: "ChatView")
                                }
                            }
                        )
                    }
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    // 自分のメッセージ
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ZStack(alignment: .bottomLeading) {
                        // メディアコンテンツ表示
                        if let assetPath = message.assetPath {
                            let assetType = getAssetType(assetPath)
                            let url = URL(fileURLWithPath: assetPath)
                            let fileExists = FileManager.default.fileExists(atPath: assetPath)
                            
                            if fileExists {
                                switch assetType {
                                case .image:
                                    imageContent(for: assetPath)
                                case .video:
                                    VideoThumbnailView(videoURL: url)
                                        .frame(width: 160, height: 284)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .matchedGeometryEffect(id: "\(assetPath)_video", in: heroNS)
                                        .onTapGesture {
                                            videoPlayerURL = url
                                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                                                isVideoPlayerShown = true
                                            }
                                        }
                                }
                            } else {
                                // ファイルが存在しない場合でも画像スライダーを開く
                                if assetType == .image {
                                    Button {
                                        // 画像スライダーでエラー表示を制御
                                        previewImages = [] // ファイル不存在でもスライダーを開く
                                        previewStartIndex = 0
                                        isPreviewShown = true
                                    } label: {
                                        VStack(spacing: 8) {
                                            Image(systemName: "photo")
                                                .font(.system(size: 32))
                                                .foregroundColor(.secondary)
                                            
                                            Text("タップして詳細を確認")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 120, height: 120)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                    }
                                } else {
                                    // 動画ファイルが見つからない場合
                                    missingMediaPlaceholder(type: assetType, message: "動画ファイルが見つかりません")
                                }
                            }
                        } else {
                            // assetPathがnil
                            missingMediaPlaceholder(type: .image, message: "メディアパスが無効です")
                        }
                        
                        // リアクション表示（CloudKit集計に置換）
                        ReactionOverlay(
                            message: message,
                            roomID: roomID,
                            xOffset: -4,
                            onTap: {
                                if actionSheetMessage == nil && reactionPickerMessage == nil {
                                    isTextFieldFocused = false
                                    reactionPickerMessage = message
                                } else {
                                    log("Reaction: skip open (another sheet active)", category: "ChatView")
                                }
                            }
                        )
                    }
                }
            }
            .onAppear { /* no-op: 過剰なログを抑制 */ }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
        .scaleEffect(pressingMessageID == message.id ? 1.03 : 1.0)
        .shadow(color: Color.primary.opacity(pressingMessageID == message.id ? 0.15 : 0.0), radius: pressingMessageID == message.id ? 8 : 0, y: pressingMessageID == message.id ? 4 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: pressingMessageID == message.id)
        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 20, pressing: { pressing in
            if pressing {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { pressingMessageID = message.id }
            } else {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { if pressingMessageID == message.id { pressingMessageID = nil } }
            }
        }, perform: {
            log("LongPress: message bubble id=\(message.id)", category: "ChatView")
            isTextFieldFocused = false
            actionSheetMessage = message
            actionSheetTargetGroup = nil
        })
        .sensoryFeedback(.impact, trigger: pressingMessageID == message.id)
        .sensoryFeedback(.selection, trigger: actionSheetMessage?.id == message.id)
        .id(message.id)
    }

    // Text / reaction bubble
    @ViewBuilder 
    func textBubble(for message: Message) -> some View {
        if let sysText = Message.systemDisplayText(for: message.body) {
            // システムメッセージは中央・小さく・シンプルに表示
            Text(sysText)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)
                .id(message.id)
        } else {
            let trimmedBody = message.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isEmojiOnly = !trimmedBody.isEmpty && trimmedBody.allSatisfy { char in
                char.unicodeScalars.allSatisfy { $0.properties.isEmoji }
            }
            let emojiCount = message.body?.count ?? 0
            
            Group {
                VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 2) {
                    HStack(alignment: .bottom, spacing: 6) {
                        if message.senderID != myID {
                            // Left side message
                            ZStack(alignment: .bottomTrailing) {
                                if isEmojiOnly && emojiCount <= 3 {
                                    Text(message.body ?? "")
                                        .font(.system(size: 60))
                                } else {
                                    Text(message.body ?? "")
                                        .padding(10)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 20))
                                        .font(.system(size: 15))
                                }
                                // リアクションをCloudKit集計で表示
                                ReactionOverlay(
                                    message: message,
                                    roomID: roomID,
                                    xOffset: 4,
                                    onTap: {
                                        if actionSheetMessage == nil && reactionPickerMessage == nil {
                                            isTextFieldFocused = false
                                            reactionPickerMessage = message
                                        } else {
                                            log("Reaction: skip open (another sheet active)", category: "ChatView")
                                        }
                                    }
                                )
                            }
                            Text(message.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            // Right side (my) message
                            Text(message.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            ZStack(alignment: .bottomLeading) {
                                // 編集は入力欄で行うため、バブル内のインライン編集UIは使用しない
                                if isEmojiOnly && emojiCount <= 3 {
                                    Text(message.body ?? "")
                                        .font(.system(size: 60))
                                } else {
                                    Text(message.body ?? "")
                                        .padding(10)
                                        .background(Color.accentColor.opacity(0.8))
                                        .foregroundColor(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 20))
                                        .font(.system(size: 15))
                                }
                                // リアクションをCloudKit集計で表示
                                ReactionOverlay(
                                    message: message,
                                    roomID: roomID,
                                    xOffset: -4,
                                    onTap: {
                                        if actionSheetMessage == nil && reactionPickerMessage == nil {
                                            isTextFieldFocused = false
                                            reactionPickerMessage = message
                                        } else {
                                            log("Reaction: skip open (another sheet active)", category: "ChatView")
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
            .scaleEffect(pressingMessageID == message.id ? 1.03 : 1.0)
            .shadow(color: Color.primary.opacity(pressingMessageID == message.id ? 0.12 : 0.0), radius: pressingMessageID == message.id ? 6 : 0, y: pressingMessageID == message.id ? 3 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: pressingMessageID == message.id)
            // テキストメッセージのワンタップでリアクション一覧を表示（他のシート表示中は抑止）
            // メッセージ全体はタップ対象にしない（リアクションエリアのみ）
            .id(message.id)
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 20, pressing: { pressing in
                if pressing {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { pressingMessageID = message.id }
                } else {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { if pressingMessageID == message.id { pressingMessageID = nil } }
                }
            }, perform: {
                log("LongPress: text bubble id=\(message.id)", category: "ChatView")
                // シート提示前にキーボードを閉じて制約衝突を避ける
                isTextFieldFocused = false
                actionSheetMessage = message
                actionSheetTargetGroup = nil
            })
            .sensoryFeedback(.impact, trigger: pressingMessageID == message.id)
            .sensoryFeedback(.selection, trigger: actionSheetMessage?.id == message.id)
            // 右クリック/長押しのデフォルトメニューは使用しない（ハーフモーダルへ集約）
        }
    }

    // imageBubble は mediaBubble に統合済み（削除）
    
    // メディアファイル不存在時のプレースホルダー
    @ViewBuilder
    func missingMediaPlaceholder(type: AssetType, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: type == .image ? "photo" : "video")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            
            VStack(spacing: 4) {
                Text(type == .image ? "画像" : "動画")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: type == .image ? 120 : 160, height: type == .image ? 120 : 284)
        .background(
            RoundedRectangle(cornerRadius: type == .image ? 8 : 12)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: type == .image ? 8 : 12)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        )
    }
} 
