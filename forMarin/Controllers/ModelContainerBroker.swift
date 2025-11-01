import Foundation
import SwiftData

@MainActor
final class ModelContainerBroker {
    static let shared = ModelContainerBroker()

    enum BrokerError: Error {
        case containerUnavailable
    }

    private var container: ModelContainer?

    private init() {}

    func register(_ container: ModelContainer) {
        self.container = container
    }

    func mainContext() throws -> ModelContext {
        guard let container else {
            throw BrokerError.containerUnavailable
        }
        return container.mainContext
    }

    func participantsSnapshot(roomID: String) -> [ChatRoom.Participant] {
        guard let container else { return [] }
        let context = container.mainContext
        var descriptor = FetchDescriptor<ChatRoom>(predicate: #Predicate<ChatRoom> { $0.roomID == roomID })
        descriptor.fetchLimit = 1
        guard let room = (try? context.fetch(descriptor))?.first else { return [] }
        return room.participants
    }

    func countMessagesMissingCloudRecord() throws -> Int {
        guard let container else {
            throw BrokerError.containerUnavailable
        }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.ckRecordName == nil })
        return try context.fetch(descriptor).count
    }
}
