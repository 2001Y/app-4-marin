import Foundation
import SwiftData

@Model
final class ChatRoom: Hashable {
    var id: UUID = UUID()
    
    // 相手のAppleアカウント（メールアドレスまたは電話番号）
    var remoteUserID: String = ""
    
    // チャット相手の表示名（オプション）
    var displayName: String?
    
    // ルームID（HMACベース）
    var roomID: String = ""
    
    // 最後のメッセージの内容（一覧表示用）
    var lastMessageText: String?
    
    // 最後のメッセージの時刻
    var lastMessageDate: Date?
    
    // 未読メッセージ数
    var unreadCount: Int = 0
    
    // 作成日時
    var createdAt: Date = Date()
    
    init(remoteUserID: String, displayName: String? = nil) {
        self.id = UUID()
        self.remoteUserID = remoteUserID
        self.displayName = displayName
        self.createdAt = Date()
        
        // roomIDを生成（実際の実装では適切なHMAC処理が必要）
        self.roomID = generateRoomID(for: remoteUserID)
        print("[DEBUG] ChatRoom: Created with remoteUserID: '\(remoteUserID)', roomID: '\(self.roomID)'")
    }
    
    private func generateRoomID(for remoteUserID: String) -> String {
        // 仮実装：実際にはHMAC-SHA256を使用
        let roomID = "\(remoteUserID)_room"
        print("[DEBUG] ChatRoom: Generated roomID: '\(roomID)' for remoteUserID: '\(remoteUserID)'")
        return roomID
    }
    
    // MARK: - Hashable
    static func == (lhs: ChatRoom, rhs: ChatRoom) -> Bool {
        return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
} 