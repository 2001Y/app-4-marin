import Foundation
import CloudKit

/// MessageReaction: Reaction レコードのUI用モデル
/// 🌟 [IDEAL SCHEMA] 1ユーザ×1メッセージ×1絵文字 = 1レコード（recordType: Reaction, parent: Message）
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
    
    /// Reaction レコードから生成（parent=Message, memberRef 参照）
    static func fromReactionRecord(_ record: CKRecord) -> MessageReaction? {
        let supportedTypes: Set<String> = [CKSchema.SharedType.reaction, "MessageReaction"]
        guard supportedTypes.contains(record.recordType) else { return nil }
        // messageRef 優先、fallback: parent
        let msgRef: CKRecord.Reference?
        if let mref = record[CKSchema.FieldKey.messageRef] as? CKRecord.Reference {
            msgRef = mref
        } else {
            msgRef = record.parent
        }
        guard let messageRef = msgRef else { return nil }
        guard let emoji = record[CKSchema.FieldKey.emoji] as? String else { return nil }
        // memberRef から userId を抽出
        var userID: String = ""
        if let mref = record[CKSchema.FieldKey.memberRef] as? CKRecord.Reference {
            let rn = mref.recordID.recordName
            if rn.hasPrefix("RM_") { userID = String(rn.dropFirst(3)) }
        }
        if userID.isEmpty, let legacyUserID = record["userID"] as? String {
            userID = legacyUserID
        }
        let createdAt = record.creationDate ?? (record["createdAt"] as? Date) ?? Date()
        return MessageReaction(
            id: record.recordID.recordName,
            messageRef: messageRef,
            userID: userID,
            emoji: emoji,
            createdAt: createdAt
        )
    }

    static func fromCloudKitRecord(_ record: CKRecord) -> MessageReaction? {
        fromReactionRecord(record)
    }
    
    /// 便利メソッド: Message ID から Reference を作成
    static func createMessageReference(messageID: String, zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        let recordID = CKRecord.ID(recordName: messageID, zoneID: zoneID)
        return CKRecord.Reference(recordID: recordID, action: .none)
    }

    func toCloudKitRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: CKSchema.SharedType.reaction, recordID: recordID)

        record[CKSchema.FieldKey.messageRef] = messageRef
        record.parent = messageRef

        if !userID.isEmpty {
            let memberID = CKSchema.roomMemberRecordID(userId: userID, zoneID: zoneID)
            let memberRef = CKRecord.Reference(recordID: memberID, action: .none)
            record[CKSchema.FieldKey.memberRef] = memberRef
            record["userID"] = userID as CKRecordValue
        }

        record[CKSchema.FieldKey.emoji] = emoji as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        return record
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
