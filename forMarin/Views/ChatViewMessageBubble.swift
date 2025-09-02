#if canImport(EmojisReactionKit)
import EmojisReactionKit
#endif
import SwiftUI
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
    
    // MARK: - Message Bubble Views
    @ViewBuilder 
    func bubble(for message: Message) -> some View {
        if isMediaMessage(message) {
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
        log("getAssetType: File extension: '\(ext)' for path: \(assetPath)", category: "DEBUG")
        
        switch ext {
        case "mov", "mp4", "m4v", "avi":
            log("getAssetType: Detected as video", category: "DEBUG")
            return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif":
            log("getAssetType: Detected as image", category: "DEBUG")
            return .image
        default:
            log("getAssetType: Unknown extension, defaulting to image", category: "DEBUG")
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
                        
                        // リアクション表示（メディアバブルの右下に相対配置）
                        if let reactions = message.reactionEmoji, !reactions.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(reactions.map { String($0) }.reduce(into: [:]) { dict, emoji in
                                    dict[emoji, default: 0] += 1
                                }.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }, id: \.0) { item in
                                    HStack(spacing: 2) {
                                        Text(item.0)
                                            .font(.system(size: 14))
                                        if item.1 > 1 {
                                            Text("\(item.1)")
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
                            .offset(x: 4, y: 12) // 右下から少し内側、テキストに被らない位置
                        }
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
                        
                        // リアクション表示（メディアバブルの左下に相対配置）
                        if let reactions = message.reactionEmoji, !reactions.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(reactions.map { String($0) }.reduce(into: [:]) { dict, emoji in
                                    dict[emoji, default: 0] += 1
                                }.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }, id: \.0) { item in
                                    HStack(spacing: 2) {
                                        Text(item.0)
                                            .font(.system(size: 14))
                                        if item.1 > 1 {
                                            Text("\(item.1)")
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
                            .offset(x: -4, y: 12) // 左下から少し内側、テキストに被らない位置
                        }
                    }
                }
            }
            .onAppear {
                // デバッグログをonAppearで出力
                if let assetPath = message.assetPath {
                    let assetType = getAssetType(assetPath)
                    let url = URL(fileURLWithPath: assetPath)
                    let fileExists = FileManager.default.fileExists(atPath: assetPath)
                    
                    log("mediaBubble: Processing message ID: \(message.id)", category: "DEBUG")
                    log("mediaBubble: Asset path: \(assetPath)", category: "DEBUG")
                    log("mediaBubble: File extension: \(url.pathExtension)", category: "DEBUG")
                    log("mediaBubble: Asset type: \(assetType)", category: "DEBUG")
                    log("mediaBubble: File exists: \(fileExists)", category: "DEBUG")
                    
                    switch assetType {
                    case .image:
                        log("mediaBubble: Processing as image", category: "DEBUG")
                        // ファイル拡張子を再チェック
                        let fileExtension = url.pathExtension.lowercased()
                        if ["mov", "mp4", "m4v", "avi"].contains(fileExtension) {
                            log("mediaBubble: WARNING - Video file detected in image processing path!", category: "DEBUG")
                            log("mediaBubble: Skipping image processing for video file: \(fileExtension)", category: "DEBUG")
                            log("mediaBubble: Skipping UIImage(contentsOfFile:) for video file: \(fileExtension)", category: "DEBUG")
                        }
                    case .video:
                        log("mediaBubble: Processing as video", category: "DEBUG")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
        .background {
            // リアクション機能（相手のメッセージのみ）
            if message.senderID != myID {
                ReactionKitWrapperView(message: message) { emoji in
                    // 触覚フィードバック
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    
                    var reactions = message.reactionEmoji ?? ""
                    reactions.append(emoji)
                    message.reactionEmoji = reactions
                    updateRecentEmoji(emoji)
                    if let recName = message.ckRecordName {
                        Task {
                            if let userID = CloudKitChatManager.shared.currentUserID {
                                try? await CloudKitChatManager.shared.addReactionToMessage(
                                    messageRecordName: recName,
                                    roomID: message.roomID,
                                    emoji: emoji,
                                    userID: userID
                                )
                            }
                        }
                    }
                }
            }
        }
        .id(message.id)
    }

    // Text / reaction bubble
    @ViewBuilder 
    func textBubble(for message: Message) -> some View {
        let reactionStr = message.reactionEmoji
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
                            // リアクションをバブルの右下に相対配置
                            if let reactionStr {
                                Text(reactionStr)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: 12) // 右下から少し内側、テキストに被らない位置
                            }
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
                            if editingMessage?.id == message.id {
                                TextField("", text: $editingText, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .padding(10)
                                    .background(Color.accentColor.opacity(0.8))
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                    .font(.system(size: 15))
                                    .focused($editingFieldFocused)
                                    .onSubmit { commitInlineEdit() }
                                    .onAppear { editingFieldFocused = true }
                            } else if isEmojiOnly && emojiCount <= 3 {
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
                            // リアクションをバブルの左下に相対配置
                            if let reactionStr {
                                Text(reactionStr)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .offset(x: -4, y: 12) // 左下から少し内側、テキストに被らない位置
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
        .id(message.id)
        .background {
            // EmojisReactionKit for partner messages
            if message.senderID != myID {
                ReactionKitWrapperView(message: message) { emoji in
                    // 触覚フィードバック
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    
                    // Add reaction
                    var reactions = message.reactionEmoji ?? ""
                    reactions.append(emoji)
                    message.reactionEmoji = reactions
                    updateRecentEmoji(emoji)
                    // Sync to CloudKit
                    if let recName = message.ckRecordName {
                        Task {
                            if let userID = CloudKitChatManager.shared.currentUserID {
                                try? await CloudKitChatManager.shared.addReactionToMessage(
                                    messageRecordName: recName,
                                    roomID: message.roomID,
                                    emoji: emoji,
                                    userID: userID
                                )
                            }
                        }
                    }
                }
            }
        }
        .contextMenu(menuItems: {
            if message.senderID == myID {
                Button {
                    editingMessage = message
                    editingText = message.body ?? ""
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteMessage(message)
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        })
    }

    // imageBubble は mediaBubble に統合済み（削除）
    
    // メディアファイル不存在時のプレースホルダー
    @ViewBuilder
    private func missingMediaPlaceholder(type: AssetType, message: String) -> some View {
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
