import Foundation
import CloudKit

/// MessageReaction: リアクションの正規化レコード
/// 🌟 [IDEAL SCHEMA] 1ユーザ×1メッセージ×1絵文字 = 1レコード
struct MessageReaction: Identifiable {
    let id: String
    let messageRef: CKRecord.Reference
    let userID: String
    let emoji: String
    let createdAt: Date
    
    init(id: String, messageRef: CKRecord.Reference, userID: String, emoji: String, createdAt: Date = Date()) {
        self.id = id
        self.messageRef = messageRef
        self.userID = userID
        self.emoji = emoji
        self.createdAt = createdAt
    }
    
    /// 🌟 [IDEAL] ID規約: reaction_<messageRecordName>_<userID>_<emoji> (冪等・重複防止)
    static func createID(messageRecordName: String, userID: String, emoji: String) -> String {
        let safeEmoji = emoji.replacingOccurrences(of: "_", with: "-")
        return "reaction_\(messageRecordName)_\(userID)_\(safeEmoji)"
    }
    
    /// CloudKitレコードに変換（ゾーン指定版）
    func toCloudKitRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "MessageReaction", recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
        
        record["messageRef"] = messageRef
        record["userID"] = userID as CKRecordValue
        record["emoji"] = emoji as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        
        return record
    }
    
    /// CloudKitレコードから生成
    static func fromCloudKitRecord(_ record: CKRecord) -> MessageReaction? {
        guard
            let messageRef = record["messageRef"] as? CKRecord.Reference,
            let userID = record["userID"] as? String,
            let emoji = record["emoji"] as? String,
            let createdAt = record["createdAt"] as? Date
        else {
            return nil
        }
        
        return MessageReaction(
            id: record.recordID.recordName,
            messageRef: messageRef,
            userID: userID,
            emoji: emoji,
            createdAt: createdAt
        )
    }
    
    /// 便利メソッド: Message ID から Reference を作成
    static func createMessageReference(messageID: String, zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        let recordID = CKRecord.ID(recordName: messageID, zoneID: zoneID)
        return CKRecord.Reference(recordID: recordID, action: .none)
    }
}

/// MessageReaction の集計結果
struct MessageReactionSummary {
    let messageID: String
    let emojiCounts: [String: Int]
    let userReactions: [String: [String]] // userID -> [emojis]
    
    init(messageID: String, reactions: [MessageReaction]) {
        self.messageID = messageID
        
        var emojiCounts: [String: Int] = [:]
        var userReactions: [String: [String]] = [:]
        
        for reaction in reactions {
            // Emoji counts
            emojiCounts[reaction.emoji, default: 0] += 1
            
            // User reactions
            if userReactions[reaction.userID] == nil {
                userReactions[reaction.userID] = []
            }
            userReactions[reaction.userID]?.append(reaction.emoji)
        }
        
        self.emojiCounts = emojiCounts
        self.userReactions = userReactions
    }
}
