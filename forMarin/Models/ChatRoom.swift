import Foundation
import SwiftData
import CryptoKit
import UIKit

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
    
    // 画像自動ダウンロード設定（相手ごと）
    var autoDownloadImages: Bool = false
    
    init(remoteUserID: String, displayName: String? = nil, myUserID: String? = nil) {
        self.id = UUID()
        self.remoteUserID = remoteUserID
        self.displayName = displayName
        self.createdAt = Date()
        
        // roomIDを生成（統一ユーザーIDを使用）
        if let myUserID = myUserID {
            self.roomID = Self.generateDeterministicRoomID(myID: myUserID, remoteID: remoteUserID)
        } else {
            // フォールバック: 一時的にデバイスIDを使用（後で更新される）
            let tempMyID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
            self.roomID = Self.generateDeterministicRoomID(myID: tempMyID, remoteID: remoteUserID)
            log("ChatRoom: Created with temporary device ID, should be updated with unified ID", category: "WARNING")
        }
        
        log("ChatRoom: Created with remoteUserID: '\(remoteUserID)', roomID: '\(self.roomID)'", category: "DEBUG")
    }
    
    /// 統一ユーザーIDでroomIDを更新
    func updateRoomID(with unifiedUserID: String) {
        let newRoomID = Self.generateDeterministicRoomID(myID: unifiedUserID, remoteID: remoteUserID)
        if newRoomID != self.roomID {
            log("ChatRoom: Updating roomID from '\(self.roomID)' to '\(newRoomID)'", category: "DEBUG")
            self.roomID = newRoomID
        }
    }
    
    /// 両ユーザーが同じroomIDを生成するための決定的な関数
    static func generateDeterministicRoomID(myID: String, remoteID: String) -> String {
        // ソートして常に同じ順序にする（重要！）
        let sortedIDs = [myID, remoteID].sorted()
        let combined = sortedIDs.joined(separator: ":")
        
        // HMAC-SHA256でハッシュ化
        let key = SymmetricKey(data: "forMarin-chat-room-v1".data(using: .utf8)!)
        let hmac = HMAC<SHA256>.authenticationCode(for: combined.data(using: .utf8)!, using: key)
        
        // 64文字のHEX文字列に変換
        let roomID = hmac.compactMap { String(format: "%02x", $0) }.joined()
        log("ChatRoom: Generated deterministic roomID: '\(roomID)' for myID: '\(myID)', remoteID: '\(remoteID)'", category: "DEBUG")
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