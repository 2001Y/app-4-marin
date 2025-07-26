import Foundation
import SwiftData

@Model
final class Message {
    // プライマリキー相当
    // デフォルト値を持たせて CloudKit 制約（optional または default）を満たす
    var id: UUID = UUID()

    // Chat room this message belongs to
    var roomID: String = ""

    // Sender identifier (my ID or remote ID)
    var senderID: String = ""

    // Message body plain text (nil for image-only message)
    var body: String?

    // 単一画像メッセージの場合のローカルファイルパス
    var assetPath: String?

    // CloudKit record name for syncing append operations
    var ckRecordName: String?

    // Timestamp
    var createdAt: Date = Date()

    // Whether the message is already uploaded to CloudKit
    var isSent: Bool = false

    // Reaction emoji (e.g. "👍") – optional
    var reactionEmoji: String?

    init(id: UUID = UUID(),
         roomID: String,
         senderID: String,
         body: String? = nil,
         assetPath: String? = nil,
         ckRecordName: String? = nil,
         createdAt: Date = Date(),
         isSent: Bool = false,
         reactionEmoji: String? = nil) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.isSent = isSent
        self.reactionEmoji = reactionEmoji
        self.assetPath = assetPath
        self.ckRecordName = ckRecordName
    }
} 