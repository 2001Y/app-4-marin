# P2P 映像未表示の根本原因と最終対策

本ドキュメントは 2025-10-13 の障害ログを踏まえて実施した恒久対応を整理したもの。CloudKit 上の `SignalMailbox` 方式は廃止し、新しいシグナリングスキーマと P2P 制御フローに全面移行した。

## 1. 参加者解決の恒久対策
- **根本原因**: 参加者 ID を `recordName` ベースのクエリで抽出しており、CloudKit の制約により常に `Invalid Arguments` で失敗。結果として remote ID が空のまま WebRTC を開始していた。
- **対策**:
  - `CloudKitChatManager.primaryCounterpartUserID` を追加し、SwiftData へ保存済みの参加者スナップショットから即時解決。
  - 解決に失敗した場合はセッション準備を中断し、ログに記録することで “remote 未解決” 状態を把握しやすくした。

## 2. シグナリングスキーマの再設計
- **旧構造**: 1 ユーザー 1 レコードの `SignalMailbox` に Offer/Answer/ICE を上書き保存。競合やレート制限の温床となっていた。
- **新構造**:
  - `SignalSession`: ルーム + 2者ペアのキーを持つ単一レコード。現在の `callEpoch` を保持。
  - `SignalEnvelope`: `callEpoch` ごとに Offer/Answer を 1 レコードずつ保持。書き込み競合が発生しない。
  - `SignalIceChunk`: ICE 候補を 1 件ずつ保存する append-only レコード。サーバーの changeTag 競合を回避。
  - すべてのレコード ID が決定的（`roomID#lo#hi`）に生成されるため、クエリレスでフェッチ可能。

## 3. レートリミットと競合の解消
- Offer/Answer/ICE は append 専用レコードとし、`mutateSignalMailbox` による楽観ロックは廃止。
- 競合が起きる要素が無くなったため `Server Record Changed` と `Request Rate Limited` の連鎖は発生しない。

## 4. WebRTC 側の状態管理刷新
- `P2PController` は新しいシグナルレコードを購読し、`sessionKey` と `callEpoch` で整合性を検証。
- 新しい `applySignalEnvelope` / `applySignalIceChunk` では以下を実施:
  - セッションキー不一致や古いエポックは即座に破棄。
  - 新しいエポックが届いた場合は `hasSetRemoteDescription` をリセットし、安全に再ネゴシエート。
  - ICE 候補はレコード ID 単位で重複排除しつつ、remoteDescription が届くまでバッファリング。
- `publishOffer` / `publishAnswer` / `publishIceCandidate` は CloudKitChatManager の新 API を利用して append-only 保存。

## 5. Glare とフォールバック処理
- polite / impolite ロールを `sessionKey` に基づいて決定し、Glare 時には impolite 側の Offer を破棄する従来仕様を維持。
- 新しいシグナル構造により衝突後も履歴が明瞭になり、リセット直後に旧 Offer が再適用される問題を解消。

## 6. ログと可観測性
- Envelope/ICE 適用時にセッション／エポックの整合性を必ずログ出力。
- 連続して同じ ICE が届いた場合は recordID ベースで無視するため、ログに “Buffered / Duplicate” が明示される。

## 7. 今後の運用指針
- Signal レコードは append 専用のためクリーンアップは CloudKit のレコード上限に達した際に個別対応。必要に応じて `SignalSession.activeCallEpoch` を基準に古い ICE を削除するメンテナンスタスクを追加する。
- 参加者情報は SwiftData が正となるため、CloudKit 側で取得失敗してもローカルキャッシュから復元できる。

---
- 対象ログ: `_logs/202510130147.log`（`nl -ba` で採番した行番号を参照）
- 参考資料: `_docs/2025-10-13-webrtc-log-analysis.md`（旧構造の問題点とログタイムライン）
