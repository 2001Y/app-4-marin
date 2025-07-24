# MarinEE 開発タスクリスト

## 1️⃣ データモデル／CloudKit
- [ ] 画像 1 枚 = 1 メッセージ構造へ移行
  - Message.imageLocalURLs を削除し assetPath:String? へ置換
  - CloudKit `MessageCK` スキーマに `assetData` と `reactions:String`, `favoriteCount:Int64` 追加

### 実装方針
* Message に `var assetPath:String?` を追加、`imageLocalURLs` を削除。
* CloudKit Record `MessageCK` に `asset <Asset>` フィールドを追加。
* 既存送信ロジック : 各画像ごとに `Message` 作成 → ファイル保存 → `CKAsset` に添付。
* 受信ロジック : `asset` が存在する場合ローカルへ保存し `assetPath` に書き込み。
* Migration : 起動時に `imageLocalURLs` が非空のレコードを分割して新構造にコピーし旧レコードを削除。
* DB リセット : `UserDefaults` フラグ `schemaVersion` を保持し、変更検知でストア削除。

## 2️⃣ 画像送信フロー
- [ ] 写真ライブラリから選択した画像を **即時** 送信

### 実装方針
* `PhotosPicker` の `item.loadTransferable(type: UIImage.self)` 完了時点で send。
* 送信 UI: ループで `sendImage(uiImg)` を呼び、各 send が非同期アップロード。
* サムネイル View は `alignment: .trailing` を確定させ `Spacer()` 位置を修正。
- [ ] 送信後サムネイルを右揃えで表示

## 3️⃣ ヒーロープレビュー UX 強化
- [ ] アニメ速度調整 (response 0.22)
- [ ] 角丸補間 (60→0)
- [ ] ボタンを最前面にし、右上 × / 右下 ↓
- [ ] 画像見切れバグ除去

## 4️⃣ 画像リアクション / お気に入り
- [ ] HeroImagePreview に QuickEmojiBar 常設
- [ ] ❤️ が 1 回以上 → 写真アプリお気に入り連動
- [ ] お気に入りは favoriteCount に集計 (連打可)
- [ ] スライダーのリアクションは内部合算で表示

## 5️⃣ テキストメッセージ
- [ ] 吹き出し内インライン編集で TextField が正しく機能

## 6️⃣ ナビゲーション
- [ ] TabView 横スワイプでカレンダーへ遷移復活

## 7️⃣ UI
- [ ] ヘッダーに「あと◯日」キャプション追加

## 8️⃣ 設定画面
- [ ] 自動ダウンロード ON/OFF
- [ ] 写真アプリお気に入り同期 ON/OFF

---
> チェックボックスが全て完了したらリリース候補