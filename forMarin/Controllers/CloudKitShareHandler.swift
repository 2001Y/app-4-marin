import Foundation
import CloudKit

/// 🌟 [IDEAL SHARING] CloudKit共有招待の統一受諾管理
final class CloudKitShareHandler {
    static let shared = CloudKitShareHandler()
    
    // 既に処理済みの共有IDを追跡（重複処理を防ぐ）
    private var handledShareIDs = Set<CKRecord.ID>()
    private let processingQueue = DispatchQueue(label: "cloudkit.share.handler", qos: .userInitiated)
    
    private init() {}
    
    /// 🔄 [IDEAL SHARING] CloudKit共有招待を受諾処理（重複防止付き）
    func acceptShare(from metadata: CKShare.Metadata) {
        log("📥 [IDEAL SHARING] CloudKit share invitation received", category: "CloudKitShareHandler")
        log("📥 [IDEAL SHARING] Processing share invitation asynchronously", category: "CloudKitShareHandler")
        
        processingQueue.async {
            Task { @MainActor in
                await self.performAcceptShare(metadata)
            }
        }
    }
    
    @MainActor
    private func performAcceptShare(_ metadata: CKShare.Metadata) async {
        let shareID = metadata.share.recordID
        
        log("🔄 [IDEAL SHARING] Starting detailed share acceptance processing", category: "CloudKitShareHandler")
        log("🔄 [IDEAL SHARING] Share RecordID: \(shareID.recordName)", category: "CloudKitShareHandler")
        log("🔄 [IDEAL SHARING] Share ZoneID: \(shareID.zoneID.zoneName) (owner: \(shareID.zoneID.ownerName))", category: "CloudKitShareHandler")
        
        // 二重受諾ガード
        guard handledShareIDs.insert(shareID).inserted else {
            log("⚠️ [DUPLICATE GUARD] Share already being processed: \(shareID.recordName)", category: "CloudKitShareHandler")
            log("⚠️ [DUPLICATE GUARD] Current handled shares count: \(handledShareIDs.count)", category: "CloudKitShareHandler")
            return
        }
        
        log("✅ [DUPLICATE GUARD] Share added to processing set: \(shareID.recordName)", category: "CloudKitShareHandler")
        log("📊 [DUPLICATE GUARD] Total shares being processed: \(handledShareIDs.count)", category: "CloudKitShareHandler")
        
        // 📋 [METADATA ANALYSIS] 詳細なメタデータ分析
        log("📋 [METADATA ANALYSIS] === SHARE METADATA DETAILED ANALYSIS ===", category: "CloudKitShareHandler")
        log("📋 [METADATA ANALYSIS] Share URL: \(metadata.share.url?.absoluteString ?? "nil")", category: "CloudKitShareHandler")
        log("📋 [METADATA ANALYSIS] Container ID: \(metadata.containerIdentifier)", category: "CloudKitShareHandler")
        log("📋 [METADATA ANALYSIS] Owner identity: \(metadata.ownerIdentity.nameComponents?.formatted() ?? "nil")", category: "CloudKitShareHandler")
        log("📋 [METADATA ANALYSIS] Share creation date: \(metadata.share.creationDate?.description ?? "nil")", category: "CloudKitShareHandler")
        log("📋 [METADATA ANALYSIS] Share modification date: \(metadata.share.modificationDate?.description ?? "nil")", category: "CloudKitShareHandler")
        
        if #available(iOS 16.0, *) {
            if let rootRecord = metadata.rootRecord {
                log("📋 [METADATA ANALYSIS] Root Record ID: \(rootRecord.recordID.recordName)", category: "CloudKitShareHandler")
                log("📋 [METADATA ANALYSIS] Root Record Type: \(rootRecord.recordType)", category: "CloudKitShareHandler")
                log("📋 [METADATA ANALYSIS] Root Record Zone: \(rootRecord.recordID.zoneID.zoneName)", category: "CloudKitShareHandler")
            } else {
                log("⚠️ [METADATA ANALYSIS] No root record found in metadata (iOS 16+)", category: "CloudKitShareHandler")
            }
        } else {
            // iOS 15以下のサポート（rootRecordIDは非推奨だが下位互換のため使用）
            log("📋 [METADATA ANALYSIS] Root Record ID (iOS 15): \(metadata.rootRecordID.recordName)", category: "CloudKitShareHandler")
            log("📋 [METADATA ANALYSIS] Root Record Zone (iOS 15): \(metadata.rootRecordID.zoneID.zoneName)", category: "CloudKitShareHandler")
        }
        
        log("📋 [METADATA ANALYSIS] === END METADATA ANALYSIS ===", category: "CloudKitShareHandler")
        
        // 🩺 [PRE-ACCEPTANCE DIAGNOSIS] 受諾前のCloudKit状態診断
        await performPreAcceptanceDiagnosis(metadata: metadata)
        
        // 🚀 [OPERATION SETUP] CKAcceptSharesOperationのセットアップ
        log("🚀 [OPERATION SETUP] Creating CKAcceptSharesOperation", category: "CloudKitShareHandler")
        let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
        operation.qualityOfService = .userInitiated
        
        log("🚀 [OPERATION SETUP] QoS set to userInitiated", category: "CloudKitShareHandler")
        log("🚀 [OPERATION SETUP] Setting up operation callbacks", category: "CloudKitShareHandler")
        
        operation.perShareResultBlock = { [weak self] receivedMetadata, result in
            Task { @MainActor in
                log("📬 [OPERATION CALLBACK] Per-share result received", category: "CloudKitShareHandler")
                log("📬 [OPERATION CALLBACK] Received metadata for share: \(receivedMetadata.share.recordID.recordName)", category: "CloudKitShareHandler")
                
                switch result {
                case .success(let share):
                    let title = share[CKShare.SystemFieldKey.title] as? String ?? "nil"
                    let participants = share.participants.count
                    log("🎉 [SUCCESS] CloudKit share accepted successfully!", category: "CloudKitShareHandler")
                    log("🎉 [SUCCESS] Share title: \(title)", category: "CloudKitShareHandler")
                    log("🎉 [SUCCESS] Participants count: \(participants)", category: "CloudKitShareHandler")
                    log("🎉 [SUCCESS] Share URL: \(share.url?.absoluteString ?? "nil")", category: "CloudKitShareHandler")
                    log("🎉 [SUCCESS] Share recordID: \(share.recordID.recordName)", category: "CloudKitShareHandler")
                    
                    // 受諾成功後の処理
                    log("🔄 [SUCCESS] Starting post-acceptance handling", category: "CloudKitShareHandler")
                    await self?.handleSuccessfulAcceptance(share: share)
                    
                case .failure(let error):
                    log("💥 [FAILURE] Share acceptance failed with error", category: "CloudKitShareHandler")
                    log("💥 [FAILURE] Error: \(error)", category: "CloudKitShareHandler")
                    
                    if let ckError = error as? CKError {
                        log("💥 [FAILURE] CKError code: \(ckError.code.rawValue)", category: "CloudKitShareHandler")
                        log("💥 [FAILURE] CKError localizedDescription: \(ckError.localizedDescription)", category: "CloudKitShareHandler")
                        log("💥 [FAILURE] CKError domain: \((ckError as NSError).domain)", category: "CloudKitShareHandler")
                        
                        // CKErrorのuserInfoも詳細出力
                        if !ckError.userInfo.isEmpty {
                            log("💥 [FAILURE] CKError userInfo:", category: "CloudKitShareHandler")
                            for (key, value) in ckError.userInfo {
                                log("💥 [FAILURE]   \(key): \(value)", category: "CloudKitShareHandler")
                            }
                        }
                    }
                    
                    await self?.handleAcceptanceError(error, for: shareID)
                }
            }
        }
        
        operation.acceptSharesResultBlock = { result in
            Task { @MainActor in
                log("🏁 [BATCH RESULT] Batch operation completed", category: "CloudKitShareHandler")
                
                switch result {
                case .success():
                    log("🎉 [BATCH RESULT] All shares in batch processed successfully", category: "CloudKitShareHandler")
                case .failure(let error):
                    log("💥 [BATCH RESULT] Batch operation failed", category: "CloudKitShareHandler")
                    log("💥 [BATCH RESULT] Batch error: \(error)", category: "CloudKitShareHandler")
                    
                    if let ckError = error as? CKError {
                        log("💥 [BATCH RESULT] Batch CKError code: \(ckError.code.rawValue)", category: "CloudKitShareHandler")
                        log("💥 [BATCH RESULT] Batch CKError description: \(ckError.localizedDescription)", category: "CloudKitShareHandler")
                    }
                }
            }
        }
        
        // 🌐 [CONTAINER] コンテナとオペレーション実行
        let container = CKContainer(identifier: metadata.containerIdentifier)
        log("🌐 [CONTAINER] Using container: \(metadata.containerIdentifier)", category: "CloudKitShareHandler")
        log("🌐 [CONTAINER] Adding operation to container", category: "CloudKitShareHandler")
        
        container.add(operation)
        log("✅ [CONTAINER] Operation added to container successfully", category: "CloudKitShareHandler")
    }
    
    /// 🎉 [SUCCESS HANDLER] 共有受諾成功後の処理
    @MainActor
    private func handleSuccessfulAcceptance(share: CKShare) async {
        log("🎉 [IDEAL SHARING] Share acceptance successful - performing post-acceptance verification", category: "CloudKitShareHandler")
        
        // 🔍 [VERIFICATION] Shared DBの状態をログ出力と検証
        await logSharedDatabaseState()
        
        // 🔍 [VERIFICATION] 受諾したShareが実際にアクセス可能かテスト
        await verifyShareAccess(share: share)
        
        // MessageSyncServiceに更新をトリガー
        if #available(iOS 17.0, *) {
            MessageSyncService.shared.checkForUpdates()
            log("🔄 [IDEAL SHARING] Triggered MessageSyncService update", category: "CloudKitShareHandler")
        }
        
        // CloudKitChatManagerに通知
        NotificationCenter.default.post(name: .cloudKitShareAccepted, object: share)
        
        // UIに成功を通知（必要に応じて）
        NotificationCenter.default.post(name: Notification.Name("CloudKitShareAcceptedSuccessfully"), object: share)
        
        log("✅ [IDEAL SHARING] Post-acceptance processing completed", category: "CloudKitShareHandler")
    }
    
    /// 🔍 [VERIFICATION] 受諾したShareへのアクセス検証
    @MainActor
    private func verifyShareAccess(share: CKShare) async {
        do {
            let container = CKContainer(identifier: "iCloud.forMarin-test")
            let sharedDB = container.sharedCloudDatabase
            
            // 🔍 [VERIFICATION] CKShareの詳細情報をログ出力
            log("🔍 [VERIFICATION] CKShare recordID: \(share.recordID.recordName)", category: "CloudKitShareHandler")
            log("🔍 [VERIFICATION] CKShare URL: \(share.url?.absoluteString ?? "nil")", category: "CloudKitShareHandler")
            log("🔍 [VERIFICATION] CKShare owner: \(share.owner.userIdentity.nameComponents?.formatted() ?? "nil")", category: "CloudKitShareHandler")
            log("🔍 [VERIFICATION] CKShare participants count: \(share.participants.count)", category: "CloudKitShareHandler")
            if let perm = share.currentUserParticipant?.permission {
                log("🔍 [VERIFICATION] My permission: \(perm)", category: "CloudKitShareHandler")
            }
            for p in share.participants {
                let name = p.userIdentity.nameComponents?.formatted() ?? "<unknown>"
                log("🔍 [VERIFICATION] Participant name=\(name), role=\(p.role), perm=\(p.permission), status=\(p.acceptanceStatus)", category: "CloudKitShareHandler")
            }
            
            // 共有ゾーンの存在確認
            let zones = try await sharedDB.allRecordZones()
            log("🔍 [VERIFICATION] Available shared zones: \(zones.count)", category: "CloudKitShareHandler")
            for zone in zones {
                log("🔍 [VERIFICATION] Zone: \(zone.zoneID.zoneName) (owner: \(zone.zoneID.ownerName))", category: "CloudKitShareHandler")
            }
            
            // ChatSessionレコードの検索
            let query = CKQuery(recordType: "ChatSession", predicate: NSPredicate(value: true))
            let (results, _) = try await sharedDB.records(matching: query, resultsLimit: 10)
            log("🔍 [VERIFICATION] ChatSession records in Shared DB: \(results.count)", category: "CloudKitShareHandler")
            
            for (recordID, result) in results {
                switch result {
                case .success(let record):
                    if let roomID = record["roomID"] as? String {
                        log("🔍 [VERIFICATION] Found ChatSession: \(roomID) in zone: \(recordID.zoneID.zoneName)", category: "CloudKitShareHandler")
                    }
                case .failure(let error):
                    log("⚠️ [VERIFICATION] Failed to fetch ChatSession record: \(error)", category: "CloudKitShareHandler")
                }
            }
            
        } catch {
            log("❌ [VERIFICATION] Failed to verify share access: \(error)", category: "CloudKitShareHandler")
            if let ckError = error as? CKError {
                log("❌ [VERIFICATION] CKError code: \(ckError.code.rawValue)", category: "CloudKitShareHandler")
                log("❌ [VERIFICATION] CKError description: \(ckError.localizedDescription)", category: "CloudKitShareHandler")
            }
        }
    }
    
    /// 🩺 [PRE-DIAGNOSIS] 受諾前のCloudKit状態診断
    @MainActor
    private func performPreAcceptanceDiagnosis(metadata: CKShare.Metadata) async {
        log("🩺 [PRE-DIAGNOSIS] === Starting Pre-Acceptance CloudKit Diagnosis ===", category: "CloudKitShareHandler")
        
        do {
            let container = CKContainer(identifier: metadata.containerIdentifier)
            
            // 1. アカウント状態確認
            let accountStatus = try await container.accountStatus()
            log("🩺 [PRE-DIAGNOSIS] Account Status: \(accountStatusDescription(accountStatus))", category: "CloudKitShareHandler")
            
            if accountStatus != .available {
                log("⚠️ [PRE-DIAGNOSIS] WARNING: CloudKit account not available - this may cause acceptance to fail", category: "CloudKitShareHandler")
            }
            
            // 2. Private DB状態確認
            let privateDB = container.privateCloudDatabase
            log("🩺 [PRE-DIAGNOSIS] Checking Private DB state...", category: "CloudKitShareHandler")
            
            let privateZones = try await privateDB.allRecordZones()
            log("🩺 [PRE-DIAGNOSIS] Private DB zones count: \(privateZones.count)", category: "CloudKitShareHandler")
            
            // 3. Shared DB状態確認
            let sharedDB = container.sharedCloudDatabase
            log("🩺 [PRE-DIAGNOSIS] Checking Shared DB state...", category: "CloudKitShareHandler")
            
            let sharedZones = try await sharedDB.allRecordZones()
            log("🩺 [PRE-DIAGNOSIS] Shared DB zones count: \(sharedZones.count)", category: "CloudKitShareHandler")
            
            // 4. 接続性テスト（軽量）
            log("🩺 [PRE-DIAGNOSIS] Testing basic CloudKit connectivity...", category: "CloudKitShareHandler")
            // 単純にゾーン一覧取得で接続性確認（既に実行済み）
            log("✅ [PRE-DIAGNOSIS] CloudKit connectivity test successful", category: "CloudKitShareHandler")
            
        } catch {
            log("⚠️ [PRE-DIAGNOSIS] Pre-acceptance diagnosis failed: \(error)", category: "CloudKitShareHandler")
            
            if let ckError = error as? CKError {
                log("⚠️ [PRE-DIAGNOSIS] CKError during diagnosis: \(ckError.code.rawValue) - \(ckError.localizedDescription)", category: "CloudKitShareHandler")
                
                // 特定のエラーについて詳細分析
                switch ckError.code {
                case .notAuthenticated:
                    log("💥 [PRE-DIAGNOSIS] CRITICAL: User not authenticated to CloudKit", category: "CloudKitShareHandler")
                case .networkUnavailable, .networkFailure:
                    log("💥 [PRE-DIAGNOSIS] CRITICAL: Network issues detected", category: "CloudKitShareHandler")
                case .quotaExceeded:
                    log("💥 [PRE-DIAGNOSIS] CRITICAL: CloudKit quota exceeded", category: "CloudKitShareHandler")
                case .requestRateLimited:
                    log("💥 [PRE-DIAGNOSIS] WARNING: Rate limited - may affect acceptance", category: "CloudKitShareHandler")
                default:
                    log("⚠️ [PRE-DIAGNOSIS] Other CKError: \(ckError.code)", category: "CloudKitShareHandler")
                }
            }
        }
        
        log("🩺 [PRE-DIAGNOSIS] === End Pre-Acceptance Diagnosis ===", category: "CloudKitShareHandler")
    }
    
    /// 🔧 [UTILITY] CKAccountStatus を人間が読める文字列に変換
    private func accountStatusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "Available"
        case .noAccount:
            return "No Account"
        case .restricted:
            return "Restricted"
        case .couldNotDetermine:
            return "Could Not Determine"
        case .temporarilyUnavailable:
            return "Temporarily Unavailable"
        @unknown default:
            return "Unknown (\(status.rawValue))"
        }
    }
    
    /// 💀 [ERROR HANDLER] 受諾エラーの処理
    @MainActor
    private func handleAcceptanceError(_ error: Error, for shareID: CKRecord.ID) async {
        log("❌ [IDEAL SHARING] Failed to accept CloudKit share: \(error)", category: "CloudKitShareHandler")
        
        if let ckError = error as? CKError {
            log("❌ [IDEAL SHARING] CKError code: \(ckError.code.rawValue)", category: "CloudKitShareHandler")
            log("❌ [IDEAL SHARING] CKError description: \(ckError.localizedDescription)", category: "CloudKitShareHandler")
            
            // 既に受諾済みのエラーは正常とみなす
            if ckError.code == .unknownItem || ckError.code == .alreadyShared {
                log("ℹ️ [IDEAL SHARING] Share already accepted (treating as success): \(ckError.code)", category: "CloudKitShareHandler")
                // 既に受諾済みの場合も成功扱いで後続処理を実行
                
                // MessageSyncServiceに更新をトリガー
                if #available(iOS 17.0, *) {
                    MessageSyncService.shared.checkForUpdates()
                }
                return
            }
            
            if let userInfo = ckError.userInfo[NSUnderlyingErrorKey] as? Error {
                log("❌ [IDEAL SHARING] Underlying error: \(userInfo)", category: "CloudKitShareHandler")
            }
        }
        
        // 処理済みセットから削除（再試行を可能にする）
        handledShareIDs.remove(shareID)
        
        // UIにエラーを通知
        NotificationCenter.default.post(name: Notification.Name("CloudKitShareAcceptanceFailed"), object: error)
    }
    
    /// 🔍 [DEBUG] Shared DB の状態をログ出力
    @MainActor
    private func logSharedDatabaseState() async {
        do {
            let container = CKContainer(identifier: "iCloud.forMarin-test")
            let sharedDB = container.sharedCloudDatabase
            
            // Shared DBのゾーン一覧
            let zones = try await sharedDB.allRecordZones()
            log("🔍 [IDEAL SHARING] Shared DB zones after acceptance: \(zones.count)", category: "CloudKitShareHandler")
            for zone in zones {
                log("🔍 [IDEAL SHARING] Zone: \(zone.zoneID.zoneName) (owner: \(zone.zoneID.ownerName))", category: "CloudKitShareHandler")
            }
            
            // ChatSessionレコードの検索
            let query = CKQuery(recordType: "ChatSession", predicate: NSPredicate(value: true))
            let (results, _) = try await sharedDB.records(matching: query)
            log("🔍 [IDEAL SHARING] ChatSession records in Shared DB: \(results.count)", category: "CloudKitShareHandler")
            
        } catch {
            log("⚠️ [IDEAL SHARING] Failed to query Shared DB state: \(error)", category: "CloudKitShareHandler")
        }
    }
}

// MARK: - Notification Names Extension

extension Notification.Name {
    // cloudKitShareAccepted は CloudKitChatManager.swift で既に定義済み
    static let cloudKitShareAcceptedSuccessfully = Notification.Name("CloudKitShareAcceptedSuccessfully")
    static let cloudKitShareAcceptanceFailed = Notification.Name("CloudKitShareAcceptanceFailed")
}
