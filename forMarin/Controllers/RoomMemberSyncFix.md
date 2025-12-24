# RoomMember userId Field Sync Issue - Root Cause Analysis and Solution

## 問題の根本原因

### 1. CKSyncEngineのフィールド取得制限
- `CKSyncEngine`は`desiredKeys`を直接指定できない
- `MessageSyncPipeline`の`fetchRecordZoneChanges`は`desiredKeys`を指定できるが、CKSyncEngineは自動同期のため制御が難しい

### 2. 型の不整合（既に修正済み）
- 旧コード: `memberRecord[CKSchema.FieldKey.userId] = userID as NSString`
- 新コード: `memberRecord[CKSchema.FieldKey.userId] = userID as CKRecordValue`

## 実装された解決策

### 1. 型の統一
すべてのRoomMemberフィールドをCKRecordValueとして設定：

```swift
// CKSyncEngineManager.swift
record[CKSchema.FieldKey.userId] = userID as CKRecordValue
record[CKSchema.FieldKey.displayName] = displayName as CKRecordValue

// CloudKitShareHandler.swift (iOS 17未満の場合)
memberRecord[CKSchema.FieldKey.userId] = userID as CKRecordValue
memberRecord[CKSchema.FieldKey.displayName] = displayName as CKRecordValue

// CloudKitChatManager.swift
memberRecord[CKSchema.FieldKey.userId] = ownerRecordName as CKRecordValue
memberRecord[CKSchema.FieldKey.displayName] = displayName as CKRecordValue
```

### 2. MessageSyncPipelineでのフィールド指定
```swift
private let messageDesiredKeys: [String] = [
    // ... 他のフィールド
    // RoomMember fields
    CKSchema.FieldKey.userId,
    CKSchema.FieldKey.displayName,
    CKSchema.FieldKey.avatarAsset,
    // ... その他のフィールド
]
```

### 3. フィールド取得の柔軟な実装
```swift
private func snapshot(from record: CKRecord) -> ParticipantProfileSnapshot {
    var userID = ""
    
    // 様々な型に対応
    if let stringValue = record[CKSchema.FieldKey.userId] as? String {
        userID = stringValue
    } else if let nsStringValue = record[CKSchema.FieldKey.userId] as? NSString {
        userID = nsStringValue as String
    } else if let ckRecordValue = record[CKSchema.FieldKey.userId] {
        userID = String(describing: ckRecordValue)
    }
    
    // フェイルセーフ: recordNameから抽出（RM_userID形式）
    if userID.isEmpty && record.recordID.recordName.hasPrefix("RM_") {
        userID = String(record.recordID.recordName.dropFirst(3))
    }
    
    // ... 残りの処理
}
```

## P2P接続の診断強化

### 1. ビデオストリーム診断
```swift
// P2PController.swift
func diagnoseVideoState() {
    // ... 既存の診断
    
    // UI側の状態も診断
    log("[P2P] UI State:", category: "P2P")
    log("[P2P]   - Local video view: \(localVideoView != nil ? "attached" : "NOT attached")", category: "P2P")
    log("[P2P]   - Remote video view: \(remoteVideoView != nil ? "attached" : "NOT attached")", category: "P2P")
    
    if remoteVideoView == nil && remoteTrack != nil {
        log("[P2P] ⚠️ ISSUE: Remote track exists but no view attached - this is why remote video is not visible", category: "P2P")
        log("[P2P] ⚠️ Solution: Ensure remoteVideoView is set and remoteTrack.add(remoteVideoView) is called", category: "P2P")
    }
}
```

### 2. オンライン状態トラッキング
```swift
// ChatViewHelpers.swift
func handleViewAppearance() {
    // オンライン状態の詳細なトラッキング
    log("👁️ [ONLINE] === CHAT OPENED ===", category: "ChatView")
    log("👁️ [ONLINE] Room: \(roomID)", category: "ChatView")
    log("👁️ [ONLINE] Current user: \(String(myID.prefix(8)))", category: "ChatView")
    log("👁️ [ONLINE] Total participants: \(participants.count) (local: \(localCount), remote: \(remoteCount))", category: "ChatView")
    
    // 各参加者の詳細情報
    for participant in participants {
        log("👁️ [ONLINE]   - userID: \(String(participant.userID.prefix(8)))", category: "ChatView")
        log("👁️ [ONLINE]   - role: \(role)", category: "ChatView")
        log("👁️ [ONLINE]   - isLocal: \(isLocal)", category: "ChatView")
        log("👁️ [ONLINE]   - displayName: \(participant.displayName ?? "nil")", category: "ChatView")
    }
    
    // P2P接続条件の確認
    if remoteCount == 0 {
        log("👁️ [ONLINE] ⚠️ No remote participant found - P2P connection cannot be established", category: "ChatView")
    } else {
        log("👁️ [ONLINE] ✅ Remote participant found - P2P connection can proceed", category: "ChatView")
    }
}
```

## トラブルシューティング

### 症状1: Remote video not visible
**原因**: `remoteVideoView`がnilまたは未接続
**解決**: ログで「Remote track exists but no view attached」を確認し、UIの接続を修正

### 症状2: RoomMember userID empty
**原因**: CKSyncEngineがフィールドを部分的にしか同期していない
**解決**: 
1. 最新のコード（CKRecordValue使用）を実行
2. recordNameからのフェイルセーフ抽出が動作
3. MessageSyncPipelineの再同期を待つ

### 症状3: No remote participant found
**原因**: RoomMemberレコードが未同期
**解決**: 
1. CloudKit Dashboardでレコードの存在を確認
2. プッシュ通知の受信を確認
3. MessageSyncPipelineの同期ログを確認

## まとめ

メッセージ送信と同じ仕組みで実装することで、RoomMemberの同期問題を根本的に解決しました。詳細なログ機能により、問題の診断と解決が容易になっています。
