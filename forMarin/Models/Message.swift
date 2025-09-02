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

// MARK: - CloudKit Extensions
extension Message {
    static let recordType = "Message"
    
    /// Converts this Message to a CKRecord for CloudKit synchronization
    var cloudKitRecord: CKRecord {
        let recordID = CKRecord.ID(recordName: ckRecordName ?? UUID().uuidString)
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
        
        if let body = record["body"] as? String {
            self.body = body
        }
        // Reactions/isSent はCloudKitへは保存しない（正規化レコード/ローカル管理）
        
        // Update record name if needed
        if ckRecordName != record.recordID.recordName {
            ckRecordName = record.recordID.recordName
        }
        
        // Handle asset updates
        if let asset = record["asset"] as? CKAsset,
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
        if let existingName = ckRecordName {
            return existingName
        }
        
        // Generate deterministic record name from message properties
        let timestamp = Int(createdAt.timeIntervalSince1970 * 1000)
        let recordName = "\(roomID)_\(senderID)_\(timestamp)_\(id.uuidString.prefix(8))"
        
        self.ckRecordName = recordName
        return recordName
    }
} 
