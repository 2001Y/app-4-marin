import Foundation
import CloudKit
import SwiftData
import UIKit

/// Handles conflict resolution for Message records in CloudKit
@MainActor
class ConflictResolver: ObservableObject {
    
    enum ConflictResolutionStrategy {
        case lastWriterWins          // タイムスタンプベース（デフォルト）
        case contentPreservation    // 内容保持優先
    }
    
    static let shared = ConflictResolver()
    
    @Published var conflictedMessages: [ConflictedMessage] = []
    @Published var conflictResolutionStrategy: ConflictResolutionStrategy = .lastWriterWins
    
    private init() {}
    
    // MARK: - Conflict Detection & Resolution
    
    /// Resolves conflicts between local and server records
    func resolveConflict(localRecord: CKRecord, serverRecord: CKRecord) async -> CKRecord {
        log("Resolving conflict for record: \(localRecord.recordID.recordName)", category: "ConflictResolver")
        
        switch conflictResolutionStrategy {
        case .lastWriterWins:
            return resolveWithLastWriterWins(localRecord: localRecord, serverRecord: serverRecord)
            
        case .contentPreservation:
            return resolveWithContentPreservation(localRecord: localRecord, serverRecord: serverRecord)
            
        }
    }
    
    /// Resolves message conflicts in SwiftData
    func resolveMessageConflict(localMessage: Message, serverMessage: Message) -> Message {
        log("Resolving message conflict: \(localMessage.id) vs server version", category: "ConflictResolver")
        
        switch conflictResolutionStrategy {
        case .lastWriterWins:
            return localMessage.createdAt > serverMessage.createdAt ? localMessage : serverMessage
            
        case .contentPreservation:
            return resolveMessageWithContentPreservation(local: localMessage, server: serverMessage)
            
        }
    }
    
    // MARK: - Resolution Strategies
    
    private func resolveWithLastWriterWins(localRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        // 現行スキーマは Message.timestamp を使用（フォールバックなし）
        guard let localDate = localRecord["timestamp"] as? Date,
              let serverDate = serverRecord["timestamp"] as? Date else {
            log("Unable to compare timestamps, using server record", category: "ConflictResolver")
            return serverRecord
        }
        
        if localDate > serverDate {
            log("Local record is newer, keeping local changes", category: "ConflictResolver")
            return localRecord
        } else {
            log("Server record is newer, accepting server changes", category: "ConflictResolver")
            return serverRecord
        }
    }
    
    private func resolveWithContentPreservation(localRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        // 反応は正規化レコード（Reaction）へ移行済みのため本文のみを比較
        let mergedRecord = serverRecord.copy() as! CKRecord
        if let localText = localRecord["text"] as? String,
           let serverText = serverRecord["text"] as? String,
           localText != serverText,
           !localText.isEmpty {
            mergedRecord["text"] = localText as CKRecordValue
            log("Preserved local text changes", category: "ConflictResolver")
        }
        log("Content preservation merge completed (reactions normalized)", category: "ConflictResolver")
        return mergedRecord
    }
    
    private func resolveMessageWithContentPreservation(local: Message, server: Message) -> Message {
        // CloudKit正規化リアクションに統一するため、reactionEmojiは統合しない
        // Create a new message that combines the best of both
        let resolved = Message(
            roomID: local.roomID,
            senderID: local.senderID,
            body: local.body ?? server.body, // Prefer local body if it exists
            assetPath: local.assetPath ?? server.assetPath,
            ckRecordName: local.ckRecordName ?? server.ckRecordName,
            createdAt: min(local.createdAt, server.createdAt), // Use earlier timestamp
            isSent: server.isSent // Server version is authoritative for sent status
        )
        
        log("Message content preservation completed (reactions normalized via CloudKit)", category: "ConflictResolver")
        return resolved
    }
    
    private func mergeReactions(local: String, server: String) -> String {
        // Combine reactions from both sources, removing duplicates
        let localReactions = Set(local.map { String($0) })
        let serverReactions = Set(server.map { String($0) })
        let merged = localReactions.union(serverReactions)
        return merged.joined()
    }
    
    // MARK: - Manual Conflict Resolution
    
    // MARK: - Conflict Prevention
    
    /// Generates a deterministic record name to reduce conflicts
    func generateConflictFreeRecordName(for message: Message) -> String {
        let timestamp = Int(message.createdAt.timeIntervalSince1970 * 1000)
        let deviceID = UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown"
        return "\(message.roomID)_\(message.senderID)_\(timestamp)_\(deviceID)"
    }
    
    /// Validates record before attempting to save
    func validateRecordForSaving(_ record: CKRecord) -> Bool {
        // Check required fields
        guard record["roomID"] as? String != nil,
              record["senderID"] as? String != nil,
              ((record["timestamp"] as? Date) ?? record.creationDate) != nil else {
            log("Record validation failed: missing required fields", category: "ConflictResolver")
            return false
        }
        
        // Check that either body or asset exists
        let hasBody = (record["text"] as? String)?.isEmpty == false
        let hasAsset = record["attachment"] as? CKAsset != nil
        
        guard hasBody || hasAsset else {
            log("Record validation failed: no content", category: "ConflictResolver")
            return false
        }
        
        return true
    }
    
    // MARK: - Statistics
    
    func getConflictStatistics() -> ConflictStatistics {
        let totalConflicts = UserDefaults.standard.integer(forKey: "TotalConflictsResolved")
        let autoResolvedConflicts = UserDefaults.standard.integer(forKey: "AutoResolvedConflicts")
        let manuallyResolvedConflicts = UserDefaults.standard.integer(forKey: "ManuallyResolvedConflicts")
        
        return ConflictStatistics(
            totalConflicts: totalConflicts,
            autoResolvedConflicts: autoResolvedConflicts,
            manuallyResolvedConflicts: manuallyResolvedConflicts,
            pendingConflicts: conflictedMessages.count
        )
    }
    
    private func incrementConflictStatistics(auto: Bool) {
        let totalKey = "TotalConflictsResolved"
        let specificKey = auto ? "AutoResolvedConflicts" : "ManuallyResolvedConflicts"
        
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: totalKey) + 1, forKey: totalKey)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: specificKey) + 1, forKey: specificKey)
    }
}

// MARK: - Supporting Types

struct ConflictedMessage: Identifiable {
    let id = UUID()
    let recordID: String
    let localRecord: CKRecord
    let serverRecord: CKRecord
    let conflictDetectedAt: Date
    
    var localBody: String? {
        localRecord["body"] as? String
    }
    
    var serverBody: String? {
        serverRecord["body"] as? String
    }
    
    var localTimestamp: Date? {
        localRecord["createdAt"] as? Date
    }
    
    var serverTimestamp: Date? {
        serverRecord["createdAt"] as? Date
    }
}

struct ConflictStatistics {
    let totalConflicts: Int
    let autoResolvedConflicts: Int
    let manuallyResolvedConflicts: Int
    let pendingConflicts: Int
    
    var autoResolutionRate: Double {
        guard totalConflicts > 0 else { return 0.0 }
        return Double(autoResolvedConflicts) / Double(totalConflicts)
    }
}

// MARK: - Notifications（既存の Notification+Extras に寄せる方針のためローカル定義は削除）
