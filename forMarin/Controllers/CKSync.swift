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
    private static let db = CKContainer(identifier: "iCloud.forMarin-test").privateCloudDatabase

    // MARK: - Subscriptions

    /// Creates silent push subscriptions for all record types used by the app.
    static func installSubscriptions() async throws {
        let types: [(String, String)] = [
            ("MessageCK", "msg-sub"),
            ("CallSessionCK", "sig-sub"),
            ("IceCandidateCK", "ice-sub"),
            ("PresenceCK", "pre-sub"),
            ("ProfileCK", "profile-sub")
            ,("AnniversaryCK","anniv-sub")
        ]

        for (type, id) in types {
            let sub = CKQuerySubscription(recordType: type,
                                           predicate: NSPredicate(value: true),
                                           subscriptionID: id,
                                           options: .firesOnRecordCreation)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            sub.notificationInfo = info
            _ = try? await db.save(sub)
        }
    }

    // MARK: - Profile Management
    
    /// Saves user profile to CloudKit
    static func saveProfile(name: String, avatarData: Data) async {
        let userID = (try? await CKContainer(identifier: "iCloud.forMarin-test").userRecordID())?.recordName ?? ""
        guard !userID.isEmpty else { return }
        
        let record = CKRecord(recordType: "ProfileCK", recordID: CKRecord.ID(recordName: "profile-\(userID)"))
        record["userID"] = userID as CKRecordValue
        record["displayName"] = name as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        
        // Save avatar as CKAsset if data exists
        if !avatarData.isEmpty {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try? avatarData.write(to: tempURL)
            record["avatar"] = CKAsset(fileURL: tempURL)
        }
        
        _ = try? await db.save(record)
    }
    
    /// Fetches profile for a given user ID
    static func fetchProfile(for userID: String) async -> (name: String?, avatarData: Data?) {
        let recordID = CKRecord.ID(recordName: "profile-\(userID)")
        
        do {
            let record = try await db.record(for: recordID)
            let name = record["displayName"] as? String
            var avatarData: Data? = nil
            
            if let asset = record["avatar"] as? CKAsset,
               let url = asset.fileURL,
               let data = try? Data(contentsOf: url) {
                avatarData = data
            }
            
            return (name, avatarData)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - Message CRUD

    /// Uploads a `Message` to CloudKit and returns the CloudKit record name.
    static func saveMessage(_ message: Message) async throws -> String? {
        let record = CKRecord(recordType: "MessageCK")
        record["roomID"] = message.roomID as CKRecordValue
        record["senderID"] = message.senderID as CKRecordValue
        record["body"] = (message.body ?? "") as CKRecordValue
        record["createdAt"] = message.createdAt as CKRecordValue
        let saved = try await db.save(record)
        return saved.recordID.recordName
    }

    /// Updates the body text of an existing CloudKit MessageCK record.
    static func updateMessageBody(recordName: String, newBody: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await db.record(for: recordID)
        record["body"] = newBody as CKRecordValue
        _ = try await db.save(record)
    }

    /// Deletes a MessageCK record from CloudKit.
    static func deleteMessage(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try await db.deleteRecord(withID: recordID)
    }

    // MARK: - Anniversary CRUD
    static func saveAnniversary(title: String, date: Date, roomID: String, repeatType: RepeatType = .none) async throws -> String? {
        let record = CKRecord(recordType: "AnniversaryCK")
        record["roomID"] = roomID as CKRecordValue
        record["title"] = title as CKRecordValue
        record["annivDate"] = date as CKRecordValue
        record["repeatType"] = repeatType.rawValue as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        let saved = try await db.save(record)
        return saved.recordID.recordName
    }

    static func updateAnniversary(recordName: String, title: String, date: Date) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await db.record(for: recordID)
        record["title"] = title as CKRecordValue
        record["annivDate"] = date as CKRecordValue
        _ = try await db.save(record)
    }

    static func deleteAnniversary(recordName: String) async {
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try? await db.deleteRecord(withID: recordID)
    }

    // MARK: - Image Message CRUD
    /// Upload a UIImage as a message (imageAsset) after size optimisation.
    static func saveMessage(image uiImage: UIImage,
                            roomID: String,
                            senderID: String) async throws {
        guard let data = uiImage.optimizedData() else { return }

        // Write to temp file so CKAsset can reference a file URL.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(data.isHEIC ? "heic" : "jpg")
        try data.write(to: tmpURL, options: .atomic)

        let record = CKRecord(recordType: "MessageCK")
        record["roomID"]    = roomID   as CKRecordValue
        record["senderID"]  = senderID as CKRecordValue
        record["body"]      = ""      as CKRecordValue  // placeholder
        record["createdAt"] = Date()  as CKRecordValue
        record["imageAsset"] = CKAsset(fileURL: tmpURL)

        _ = try await db.save(record)
    }

    // MARK: - Multi-Image Message CRUD
    static func saveImages(_ images: [UIImage], roomID: String, senderID: String) async throws -> String? {
        let record = CKRecord(recordType: "MessageCK")
        record["roomID"] = roomID as CKRecordValue
        record["senderID"] = senderID as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue

        var assets: [CKAsset] = []
        for img in images {
            guard let data = img.optimizedData() else { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(data.isHEIC ? "heic" : "jpg")
            try data.write(to: tmp)
            assets.append(CKAsset(fileURL: tmp))
        }
        record["imageAssets"] = assets as CKRecordValue
        let saved = try await db.save(record)
        return saved.recordID.recordName
    }

    static func appendImages(_ images: [UIImage], recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await db.record(for: recordID)
        var existing = record["imageAssets"] as? [CKAsset] ?? []
        for img in images {
            guard let data = img.optimizedData() else { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(data.isHEIC ? "heic" : "jpg")
            try data.write(to: tmp)
            existing.append(CKAsset(fileURL: tmp))
        }
        record["imageAssets"] = existing as CKRecordValue
        _ = try await db.save(record)
    }

    // MARK: - Video Message CRUD
    /// 保存済みローカル動画 (.mov) を CKAsset としてアップロード。
    static func saveVideo(_ fileURL: URL,
                          roomID: String,
                          senderID: String) async throws -> String? {
        print("[DEBUG] CKSync.saveVideo: Starting upload for file: \(fileURL)")
        print("[DEBUG] CKSync.saveVideo: File exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
        
        // ファイルサイズをチェック
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int64 {
            print("[DEBUG] CKSync.saveVideo: File size: \(fileSize) bytes (\(Double(fileSize) / 1024 / 1024) MB)")
        }
        
        let record = CKRecord(recordType: "MessageCK")
        record["roomID"] = roomID as CKRecordValue
        record["senderID"] = senderID as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        
        print("[DEBUG] CKSync.saveVideo: Creating CKAsset from file URL")
        let videoAsset = CKAsset(fileURL: fileURL)
        record["videoAsset"] = videoAsset
        
        print("[DEBUG] CKSync.saveVideo: Saving record to CloudKit")
        let saved = try await db.save(record)
        print("[DEBUG] CKSync.saveVideo: Successfully saved record: \(saved.recordID.recordName)")
        
        return saved.recordID.recordName
    }

    // MARK: - Single Image Message
    
    /// Saves a single image as a message with CKAsset
    static func saveImageMessage(_ image: UIImage, roomID: String, senderID: String) async throws -> String? {
        guard let fileURL = AttachmentManager.saveImageToCache(image) else { return nil }
        
        let record = CKRecord(recordType: "MessageCK")
        record["roomID"] = roomID
        record["senderID"] = senderID
        record["createdAt"] = Date()
        record["asset"] = CKAsset(fileURL: fileURL)
        record["reactions"] = "" // Initialize empty reactions
        
        let saved = try await db.save(record)
        return saved.recordID.recordName
    }

    // MARK: - WebRTC Signalling

    /// Persists an ICE candidate generated by WebRTC into CloudKit so the peer can pick it up.
    static func saveCandidate(_ candidate: RTCIceCandidate, roomID: String) async throws {
        let record = CKRecord(recordType: "IceCandidateCK")
        record["roomID"] = roomID as CKRecordValue
        if let mid = candidate.sdpMid {
            record["sdpMid"] = mid as CKRecordValue
        }
        record["sdpMLineIndex"] = candidate.sdpMLineIndex as CKRecordValue
        record["candidate"] = candidate.sdp as CKRecordValue
        _ = try await db.save(record)
    }

    // Presence heartbeat (best-effort, non-blocking)
    static func refreshPresence(_ roomID: String, _ userID: String) {
        Task {
            let record = CKRecord(recordType: "PresenceCK")
            record["roomID"] = roomID as CKRecordValue
            record["userID"] = userID as CKRecordValue
            record["expires"] = Date().addingTimeInterval(30) as CKRecordValue
            _ = try? await db.save(record)
        }
    }

    // MARK: - Push Handling

    /// Handles a CloudKit push payload by fetching zone changes and updating local state.
    static func handlePush(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // Use the convenience API on CKDatabase to fetch all changes since last fetch.
        // In production you should maintain serverChangeTokens but for brevity we re-fetch everything.
        do {
            let changes = try await db.fetchAllChanges()
            await MainActor.run {
                if let context = modelContext {
                    for record in changes {
                        if let message = MessageMapper.message(from: record) {
                            context.insert(message)
                        } else if let anniv = AnniversaryMapper.anniversary(from: record) {
                            context.insert(anniv)
                        }
                        P2PController.shared.ingest(record)
                    }
                }
            }
            return .newData
        } catch {
            return .failed
        }
    }

    // MARK: - Reactions
    
    /// Updates reaction emoji string for a message
    static func updateReaction(recordName: String, emoji: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        
        do {
            let record = try await db.record(for: recordID)
            record["reactions"] = emoji
            _ = try await db.save(record)
        } catch {
            print("[CKSync] Failed to update reaction: \(error)")
            throw error
        }
    }
    
    static func saveReaction(_ message: Message) async throws {
        let record = CKRecord(recordType: "MessageCK")
        record["roomID"] = message.roomID as CKRecordValue
        record["senderID"] = message.senderID as CKRecordValue
        record["body"] = (message.body ?? "") as CKRecordValue
        record["createdAt"] = message.createdAt as CKRecordValue
        _ = try await db.save(record)
    }
}

// MARK: - Helper

fileprivate struct MessageMapper {
    /// Converts a CloudKit record into a local `Message` if possible.
    static func message(from record: CKRecord) -> Message? {
        guard record.recordType == "MessageCK",
              let roomID = record["roomID"] as? String,
              let senderID = record["senderID"] as? String,
              let createdAt = record["createdAt"] as? Date else { return nil }

        // Single asset message (new structure)
        if let asset = record["asset"] as? CKAsset,
           let fileURL = asset.fileURL {
            // Download to local cache
            let localURL = AttachmentManager.makeFileURL(ext: "jpg")
            do {
                try FileManager.default.copyItem(at: fileURL, to: localURL)
                let reactions = record["reactions"] as? String
                return Message(roomID: roomID,
                             senderID: senderID,
                             body: nil,
                             assetPath: localURL.path,
                             createdAt: createdAt,
                             isSent: true,
                             reactionEmoji: reactions)
            } catch {
                print("[MessageMapper] Failed to copy asset: \(error)")
            }
        }

        // image array message
        if let assetArray = record["imageAssets"] as? [CKAsset], !assetArray.isEmpty {
            var urls: [URL] = []
            for asset in assetArray {
                if let srcURL = asset.fileURL {
                    let dstURL = AttachmentManager.makeFileURL(ext: srcURL.pathExtension)
                    if !FileManager.default.fileExists(atPath: dstURL.path) {
                        try? FileManager.default.copyItem(at: srcURL, to: dstURL)
                    }
                    urls.append(dstURL)
                }
            }
            ImageCacheManager.enforceLimit()
            return Message(roomID: roomID,
                           senderID: senderID,
                           body: nil,
           
                           ckRecordName: record.recordID.recordName,
                           createdAt: createdAt,
                           isSent: true)
        }

        // video message
        if let vAsset = record["videoAsset"] as? CKAsset,
           let srcURL = vAsset.fileURL {
            let dstURL = AttachmentManager.makeFileURL(ext: srcURL.pathExtension)
            if !FileManager.default.fileExists(atPath: dstURL.path) {
                try? FileManager.default.copyItem(at: srcURL, to: dstURL)
            }
            return Message(roomID: roomID,
                           senderID: senderID,
                           body: nil,
                           assetPath: dstURL.path,
                           ckRecordName: record.recordID.recordName,
                           createdAt: createdAt,
                           isSent: true)
        }

        // text message
        let body = record["body"] as? String
        let reactions = record["reactions"] as? String
        return Message(roomID: roomID,
                       senderID: senderID,
                       body: body,
                       createdAt: createdAt,
                       isSent: true,
                       reactionEmoji: reactions)
    }
}

fileprivate struct AnniversaryMapper {
    static func anniversary(from record: CKRecord) -> Anniversary? {
        guard record.recordType == "AnniversaryCK",
              let roomID = record["roomID"] as? String,
              let title = record["title"] as? String,
              let date = record["annivDate"] as? Date else { return nil }
        
        let repeatTypeString = record["repeatType"] as? String ?? "none"
        let repeatType = RepeatType(rawValue: repeatTypeString) ?? .none
        
        return Anniversary(roomID: roomID,
                           title: title,
                           date: date,
                           repeatType: repeatType,
                           ckRecordName: record.recordID.recordName)
    }
}

// MARK: - Context injection

extension CKSync {
    static var modelContext: ModelContext?
}

extension CKDatabase {
    /// Fetches **all** records for the app in parallel, grouped by record type.
    /// 本サンプルではサーバートークンを保持せず、毎回全件取得する実装とする。
    /// - Returns: 取得した `CKRecord` 配列（重複なし）。
    func fetchAllChanges() async throws -> [CKRecord] {
        // 追加したいレコードタイプがあれば配列へ追記する
        let recordTypes: [String] = [
            "MessageCK",
            "AnniversaryCK",
            "CallSessionCK",
            "IceCandidateCK",
            "PresenceCK",
            "ProfileCK"
        ]

        // Helper that fetches *all* records of 1 type using paginated CKQueryOperation
        func fetchRecords(ofType recordTypeStr: String) async throws -> [CKRecord] {
            let query = CKQuery(recordType: recordTypeStr, predicate: NSPredicate(value: true))
            let operation = CKQueryOperation(query: query)
            
            return try await withCheckedThrowingContinuation { continuation in
                var results: [CKRecord] = []
                
                operation.recordMatchedBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        results.append(record)
                    case .failure(_):
                        break
                    }
                }
                
                operation.queryResultBlock = { result in
                    switch result {
                    case .success(_):
                        continuation.resume(returning: results)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                
                self.add(operation)
            }
        }

        // 各タイプを並列取得
        return try await withThrowingTaskGroup(of: [CKRecord].self) { group in
            for rt in recordTypes {
                group.addTask {
                    try await fetchRecords(ofType: rt)
                }
            }
            var combined: [CKRecord] = []
            for try await list in group {
                combined.append(contentsOf: list)
            }
            return combined
        }
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