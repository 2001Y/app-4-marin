import Foundation
import Network
import SwiftData
import CloudKit

@MainActor
class OfflineManager: ObservableObject {
    static let shared = OfflineManager()
    
    @Published var isOnline: Bool = true
    @Published var queuedMessagesCount: Int = 0
    @Published var lastSyncDate: Date?
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    
    private init() {
        setupNetworkMonitoring()
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
    
    // MARK: - Queue Management (Engine委譲)

    func queueMessage(_ message: Message) {
        guard #available(iOS 17.0, *) else {
            log("CKSyncEngine unavailable on this OS. Skipping queue.", category: "OfflineManager")
            return
        }

        Task { @MainActor in
            await CKSyncEngineManager.shared.queueMessage(message)
            if let path = message.assetPath {
                await CKSyncEngineManager.shared.queueAttachment(
                    messageRecordName: message.id.uuidString,
                    roomID: message.roomID,
                    localFileURL: URL(fileURLWithPath: path)
                )
            }
            await updateQueuedMessagesCount()
            log("[Engine] Queued message to CKSyncEngine: id=\(message.id) pending=\(queuedMessagesCount)", category: "OfflineManager")
            if isOnline { await CKSyncEngineManager.shared.kickSyncNow() }
        }
    }
    
    func processOfflineQueue() {
        guard #available(iOS 17.0, *), isOnline else { return }
        Task { @MainActor in
            await CKSyncEngineManager.shared.kickSyncNow()
            await updateQueuedMessagesCount()
            log("[Engine] Kicked sync. pending=\(queuedMessagesCount)", category: "OfflineManager")
        }
    }
    
    // 旧オフラインキュー関連はEngine移行に伴い廃止
    
    // MARK: - Public API
    
    func clearQueue() {
        guard #available(iOS 17.0, *) else {
            log("CKSyncEngine unavailable on this OS. Skipping queue reset.", category: "OfflineManager")
            return
        }

        Task { @MainActor in
            await CKSyncEngineManager.shared.resetEngines()
            await updateQueuedMessagesCount()
            log("[Engine] Reset engines. pending=\(queuedMessagesCount)", category: "OfflineManager")
        }
    }
    
    // 旧 getQueueStatistics は廃止（Engineのpendingは直接参照する想定）
    
    func forceSync() {
        guard isOnline else {
            log("Cannot force sync while offline", category: "OfflineManager")
            return
        }
        log("Force sync requested", category: "OfflineManager")
        if #available(iOS 17.0, *) {
            Task { await CKSyncEngineManager.shared.kickSyncNow() }
        }
        lastSyncDate = Date()
    }
    
    // 旧 retryFailedMessages は廃止
    
    // MARK: - Connectivity Utils
    
    func checkConnectivity() -> Bool {
        return monitor.currentPath.status == .satisfied
    }
    
    func getConnectionType() -> String {
        let path = monitor.currentPath

        let interfaces: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "WiFi"),
            (.cellular, "Cellular"),
            (.wiredEthernet, "Ethernet")
        ]

        if let matched = interfaces.first(where: { path.usesInterfaceType($0.0) }) {
            return matched.1
        }
        return "Unknown"
    }
    
    deinit {
        monitor.cancel()
    }

    // MARK: - Helpers

    @MainActor
    private func updateQueuedMessagesCount() async {
        let stats = await CKSyncEngineManager.shared.pendingStats()
        queuedMessagesCount = stats.total
    }
}

// MARK: - Supporting Types
// 旧QueuedMessage/QueueStatistics型は廃止

// MARK: - Notifications

extension Notification.Name {
    static let messageFailedPermanently = Notification.Name("MessageFailedPermanently")
    static let networkStatusChanged = Notification.Name("NetworkStatusChanged")
}
