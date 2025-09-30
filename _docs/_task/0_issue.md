# Issue Backlog (as of 2025-09-22)

## CloudKit Logging & Observability

- ログカテゴリを `account / zone / share / subs / push / sync / error` へ再編し、`OSLog` / `LogCollector` のサインポスト整備をまだ実施していない。push 到達遅延 (`latency_ms`)、`CKSyncEngine` イベント、BG タスクのステータスを一貫したカテゴリで出力できるようヘルパを追加する必要がある。
- `CloudKitChatManager` のログカテゴリ最適化（特に `share` / `zone` の詳細ログ削減）と本番向けフィルタリングポリシーを策定する。

## CloudKit 招待リテンション

- 未承諾ゾーンを 7 日でクリーンアップするポリシーは実装済みだが、実機での定期確認手順と QA ケースが未策定。`performInviteMaintenance` の削除対象（roomID / shareID）をログ化し、`modelContext.fetch` で SwiftData 側の整合性を確認するチェックリストとダッシュボードを用意する。
- 受理（accepted）0 件かつ retention 経過の共有は CKShare を削除（`unknownItem` は成功扱い）。受理が 1 件でもある共有は保持する。

## PiP / P2P 追加確認

- 参加完了システムメッセージが共有ゾーンに保存され、両端末の `MessageSyncPipeline` で確実に取得されるか要実機検証。timestamp を含めたレコード内容の整合性チェックが未実施。
- `CloudKitChatManager` のリモート参加者解決強化により `CKError.invalidArguments` が消える想定だが、テレメトリ上で再発がないか確認が必要。
- 要件: アプリ内の小型・可搬オーバーレイのみを採用（システム PiP は不採用、録画は要件外）。
- 実装: `RTCMTLVideoView` + 最前面 `UIWindow`（PassthroughWindow を `UIWindowScene` に添付）で常時最前面表示。ドラッグ/リサイズ可、位置は正規化座標で保持。
- 動作: リモートトラック到着で自動表示、トラック消失/フレーム途絶で自動非表示。PiP ボタンは設けない。
- 非対応時: エラーログのみ出力（例: `overlay.unsupported.os_version|no_active_scene|metal|renderer_init_failed`）。
- パフォーマンス: デフォルト 30fps にスロットル、熱/メモリ圧で縮小＋ 15–20fps へ低減（`overlay.degraded.*`）。
## 2025-09-22 以降の検討事項（招待UI/P2P関連）

- 受諾成功時の自動遷移オプション
  - 現状は受諾成功で .openChatRoom をポストしつつ、Root 側で安全に遷移。要件に応じて設定トグル化も検討可能。

- P2P 可観測性の強化
  - ICE/TURN 接続状態、candidate 数、RD 設定を UI デバッグオーバーレイで確認できるようにする（本番ビルドでは隠す）。

- 共有ゾーンの健全性ダッシュボード
  - 共有DBのゾーン/トークン/保留件数を設定画面に簡易表示し、復旧（フルリセット）操作を1箇所に集約。

- QR/招待のオンボーディング整流化
  - FeaturesPage 直下の動線（名前→招待/参加→QR）を1画面フロー化する案を検討。

（メモ）本イテレーションでの既知問題は解消済み。新規に観測された問題があれば随時ここへ追記する。

---

## 2025-09-24 対処・修正記録（実ログに基づく根本原因と低レイヤー改善）

以下は 2025-09-24 の実行ログ解析と、それに基づく実装修正・追加ログのまとめ（守るべき実装方針準拠）。

### A. 招待/参加QRモーダルの二重表示／誤表示
- 原因: CloudKit クエリ（参加者数）失敗時のフォールバックで「不在」と誤判定。
- 対応: ChatView の招待表示条件を「オーナー かつ remoteUserID 空」のローカル判定へ変更。

### B. 送信後に入力欄が空にならないことがある
- 原因: UI反映タイミングの希少レース。
- 対応: send/commitSend を @MainActor 化し、State 反映をメインスレッドへ固定。

### C. 共有受諾後、2回読み込まないとチャットに遷移しない
- 原因: 共有受諾→遷移通知の順序が、SwiftData 反映より先行。
- 対応: 受諾直後に bootstrapSharedRooms を先行実行→その後に .openChatRoom 通知。

### D. 双方向オンラインでカメラ許可は来るが PiP が表示されない
- 原因: PiP 表示が「リモート到着前提」。
- 対応: リモート未着でもローカル映像を表示（フォールバック）、到着後は小窓重ね。

### E. 共有DBの書込み拒否
- 原因: CloudKit コンテナ設定（Shared Database update 未有効）。
- 対応: ダッシュボード側の設定が必要（コードでは変更なし）。

### 追加ログ（ローカルLAN vs インターネット差の可視化）
- P2P開始時に NWPath（wifi/cellular/constrained）をログ。
- ICE候補タイプ（host/srflx/relay）を10件単位と接続確立時にサマリ出力。

### 変更ファイル概要
- FloatingVideoOverlay.swift: ローカル映像フォールバック。
- ChatView.swift: 招待表示条件をローカル判定化。
- CloudKitShareHandler.swift: 受諾→ローカル反映→遷移通知の順序へ。
- P2PController.swift: NWPath/ICE候補タイプの追加ログ。
- ChatViewHelpers.swift: @MainActor 化。
