# 4-Marin 開発タスクリスト

## 1️⃣ データモデル／CloudKit

- [x] 画像 1 枚 = 1 メッセージ構造へ移行
  - Message.imageLocalURLs を削除し assetPath:String? へ置換
  - CloudKit `MessageCK` スキーマに `assetData` と `reactions:String`, `favoriteCount:Int64` 追加
- [x] モデル Migration ルーチン（旧 DB→ 新 DB）
- [x] DB リセット機能（公開前なので自動リセットで可）

### 実装方針

- Message に `var assetPath:String?` を追加、`imageLocalURLs` を削除。
- CloudKit Record `MessageCK` に `asset <Asset>` フィールドを追加。
- 既存送信ロジック : 各画像ごとに `Message` 作成 → ファイル保存 → `CKAsset` に添付。
- 受信ロジック : `asset` が存在する場合ローカルへ保存し `assetPath` に書き込み。
- Migration : 起動時に `imageLocalURLs` が非空のレコードを分割して新構造にコピーし旧レコードを削除。
- DB リセット : `UserDefaults` フラグ `schemaVersion` を保持し、変更検知でストア削除。

## 2️⃣ 画像送信フロー

- [x] 写真ライブラリから選択した画像を **即時** 送信
- [x] 送信後サムネイルを右揃えで表示

### 実装方針

- `PhotosPicker` の `item.loadTransferable(type: UIImage.self)` 完了時点で send。
- 送信 UI: ループで `sendImage(uiImg)` を呼び、各 send が非同期アップロード。
- サムネイル View は `alignment: .trailing` を確定させ `Spacer()` 位置を修正。

## 3️⃣ ヒーロープレビュー UX 強化

- [x] アニメ速度調整 (response 0.22)
- [x] 角丸補間 (60→0)
- [x] ボタンを最前面にし、右上 × / 右下 ↓
- [x] 画像見切れバグ除去

## 4️⃣ 画像リアクション / お気に入り

- [x] HeroImagePreview に QuickEmojiBar 常設
- [x] ❤️ が 1 回以上 → 写真アプリお気に入り連動
- [x] お気に入りは favoriteCount に集計 (連打可)
- [x] スライダーのリアクションは内部合算で表示

### 実装方針

- CloudKit `MessageCK` に `reactions:String` を追加（重複絵文字を連結）。
- 「❤️」カウントが 1 以上 → Photos お気に入り同期（設定で ON/OFF）。
- `QuickEmojiBar` を HeroImagePreview 中央に配置。

## 5️⃣ テキストメッセージ

- [x] 吹き出し内インライン編集で TextField が正しく機能

## 6️⃣ ナビゲーション

- [x] TabView 横スワイプでカレンダーへ遷移復活

## 7️⃣ UI

- [x] ヘッダーに「あと ◯ 日」キャプション追加

## 8️⃣ 設定画面

- [x] 自動ダウンロード ON/OFF
- [x] 写真アプリお気に入り同期 ON/OFF

## 9️⃣ 通知許可

- [x] チャット画面初回表示時に通知許可リクエスト

## 10️⃣ 自動ダウンロード

- [x] 設定で有効時、受信画像を自動で写真アプリに保存

---

> チェックボックスが全て完了したらリリース準備完了
