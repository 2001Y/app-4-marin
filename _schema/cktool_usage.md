# CKTool 運用ガイド (_schema)
cktoolは、Appleが提供するCloudKit用コマンドラインツールで、スキーマのエクスポートやインポート、検証、トークン管理などをスクリプトやCIから自動化するための公式手段です。

forMarin の CloudKit スキーマ (`_schema/CloudKitSchema.ckdb`) を管理するための cktool 利用手順をまとめる。基本的なセットアップや詳細解説は `_docs/cktool_setup.md` を参照すること。プロジェクト固有の値は【例：〜〜】で示す。

## 必要環境
- macOS 上で Xcode 13 以降がインストール済み (`xcrun cktool` が利用可能であること)
- Apple Developer Program の有効なチームメンバーシップ
- CloudKit Console で発行した CloudKit Management Token を `xcrun cktool save-token --type management` で保存済み

## 最小確認コマンド
```bash
xcrun cktool --help
xcrun cktool --version
xcrun cktool get-teams
```
- `xcrun cktool get-teams` の出力例: `2YQ8WT2BZY: Yoshiki Tamura`

## スキーマ運用フロー (forMarin の例)
1. **スキーマをエクスポートして `_schema/CloudKitSchema.ckdb` に保存**
   ```bash
   xcrun cktool export-schema \
     --team-id 【例：2YQ8WT2BZY】 \
     --container-id 【例：iCloud.forMarin-test】 \
     --environment development \
     --output-file _schema/CloudKitSchema.ckdb
   ```
2. **インポート前に整合性を検証**
   ```bash
   xcrun cktool validate-schema \
     --team-id 【例：2YQ8WT2BZY】 \
     --container-id 【例：iCloud.forMarin-test】 \
     --environment development \
     --file _schema/CloudKitSchema.ckdb
   ```
   - 成功時出力: `✅ Schema is valid.`
3. **開発環境へ適用 (必要なときのみ)**
   ```bash
   xcrun cktool import-schema \
     --team-id 【例：2YQ8WT2BZY】 \
     --container-id 【例：iCloud.forMarin-test】 \
     --environment development \
     --file _schema/CloudKitSchema.ckdb
   ```
4. **開発環境を本番定義へリセット (破壊的操作)**
   ```bash
   xcrun cktool reset-schema \
     --team-id 【例：2YQ8WT2BZY】 \
     --container-id 【例：iCloud.forMarin-test】
   ```

## 運用メモ
- `_schema/CloudKitSchema.ckdb` は Git で差分管理し、レビューで変更箇所を確認する
- CI で自動検証する場合、`validate-schema` を必ず挟み失敗時はジョブを停止させる
- ネットワーク制限環境では Apple API ドメイン (`api.icloud.apple.com`) へ接続できるよう VPN / FW 設定を確認する
- チーム ID や Container ID を変更する際は、各コマンド引数とアプリの `CloudKitContainerIdentifier` を合わせて更新する (forMarin の例: `iCloud.forMarin-test`)
