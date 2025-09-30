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

    func countMessagesMissingCloudRecord() throws -> Int {
        guard let container else {
            throw BrokerError.containerUnavailable
        }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.ckRecordName == nil })
        return try context.fetch(descriptor).count
    }
}
