import Foundation
import SwiftData
import UIKit

@Model
final class ChatRoom: Hashable {
    var id: UUID = UUID()
    
    // 相手のAppleアカウント（メールアドレスまたは電話番号）
    var remoteUserID: String = ""
    
    // チャット相手の表示名（オプション）
    var displayName: String?
    
    // ルームID（= ゾーン名。唯一の真実）
    var roomID: String = ""
    
    // 最後のメッセージの内容（一覧表示用）
    var lastMessageText: String?
    
    // 最後のメッセージの時刻
    var lastMessageDate: Date?
    
    // 未読メッセージ数
    var unreadCount: Int = 0
    
    // 作成日時
    var createdAt: Date = Date()
    
    // 画像自動ダウンロード設定（相手ごと）
    var autoDownloadImages: Bool = false
    
    init(roomID: String, remoteUserID: String, displayName: String? = nil) {
        self.id = UUID()
        self.remoteUserID = remoteUserID
        self.displayName = displayName
        self.createdAt = Date()
        self.roomID = roomID  // ゾーン名と一致させる
        log("ChatRoom: Created with remoteUserID: '\(remoteUserID)', roomID(zoneName): '\(self.roomID)'", category: "DEBUG")
    }
    
    // MARK: - Hashable
    static func == (lhs: ChatRoom, rhs: ChatRoom) -> Bool {
        return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
} 
