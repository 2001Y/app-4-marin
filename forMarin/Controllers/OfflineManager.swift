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
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                await CKSyncEngineManager.shared.queueMessage(message)
                if let path = message.assetPath {
                    await CKSyncEngineManager.shared.queueAttachment(
                        messageRecordName: message.id.uuidString,
                        roomID: message.roomID,
                        localFileURL: URL(fileURLWithPath: path)
                    )
                }
                let stats = await CKSyncEngineManager.shared.pendingStats()
                self.queuedMessagesCount = stats.total
                log("[Engine] Queued message to CKSyncEngine: id=\(message.id) pending=\(stats.total)", category: "OfflineManager")
                if self.isOnline { await CKSyncEngineManager.shared.kickSyncNow() }
            }
        } else {
            log("CKSyncEngine unavailable on this OS. Skipping queue.", category: "OfflineManager")
        }
    }
    
    func processOfflineQueue() {
        if #available(iOS 17.0, *) {
            guard isOnline else { return }
            Task { @MainActor in
                await CKSyncEngineManager.shared.kickSyncNow()
                let stats = await CKSyncEngineManager.shared.pendingStats()
                queuedMessagesCount = stats.total
                log("[Engine] Kicked sync. pending=\(stats.total)", category: "OfflineManager")
            }
        }
    }
    
    // 旧オフラインキュー関連はEngine移行に伴い廃止
    
    // MARK: - Public API
    
    func clearQueue() {
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                await CKSyncEngineManager.shared.resetEngines()
                let stats = await CKSyncEngineManager.shared.pendingStats()
                queuedMessagesCount = stats.total
                log("[Engine] Reset engines. pending=\(stats.total)", category: "OfflineManager")
            }
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
    }
}

// MARK: - Supporting Types
// 旧QueuedMessage/QueueStatistics型は廃止

// MARK: - Notifications

extension Notification.Name {
    static let messageFailedPermanently = Notification.Name("MessageFailedPermanently")
    static let networkStatusChanged = Notification.Name("NetworkStatusChanged")
}
