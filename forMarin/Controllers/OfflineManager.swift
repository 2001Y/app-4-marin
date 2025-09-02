import Foundation
import Network
import SwiftData
import Combine

@MainActor
class OfflineManager: ObservableObject {
    static let shared = OfflineManager()
    
    @Published var isOnline: Bool = true
    @Published var queuedMessagesCount: Int = 0
    @Published var lastSyncDate: Date?
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private var cancellables = Set<AnyCancellable>()
    
    // Offline message queue
    private var offlineQueue: [QueuedMessage] = []
    private let maxQueueSize = 1000
    private let queuePersistenceKey = "OfflineMessageQueue"
    
    // Retry configuration
    private let maxRetryAttempts = 3
    private let baseRetryDelay: TimeInterval = 2.0
    private var retryTimer: Timer?
    
    private init() {
        setupNetworkMonitoring()
        loadPersistedQueue()
    }
    
    // MARK: - Network Monitoring
    
    private func setupNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let wasOnline = self?.isOnline ?? true
                self?.isOnline = path.status == .satisfied
                
                if !wasOnline && (self?.isOnline ?? false) {
                    log("Network restored, processing offline queue", category: "OfflineManager")
                    self?.processOfflineQueue()
                } else if wasOnline && !(self?.isOnline ?? true) {
                    log("Network lost, enabling offline mode", category: "OfflineManager")
                }
            }
        }
        
        monitor.start(queue: monitorQueue)
    }
    
    // MARK: - Queue Management
    
    func queueMessage(_ message: Message) {
        let queuedMessage = QueuedMessage(
            message: message,
            queuedAt: Date(),
            retryCount: 0
        )
        
        // Add to queue with size limit
        if offlineQueue.count >= maxQueueSize {
            // Remove oldest message
            offlineQueue.removeFirst()
            log("Queue full, removed oldest message", category: "OfflineManager")
        }
        
        offlineQueue.append(queuedMessage)
        queuedMessagesCount = offlineQueue.count
        
        persistQueue()
        log("Message queued: \(message.id), queue size: \(offlineQueue.count)", category: "OfflineManager")
        
        // Try immediate sync if online
        if isOnline {
            processNextQueuedMessage()
        }
    }
    
    func processOfflineQueue() {
        guard isOnline && !offlineQueue.isEmpty else { return }
        
        log("Processing \(offlineQueue.count) queued messages", category: "OfflineManager")
        
        // Process messages in batches to avoid overwhelming the system
        let batchSize = 5
        let batch = Array(offlineQueue.prefix(batchSize))
        
        for queuedMessage in batch {
            processQueuedMessage(queuedMessage)
        }
    }
    
    private func processNextQueuedMessage() {
        guard isOnline, let queuedMessage = offlineQueue.first else { return }
        
        processQueuedMessage(queuedMessage)
    }
    
    private func processQueuedMessage(_ queuedMessage: QueuedMessage) {
        guard isOnline else { return }
        
        Task {
            // iOS 17+ 前提: 共有ゾーン対応の送信経路のみ使用（非throw）
            MessageSyncService.shared.sendMessage(queuedMessage.message)
            // ここでは成功扱いとし、失敗はsyncErrorの購読側で再キュー
            await MainActor.run {
                removeFromQueue(queuedMessage)
                log("Successfully queued send for message: \(queuedMessage.message.id)", category: "OfflineManager")
                processNextQueuedMessage()
            }
        }
    }
    
    private func handleQueuedMessageFailure(_ queuedMessage: QueuedMessage, error: Error) {
        queuedMessage.retryCount += 1
        queuedMessage.lastRetryAt = Date()
        
        if queuedMessage.retryCount >= maxRetryAttempts {
            log("Max retries reached for message: \(queuedMessage.message.id)", category: "OfflineManager")
            removeFromQueue(queuedMessage)
            
            // Notify user about failed message
            NotificationCenter.default.post(
                name: .messageFailedPermanently,
                object: nil,
                userInfo: ["message": queuedMessage.message, "error": error]
            )
        } else {
            log("Retry \(queuedMessage.retryCount)/\(maxRetryAttempts) for message: \(queuedMessage.message.id)", category: "OfflineManager")
            scheduleRetry(for: queuedMessage)
        }
    }
    
    private func scheduleRetry(for queuedMessage: QueuedMessage) {
        let delay = baseRetryDelay * pow(2.0, Double(queuedMessage.retryCount - 1)) // Exponential backoff
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.isOnline {
                self.processQueuedMessage(queuedMessage)
            }
        }
    }
    
    private func removeFromQueue(_ queuedMessage: QueuedMessage) {
        offlineQueue.removeAll { $0.id == queuedMessage.id }
        queuedMessagesCount = offlineQueue.count
        persistQueue()
    }
    
    // MARK: - Queue Persistence
    
    private func persistQueue() {
        do {
            let data = try JSONEncoder().encode(offlineQueue.map { $0.persistableData })
            UserDefaults.standard.set(data, forKey: queuePersistenceKey)
        } catch {
            log("Failed to persist queue: \(error)", category: "OfflineManager")
        }
    }
    
    private func loadPersistedQueue() {
        guard let data = UserDefaults.standard.data(forKey: queuePersistenceKey) else { return }
        
        do {
            let persistableData = try JSONDecoder().decode([QueuedMessage.PersistableData].self, from: data)
            // In a real implementation, you would reconstruct the full messages from the persisted data
            // For now, we just update the count
            queuedMessagesCount = persistableData.count
            log("Loaded \(persistableData.count) persisted messages from queue", category: "OfflineManager")
        } catch {
            log("Failed to load persisted queue: \(error)", category: "OfflineManager")
        }
    }
    
    // MARK: - Public API
    
    func clearQueue() {
        offlineQueue.removeAll()
        queuedMessagesCount = 0
        persistQueue()
        log("Queue cleared", category: "OfflineManager")
    }
    
    func getQueueStatistics() -> QueueStatistics {
        let failedMessages = offlineQueue.filter { $0.retryCount > 0 }.count
        let oldestMessage = offlineQueue.first?.queuedAt
        
        return QueueStatistics(
            totalQueued: offlineQueue.count,
            failedMessages: failedMessages,
            oldestMessageDate: oldestMessage,
            isProcessing: isOnline && !offlineQueue.isEmpty
        )
    }
    
    func forceSync() {
        guard isOnline else {
            log("Cannot force sync while offline", category: "OfflineManager")
            return
        }
        
        log("Force sync requested", category: "OfflineManager")
        processOfflineQueue()
        
        // Also trigger MessageSyncService update
        if #available(iOS 17.0, *) {
            MessageSyncService.shared.checkForUpdates()
        }
        
        lastSyncDate = Date()
    }
    
    func retryFailedMessages() {
        let failedMessages = offlineQueue.filter { $0.retryCount > 0 }
        
        for message in failedMessages {
            message.retryCount = 0
            message.lastRetryAt = nil
        }
        
        log("Reset retry count for \(failedMessages.count) failed messages", category: "OfflineManager")
        
        if isOnline {
            processOfflineQueue()
        }
    }
    
    // MARK: - Connectivity Utils
    
    func checkConnectivity() -> Bool {
        return monitor.currentPath.status == .satisfied
    }
    
    func getConnectionType() -> String {
        let path = monitor.currentPath
        
        if path.usesInterfaceType(.wifi) {
            return "WiFi"
        } else if path.usesInterfaceType(.cellular) {
            return "Cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            return "Ethernet"
        } else {
            return "Unknown"
        }
    }
    
    deinit {
        monitor.cancel()
        retryTimer?.invalidate()
    }
}

// MARK: - Supporting Types

class QueuedMessage: Identifiable, ObservableObject {
    let id = UUID()
    let message: Message
    let queuedAt: Date
    @Published var retryCount: Int
    @Published var lastRetryAt: Date?
    
    init(message: Message, queuedAt: Date, retryCount: Int) {
        self.message = message
        self.queuedAt = queuedAt
        self.retryCount = retryCount
    }
    
    var persistableData: PersistableData {
        PersistableData(
            messageID: message.id.uuidString,
            roomID: message.roomID,
            senderID: message.senderID,
            body: message.body,
            assetPath: message.assetPath,
            queuedAt: queuedAt,
            retryCount: retryCount
        )
    }
    
    struct PersistableData: Codable {
        let messageID: String
        let roomID: String
        let senderID: String
        let body: String?
        let assetPath: String?
        let queuedAt: Date
        let retryCount: Int
    }
}

struct QueueStatistics {
    let totalQueued: Int
    let failedMessages: Int
    let oldestMessageDate: Date?
    let isProcessing: Bool
    
    var averageAge: TimeInterval? {
        guard let oldest = oldestMessageDate else { return nil }
        return Date().timeIntervalSince(oldest)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let messageFailedPermanently = Notification.Name("MessageFailedPermanently")
    static let offlineQueueProcessed = Notification.Name("OfflineQueueProcessed")
    static let networkStatusChanged = Notification.Name("NetworkStatusChanged")
}
