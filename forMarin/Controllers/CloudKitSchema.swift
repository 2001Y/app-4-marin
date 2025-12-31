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
        static let signalSession = "SignalSession"
        static let signalEnvelope = "SignalEnvelope"
        static let signalIceChunk = "SignalIceChunk"
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

        // Signal records (session / envelope / ice)
        static let updatedAt = "updatedAt"
        static let callEpoch = "callEpoch"
        static let otherUserId = "otherUserId"
        static let sessionKey = "sessionKey"
        static let payload = "payload"
        static let envelopeType = "envelopeType"
        static let ownerUserId = "ownerUserId"
        static let candidate = "candidate"
        static let candidateType = "candidateType"
        static let chunkCreatedAt = "chunkCreatedAt"

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

    static func signalSessionRecordID(sessionKey: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        return CKRecord.ID(recordName: "SS_\(sessionKey)", zoneID: zoneID)
    }

    /// SignalEnvelope RecordID - 上書き可能設計
    /// callEpochを除去することで、同じセッションのOffer/Answerは上書きされる
    static func signalEnvelopeRecordID(sessionKey: String, envelopeType: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        return CKRecord.ID(recordName: "SE_\(sessionKey)_\(envelopeType)", zoneID: zoneID)
    }

    /// SignalIceChunk RecordID - 上書き可能設計
    /// callEpochとUUIDを除去することで、送信者ごとに1レコード（配列で上書き）
    static func signalIceChunkRecordID(sessionKey: String, ownerUserID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        return CKRecord.ID(recordName: "IC_\(sessionKey)_\(ownerUserID)", zoneID: zoneID)
    }
}
