# CKTool セットアップメモ

forMarin リポジトリにおける CloudKit Command Line Tool (cktool) の利用手順を「最小セットアップ → 動作確認 → 運用」の順に整理する。実行ログは 2025-10-03 の Codex セッションで取得したものを記録する。

## 1. 最小セットアップ

### 1.1 前提条件
- cktool は Xcode 13 以降に同梱されるため別途インストール不要。`xcrun cktool` で常に現在選択中の Xcode のバンドルを呼び出せる。
- Apple Developer Program の有効なメンバーシップ (個人 / 法人 / Enterprise) が必要。
- CloudKit Console の Account 設定から CloudKit Management Token を発行し、安全に保管しておく (再表示不可)。
- コマンド確認:
  - `xcrun -f cktool` → `/Applications/Xcode.app/Contents/Developer/usr/bin/cktool`
  - `xcrun cktool --version` → `1.0.23001`

### 1.2 認証トークン登録 (初回のみ)
1. Apple ID で CloudKit Console にサインインし、管理トークンを発行。
2. `xcrun cktool save-token --type management` を実行。Safari が開くので発行済みトークンを貼り付けて保存する (デフォルトでキーチェーン保管)。
3. CI など対話できない環境では `CLOUDKIT_MANAGEMENT_TOKEN` 環境変数で渡す運用も可能。機密情報はシークレットストアに登録し、ジョブ開始時にエクスポートする。
4. トークン不要時は `xcrun cktool remove-token --type management` で削除。
5. ユーザーデータ操作が必要な場合は `--type user` でユーザートークンを保存。ただし有効期限が短いため常時運用には不向き。

## 2. 動作確認

### 2.1 実行コマンド
- `xcrun cktool --help`
- `xcrun cktool --version`
- `xcrun cktool get-teams`

### 2.2 2025-10-03 実行ログ
- `xcrun cktool --help` → 正常終了。`OVERVIEW: CloudKit Command Line Tool` などヘルプが表示されることを確認。
- `xcrun cktool --version` → 正常終了 (`1.0.23001`)。
- `xcrun cktool get-teams`
  - 10:12 JST: ネットワーク制限により `NSURLErrorDomain Code=-1003` (`api.icloud.apple.com` が解決できず) で失敗。
  - 11:04 JST: ネットワーク許可後に再実行し成功。出力 `2YQ8WT2BZY: Yoshiki Tamura` を確認し、Team ID と表示名の取得が完了した。

## 3. スキーマ運用フロー (推奨)
1. **本番または基準環境のスキーマをエクスポートしソース管理する**
   ```bash
   xcrun cktool export-schema \
     --team-id <TEAM_ID> \
     --container-id <CONTAINER_ID> \
     --environment production \
     --output-file Schema/CloudKitSchema.ckdb
   ```
   - 生成された `Schema/CloudKitSchema.ckdb` をリポジトリにコミットし、差分レビューで変更点を把握する。
2. **インポート前に validate-schema で検証する**
   ```bash
   xcrun cktool validate-schema \
     --team-id <TEAM_ID> \
     --container-id <CONTAINER_ID> \
     --environment development \
     --file Schema/CloudKitSchema.ckdb
   ```
   - `✅ Schema is valid.` が出力されれば整合性チェック完了。エラー時は指摘された Record Type / Field を修正する。
3. **開発環境へインポート**
   ```bash
   xcrun cktool import-schema \
     --team-id <TEAM_ID> \
     --container-id <CONTAINER_ID> \
     --environment development \
     --file Schema/CloudKitSchema.ckdb
   ```
   - development 環境のみを書き換える運用とし、本番環境は export 専用とする。
4. **必要に応じて開発環境を本番定義にリセット**
   ```bash
   xcrun cktool reset-schema \
     --team-id <TEAM_ID> \
     --container-id <CONTAINER_ID>
   ```
   - 本番スキーマを複製しつつ開発データを削除する破壊的操作。実行タイミングと権限管理を明確化する。

### 3.1 2025-10-03 実行ログ
- `xcrun cktool export-schema --team-id 2YQ8WT2BZY --container-id iCloud.forMarin-test --environment development --output-file Schema/CloudKitSchema.ckdb`
  - 11:08 JST: 成功。`Schema/CloudKitSchema.ckdb` を新規作成しバージョン管理に追加。
- `xcrun cktool validate-schema --team-id 2YQ8WT2BZY --container-id iCloud.forMarin-test --environment development --file Schema/CloudKitSchema.ckdb`
  - 11:09 JST: 成功。出力 `✅ Schema is valid.` を確認し、インポート前チェックが通ることを確認。

## 4. CI / 自動化のヒント
- トークンは CI プラットフォームのシークレットに保存し、`CLOUDKIT_MANAGEMENT_TOKEN` として注入する。`--token` 引数での直接指定はログ露出のリスクが高いため避ける。
- 管理トークンの有効期限 (既定 1 年) を追跡し、失効前に再発行・更新するスケジュールを運用ルールに含める。
- 複数の Xcode を併用する場合でも `xcrun` を通すことで選択中 Xcode の cktool が呼び出される。
- CI ジョブでは `set -euo pipefail` などを付与し失敗時に早期検出できるようにする。

## 5. データ操作の疎通確認 (任意)
```bash
xcrun cktool query-records \
  --team-id <TEAM_ID> \
  --container-id <CONTAINER_ID> \
  --zone-name _defaultZone \
  --database-type public \
  --environment development \
  --record-type <RECORD_TYPE>
```
- レコード型に queryable フィールド (例: `___recordID`) がない場合はフィルタ条件を指定する。
- ユーザートークンが必要。CI などでは短命なため、基本的には手動検証に留める。

## 6. よくある落とし穴
- Team ID / Container ID の取り違え → `xcrun cktool get-teams` で Team ID を確定し、Container は CloudKit Console や Xcode の Signing & Capabilities で確認する。
- 環境指定ミス → `export-schema` は production / development から選択、`import-schema` は development へ、`reset-schema` は development を本番定義に戻す。
- トークン露出 → 共有環境では `--token` 直渡しを避け、キーチェーン保存または環境変数経由に統一する。
- ネットワーク制限 → Apple API ドメインへの到達性がないと get-teams などが失敗する。VPN/プロキシ設定や許可リストを事前に確認する。

## 7. 最小コマンドセット (コピペ用)
```bash
# 0) ヘルプとバージョン
xcrun cktool --help
xcrun cktool --version

# 1) トークン保存 (初回のみ)
xcrun cktool save-token --type management

# 2) チーム一覧
xcrun cktool get-teams

# 3) 本番スキーマ→ファイル
xcrun cktool export-schema --team-id <TEAM_ID> --container-id <CONTAINER_ID> --environment production --output-file Schema/CloudKitSchema.ckdb

# 4) (任意) スキーマ整合性チェック
xcrun cktool validate-schema --team-id <TEAM_ID> --container-id <CONTAINER_ID> --environment development --file Schema/CloudKitSchema.ckdb

# 5) 開発へ適用
xcrun cktool import-schema --team-id <TEAM_ID> --container-id <CONTAINER_ID> --environment development --file Schema/CloudKitSchema.ckdb

# 6) (必要時) 開発を本番定義にリセット
xcrun cktool reset-schema --team-id <TEAM_ID> --container-id <CONTAINER_ID>
```

## 8. 次のステップ
- CloudKit スキーマファイルのバージョン管理運用 (レビュー、ブランチ戦略、CI 連携) を詰め、必要に応じて Makefile / GitHub Actions の雛形を追加する。
- `validate-schema` コマンドを導入し、インポート前に整合性チェックを組み込む運用を検討する。
