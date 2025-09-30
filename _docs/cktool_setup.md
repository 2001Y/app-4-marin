# CKTool セットアップメモ

## 目的
Codex セッションから `cktool` (CloudKit Command Line Tool) を再現性よく利用できるよう、必須要件の確認と利用手順を整理する。

## 環境確認
- `xcrun cktool --help` でヘルプが表示され、コマンドが利用可能であることを確認。
- `xcrun cktool version` 出力: `1.0.23001`
- `xcrun -f cktool` 出力: `/Applications/Xcode.app/Contents/Developer/usr/bin/cktool`

> 上記より Xcode 同梱の CKTool が既に導入済みであることを確認した。

## 認証トークン設定手順
1. Apple Developer Program に登録済みの Apple ID を用意する。
2. `xcrun cktool save-token` を実行し、CloudKit Console で生成した API キーを保存する。
   - 例: `xcrun cktool save-token --type management --api-key-id <鍵ID> --api-key-file <PKCS8鍵ファイル>`
   - キーチェーンに保存する場合は `--destination keychain` (既定値) を利用する。
3. 保存済みトークンは `xcrun cktool get-teams` 等のサブコマンドで利用される。複数アカウントを扱う場合はトークンを切り替える。
4. トークンを削除する場合は `xcrun cktool remove-token` を使用。

## スキーマファイル取得手順
1. スキーマを保存するディレクトリを作成 (例: `mkdir -p Schema`).
2. `xcrun cktool export-schema --team-id <TEAM_ID> --container-id <CONTAINER_ID> --environment <ENV>` を実行し、標準出力をファイルにリダイレクトするか `--output-file` で保存先を指定する。
   - 例: `xcrun cktool export-schema --team-id 2YQ8WT2BZY --container-id iCloud.com.example.app --environment development --output-file Schema/exported_schema.ckdb`
3. 取得したファイルを `validate-schema` や `import-schema` の `--file` 引数に渡す。

## よく使うサブコマンド
- `export-schema` / `import-schema` / `validate-schema`: CloudKit スキーマの取得・反映・検証。
- `reset-schema`: 開発環境スキーマを本番と同期し、同時に開発データを削除。
- `create-record` / `query-records` / `delete-record(s)`: レコード CRUD 操作。
- `get-teams`: 所属チーム一覧を取得し、環境確認に利用。

各コマンドの詳細ヘルプは `xcrun cktool help <subcommand>` で参照する。

## 検証ログ
- `xcrun cktool --help` → 正常終了。
- `xcrun cktool version` → 正常終了 (`1.0.23001`)。
- `xcrun cktool get-teams` → ネットワーク制限により `NSURLErrorDomain Code=-1003` が発生。外部接続が可能な環境または許可設定で再試行する。

## 参考情報
- Apple Developer: CloudKit CKTool ドキュメント (2024年10月時点での最新版に基づく)。
- CKTool は Xcode 13 以降に同梱。最新仕様では CloudKit Console の API キー発行とペアで使用する。

## 次のステップ
- ネットワーク制限が解除された環境で `get-teams` を実行し、トークン保存状態を確認する。
- 本番環境で利用する前に `validate-schema` で整合性チェックを行う。
