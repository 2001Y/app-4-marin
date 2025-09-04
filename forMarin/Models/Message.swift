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

    // CloudKit record name for syncing append operations
    var ckRecordName: String?

    // Timestamp
    var createdAt: Date = Date()

    // Whether the message is already uploaded to CloudKit
    var isSent: Bool = false

    // Reaction emoji (e.g. "👍") – optional
    // Deprecated: reactionEmoji was removed (CloudKit normalized reactions)

    init(id: UUID = UUID(),
         roomID: String,
         senderID: String,
         body: String? = nil,
         assetPath: String? = nil,
         ckRecordName: String? = nil,
         createdAt: Date = Date(),
         isSent: Bool = false) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.isSent = isSent
        self.assetPath = assetPath
        self.ckRecordName = ckRecordName
    }
}

// MARK: - CloudKit Extensions
extension Message {
// MessageAttachment はCloudKit上の別レコード（ローカルのSwiftDataモデルは不要）
    static let recordType = "Message"
    
    /// Converts this Message to a CKRecord for CloudKit synchronization
    var cloudKitRecord: CKRecord {
        // 一貫したレコード名: UUID（id.uuidString）を採用
        let recordID = CKRecord.ID(recordName: ckRecordName ?? id.uuidString)
        let record = CKRecord(recordType: Message.recordType, recordID: recordID)
        
        record["roomID"] = roomID as CKRecordValue
        record["senderID"] = senderID as CKRecordValue
        record["text"] = (body ?? "") as CKRecordValue
        record["timestamp"] = createdAt as CKRecordValue
        
        // Handle asset attachment
        if let assetPath = assetPath, FileManager.default.fileExists(atPath: assetPath) {
            let assetURL = URL(fileURLWithPath: assetPath)
            record["attachment"] = CKAsset(fileURL: assetURL)
        }
        
        return record
    }
    
    
    /// Updates this Message with data from a CKRecord (for conflict resolution)
    func update(from record: CKRecord) {
        guard record.recordType == Message.recordType else { return }

        // Align with ideal schema keys: text / attachment / timestamp
        if let text = record["text"] as? String { self.body = text }
        if let ts = record["timestamp"] as? Date { self.createdAt = ts }
        // senderID は理想スキーマでは必須。欠如時のフォールバックは行わない
        if let sid = record["senderID"] as? String {
            self.senderID = sid
        }
        // Reactions/isSent はCloudKitへは保存しない（正規化レコード/ローカル管理）

        // Update record name if needed
        if ckRecordName != record.recordID.recordName {
            ckRecordName = record.recordID.recordName
        }
        
        // Handle asset updates
        if let asset = record["attachment"] as? CKAsset,
           let fileURL = asset.fileURL {
            let localURL = AttachmentManager.makeFileURL(ext: fileURL.pathExtension)
            do {
                if !FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.copyItem(at: fileURL, to: localURL)
                    assetPath = localURL.path
                }
            } catch {
                log("Failed to update asset: \(error)", category: "Message")
            }
        }
    }
    
    /// Validates if the message is ready for CloudKit sync
    var isValidForSync: Bool {
        return !roomID.isEmpty && !senderID.isEmpty && (body != nil || assetPath != nil)
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

    /// システム文（表示用）を返す。対象でない場合はnil
    static func systemDisplayText(for body: String?) -> String? {
        guard let body else { return nil }
        guard body.hasPrefix(sysFaceTimePrefix) else { return nil }
        // 形式: [SYS:FT_REG]|name=<name>|id=<faceTimeID>
        let parts = body.components(separatedBy: "|")
        var name: String? = nil
        for p in parts {
            if p.hasPrefix("name=") { name = String(p.dropFirst(5)) }
        }
        let dispName = (name?.isEmpty == false) ? name! : "相手"
        return "\(dispName)さんがFaceTimeを登録しました"
    }

    /// FaceTime登録システムメッセージ本文を作成
    static func makeFaceTimeRegisteredBody(name: String, faceTimeID: String) -> String {
        return "\(sysFaceTimePrefix)|name=\(name)|id=\(faceTimeID)"
    }

    /// FaceTime登録メッセージからFaceTimeIDを抽出
    static func extractFaceTimeID(from body: String?) -> String? {
        guard let body, body.hasPrefix(sysFaceTimePrefix) else { return nil }
        let parts = body.components(separatedBy: "|")
        for p in parts {
            if p.hasPrefix("id=") { return String(p.dropFirst(3)) }
        }
        return nil
    }
}
