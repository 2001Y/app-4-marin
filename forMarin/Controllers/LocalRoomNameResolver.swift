import Foundation
import SwiftData
import CloudKit

/// ローカル専用のルーム名決定ロジック。
/// - CloudKit へは一切保存しない（決定した名前は呼び出し側が ChatRoom.displayName に反映する想定）。
/// - ルームを開くたびに呼び出し、空名であれば判定を行う。既に displayName がある場合は何もしない。
/// - 2人（自分+相手1人）: 相手の名前を採用。
/// - 3人以上: 3人の表示名を「、」で連結した名前を採用（自分を含む/含まないは設定で切替可能）。
enum LocalRoomNameResolver {
    /// 3人以上のときに自分を含めるか。既定は true（自分を含む）。
    /// 仕様が確定するまでのローカル設定。必要であれば false にすると「自分以外の上位3人」を使用。
    private static let includeSelfInGroupName = true

    /// ルーム表示名の提案を行う（ローカル推論のみ）。
    /// - Returns: 新しい表示名（更新不要なら nil）
    @MainActor
    static func proposeNameIfNeeded(room: ChatRoom,
                                    openerUserID: String,
                                    modelContext: ModelContext) -> String? {
        // 既に名前がある場合は何もしない
        let current = room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard current.isEmpty else { return nil }

        let roomID = room.roomID
        // ローカルメッセージから参加者・名前ヒントを収集
        let (participantIDs, nameHints) = collectParticipantsAndHints(roomID: roomID, modelContext: modelContext)

        // 2人（自分+相手1人）
        if participantIDs.count == 2 {
            let otherID = participantIDs.first { $0 != openerUserID } ?? room.remoteUserID
            let display = displayName(for: otherID, roomID: roomID, hints: nameHints)
            return display
        }

        // 3人以上
        if participantIDs.count >= 3 {
            let ordered = orderedParticipants(participantIDs: participantIDs,
                                              openerUserID: openerUserID,
                                              includeSelf: includeSelfInGroupName)
            let top3 = Array(ordered.prefix(3))
            let names = top3.map { displayName(for: $0, roomID: roomID, hints: nameHints) }
            let joined = names.joined(separator: "、")
            return joined
        }

        // 参加者情報が十分でなければ何もしない（次回オープン時に再評価）
        return nil
    }

    // MARK: - 新要件対応: CloudKit名との協調と3名以上時のCloudKit反映
    /// ルームを開いたタイミングで呼び出し、displayNameが空のときにのみ評価します。
    /// 優先順位:
    /// 1) CloudKit の Room.name があればそれを採用（CloudKitへは未変更）
    /// 2) CloudKitにも無ければ: 2人→相手名をローカル設定、3人以上→「3名連結」をローカル設定しCloudKitにも保存
    @MainActor
    static func evaluateOnOpen(room: ChatRoom,
                               openerUserID: String,
                               modelContext: ModelContext) async {
        let current = room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard current.isEmpty else { return }

        let roomID = room.roomID

        // 1) CloudKitのnameがあれば必ずローカルを空にして終了（Cloud主導）
        if let ckName = await fetchCloudRoomName(roomID: roomID), !ckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let local = room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !local.isEmpty {
                room.displayName = nil
                try? modelContext.save()
            }
            return
        }

        // 2) ローカル推論
        // 2) クラウドから参加者と表示名ヒントを取得（失敗時はローカルにフォールバック）
        var (participantIDs, nameHints) = await fetchCloudParticipants(roomID: roomID)
        if participantIDs.isEmpty {
            (participantIDs, nameHints) = collectParticipantsAndHints(roomID: roomID, modelContext: modelContext)
        }
        if participantIDs.count == 2 {
            let otherID = participantIDs.first { $0 != openerUserID } ?? room.remoteUserID
            let display = displayName(for: otherID, roomID: roomID, hints: nameHints)
            room.displayName = display
            try? modelContext.save()
            return
        }
        if participantIDs.count >= 3 {
            // 三人目以降の命名（CloudKitへの保存）は参加してきた側（受諾成功側）が実行する。
            // ここ（他端末）では保存処理を行わず、Cloud側のRoom.nameが付与されるのを待つ。
            // 表示は effectiveTitle(...) 側でCloud名 or 動的推論を用いる。
        }
    }

    /// 表示専用の有効タイトル解決（保存は行わない）
    /// 優先順: ローカルdisplayName → CloudKit Room.name → ローカル推論（2人/3人以上）→ remoteUserID or 既定
    @MainActor
    static func effectiveTitle(room: ChatRoom,
                               openerUserID: String,
                               modelContext: ModelContext) async -> String {
        let local = (room.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty { return local }

        if let ckName = await fetchCloudRoomName(roomID: room.roomID), !ckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ckName
        }
        // Cloud参加者から解決（失敗時のみローカルフォールバック）
        var (participantIDs, nameHints) = await fetchCloudParticipants(roomID: room.roomID)
        if participantIDs.isEmpty {
            (participantIDs, nameHints) = collectParticipantsAndHints(roomID: room.roomID, modelContext: modelContext)
        }
        if participantIDs.count == 2 {
            let otherID = participantIDs.first { $0 != openerUserID } ?? room.remoteUserID
            return displayName(for: otherID, roomID: room.roomID, hints: nameHints)
        }
        if participantIDs.count >= 3 {
            let ordered = orderedParticipants(participantIDs: participantIDs,
                                              openerUserID: openerUserID,
                                              includeSelf: includeSelfInGroupName)
            let top3 = Array(ordered.prefix(3))
            let names = top3.map { displayName(for: $0, roomID: room.roomID, hints: nameHints) }
            return names.joined(separator: "、")
        }

        let rid = room.remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        return rid.isEmpty ? "新規チャット" : rid
    }

    // MARK: - Cloud participants (RoomMember) fetch
    @MainActor
    private static func fetchCloudParticipants(roomID: String) async -> (Set<String>, [String: String]) {
        do {
            let record = try await CloudKitChatManager.shared.getRoomRecord(roomID: roomID)
            let zoneID = record.recordID.zoneID
            let isPrivate = zoneID.ownerName.isEmpty
            let db = isPrivate ? CloudKitChatManager.shared.privateDB : CloudKitChatManager.shared.sharedDB
            let query = CKQuery(recordType: CKSchema.SharedType.roomMember, predicate: NSPredicate(value: true))
            let (results, _) = try await db.records(matching: query, inZoneWith: zoneID)

            var ids = Set<String>()
            var hints: [String: String] = [:]
            for (_, result) in results {
                if case .success(let rec) = result {
                    if let uid = rec[CKSchema.FieldKey.userId] as? String {
                        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { ids.insert(trimmed) }
                        if let dn = rec[CKSchema.FieldKey.displayName] as? String {
                            let dnTrim = dn.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !dnTrim.isEmpty { hints[trimmed] = dnTrim }
                        }
                    }
                }
            }
            return (ids, hints)
        } catch {
            return ([], [:])
        }
    }

    // CloudKit helpers
    @MainActor
    private static func fetchCloudRoomName(roomID: String) async -> String? {
        do {
            let record = try await CloudKitChatManager.shared.getRoomRecord(roomID: roomID)
            if let name = record[CKSchema.FieldKey.name] as? String { return name }
        } catch { }
        return nil
    }

    @MainActor
    private static func saveCloudRoomName(roomID: String, newName: String) async {
        do {
            let record = try await CloudKitChatManager.shared.getRoomRecord(roomID: roomID)
            record[CKSchema.FieldKey.name] = newName as CKRecordValue

            // DB選択: キャッシュ→ownerName有無
            let isOwner = CloudKitChatManager.shared.isOwnerCached(roomID)
            let database: CKDatabase
            if let isOwner {
                database = isOwner ? CloudKitChatManager.shared.privateDB : CloudKitChatManager.shared.sharedDB
            } else {
                let isPrivate = record.recordID.zoneID.ownerName.isEmpty
                database = isPrivate ? CloudKitChatManager.shared.privateDB : CloudKitChatManager.shared.sharedDB
            }
            _ = try await database.save(record)
        } catch { }
    }

    /// ローカルDB（SwiftData）のメッセージを元に、参加者ID集合と名前ヒントを収集する。
    private static func collectParticipantsAndHints(roomID: String,
                                                    modelContext: ModelContext) -> (Set<String>, [String: String]) {
        var ids = Set<String>()
        var hints: [String: String] = [:] // userID -> name
        do {
            let desc = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.roomID == roomID })
            let messages = try modelContext.fetch(desc)
            for m in messages {
                let uid = m.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !uid.isEmpty { ids.insert(uid) }
                if let (name, userID) = Message.extractParticipantJoinedInfo(from: m.body) {
                    if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty,
                       let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                        hints[userID] = name
                        ids.insert(userID)
                    }
                }
            }
        } catch {
            // フェッチ失敗時は空集合を返し、次回に再評価
        }
        return (ids, hints)
    }

    /// 表示名の解決（ヒント優先 → 自分のローカルプロフィール → userID）
    @MainActor
    private static func displayName(for userID: String?, roomID: String, hints: [String: String]) -> String {
        let uid = (userID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = hints[uid], !name.isEmpty { return name }

        // 自分自身のIDならローカル名を優先
        if let me = CloudKitChatManager.shared.currentUserID, me == uid {
            let myName = UserDefaults.standard.string(forKey: "myDisplayName")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let myName, !myName.isEmpty { return myName }
        }

        // 最後のフォールバック：IDを短縮して表示
        if uid.isEmpty { return "メンバー" }
        return String(uid.prefix(8))
    }

    /// 3人以上で並べる順番を決定。
    /// - includeSelf=true: 自分を含め、(自分→他)の順で並べる
    /// - includeSelf=false: 自分を除外し、他メンバーのソート順
    private static func orderedParticipants(participantIDs: Set<String>,
                                            openerUserID: String,
                                            includeSelf: Bool) -> [String] {
        // 決定論的にするためIDでソート（表示名に依らず安定）
        let sorted = participantIDs.sorted()
        if includeSelf {
            // 自分を先頭へ、それ以外はID昇順
            var head: [String] = []
            var tail: [String] = []
            for id in sorted {
                if id == openerUserID { head.append(id) } else { tail.append(id) }
            }
            return head + tail
        } else {
            return sorted.filter { $0 != openerUserID }
        }
    }
}
