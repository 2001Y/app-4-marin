# P2P/映像が相手側で見えない件 調査メモ（2025-09-26）

対象: コンテナ `iCloud.forMarin-test`（Development）/ ルーム `room_BADCFD65` → `room_F57A4DF5` → 共有受諾 `room_8EE885CD`

## ログからの事実

- CloudKit 初期化/サブスクは正常。チュートリアルメッセージの同期も完了。
- 共有受諾: `room_8EE885CD` で Shared DB ゾーンが 1 件見えており、参加者 Permission は `rawValue: 3`（= READ_WRITE 相当）。
- 自端末の WebRTC:
  - RTCPeerConnection 作成、`sendRecv` の video transceiver 追加、ローカル映像開始まで成功。
  - Offer を保存（"Offer published"）。ICE 候補は 10→20 まで保存ログ（以前のセッションでは 503→2061 による rate limit 多発）。
  - しかし `Remote answer set` も `RTCPeerConnection state=connected` も出ない。
  - `Buffered remote ICE (no remoteDescription yet)` が継続（= RD 未設定のまま候補が溜まる）。
  - `Glare detected (haveLocalOffer & impolite). Ignoring remote offer` あり（衝突時 PN: impolite 側は無視、polite 側が rollback する想定）。

- CKSyncEngine/共有ゾーン:
  - `Shared zone update is not enabled for container` により shared scope の `failedZoneSaves` が発生（ゾーン保存は不可）。
  - 一方で shared DB へのレコード保存（SYS:JOIN、メッセージ）は成功している。

- スキーマ/インデックス:
  - `Field 'recordName' is not marked queryable` が複数箇所で発生（Room.name 命名、参加者推定）— P2P 直接因ではないが副作用あり。

## 原因候補（優先度順）

1. 相手端末が Offer を取り込めず Answer を返していない（最可能）
   - 自端末には `Remote offer/answer set` ログなし。`pending ICE（no RD yet）` が継続。
   - 相手側ログに `Remote offer set → Answer published` が出ていない可能性。

2. CloudKit の 503/2061 によるシグナリング詰まり（ICE 候補の逐次保存）
   - 以前のセッションで候補保存が大量に `Request Rate Limited`。相手側でも Answer/ICE 保存が抑止されていると、オファー取り込み→アンサー作成→保存→配信の鎖が切れる。

3. 共有ゾーンの「ゾーン更新」が不可（`failedZoneSaves`）
   - レコード保存は通っているが、ゾーン保存系は不可。CKSyncEngine の共有スコープでのゾーン更新は権限外（参加者）で失敗するため、不要なゾーン保存が発生していないかを要確認。

## 直近の切り分け（ログのみ）

相手端末側で次の有無を確認:

- `[P2P] Remote offer set. Creating answer...`（無ければ Offer 取り込み未実行）
- `Answer published` / `setRemoteDescription(answer)`（無ければ Answer 未発行）
- `Failed to save signal(kind=answer)`（CKError=2061/503 等）

自端末側:

- `Applied RTCSignal records: N` の中身が `answer` を含んだか（RD 設定ログから推定）。
- `RTCPeerConnection state changed: connected` の有無。

## 実装上の匂いと根本対策（方針準拠）

- 匂い: ICE 候補を 1 件=1 レコードで高頻度保存 → CloudKit の rate limit に弱い。
  - 対策（構造修正）: 1 秒間バッファして `ice-pack`（複数候補を結合）を 1 レコードに上書き保存。受信側は分解して `addIce`。
  - 効果: 書込み回数の桁落ち、503/2061 回避、シグナリングの頑健化。

- 匂い: 共有スコープでゾーン保存が走っている（`failedZoneSaves`）。
  - 対策: 共有DBでは「ゾーン保存（save）」は行わない。必要なのはレコード保存とサブスクリプションのみ。

- インデックス不足（recordName Queryable 等）。
  - 対策: Console > Schema > Record Types で `recordName: Queryable`、`RoomMember.userId: Queryable`、`Message.roomID: Queryable`、`Message.timestamp: Sortable` を追加（開発/本番で個別に）。

## Console 側チェック（Development）

- room_8EE885CD の Zone Details:
  - "Zone wide sharing is enabled" = ON（既にレコード保存は通っているが、明示確認）
- インデックスを追加し Save（上記参照）。

## まとめ

現状のログからは、**相手側が Offer を取り込めず Answer を返していない**ことが原因で、remoteTrack が来ていません。併発している CloudKit のレート制限（2061）と共有スコープでの `failedZoneSaves` は交渉を不安定化させています。まずは相手端末ログで `Remote offer set / Answer published` の有無を確認しつつ、構造対策（ICE パック化）と Console のインデックス整備を行うのが最短です。

