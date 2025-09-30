import Foundation
import SwiftUI
import SwiftData

@MainActor
class URLManager: ObservableObject {
    static let shared = URLManager()
    
    @Published var pendingInviteUserID: String?
    
    private init() {}
    
    // MARK: - 招待URL生成
    
    /// カスタムURLスキームで招待URLを生成
    func generateInviteURL(userID: String) -> String {
        return "fourmarin://invite?userID=\(userID)"
    }
    
    // MARK: - URL解析
    
    /// URLから招待パラメータを解析
    func parseInviteURL(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            log("Invalid URL format: \(url)", category: "URLManager")
            return nil
        }
        
        // userIDパラメータを検索
        for item in queryItems {
            if item.name == "userID", let userID = item.value, !userID.isEmpty {
                log("Found userID in URL: \(userID)", category: "URLManager")
                return userID
            }
        }
        
        log("No userID parameter found in URL: \(url)", category: "URLManager")
        return nil
    }
    
    /// URLが招待リンクかどうかを判定
    func isInviteURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        
        // カスタムURLスキーム: fourmarin://invite
        return scheme == "fourmarin" && host == "invite"
    }
    
    // MARK: - チャット作成処理
    
    /// 招待URLからチャットを作成（ゾーン名=roomID を先に確定し、そのroomIDで全体を駆動）
    func createChatFromInvite(userID: String, modelContext: ModelContext) async -> ChatRoom? {
        do {
            // CloudKitの単一ソースからUserIDを取得
            let myUserID = try await CloudKitChatManager.shared.ensureCurrentUserID()
            
            // 自分自身のIDかチェック
            if userID == myUserID {
                log("Cannot create chat with self: \(userID)", category: "URLManager")
                return nil
            }
            
            // 既存のチャットルームをチェック
            let descriptor = FetchDescriptor<ChatRoom>(
                predicate: #Predicate<ChatRoom> { room in
                    room.remoteUserID == userID
                }
            )
            
            let existingRooms = try modelContext.fetch(descriptor)
            if let existingRoom = existingRooms.first {
                log("Chat already exists with userID: \(userID)", category: "URLManager")
                return existingRoom
            }
            
            // ゾーン名（roomID）を先に確定
            let roomID = CKSchema.makeZoneName()

            // CloudKit側にカスタムゾーン + ChatSession + CKShare(Zone Share) を作成
            do {
                _ = try await CloudKitChatManager.shared.createSharedChatRoom(roomID: roomID, invitedUserID: userID)
            } catch {
                log("❌ Failed to create shared chat room in CloudKit: \(error)", category: "URLManager")
                return nil
            }

            // ローカルのチャットルームを作成（roomID=zoneName）
            let newRoom = ChatRoom(roomID: roomID, remoteUserID: userID, displayName: nil)
            log("📝 Created ChatRoom with ID: \(newRoom.id), roomID(zoneName): \(newRoom.roomID)", category: "URLManager")
            
            modelContext.insert(newRoom)
            
            try modelContext.save()
            log("💾 Successfully saved ChatRoom to SwiftData", category: "URLManager")
            
            return newRoom
            
        } catch {
            log("❌ Failed to create chat from invite: \(error)", category: "URLManager")
            return nil
        }
    }
    
    // MARK: - ペンディング処理
    
    /// アプリがフォアグラウンドにない時の招待処理
    func setPendingInvite(userID: String) {
        pendingInviteUserID = userID
        log("Set pending invite for userID: \(userID)", category: "URLManager")
    }
    
    /// ペンディング中の招待を処理
    func processPendingInvite(modelContext: ModelContext) async -> ChatRoom? {
        guard let userID = pendingInviteUserID else { return nil }
        
        log("Processing pending invite for userID: \(userID)", category: "URLManager")
        pendingInviteUserID = nil
        
        return await createChatFromInvite(userID: userID, modelContext: modelContext)
    }
    
    /// ペンディング招待をクリア
    func clearPendingInvite() {
        pendingInviteUserID = nil
        log("Cleared pending invite", category: "URLManager")
    }
}

// MARK: - 通知

extension Notification.Name {
    static let inviteURLReceived = Notification.Name("InviteURLReceived")
}
