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
        print("[DEBUG] getAssetType: File extension: '\(ext)' for path: \(assetPath)")
        
        switch ext {
        case "mov", "mp4", "m4v", "avi":
            print("[DEBUG] getAssetType: Detected as video")
            return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif":
            print("[DEBUG] getAssetType: Detected as image")
            return .image
        default:
            print("[DEBUG] getAssetType: Unknown extension, defaulting to image")
            return .image // デフォルトは画像として扱う
        }
    }

    // 統一メディアバブル（画像・ビデオ対応）
    @ViewBuilder 
    func mediaBubble(for message: Message) -> some View {
        VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.senderID == myID {
                    Spacer(minLength: 0)
                }
                
                // メディアコンテンツ表示
                if let assetPath = message.assetPath {
                    let assetType = getAssetType(assetPath)
                    let url = URL(fileURLWithPath: assetPath)
                    let fileExists = FileManager.default.fileExists(atPath: assetPath)
                    
                    if fileExists {
                        switch assetType {
                        case .image:
                            // ファイル拡張子を再チェックして、動画ファイルを画像として処理しないようにする
                            let fileExtension = url.pathExtension.lowercased()
                            if ["mov", "mp4", "m4v", "avi"].contains(fileExtension) {
                                print("[DEBUG] mediaBubble: Skipping UIImage(contentsOfFile:) for video file: \(fileExtension)")
                                missingMediaPlaceholder(type: .video, message: "動画ファイルが画像として処理されました")
                            } else if let img = UIImage(contentsOfFile: assetPath) {
                                Button {
                                    // 単一画像でもFullScreenPreviewViewを使用
                                    previewImages = [img]
                                    previewStartIndex = 0
                                    isPreviewShown = true
                                } label: {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .matchedGeometryEffect(id: "\(assetPath)_single", in: heroNS)
                                }
                            } else {
                                // 画像読み込み失敗時
                                missingMediaPlaceholder(type: .image, message: "画像を読み込めませんでした")
                            }
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
                        // ファイルが存在しない場合
                        missingMediaPlaceholder(type: assetType, message: assetType == .image ? "画像ファイルが見つかりません" : "動画ファイルが見つかりません")
                    }
                } else {
                    // assetPathがnil
                    missingMediaPlaceholder(type: .image, message: "メディアパスが無効です")
                }
                
                if message.senderID != myID {
                    Spacer(minLength: 0)
                }
            }
            .onAppear {
                // デバッグログをonAppearで出力
                if let assetPath = message.assetPath {
                    let assetType = getAssetType(assetPath)
                    let url = URL(fileURLWithPath: assetPath)
                    let fileExists = FileManager.default.fileExists(atPath: assetPath)
                    
                    print("[DEBUG] mediaBubble: Processing message ID: \(message.id)")
                    print("[DEBUG] mediaBubble: Asset path: \(assetPath)")
                    print("[DEBUG] mediaBubble: File extension: \(url.pathExtension)")
                    print("[DEBUG] mediaBubble: Asset type: \(assetType)")
                    print("[DEBUG] mediaBubble: File exists: \(fileExists)")
                    
                    switch assetType {
                    case .image:
                        print("[DEBUG] mediaBubble: Processing as image")
                        // ファイル拡張子を再チェック
                        let fileExtension = url.pathExtension.lowercased()
                        if ["mov", "mp4", "m4v", "avi"].contains(fileExtension) {
                            print("[DEBUG] mediaBubble: WARNING - Video file detected in image processing path!")
                            print("[DEBUG] mediaBubble: Skipping image processing for video file: \(fileExtension)")
                        }
                    case .video:
                        print("[DEBUG] mediaBubble: Processing as video")
                    }
                }
            }
            
            // リアクション表示
            if let reactions = message.reactionEmoji, !reactions.isEmpty {
                ReactionBarView(emojis: reactions.map { String($0) }, isMine: message.senderID == myID)
            }
            
            // タイムスタンプ
            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: message.senderID == myID ? .trailing : .leading)
        .background {
            // リアクション機能（相手のメッセージのみ）
            if message.senderID != myID {
                ReactionKitWrapperView(message: message) { emoji in
                    var reactions = message.reactionEmoji ?? ""
                    reactions.append(emoji)
                    message.reactionEmoji = reactions
                    updateRecentEmoji(emoji)
                    if let recName = message.ckRecordName {
                        Task { try? await CKSync.updateReaction(recordName: recName, emoji: reactions) }
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
        let isEmojiOnly = message.body?.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy { $0.unicodeScalars.allSatisfy { $0.properties.isEmoji } } ?? false
        let emojiCount = message.body?.count ?? 0
        
        Group {
            VStack(alignment: message.senderID == myID ? .trailing : .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: 6) {
                    if message.senderID != myID {
                        // Left side message
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
                        Text(message.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        // Right side (my) message
                        Text(message.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
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
                    }
                }
                // Reaction below message (single emoji)
                if let reactionStr {
                    Text(reactionStr)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .offset(y: -6)
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
                    // Add reaction
                    var reactions = message.reactionEmoji ?? ""
                    reactions.append(emoji)
                    message.reactionEmoji = reactions
                    updateRecentEmoji(emoji)
                    // Sync to CloudKit
                    if let recName = message.ckRecordName {
                        Task { try? await CKSync.updateReaction(recordName: recName, emoji: reactions) }
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