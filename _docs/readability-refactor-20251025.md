# 2025-10-25 可読性向上メモ: Avatar Placeholder

## 背景
- `ChatListView` 内でアバターのプレースホルダー形状を `switch` 文と個別 `Shape` 構造体で定義しており、同じ塗りとオーバーレイ処理が繰り返されていた。
- 守るべき実装方針（冗長な定義を避け、シンプルなロジックへ集約）に反していたため、小規模リファクタ対象と判断。

## 対応内容
- `AvatarPlaceholderConfig` を追加し、形状とサイズの対応関係を1箇所に集約。
- `AvatarPlaceholderShape` を実装し、円・角丸矩形・正多角形を単一の `Shape` で描画できるように統合。
- 旧 `PentagonShape` / `HexagonShape` / `OctagonShape` は統合済みのため削除。

## 影響
- 表示サイズとフォントは従来値をそのまま保持。
- SwiftUI の `Shape` API のみを利用しており、副作用のあるロジック変更はなし。
- ビルド/テストは未実施（UI変更なしのため）。

## 今後の検討候補
- `AvatarPlaceholderConfig` の定義を `CloudKitChatManager` が持つshapeインデックス仕様と同期できるようコメント化またはユニットテスト整備。
- placeholder色やフォントをテーマ設定に切り出して、アクセシビリティ調整を容易にする。
