import Foundation
import SwiftData
import CloudKit

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

    // 送信者 RoomMember レコード名（"RM_..."）
    var senderMemberRecordName: String?

    // CloudKit record name for syncing append operations
    var ckRecordName: String?

    // Timestamp
    var createdAt: Date = Date()

    // CloudKit メッセージタイプ ("txt" or "attachment")
    var messageType: String = "txt"

    // 添付タイプ ("image", "video" など)
    var attachmentType: String?

    // Whether the message is already uploaded to CloudKit
    var isSent: Bool = false

    // Reaction emoji (e.g. "👍") – optional
    // Deprecated: reactionEmoji was removed (CloudKit normalized reactions)

    init(id: UUID = UUID(),
         roomID: String,
         senderID: String,
         body: String? = nil,
         assetPath: String? = nil,
         senderMemberRecordName: String? = nil,
         ckRecordName: String? = nil,
         createdAt: Date = Date(),
         messageType: String = "txt",
         attachmentType: String? = nil,
         isSent: Bool = false) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.isSent = isSent
        self.assetPath = assetPath
        self.senderMemberRecordName = senderMemberRecordName
        self.ckRecordName = ckRecordName
        self.messageType = messageType
        self.attachmentType = attachmentType
    }
}

// MARK: - CloudKit Extensions
extension Message {
    /// Updates this Message with data from a CKRecord (for conflict resolution)
    func update(from record: CKRecord) {
        guard record.recordType == CKSchema.SharedType.message else { return }

        if let text = record[CKSchema.FieldKey.text] as? String {
            self.body = text
        }
        if let ts = record.creationDate {
            self.createdAt = ts
        }
        if let type = record[CKSchema.FieldKey.type] as? String {
            self.messageType = type
        }
        if let senderRef = record[CKSchema.FieldKey.senderMemberRef] as? CKRecord.Reference {
            senderMemberRecordName = senderRef.recordID.recordName
            if senderRef.recordID.recordName.hasPrefix("RM_") {
                let trimmed = String(senderRef.recordID.recordName.dropFirst(3))
                if !trimmed.isEmpty {
                    senderID = trimmed
                }
            }
        }

        if ckRecordName != record.recordID.recordName {
            ckRecordName = record.recordID.recordName
        }
    }

    /// Validates if the message is ready for CloudKit sync
    var isValidForSync: Bool {
        if messageType == "attachment" {
            return !roomID.isEmpty && !senderID.isEmpty && assetPath != nil
        }
        return !roomID.isEmpty && !senderID.isEmpty
    }

    /// Creates a conflict-free record name based on message properties
    func generateRecordName() -> String {
        if let existingName = ckRecordName { return existingName }
        // 送受信の重複排除のため、Engineが使用する id.uuidString と統一
        self.ckRecordName = id.uuidString
        return id.uuidString
    }
}

// MARK: - System Message Utilities
extension Message {
    // システムメッセージの種類：FaceTime登録
    static let sysFaceTimePrefix = "[SYS:FT_REG]"
    static let sysJoinPrefix = "[SYS:JOIN]"

    /// システム文（表示用）を返す。対象でない場合はnil
    static func systemDisplayText(for body: String?) -> String? {
        guard let body else { return nil }

        if body.hasPrefix(sysJoinPrefix) {
            let fields = parseSystemFields(from: body, prefix: sysJoinPrefix)
            let nameRaw = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let uidRaw = fields["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (nameRaw?.isEmpty == false) ? nameRaw! : (uidRaw?.isEmpty == false ? uidRaw! : "参加者")
            return "\(display) が参加しました"
        }

        if body.hasPrefix(sysFaceTimePrefix) {
            let fields = parseSystemFields(from: body, prefix: sysFaceTimePrefix)
            let rawName = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dispName = (rawName?.isEmpty == false) ? rawName! : "相手"
            return "\(dispName)さんがFaceTimeを登録しました"
        }

        return nil
    }

    /// FaceTime登録システムメッセージ本文を作成
    static func makeFaceTimeRegisteredBody(name: String, faceTimeID: String) -> String {
        let safeName = sanitizeSystemValue(name)
        let safeID = sanitizeSystemValue(faceTimeID)
        return "\(sysFaceTimePrefix)|name=\(safeName)|id=\(safeID)"
    }

    /// 共有チャットへの参加完了メッセージ本文を作成
    static func makeParticipantJoinedBody(name: String, userID: String) -> String {
        let safeName = sanitizeSystemValue(name)
        let safeID = sanitizeSystemValue(userID)
        return "\(sysJoinPrefix)|name=\(safeName)|uid=\(safeID)"
    }

    /// FaceTime登録メッセージからFaceTimeIDを抽出
    static func extractFaceTimeID(from body: String?) -> String? {
        guard let body, body.hasPrefix(sysFaceTimePrefix) else { return nil }
        let fields = parseSystemFields(from: body, prefix: sysFaceTimePrefix)
        return fields["id"]
    }

    /// 共有ルーム参加完了メッセージから名前とユーザIDを抽出
    static func extractParticipantJoinedInfo(from body: String?) -> (name: String?, userID: String?)? {
        guard let body, body.hasPrefix(sysJoinPrefix) else { return nil }
        let fields = parseSystemFields(from: body, prefix: sysJoinPrefix)
        let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = fields["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = (name?.isEmpty == true) ? nil : name
        let normalizedUID = (uid?.isEmpty == true) ? nil : uid
        return (name: normalizedName, userID: normalizedUID)
    }

    private static func parseSystemFields(from body: String, prefix: String) -> [String: String] {
        guard body.hasPrefix(prefix) else { return [:] }
        let segments = body.components(separatedBy: "|").dropFirst()
        var result: [String: String] = [:]
        for segment in segments {
            guard !segment.isEmpty else { continue }
            let pair = segment.split(separator: "=", maxSplits: 1)
            if pair.count == 2 {
                result[String(pair[0])] = String(pair[1])
            }
        }
        return result
    }

    private static func sanitizeSystemValue(_ value: String) -> String {
        var sanitized = value.replacingOccurrences(of: "|", with: "／")
        sanitized = sanitized.replacingOccurrences(of: "\n", with: " ")
        return sanitized
    }
}
