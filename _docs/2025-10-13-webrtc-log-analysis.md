# 2025-10-13 01:47 ログ解析レポート

## ログ概要
- ファイル: `_logs/202510130147.log`
- 総行数: 2,007 行
- 収集環境: Debug ビルド（dSYM 未生成警告あり, 行1）

## 時系列ハイライト
| # | 行 | イベント | 詳細 |
|---|---|---|---|
|1|1-35|初期化|CloudKitChatManager 初期化と Push 登録、環境確認。DBサブスクリプション確立。|
|2|72-80|room_2B73226B 作成|チュートリアルメッセージをシードし共有ゾーン作成、MessageStore 起動。|
|3|83-119|最初の P2P 開始|ローカル ID 更新を契機に WebRTC 接続開始。ただし remote ID は空。ローカル映像キャプチャ開始（行119-123）。|
|4|97,107,130|参加者解決失敗|room_2B73226B の相手ユーザ解決に失敗しプレフィッチも空振り。|
|5|202|CloudKit スロットリング|失敗率上昇に伴い CloudKit 側でスロットリングが発動。|
|6|270-276|シグナリング書き込み失敗|Owner 追加時に ServiceUnavailable、ICE 公開で Request Rate Limited が発生。|
|7|312-318|競合 & 無効パラメータ|ICE 保存時に `Server Record Changed` が多発、Mailbox チャンネル準備で `Field 'recordName' is not marked queryable`（Invalid Arguments）。|
|8|320-347|リモート解決→即再接続|remote=_203df8f が解決し再度 P2P 起動。しかしナビゲーションで close され idle に戻る。|
|9|503-536|Mailbox グレアと ICE 競合|Mailbox にリモート offer が到着 → Impolite glare として破棄。以後も複数回 glare（例: 行504, 534, 762）。|
|10|585-624|追加 ICE 公開|新エポックで再度 Offer/ICE を発行するも並行で競合エラー継続。|
|11|1053-1238|room_0ECE649F 共有化|CloudKitShareHandler が共有ゾーンを設定。SwiftData へ ChatRoom 作成。|
|12|1245-1285|共有側 P2P開始|共有ルームで再び remote 空のまま P2P 開始。ローカル映像キャプチャ, ICE 収集開始。|
|13|1431-1517|再 Offer & capture|新エポックで Offer を発行。ローカル映像は継続するが remote 受信ログ無し。|
|14|1473-1478|参加者解決障害|room_0ECE649F / room_AF6F13C7 ともに `Field 'recordName' is not marked queryable` の Invalid Arguments で参加者解決に失敗。|
|15|1603|Mailbox 準備再び失敗|共有側で再度 `Field 'recordName' is not marked queryable` が発生。|
|16|1626-1713|再 Offer / ICE 競合|新しいエポックで Offer 発行。ICE 公開時に `Server Record Changed` が多数発生（行1690-1710）。|
|17|1389, 1710+|CloudKit 再スロットリング|失敗蓄積で再度スロットリング通知。以後も ICE 競合が続く。|

## 繰り返し観測された異常
- **CloudKit スロットリング**: 行202, 1389。失敗率が高くバックオフ状態。
- **シグナリング書き込み失敗**:
  - `Request Rate Limited`（行275）: 送信頻度制御が効いておらず短時間に多数の ICE 更新。
  - `Server Record Changed`（行312-314, 1460, 1690-1710 他）: 同一レコードに対する競合保存。Etag 管理または保存ポリシーの不整合が疑われる。
- **Invalid Arguments (`recordName` 非 queryable)**: 行318, 1174, 1430 以降多数。Mailbox/参加者解決で CKQuery に `recordName` 等のクエリ不可キーを使用している可能性。
- **Mailbox glare (Offer 衝突)**: 行504, 534, 762 などで `Glare detected (impolite)`。双方が同時に Offer 発行。
- **リモートトラック未検知**: ログ中に remote track 追加や `setRemoteDescription` 成功を示すログが存在せず、全てローカル側イベントで終了。

## P2P 信号経路メモ
- ローカル映像は各セッションで `startCapture` まで進む（行119, 361, 1277, 1517）が、リモート SDP/ICE 受信ログが無い。
- Mailbox は複数回 `onZoneChanged` を受信するが `Mailbox ignored (epoch=0)`（行1567）など初期化状態が見られる。
- グレア検知後に polite モードでのフォールバックや Offer/Answer 再調整が行われていない。

## 参加者解決/プロフィール関連
- `Failed to infer remote participant` が複数回発生（行107, 1174, 1473 等）。Invalid Arguments エラーのため、CloudKit 側のインデックス設定やクエリ方式を見直す必要がある。
- プロファイル取得が失敗したままでも UI による再試行が頻繁に走り (`prefetch profiles start` → `still no counterpart`)、結果として余計な CloudKit 呼び出しを増やしている。

## 次の検証で確認すべきポイント
1. CloudKit レコード設計: Mailbox レコードに対し `recordName` でのクエリを行っていないか、必要なインデックス/`recordType` 構成を再設計。
2. シグナリング保存: `modifyRecords` 時の `savePolicy` や ETag 更新処理を確認し、`Server Record Changed` を減らすための単一ライター保証またはバージョン管理が必要。
3. Glare 処理: polite/impolite ロールの決め方と再オファー時のバックオフ戦略を実装（ログ上は impolite で破棄し続けている）。
4. Remote SDP 受信ログ: `setRemoteDescription` や `onAddStream` 相当のログが存在しないため、受信フローに計測ログを追加して欠落箇所を特定する。
5. 参加者解決: `remote` ID が空のまま P2P を開始しており、UI からの自動再接続がループしている。CloudKit でのプロファイル同期完了を待つ機構を検討。

## 本日の対応
- シグナリングを `SignalSession` / `SignalEnvelope` / `SignalIceChunk` の append-only 構成へ移行し、Mailbox 競合を全廃。
- P2P 側はセッションキーとエポックで整合性を確認しつつ、Offer/Answer/ICE を順序適用。
- 参加者解決は SwiftData の `ChatRoom.participants` を正とし、remote 未解決時はシグナリングを起動しない。
