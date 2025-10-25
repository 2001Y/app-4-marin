# forMarin 概要メモ (2025-10-25)

## リポジトリ概観
- P2P チャット & 無音ビデオ通話アプリ（README.md 参照）。
- `forMarin/Controllers` に CloudKit / P2P / 同期管理の主要ロジック、`Views` に SwiftUI 画面群。
- CKSyncEngine ベースの最新実装と、"legacy" と名付けられた旧実装の同居が散見される。

## 今回の調査と変更
- `OfflineManager`（`forMarin/Controllers/OfflineManager.swift`）で OS バージョン判定とキュー統計更新の重複を整理し、可読性を向上。
- NWPath から接続種別を求める分岐も簡素化し、ログ出力が常に最新キュー件数を参照するよう統一。

## 気になる実装メモ
1. `forMarin/Controllers/MessageSyncPipeline.swift:89-100` に "Schema creation flag" コメントが残るが旗本体や設定処理が存在せず、不要なレガシー記述の可能性。
2. 同ファイル `:723-744` で必須フィールド欠落時に `CloudKitChatManager.shared.performCompleteReset` を即実行するガード（`hasTriggeredLegacyReset`）があり、誤検出時でも全リセットされる恐れ。判定ロジックの検証やリカバリ方針の明文化が必要そう。
3. `forMarin/Controllers/UserIDManager.swift:52-108` では "CloudKit必須" としつつ `LegacyDeviceID` を `UserDefaults` に常時書き戻しており、不要な一時データが残存する。旧デバイス ID 運用を継続するなら仕様化、不要なら削除対象候補。

## 追加要件として検討したい項目
- iOS 17 未満を公式にサポートしないか（CKSyncEngine を利用する各機能で明確化すると実装が単純化）。
- CloudKit リセット系の自動実行条件とログ出力フォーマットを仕様化し、リモートサポート時に誤操作を避ける仕組みを設ける。
- Legacy 移行フローが完了済みかを telemetry/log で追跡できるよう、成功フラグと最終実施日時を集計する仕組みがあると便利。

## MCP 利用状況
- DeepWiki / Serena などの MCP サーバーはこの環境で検出できなかったため、ローカルリポジトリ探索で代替。
