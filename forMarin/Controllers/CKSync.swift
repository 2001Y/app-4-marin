import Foundation
import CloudKit
import UIKit
#if canImport(WebRTC)
import WebRTC
#endif
import SwiftData
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Utility namespace that encapsulates all CloudKit interactions used by forMarin.
enum CKSync {
    private static let container = CKContainer(identifier: "iCloud.forMarin-test")
    private static var privateDB: CKDatabase {
        return container.privateCloudDatabase
    }

    // MARK: - Subscriptions
    // 注: プライベートDBの共有ゾーン使用のため、レガシーサブスクリプションは不要
    // CloudKitChatManagerでプライベートDB用サブスクリプションを管理

    // MARK: - Profile Management (プライベートDB マスター + 共有ゾーン同期)
    
    /// Saves master profile to private DB and syncs to all chats
    static func saveProfile(name: String, avatarData: Data) async {
        do {
            // Save master profile to private DB
            try await CloudKitChatManager.shared.saveMasterProfile(
                name: name,
                avatarData: avatarData
            )
            log("Master profile saved and synced to all chats", category: "CKSync")
        } catch {
            log("Failed to save master profile: \(error)", category: "CKSync")
        }
    }
    
    /// Fetches profile for a given user ID from private DB shared zone
    static func fetchProfile(for userID: String) async -> (name: String?, avatarData: Data?) {
        let result = await CloudKitChatManager.shared.fetchProfile(for: userID)
        log("Profile fetched from private DB shared zone for userID: \(userID)", category: "CKSync")
        return result
    }

    // MARK: - Message CRUD

    /// Uploads a `Message` to CloudKit using private DB shared zone and returns the CloudKit record name.
    /// This function requires a valid shared room - no fallback to legacy methods.
    static func saveMessage(_ message: Message) async throws -> String? {
        // CloudKitChatManagerを使用してプライベートDBの共有ゾーンに保存
        guard let roomRecord = await CloudKitChatManager.shared.getRoomRecord(for: message.roomID) else {
            log("No shared room found for roomID: \(message.roomID)", category: "CKSync")
            throw CloudKitChatError.roomNotFound
        }
        
        let recordName = try await CloudKitChatManager.shared.sendMessage(message, to: roomRecord)
        log("Message saved to private DB shared zone: \(recordName)", category: "CKSync")
        return recordName
    }

    /// Updates the body text of an existing CloudKit MessageCK record.
    static func updateMessageBody(recordName: String, newBody: String) async throws {
        try await CloudKitChatManager.shared.updateMessage(recordName: recordName, newBody: newBody)
        log("Message updated in private DB shared zone: \(recordName)", category: "CKSync")
    }

    /// Deletes a MessageCK record from CloudKit.
    static func deleteMessage(recordName: String) async throws {
        try await CloudKitChatManager.shared.deleteMessage(recordName: recordName)
        log("Message deleted from private DB shared zone: \(recordName)", category: "CKSync")
    }

    // MARK: - Anniversary CRUD (プライベートDB共有ゾーン使用)
    static func saveAnniversary(title: String, date: Date, roomID: String, repeatType: RepeatType = .none) async throws -> String? {
        let recordName = try await CloudKitChatManager.shared.saveAnniversary(
            title: title,
            date: date,
            roomID: roomID,
            repeatType: repeatType
        )
        return recordName
    }

    static func updateAnniversary(recordName: String, title: String, date: Date) async throws {
        try await CloudKitChatManager.shared.updateAnniversary(
            recordName: recordName,
            title: title,
            date: date
        )
    }

    static func deleteAnniversary(recordName: String) async {
        do {
            try await CloudKitChatManager.shared.deleteAnniversary(recordName: recordName)
        } catch {
            log("Failed to delete anniversary: \(error)", category: "CKSync")
        }
    }

    // MARK: - Media Messages
    
    /// Saves a single image as a message to private DB shared zone
    static func saveImageMessage(_ image: UIImage, roomID: String, senderID: String) async throws -> String? {
        // Create a Message object for the image
        guard let localURL = AttachmentManager.saveImageToCache(image) else { 
            log("Failed to save image to cache", category: "CKSync")
            return nil 
        }
        
        let message = Message(
            roomID: roomID,
            senderID: senderID,
            body: nil,
            assetPath: localURL.path,
            createdAt: Date(),
            isSent: false
        )
        
        // Save via CloudKitChatManager
        guard let roomRecord = await CloudKitChatManager.shared.getRoomRecord(for: roomID) else {
            log("No shared room found for roomID: \(roomID)", category: "CKSync")
            throw CloudKitChatError.roomNotFound
        }
        
        let recordName = try await CloudKitChatManager.shared.sendMessage(message, to: roomRecord)
        log("Image message saved to private DB shared zone: \(recordName)", category: "CKSync")
        return recordName
    }

    // MARK: - Deprecated Features (Stubs)
    // 注: WebRTC、Presence、Push Handlingはプライベート DB共有ゾーン移行により廃止
    // コンパイルエラー防止のためのスタブメソッド
    
    #if canImport(WebRTC)
    /// WebRTC ICE candidate saving (deprecated - stub only)
    static func saveCandidate(_ candidate: RTCIceCandidate, roomID: String) async throws {
        log("saveCandidate is deprecated in private DB shared zone architecture", category: "CKSync")
        // No-op: WebRTC functionality disabled in shared zone mode
    }
    #endif
    
    /// Presence refresh (deprecated - stub only)
    static func refreshPresence(_ roomID: String, _ userID: String) {
        log("refreshPresence is deprecated in private DB shared zone architecture", category: "CKSync")
        // No-op: Presence functionality disabled in shared zone mode
    }

    // MARK: - Reactions
    
    /// メッセージにリアクション絵文字を追加
    static func addReaction(recordName: String, emoji: String) async throws {
        try await CloudKitChatManager.shared.addReactionToMessage(recordName: recordName, emoji: emoji)
        log("Added reaction: \(emoji) to record: \(recordName)", category: "CKSync")
    }
}

// MARK: - Helpers

extension Data {
    /// Rough check for HEIC/HEIF based on 'ftypheic' brand fourCC at offset 8.
    var isHEIC: Bool {
        if count >= 12 {
            let slice = self[8..<12]
            // "heic" in ASCII
            return slice.elementsEqual([0x68, 0x65, 0x69, 0x63])
        }
        return false
    }
} 