# シグナルレコード上書き可能設計 - 実装計画

## 概要

PIP が消えたりついたりする問題の根本原因は、CloudKit に古いシグナルレコード（Offer/Answer/ICE）が蓄積し、ポーリング時に再取得されてリセットが発生することです。

本実装では、シグナルレコードを「上書き可能」な設計に変更し、レコードの蓄積を防ぎます。

---

## 現在の実装

### RecordID 命名規則（現在）

```swift
// CloudKitSchema.swift

// SignalSession（セッション管理）
SS_{sessionKey}
// 例: SS_room_ABC123#_user1abc#_user2xyz

// SignalEnvelope（Offer/Answer SDP）
SE_{sessionKey}_{callEpoch}_{offer|answer}
// 例: SE_room_ABC123#_user1abc#_user2xyz_1767129155213_offer

// SignalIceChunk（ICE Candidate）
IC_{sessionKey}_{callEpoch}_{ownerUserID}_{UUID}
// 例: IC_room_ABC123#_user1abc#_user2xyz_1767129155213__user1abc_A1B2C3D4-E5F6-...
```

### 問題点

1. **SignalEnvelope**: `callEpoch` が RecordID に含まれるため、リトライごとに**新しいレコードが作成**される
2. **SignalIceChunk**: `UUID` が RecordID に含まれるため、ICE 候補ごとに**新しいレコードが作成**される
3. **レコードが削除されない**: 接続確立後も古いレコードが CloudKit に残り続ける
4. **ポーリングで全取得**: `recordZoneChanges(since: nil)` で毎回全レコードを取得し、古いレコードを処理してしまう

### 結果

- 古い Offer 検出 → `scheduleRestartAfterDelay("stale offer after RD")` → PeerConnection リセット → PIP 消える
- 再接続 → PIP 表示 → 古いレコード再検出 → リセット... のループ

---

## 新しい設計

### RecordID 命名規則（新設計）

```swift
// SignalSession（変更なし）
SS_{sessionKey}

// SignalEnvelope（callEpochを除去）
SE_{sessionKey}_{offer|answer}
// 例: SE_room_ABC123#_user1abc#_user2xyz_offer

// SignalIceChunk（UUIDとcallEpochを除去、ownerUserIDで分離）
IC_{sessionKey}_{ownerUserID}
// 例: IC_room_ABC123#_user1abc#_user2xyz__user1abc
```

### 効果

| セッションあたりのレコード数         | 現在                      | 新設計             |
| ------------------------------------ | ------------------------- | ------------------ |
| SignalSession                        | 1                         | 1                  |
| SignalEnvelope (Offer)               | リトライ回数分            | **1**              |
| SignalEnvelope (Answer)              | リトライ回数分            | **1**              |
| SignalIceChunk                       | ICE 候補数 × リトライ回数 | **2** (送信者ごと) |
| **合計（3 リトライ × 20 ICE 候補）** | 1 + 6 + 60 = **67**       | **4**              |

---

## 変更対象ファイル

### 1. `forMarin/Controllers/CloudKitSchema.swift`

RecordID 生成ロジックの変更

```swift
// 変更前
static func signalEnvelopeRecordID(sessionKey: String, callEpoch: Int, envelopeType: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
    return CKRecord.ID(recordName: "SE_\(sessionKey)_\(callEpoch)_\(envelopeType)", zoneID: zoneID)
}

static func signalIceChunkRecordID(sessionKey: String, callEpoch: Int, ownerUserID: String, uuid: UUID = UUID(), zoneID: CKRecordZone.ID) -> CKRecord.ID {
    return CKRecord.ID(recordName: "IC_\(sessionKey)_\(callEpoch)_\(ownerUserID)_\(uuid.uuidString)", zoneID: zoneID)
}

// 変更後
static func signalEnvelopeRecordID(sessionKey: String, envelopeType: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
    // callEpochを除去 → 同じOffer/Answerは上書きされる
    return CKRecord.ID(recordName: "SE_\(sessionKey)_\(envelopeType)", zoneID: zoneID)
}

static func signalIceChunkRecordID(sessionKey: String, ownerUserID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
    // callEpochとUUIDを除去 → 送信者ごとに1レコード（配列で上書き）
    return CKRecord.ID(recordName: "IC_\(sessionKey)_\(ownerUserID)", zoneID: zoneID)
}
```

---

### 2. `forMarin/Controllers/CloudKitChatManager.swift`

#### 2.1 SignalEnvelope 作成ロジック

```swift
// 変更前
private func makeSignalEnvelopeRecord(sessionKey: String,
                                      roomID: String,
                                      ownerUserID: String,
                                      callEpoch: Int,
                                      type: SignalEnvelopeType,
                                      sdp: String,
                                      existing: CKRecord? = nil,
                                      zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKSchema.signalEnvelopeRecordID(sessionKey: sessionKey, callEpoch: callEpoch, envelopeType: type.rawValue, zoneID: zoneID)
    let record = existing ?? CKRecord(recordType: CKSchema.SharedType.signalEnvelope, recordID: recordID)
    // ...
}

// 変更後
private func makeSignalEnvelopeRecord(sessionKey: String,
                                      roomID: String,
                                      ownerUserID: String,
                                      callEpoch: Int,
                                      type: SignalEnvelopeType,
                                      sdp: String,
                                      zoneID: CKRecordZone.ID) async throws -> CKRecord {
    let recordID = CKSchema.signalEnvelopeRecordID(sessionKey: sessionKey, envelopeType: type.rawValue, zoneID: zoneID)

    // 既存レコードがあれば取得して上書き（CloudKitはrecordChangeTagで競合検出）
    let (database, _) = try await resolveZone(for: roomID, purpose: .signal)
    let record: CKRecord
    if let existing = try? await database.record(for: recordID) {
        record = existing
    } else {
        record = CKRecord(recordType: CKSchema.SharedType.signalEnvelope, recordID: recordID)
    }

    record[CKSchema.FieldKey.sessionKey] = sessionKey as CKRecordValue
    record[CKSchema.FieldKey.roomID] = roomID as CKRecordValue
    record[CKSchema.FieldKey.callEpoch] = callEpoch as CKRecordValue  // 最新のepochを記録
    record[CKSchema.FieldKey.ownerUserId] = ownerUserID as CKRecordValue
    record[CKSchema.FieldKey.envelopeType] = type.rawValue as CKRecordValue
    record[CKSchema.FieldKey.payload] = sdp as CKRecordValue
    record[CKSchema.FieldKey.updatedAt] = Date() as CKRecordValue
    return record
}
```

#### 2.2 SignalIceChunk 作成ロジック（配列で上書き）

```swift
// 新しいデータ構造
struct SignalIceChunkSnapshot {
    let recordID: CKRecord.ID
    let sessionKey: String
    let roomID: String
    let callEpoch: Int
    let ownerUserID: String
    let candidates: [String]  // 配列に変更
    let createdAt: Date?
}

// 新しい公開API
func publishIceCandidatesBatch(roomID: String,
                               localUserID: String,
                               remoteUserID: String,
                               callEpoch: Int,
                               newCandidates: [String]) async throws -> SignalIceChunkSnapshot {
    let (database, zoneID) = try await resolveZone(for: roomID, purpose: .signal)
    let sessionKey = signalSessionKey(roomID: roomID, localUserID: localUserID, remoteUserID: remoteUserID)
    let recordID = CKSchema.signalIceChunkRecordID(sessionKey: sessionKey, ownerUserID: localUserID, zoneID: zoneID)

    // 既存レコードを取得（あれば）
    var existingCandidates: [String] = []
    var existingEpoch = callEpoch
    let record: CKRecord
    if let existing = try? await database.record(for: recordID) {
        record = existing
        // 既存の候補を取得
        if let payload = existing[CKSchema.FieldKey.candidate] as? String,
           let data = payload.data(using: .utf8),
           let batch = try? JSONDecoder().decode(IceBatchV1Payload.self, from: data) {
            existingCandidates = batch.candidates
        }
        existingEpoch = existing[CKSchema.FieldKey.callEpoch] as? Int ?? callEpoch
    } else {
        record = CKRecord(recordType: CKSchema.SharedType.signalIceChunk, recordID: recordID)
    }

    // 新しいepochの場合はリセット、同じepochなら追加
    let finalCandidates: [String]
    if callEpoch > existingEpoch {
        // 新しいセッション → 古い候補をクリアして新しい候補のみ
        finalCandidates = newCandidates
    } else {
        // 同じセッション → 既存候補に追加（重複排除）
        let combined = existingCandidates + newCandidates
        finalCandidates = Array(Set(combined))  // 重複排除
    }

    // JSON配列として保存
    let payload = IceBatchV1Payload(v: 1, candidates: finalCandidates)
    let data = try JSONEncoder().encode(payload)
    let json = String(data: data, encoding: .utf8) ?? ""

    record[CKSchema.FieldKey.sessionKey] = sessionKey as CKRecordValue
    record[CKSchema.FieldKey.roomID] = roomID as CKRecordValue
    record[CKSchema.FieldKey.callEpoch] = callEpoch as CKRecordValue
    record[CKSchema.FieldKey.ownerUserId] = localUserID as CKRecordValue
    record[CKSchema.FieldKey.candidate] = json as CKRecordValue
    record[CKSchema.FieldKey.candidateType] = "batch-v1" as CKRecordValue
    record[CKSchema.FieldKey.updatedAt] = Date() as CKRecordValue

    try await database.save(record)

    return SignalIceChunkSnapshot(
        recordID: record.recordID,
        sessionKey: sessionKey,
        roomID: roomID,
        callEpoch: callEpoch,
        ownerUserID: localUserID,
        candidates: finalCandidates,
        createdAt: Date()
    )
}
```

---

### 3. `forMarin/Controllers/P2PController.swift`

#### 3.1 ICE 候補の適用ロジック（重複スキップ）

```swift
// 追加: 適用済みICE候補のフィンガープリントを保持
private var appliedIceCandidateFingerprints: Set<String> = []

// applySignalIceChunk内で重複スキップ
@MainActor
private func applySignalIceChunk(_ chunk: CloudKitChatManager.SignalIceChunkSnapshot) async -> Bool {
    // ... 既存のバリデーション ...

    var appliedCount = 0
    for candidateJson in chunk.candidates {
        // フィンガープリントで重複チェック
        let fingerprint = candidateJson.hashValue.description
        guard !appliedIceCandidateFingerprints.contains(fingerprint) else {
            continue
        }
        appliedIceCandidateFingerprints.insert(fingerprint)

        // ICE候補を適用
        let candidate = decodeCandidate(candidateJson)
        try? await pc?.add(candidate)
        appliedCount += 1
    }

    if appliedCount > 0 {
        log("[P2P] Applied \(appliedCount) new ICE candidates", category: "P2P")
    }
    return appliedCount > 0
}
```

#### 3.2 stale 検出ロジックの変更（リセットからスキップへ）

```swift
// 変更前: stale検出でリセット
if hasSetRemoteDescription {
    scheduleRestartAfterDelay(reason: "stale offer after RD", cooldownMs: 300)
    return true
}

// 変更後: stale検出でスキップ（リセットしない）
if hasSetRemoteDescription {
    log("[P2P] Ignoring stale offer (already have RD, epoch=\(callEpoch))", level: "DEBUG", category: "P2P")
    return false  // リセットせずスキップ
}
```

#### 3.3 セッション開始時のリセット

```swift
// startIfNeeded() 内で適用済みキャッシュをクリア
private func startIfNeeded(roomID: String, myID: String, initialRemoteUserID: String?) async {
    // ...
    appliedIceCandidateFingerprints.removeAll()  // 新しいセッション開始時にクリア
    // ...
}
```

---

## 実装手順

### Phase 1: CloudKitSchema 変更

1. `signalEnvelopeRecordID` から `callEpoch` パラメータを削除
2. `signalIceChunkRecordID` から `callEpoch` と `uuid` パラメータを削除
3. コンパイルエラーを修正

### Phase 2: CloudKitChatManager 変更

1. `makeSignalEnvelopeRecord` を既存レコード取得 → 上書き方式に変更
2. `publishIceCandidatesBatch` を配列マージ方式に変更
3. 古い `publishIceCandidate` メソッドを削除または非推奨化

### Phase 3: P2PController 変更

1. `appliedIceCandidateFingerprints` を追加
2. `applySignalIceChunk` を配列処理+重複スキップに変更
3. stale 検出時の `scheduleRestartAfterDelay` を削除（ログのみに変更）
4. `startIfNeeded` でキャッシュクリア追加

### Phase 4: テスト

1. 新規ルームで接続テスト
2. リトライ発生時の動作確認（古いレコードが蓄積しないこと）
3. PIP が安定表示されることを確認

---

## 後方互換性

### 古い RecordID のレコード

既存の古い RecordID（`SE_{sessionKey}_{callEpoch}_{type}`）のレコードは CloudKit に残りますが、新しい実装では：

1. 新しい RecordID（`SE_{sessionKey}_{type}`）で上書きするため、新規接続には影響なし
2. 古いレコードはポーリングで取得されるが、`epoch < activeCallEpoch` で無視される
3. 時間経過またはルーム削除時に自然消滅

### 移行期間中の対応

- 古いクライアントと新しいクライアントが混在する期間は、両方の RecordID 形式を読み取れるようにする
- 書き込みは新しい形式のみ

---

## リスクと対策

| リスク                     | 影響度 | 対策                                            |
| -------------------------- | ------ | ----------------------------------------------- |
| 競合時のデータ損失         | 低     | CloudKit の楽観的ロックで検出、リトライで上書き |
| 古いクライアントとの非互換 | 低     | 読み取りは両形式対応、書き込みは新形式のみ      |
| ICE 候補の配列が肥大化     | 低     | epoch 変更時にリセット、最大でも 20-30 候補程度 |

---

## 期待される効果

1. **レコード蓄積の解消**: リトライしても同じ RecordID で上書きされるため蓄積しない
2. **stale リセットループの解消**: 古いレコードがないため stale 検出が発生しない
3. **PIP の安定表示**: 接続確立後にリセットされなくなる
4. **CloudKit 負荷軽減**: レコード数が大幅減少（67 → 4）

---

## チェックリスト

### 実装前

- [ ] 現在のシグナルレコード数を CloudKit Dashboard で確認
- [ ] テスト用の新規ルームを作成

### 実装中

- [ ] CloudKitSchema.swift 変更
- [ ] CloudKitChatManager.swift 変更
- [ ] P2PController.swift 変更
- [ ] コンパイル成功確認

### 実装後

- [ ] 新規ルームで接続テスト
- [ ] リトライ動作確認
- [ ] PIP 安定表示確認
- [ ] ログに "stale offer" が出ないことを確認
- [ ] CloudKit Dashboard でレコード数が減少していることを確認

---

## 参考: 変更されるログメッセージ

### 変更前（問題のあるログ）

```
[P2P] Scheduling full reset due to: stale offer after RD
[P2P] Skip ICE chunk (stale epoch) record=IC_...
[P2P] setRemoteDescription(answer) error: Called in wrong state: stable
```

### 変更後（期待されるログ）

```
[P2P] Ignoring stale offer (already have RD, epoch=1234567890)
[P2P] Applied 5 new ICE candidates
[P2P] ✅ Connection established!
```
