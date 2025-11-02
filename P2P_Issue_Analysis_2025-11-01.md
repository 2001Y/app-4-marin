# P2P ビデオ通話問題の調査・分析レポート

作成日：2025 年 11 月 1 日

## 目次

1. [問題の概要](#問題の概要)
2. [初期状態の分析](#初期状態の分析)
3. [根本原因の特定](#根本原因の特定)
4. [実施した修正](#実施した修正)
5. [現在の状況](#現在の状況)
6. [今後の対応](#今後の対応)

## 問題の概要

### 症状

- チャットメッセージの送受信は正常に動作
- P2P ビデオ通話が開始されない
- 画面を開いた際に自動的にビデオ通話が始まるはずが、接続されない

### 環境

- CloudKit Container: `iCloud.forMarin-test`
- 環境: Development
- 参加者 1: `_203df8ff164babea80e2df3c156f4f62`（オーナー）
- 参加者 2: `_9e7af715e3ec99432bc570b0463689cd`（参加者）

## 初期状態の分析

### ログから判明した問題

1. **P2P 接続の失敗**

```
[INFO] [P2P] Signal prep: remote user unresolved - scheduling retry
[INFO] [P2P] primaryCounterpartUserID no remote participant found
```

2. **参加者情報の不足**

```
Total participants=1
```

相手の参加者情報が取得できていない

3. **Permission Failure（初期ログ）**

```
"Permission Failure" (10/2007); server message = "Shared zone update is not enabled for container"
```

## 根本原因の特定

### 1. メッセージは同期されるが RoomMember が同期されない

#### 分析結果

- メッセージレコード：正常に同期 ✅
- RoomMember レコード：同期されない ❌

#### 原因

1. **オーナー側**：RoomMember レコードを Private DB に作成していた
2. **参加者側**：RoomMember レコードが作成されていなかった

### 2. CloudKit の設定問題

初期状態では「Zone wide sharing」の権限設定に問題があった可能性があるが、確認したところ既に正しく設定されていた：

- Zone wide sharing: 有効
- Public Permissions: Read Write
- 両参加者: READ_WRITE 権限、ACCEPTED

### 3. コードレベルの問題

#### オーナー側（CloudKitChatManager.swift）

```swift
// line 1140: privateDBに作成していた
_ = try await privateDB.save(memberRecord)
```

#### 参加者側（CloudKitShareHandler.swift）

```swift
// RoomMemberレコードの作成処理が実装されていなかった
```

## 実施した修正

### 1. オーナーの RoomMember レコード作成（CloudKitChatManager.swift）

```swift
// line 1129-1144
// オーナーのRoomMemberレコードを作成
let memberRecordID = CKSchema.roomMemberRecordID(userId: ownerRecordName, zoneID: zoneID)
let memberRecord = CKRecord(recordType: CKSchema.SharedType.roomMember, recordID: memberRecordID)
memberRecord[CKSchema.FieldKey.userId] = ownerRecordName as CKRecordValue

let displayName = (UserDefaults.standard.string(forKey: "myDisplayName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
if !displayName.isEmpty {
    memberRecord[CKSchema.FieldKey.displayName] = displayName as CKRecordValue
}

do {
    _ = try await privateDB.save(memberRecord)
    log("✅ Created owner's RoomMember record roomID=\(normalizedRoomID)", category: "share")
} catch {
    log("⚠️ Failed to create owner's RoomMember record: \(error)", category: "share")
}
```

### 2. 参加者の RoomMember レコード作成（CloudKitShareHandler.swift）

```swift
// line 327-345
// RoomMemberレコードも作成して自分のプロフィール情報を共有
log("[DEBUG] [SYSJOIN] Attempting to create RoomMember record for userID=\(userID) in room=\(roomID)", category: "CloudKitShareHandler")
let memberRecordID = CKSchema.roomMemberRecordID(userId: userID, zoneID: zoneID)
let memberRecord = CKRecord(recordType: CKSchema.SharedType.roomMember, recordID: memberRecordID)
memberRecord[CKSchema.FieldKey.userId] = userID as CKRecordValue
if !displayName.isEmpty && displayName != userID {
    memberRecord[CKSchema.FieldKey.displayName] = displayName as CKRecordValue
}

do {
    let savedMemberRecord = try await container.sharedCloudDatabase.save(memberRecord)
    log("✅ [SYSJOIN] Posted RoomMember record=\(savedMemberRecord.recordID.recordName) room=\(roomID)", category: "CloudKitShareHandler")
} catch {
    log("⚠️ [SYSJOIN] Failed to post RoomMember record for room=\(roomID): \(error)", category: "CloudKitShareHandler")
    // エラーの詳細をログ出力
    if let ckError = error as? CKError {
        log("⚠️ [SYSJOIN] CKError code=\(ckError.code.rawValue) desc=\(ckError.localizedDescription)", category: "CloudKitShareHandler")
    }
}
```

### 3. P2P 再起動の遅延追加（CloudKitChatManager.swift）

```swift
// line 2625-2638
// P2P再起動: リモート参加者が設定された場合、P2Pを再起動
if !isLocal && P2PController.shared.currentRoomID == roomID {
    let myID = (currentUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    log("[P2P] Remote participant resolved via RoomMember, triggering P2P restart for room=\(roomID) remote=\(normalizedID)", category: "share")

    // 少し遅延を入れてからP2Pを再起動
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒待機
        if P2PController.shared.currentRoomID == roomID {
            P2PController.shared.closeIfCurrent(roomID: roomID, reason: "remote-participant-resolved")
            P2PController.shared.startIfNeeded(roomID: roomID, myID: myID, remoteID: normalizedID)
        }
    }
}
```

### 4. デバッグログの強化

#### P2PController.swift

```swift
// prepareSignalChannel内でremote ID解決のログを追加
if resolvedRemoteUserID == nil {
    if let hinted = (!remoteHint.isEmpty ? remoteHint : nil) {
        resolvedRemoteUserID = hinted
        log("[P2P] Using hinted remote ID: \(String(hinted.prefix(8)))", category: "P2P")
    } else if let counterpart = CloudKitChatManager.shared.primaryCounterpartUserID(roomID: currentRoomID) {
        resolvedRemoteUserID = counterpart
        log("[P2P] Using counterpart from CloudKit: \(String(counterpart.prefix(8)))", category: "P2P")
    } else {
        log("[P2P] No remote ID available yet, will retry", category: "P2P")
    }
}
```

#### CloudKitChatManager.swift

```swift
// primaryCounterpartUserIDにログ追加
if let remote = remoteParticipant {
    log("[P2P] primaryCounterpartUserID found remote participant: \(String(remote.userID.prefix(8))) for room=\(roomID)", category: "share")
    return remote.userID.trimmingCharacters(in: .whitespacesAndNewlines)
} else {
    log("[P2P] primaryCounterpartUserID no remote participant found for room=\(roomID). Total participants=\(participants.count)", category: "share")
    return nil
}
```

### 5. P2P リトライ間隔の最適化

```swift
// P2PController.swift
// 初回は短い間隔でリトライ
let retryDelay: UInt64 = initial ? 500 : 2000
scheduleSignalInfraRetry(afterMilliseconds: retryDelay)
```

### 6. 共有 URL 生成時のログ追加

```swift
// CloudKitChatManager.swift line 1152
log("📎 [SHARE URL] Generated share URL for roomID=\(normalizedRoomID): \(url.absoluteString)", category: "share")
```

### 7. MessageSyncPipeline のデバッグログ強化（2025/11/02 実施）

#### processNonMessageRecords メソッドへの詳細ログ追加

```swift
// MessageSyncPipeline.swift line 597-628
private func processNonMessageRecords(_ records: [CKRecord], roomFilter: String?) async {
    // ... 既存コード ...

    log("[DEBUG] [MessageSyncPipeline] processNonMessageRecords called with \(records.count) records roomFilter=\(roomFilter ?? "nil")", category: "MessageSyncPipeline")

    for record in records {
        let recordType = record.recordType
        log("[DEBUG] [MessageSyncPipeline] Processing record type=\(recordType) recordName=\(record.recordID.recordName)", category: "MessageSyncPipeline")

        if recordType == CKSchema.SharedType.roomMember {
            let roomID = record.recordID.zoneID.zoneName
            log("[DEBUG] [MessageSyncPipeline] Found RoomMember record=\(record.recordID.recordName) room=\(roomID) roomFilter=\(roomFilter ?? "nil")", category: "MessageSyncPipeline")
            if let filter = roomFilter, filter != roomID {
                log("[DEBUG] [MessageSyncPipeline] Skipping RoomMember record due to roomFilter mismatch room=\(roomID) filter=\(filter)", category: "MessageSyncPipeline")
                continue
            }
            log("[DEBUG] [MessageSyncPipeline] Processing RoomMember record=\(record.recordID.recordName) room=\(roomID)", category: "MessageSyncPipeline")
            do {
                await CloudKitChatManager.shared.ingestRoomMemberRecord(record)
                roomMemberApplied += 1
                log("[DEBUG] [MessageSyncPipeline] Successfully ingested RoomMember record=\(record.recordID.recordName) room=\(roomID)", category: "MessageSyncPipeline")
            } catch {
                log("⚠️ [MessageSyncPipeline] Failed to ingest RoomMember record=\(record.recordID.recordName) room=\(roomID): \(error)", category: "MessageSyncPipeline")
            }
            continue
        }
        // ... 既存コード ...
    }
}
```

#### ingestRoomMemberRecord メソッドへの詳細ログ追加

```swift
// CloudKitChatManager.swift line 2583-2650
@MainActor
func ingestRoomMemberRecord(_ record: CKRecord) async {
    log("[DEBUG] [SIGNAL] ingestRoomMemberRecord called record=\(record.recordID.recordName) recordType=\(record.recordType)", category: "share")

    let zoneID = record.recordID.zoneID
    let roomID = zoneID.zoneName
    guard !roomID.isEmpty else {
        log("⚠️ [SIGNAL] Empty roomID in RoomMember record=\(record.recordID.recordName)", category: "share")
        return
    }

    let scope: RoomScope = zoneID.ownerName.isEmpty ? .private : .shared
    cache(roomID: roomID, scope: scope, zoneID: zoneID)

    log("[DEBUG] [SIGNAL] Zone info roomID=\(roomID) scope=\(scope) ownerName=\(zoneID.ownerName)", category: "share")

    // ... 既存の処理に詳細ログを追加 ...

    log("[DEBUG] [SIGNAL] Processing RoomMember record=\(record.recordID.recordName) room=\(roomID) userID=\(String(normalizedID.prefix(8))) isLocal=\(isLocal) current=\(String(current.prefix(8)))", category: "share")

    // ... 処理後 ...

    log("[SIGNAL] Ingested RoomMember record=\(record.recordID.recordName) room=\(roomID) userID=\(String(normalizedID.prefix(8))) isLocal=\(isLocal) participants=\(participantsAfter)", category: "share")
}
```

#### MessageSyncPipeline での RoomMember 処理時のエラーハンドリング追加

```swift
// MessageSyncPipeline.swift line 608-619
if record.recordType == CKSchema.SharedType.roomMember {
    let roomID = record.recordID.zoneID.zoneName
    if let filter = roomFilter, filter != roomID { continue }
    log("[DEBUG] [MessageSyncPipeline] Processing RoomMember record=\(record.recordID.recordName) room=\(roomID)", category: "MessageSyncPipeline")
    do {
        await CloudKitChatManager.shared.ingestRoomMemberRecord(record)
        roomMemberApplied += 1
    } catch {
        log("⚠️ [MessageSyncPipeline] Failed to ingest RoomMember record=\(record.recordID.recordName) room=\(roomID): \(error)", category: "MessageSyncPipeline")
    }
    continue
}
```

## 現在の状況

### 動作している部分 ✅

1. チャットルームの作成
2. 共有 URL の生成
3. メッセージの送受信
4. CloudKit Zone wide sharing の設定

### 動作していない部分 ❌

1. RoomMember レコードの相互同期
2. P2P ビデオ通話の自動開始

### 最新のログ分析

#### 2025/11/01 18:44 時点

```
[INFO] [MessageSyncPipeline] [P2P] Applied RoomMember records count=1
[INFO] [share] [P2P] primaryCounterpartUserID no remote participant found for room=room_B52397A7. Total participants=1
```

#### 2025/11/02 14:32-14:45 時点（最新）

```
[INFO] [MessageSyncPipeline] [P2P] Applied RoomMember records count=2
[INFO] [share] [P2P] primaryCounterpartUserID no remote participant found for room=room_D32CC988. Total participants=1
```

**問題：`Applied RoomMember records count=2`が出力されているが、詳細なデバッグログが出力されていない**

### 現在の課題（2025/11/02）

1. **デバッグログが出力されない問題**

   - `[DEBUG] [MessageSyncPipeline] processNonMessageRecords called with X records` が出力されていない
   - `[DEBUG] [MessageSyncPipeline] Processing record type=...` が出力されていない
   - `[DEBUG] [SIGNAL] ingestRoomMemberRecord called record=...` が出力されていない
   - **原因の可能性**: アプリが再ビルドされていない、または別のコードパスで処理されている

2. **RoomMember レコードの同期が不完全**

   - `Applied RoomMember records count=2` は出力されているが、`primaryCounterpartUserID`でリモート参加者が見つからない
   - 自分自身の RoomMember レコードのみが処理されている可能性

3. **CKSyncEngine との連携**
   - `MessageSyncPipeline.processNonMessageRecords`が呼ばれていない可能性
   - CKSyncEngine のデリゲートメソッドから直接処理されている可能性を調査中

### 考えられる原因

1. **アプリが再ビルドされていない**

   - 追加したデバッグログのコードは存在するが、実行されていない
   - クリーンビルドが必要

2. **別のコードパスで処理されている**

   - `processNonMessageRecords`が呼ばれず、別の場所で RoomMember レコードが処理されている可能性
   - CKSyncEngine のデリゲートメソッドから直接処理されている可能性

3. **ログレベルの問題**

   - デバッグログがフィルタリングされている可能性（低い）

4. **参加者側の RoomMember レコード作成の問題**
   - 参加者が Shared DB に RoomMember レコードを作成しているが、オーナー側で同期されていない
   - Zone-wide sharing の動作を再確認が必要

## 今後の対応

### 即時対応（優先度：高）

1. **アプリのクリーンビルドと再実行**

   ```bash
   # Xcodeでクリーンビルド
   Cmd+Shift+K → Cmd+B → Cmd+R
   ```

   - 追加したデバッグログが正しく実行されることを確認
   - 以下のログが出力されることを確認：
     - `[DEBUG] [MessageSyncPipeline] processNonMessageRecords called with X records`
     - `[DEBUG] [MessageSyncPipeline] Processing record type=RoomMember...`
     - `[DEBUG] [SIGNAL] ingestRoomMemberRecord called record=...`

2. **完全な再テスト手順**

   - 両端末でアプリを完全終了
   - Xcode でクリーンビルド実行
   - 新しいチャットルームを作成
   - 共有 URL をコピーして相手に送信
   - 相手が共有 URL から参加
   - ログを確認

3. **デバッグログの確認**
   - `processNonMessageRecords`が呼ばれているか確認
   - RoomMember レコードが正しく処理されているか確認
   - `ingestRoomMemberRecord`が呼ばれているか確認

### 確認すべきログ

#### 相手側で参加時

```
[DEBUG] [SYSJOIN] Attempting to create RoomMember record for userID=_9e7af71... in room=room_...
✅ [SYSJOIN] Posted RoomMember record=RM__9e7af71... room=room_...
```

#### MessageSyncPipeline での処理（追加したデバッグログ）

```
[DEBUG] [MessageSyncPipeline] processNonMessageRecords called with X records roomFilter=room_...
[DEBUG] [MessageSyncPipeline] Processing record type=RoomMember recordName=RM_...
[DEBUG] [MessageSyncPipeline] Found RoomMember record=RM_... room=room_... roomFilter=room_...
[DEBUG] [MessageSyncPipeline] Processing RoomMember record=RM_... room=room_...
[DEBUG] [SIGNAL] ingestRoomMemberRecord called record=RM_... recordType=RoomMember
[DEBUG] [SIGNAL] Zone info roomID=room_... scope=shared ownerName=_...
[DEBUG] [SIGNAL] Processing RoomMember record=RM_... room=room_... userID=_... isLocal=false current=_...
[DEBUG] [MessageSyncPipeline] Successfully ingested RoomMember record=RM_... room=room_...
[SIGNAL] Ingested RoomMember record=RM_... room=room_... userID=_... isLocal=false participants=2
```

#### オーナー側で RoomMember 同期後

```
[SIGNAL] Ingested RoomMember record=RM__9e7af71... room=room_... userID=_9e7af71... isLocal=false
[P2P] Remote participant resolved via RoomMember, triggering P2P restart
[P2P] primaryCounterpartUserID found remote participant: _9e7af71... for room=room_...
```

### 中期対応（優先度：中）

1. **エラーハンドリングの改善**

   - RoomMember 作成失敗時のリトライ処理
   - より詳細なエラーログ

2. **デバッグツールの追加**
   - 参加者リストを表示する UI
   - CloudKit 同期状態を確認するデバッグビュー

### まとめ

本件は、P2P 接続に必要な参加者情報（RoomMember レコード）が適切に同期されていないことが根本原因です。コードレベルの修正は完了していますが、以下の問題が残っています：

1. **デバッグログが出力されない問題**

   - 追加したデバッグログのコードは存在するが、実行時に出力されていない
   - アプリの再ビルドが必要、または別のコードパスで処理されている可能性

2. **RoomMember レコードの同期が不完全**

   - `Applied RoomMember records count=2`が出力されているが、リモート参加者が見つからない
   - 自分自身の RoomMember レコードのみが処理されている可能性

3. **次のステップ**
   - クリーンビルドを実行してデバッグログが正しく出力されることを確認
   - デバッグログの出力内容を分析して、RoomMember レコードの処理フローを特定
   - 必要に応じて、CKSyncEngine のデリゲートメソッドからの処理も調査

CloudKit の設定（Zone wide sharing、権限）は正しく設定されており、メッセージ送受信が正常に動作していることから、インフラレベルの問題ではないことが確認されています。

---

## 更新履歴

- **2025/11/01**: 初版作成
- **2025/11/02**: MessageSyncPipeline と CloudKitChatManager へのデバッグログ追加、現在の課題と現状を追記
