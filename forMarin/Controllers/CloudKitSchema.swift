import Foundation
import CloudKit

enum CKSchema {
    // Zone naming
    static let zonePrefix = "room_"

    // Record types (shared DB)
    enum SharedType {
        static let room = "Room"
        static let roomMember = "RoomMember"
        static let message = "Message"
        static let messageAttachment = "MessageAttachment"
        static let reaction = "Reaction"
        static let signalMailbox = "SignalMailbox"
    }

    // Record types (private DB)
    enum PrivateType {
        static let myProfile = "MyProfilePrivate"
        static let roomListEntry = "RoomListEntry"
    }

    // Field keys
    enum FieldKey {
        // Room
        static let roomID = "roomID"
        static let name = "name"
        static let shareURL = "shareURL"
        static let roomImageAsset = "roomImageAsset"
        static let roomImageShape = "roomImageShape"

        // RoomMember
        static let userId = "userId" // CKUserRecordID.recordName
        static let displayName = "displayName"
        static let avatarAsset = "avatarAsset"

        // Message
        static let type = "type"      // e.g., "txt"
        static let text = "text"
        static let senderMemberRef = "senderMemberRef"

        // MessageAttachment
        static let asset = "asset"
        static let attachmentType = "type" // "image" | "video"

        // Reaction
        static let memberRef = "memberRef"
        static let emoji = "emoji"

        // SignalMailbox（メンバー単位シグナル）
        static let updatedAt = "updatedAt"
        static let mailboxPayload = "mailboxPayload"
        static let intentEpoch = "intentEpoch"
        static let callEpoch = "callEpoch"
        static let consumedEpoch = "consumedEpoch"
        static let targetUserId = "targetUserId"
        static let lastSeenAt = "lastSeenAt"

        // Private profile
        static let faceTimeID = "faceTimeID"
        
        // System fields reference names
        // Message relations (zone-sharing friendly)
        static let messageRef = "messageRef"
        static let creationDate = "creationDate"
        static let modificationDate = "modificationDate"
    }

    static func makeZoneName() -> String {
        return zonePrefix + UUID().uuidString.prefix(8)
    }

    static func roomRecordID(for roomID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        // Room の recordName はゾーン名と同一にして単純化
        return CKRecord.ID(recordName: roomID, zoneID: zoneID)
    }

    static func roomMemberRecordID(userId: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        return CKRecord.ID(recordName: "RM_\(userId)", zoneID: zoneID)
    }

    static func signalMailboxRecordID(userId: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        return CKRecord.ID(recordName: "MB_\(userId)", zoneID: zoneID)
    }
}
