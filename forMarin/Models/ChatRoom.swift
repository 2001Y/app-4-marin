import Foundation
import SwiftData
import UIKit

@Model
final class ChatRoom: Hashable {
    enum ParticipantRole: String, Codable {
        case owner
        case participant
        case unknown
    }

    struct Participant: Codable, Hashable {
        var userID: String
        var isLocal: Bool
        var role: ParticipantRole
        var displayName: String?
        var avatarData: Data?
        var lastUpdatedAt: Date
    }

    var id: UUID = UUID()
    var displayName: String?
    var roomID: String = ""
    var lastMessageText: String?
    var lastMessageDate: Date?
    var unreadCount: Int = 0
    var createdAt: Date = Date()
    var autoDownloadImages: Bool = false
    private static let participantsEncoder = JSONEncoder()
    private static let participantsDecoder = JSONDecoder()
    private static let emptyParticipantsData: Data = {
        (try? ChatRoom.participantsEncoder.encode([Participant]())) ?? Data()
    }()

    @Attribute(.externalStorage)
    private var participantsBlob: Data = ChatRoom.emptyParticipantsData

    @Transient
    var participants: [Participant] {
        get {
            guard !participantsBlob.isEmpty else { return [] }
            do {
                return try ChatRoom.participantsDecoder.decode([Participant].self, from: participantsBlob)
            } catch {
                log("ChatRoom participants decode failed: \(error)", category: "SwiftData")
                return []
            }
        }
        set {
            do {
                participantsBlob = try ChatRoom.participantsEncoder.encode(newValue)
            } catch {
                log("ChatRoom participants encode failed: \(error)", category: "SwiftData")
            }
        }
    }

    init(roomID: String, displayName: String? = nil) {
        self.id = UUID()
        self.displayName = displayName
        self.roomID = roomID
        self.lastMessageText = nil
        self.lastMessageDate = nil
        self.unreadCount = 0
        self.createdAt = Date()
        self.autoDownloadImages = false
        self.participantsBlob = ChatRoom.emptyParticipantsData
        log("ChatRoom: Created roomID(zoneName): '\(roomID)'", category: "DEBUG")
    }

    var primaryCounterpart: Participant? {
        participants.first(where: { !$0.isLocal })
    }

    func participant(for userID: String) -> Participant? {
        participants.first(where: { $0.userID == userID })
    }

    func upsertParticipant(_ participant: Participant) {
        if let idx = participants.firstIndex(where: { $0.userID == participant.userID }) {
            participants[idx] = participant
        } else {
            participants.append(participant)
        }
    }

    func removeParticipant(userID: String) {
        participants.removeAll { $0.userID == userID }
    }

    // MARK: - Hashable
    static func == (lhs: ChatRoom, rhs: ChatRoom) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ChatRoom {
    var remoteUserID: String {
        primaryCounterpart?.userID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
