import Foundation
import CloudKit
import Combine
import UIKit
import os.log

@MainActor
class PerformanceOptimizer: ObservableObject {
    static let shared = PerformanceOptimizer()
    
    // Performance Metrics
    @Published var averageResponseTime: TimeInterval = 0
    @Published var totalSyncOperations: Int = 0
    @Published var failedOperations: Int = 0
    @Published var cacheHitRate: Double = 0.0
    
    // Rate Limiting
    private var rateLimiter = RateLimiter()
    private var lastSyncTimes: [String: Date] = [:] // RoomID -> Last sync time
    
    // Batch Processing
    private var pendingBatches: [String: BatchOperation] = [:] // RoomID -> Batch
    private let batchDelay: TimeInterval = 0.5 // 500ms batch window
    private let maxBatchSize = 20
    
    // Memory Management
    private var messageCache = NSCache<NSString, CachedMessage>()
    private let maxCacheSize = 1000
    
    // Monitoring
    private let logger = Logger(subsystem: "com.formarin.app", category: "Performance")
    private var operationTimes: [TimeInterval] = []
    private let maxOperationHistory = 100
    
    private init() {
        setupCacheConfiguration()
        setupPerformanceMonitoring()
    }
    
    // MARK: - Cache Management
    
    private func setupCacheConfiguration() {
        messageCache.countLimit = maxCacheSize
        messageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
        // Clean cache on memory warnings
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.messageCache.removeAllObjects()
                self?.logger.info("Cleared message cache due to memory warning")
            }
        }
    }
    
    func cacheMessage(_ message: Message) {
        let cachedMessage = CachedMessage(
            message: message,
            cacheTime: Date(),
            accessCount: 1
        )
        
        messageCache.setObject(cachedMessage, forKey: message.id.uuidString as NSString)
    }
    
    func getCachedMessage(id: String) -> Message? {
        if let cached = messageCache.object(forKey: id as NSString) {
            cached.accessCount += 1
            cached.lastAccessed = Date()
            return cached.message
        }
        return nil
    }
    
    func clearCache() {
        messageCache.removeAllObjects()
        logger.info("Message cache cleared manually")
    }
    
    // MARK: - Rate Limiting
    
    func canPerformSync(for roomID: String) -> Bool {
        return rateLimiter.canPerform(operation: "sync_\(roomID)")
    }
    
    func shouldBatchOperation(for roomID: String) -> Bool {
        // Check if there's already a pending batch
        if let batch = pendingBatches[roomID] {
            return batch.operations.count < maxBatchSize
        }
        return true
    }
    
    func addToBatch(roomID: String, operation: SyncOperation) {
        if pendingBatches[roomID] == nil {
            pendingBatches[roomID] = BatchOperation(roomID: roomID)
        }
        
        pendingBatches[roomID]?.operations.append(operation)
        
        // Schedule batch processing
        DispatchQueue.main.asyncAfter(deadline: .now() + batchDelay) { [weak self] in
            self?.processBatch(for: roomID)
        }
    }
    
    private func processBatch(for roomID: String) {
        guard let batch = pendingBatches[roomID], !batch.operations.isEmpty else { return }
        
        logger.info("Processing batch for room \(roomID) with \(batch.operations.count) operations")
        
        // Remove from pending
        pendingBatches.removeValue(forKey: roomID)
        
        // Process operations
        Task {
            await performBatchOperations(batch)
        }
    }
    
    private func performBatchOperations(_ batch: BatchOperation) async {
        let startTime = Date()
        
        // Group operations by type for efficient processing
        let sendOperations = batch.operations.compactMap { $0.sendMessage }
        let updateOperations = batch.operations.compactMap { $0.updateMessage }
        let deleteOperations = batch.operations.compactMap { $0.deleteMessage }
        
        // Process in parallel where possible
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.processSendOperations(sendOperations)
            }
            group.addTask {
                await self.processUpdateOperations(updateOperations)
            }
            group.addTask {
                await self.processDeleteOperations(deleteOperations)
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        recordOperationTime(duration)
        
        logger.info("Batch processing completed in \(duration)s")
    }
    
    private func processSendOperations(_ messages: [Message]) async {
        // Implement parallel message sending with rate limiting
        for message in messages {
            if #available(iOS 17.0, *) {
                MessageSyncService.shared.sendMessage(message)
            }
        }
    }
    
    private func processUpdateOperations(_ messages: [Message]) async {
        // Implement parallel message updates
        for message in messages {
            if #available(iOS 17.0, *) {
                MessageSyncService.shared.updateMessage(message)
            }
        }
    }
    
    private func processDeleteOperations(_ messages: [Message]) async {
        // Implement parallel message deletions
        for message in messages {
            if #available(iOS 17.0, *) {
                MessageSyncService.shared.deleteMessage(message)
            }
        }
    }
    
    // MARK: - Performance Monitoring
    
    private func setupPerformanceMonitoring() {
        // Monitor memory usage
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.logMemoryUsage()
            }
        }
        
        // Update cache hit rate periodically
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCacheHitRate()
            }
        }
    }
    
    private func logMemoryUsage() {
        let memoryUsage = getMemoryUsage()
        logger.info("Memory usage: \(memoryUsage.used)MB / \(memoryUsage.total)MB")
        
        // Cleanup if memory usage is high
        if memoryUsage.percentage > 0.8 {
            cleanupResources()
        }
    }
    
    private func getMemoryUsage() -> (used: Double, total: Double, percentage: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024 / 1024
            let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024
            let percentage = usedMB / totalMB
            return (usedMB, totalMB, percentage)
        }
        
        return (0, 0, 0)
    }
    
    private func cleanupResources() {
        logger.info("Performing resource cleanup")
        
        // Clear old cached messages
        messageCache.removeAllObjects()
        
        // Clear old operation history
        if operationTimes.count > maxOperationHistory {
            operationTimes.removeFirst(operationTimes.count - maxOperationHistory)
        }
        
        // Clear old sync time records
        let cutoffTime = Date().addingTimeInterval(-3600) // 1 hour ago
        lastSyncTimes = lastSyncTimes.filter { $0.value > cutoffTime }
    }
    
    private func updateCacheHitRate() {
        // This would typically be calculated based on cache access patterns
        // For now, we'll use a simple approximation based on cache utilization
        // NSCache doesn't provide a way to get current count, so we'll use a simple heuristic
        cacheHitRate = 0.8 // Placeholder value, in a real implementation this would be calculated from actual hits/misses
    }
    
    func recordOperationTime(_ duration: TimeInterval) {
        operationTimes.append(duration)
        totalSyncOperations += 1
        
        // Calculate rolling average
        if operationTimes.count > maxOperationHistory {
            operationTimes.removeFirst()
        }
        
        averageResponseTime = operationTimes.reduce(0, +) / Double(operationTimes.count)
    }
    
    func recordFailedOperation() {
        failedOperations += 1
    }
    
    // MARK: - Error Handling
    
    func handleSyncError(_ error: Error, for roomID: String) -> ErrorRecoveryAction {
        logger.error("Sync error for room \(roomID): \(error.localizedDescription)")
        
        if let ckError = error as? CKError {
            return handleCloudKitError(ckError, for: roomID)
        }
        
        return .retry
    }
    
    private func handleCloudKitError(_ error: CKError, for roomID: String) -> ErrorRecoveryAction {
        switch error.code {
        case .networkUnavailable, .networkFailure:
            return .queueForLater
            
        case .requestRateLimited:
            let retryAfter = error.retryAfterSeconds ?? 60
            return .retryAfter(TimeInterval(retryAfter))
            
        case .quotaExceeded:
            return .pauseSync
            
        case .serverRecordChanged:
            return .resolveConflict
            
        case .unknownItem:
            return .recreateRecord
            
        case .permissionFailure:
            return .requestPermissions
            
        default:
            return .retry
        }
    }
    
    // MARK: - Statistics
    
    func getPerformanceStatistics() -> PerformanceStatistics {
        let successRate = totalSyncOperations > 0 ? 
            Double(totalSyncOperations - failedOperations) / Double(totalSyncOperations) : 1.0
        
        return PerformanceStatistics(
            averageResponseTime: averageResponseTime,
            totalOperations: totalSyncOperations,
            failedOperations: failedOperations,
            successRate: successRate,
            cacheHitRate: cacheHitRate,
            pendingBatches: pendingBatches.count,
            memoryUsage: getMemoryUsage().used
        )
    }
    
    func resetStatistics() {
        averageResponseTime = 0
        totalSyncOperations = 0
        failedOperations = 0
        operationTimes.removeAll()
        logger.info("Performance statistics reset")
    }
}

// MARK: - Rate Limiter

class RateLimiter {
    private var operationTimes: [String: [Date]] = [:]
    private let maxOperationsPerMinute = 60
    private let timeWindow: TimeInterval = 60 // 1 minute
    
    func canPerform(operation: String) -> Bool {
        let now = Date()
        let cutoffTime = now.addingTimeInterval(-timeWindow)
        
        // Clean old operations
        operationTimes[operation] = operationTimes[operation]?.filter { $0 > cutoffTime } ?? []
        
        let recentOperations = operationTimes[operation]?.count ?? 0
        
        if recentOperations < maxOperationsPerMinute {
            operationTimes[operation, default: []].append(now)
            return true
        }
        
        return false
    }
}

// MARK: - Supporting Types

class CachedMessage {
    let message: Message
    let cacheTime: Date
    var lastAccessed: Date
    var accessCount: Int
    
    init(message: Message, cacheTime: Date, accessCount: Int) {
        self.message = message
        self.cacheTime = cacheTime
        self.lastAccessed = cacheTime
        self.accessCount = accessCount
    }
}

class BatchOperation {
    let roomID: String
    var operations: [SyncOperation] = []
    let createdAt: Date
    
    init(roomID: String) {
        self.roomID = roomID
        self.createdAt = Date()
    }
}

enum SyncOperation {
    case send(Message)
    case update(Message)
    case delete(Message)
    
    var sendMessage: Message? {
        if case .send(let message) = self { return message }
        return nil
    }
    
    var updateMessage: Message? {
        if case .update(let message) = self { return message }
        return nil
    }
    
    var deleteMessage: Message? {
        if case .delete(let message) = self { return message }
        return nil
    }
}

enum ErrorRecoveryAction {
    case retry
    case retryAfter(TimeInterval)
    case queueForLater
    case resolveConflict
    case recreateRecord
    case requestPermissions
    case pauseSync
}

struct PerformanceStatistics {
    let averageResponseTime: TimeInterval
    let totalOperations: Int
    let failedOperations: Int
    let successRate: Double
    let cacheHitRate: Double
    let pendingBatches: Int
    let memoryUsage: Double
    
    var isHealthy: Bool {
        return successRate > 0.9 && averageResponseTime < 2.0 && memoryUsage < 100
    }
}

// MARK: - Extensions

extension CKError {
    var retryAfterSeconds: Int? {
        return userInfo[CKErrorRetryAfterKey] as? Int
    }
}