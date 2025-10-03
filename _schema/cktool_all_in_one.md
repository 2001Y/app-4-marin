# CKTool セットアップ & 運用コマンド

cktoolは、Appleが提供するCloudKit用コマンドラインツールで、スキーマのエクスポートやインポート、検証、トークン管理などをスクリプトやCIから自動化するための公式手段。

CloudKit Command Line Tool (cktool) をどのプロジェクトでも再利用できるよう、セットアップから日常運用までを 1 つのファイルにまとめた。

---

## 0. TL;DR (最速チェックリスト)
```bash
# 0-1. cktool が使えるか確認
xcrun cktool --version

# 0-2. 管理トークンを保存 (初回のみ)
xcrun cktool save-token --type management

# 0-3. Team ID と Container ID を把握
xcrun cktool get-teams
plutil -extract "com.apple.developer.icloud-container-identifiers" json -o - 【例：forMarin/forMarin.entitlements】

# 0-4. スキーマ運用 (export → validate → import)
xcrun cktool export-schema --team-id 【例：2YQ8WT2BZY】 --container-id 【例：iCloud.forMarin-test】 --environment development --output-file _schema/CloudKitSchema.ckdb
xcrun cktool validate-schema --team-id 【例：2YQ8WT2BZY】 --container-id 【例：iCloud.forMarin-test】 --environment development --file _schema/CloudKitSchema.ckdb
xcrun cktool import-schema --team-id 【例：2YQ8WT2BZY】 --container-id 【例：iCloud.forMarin-test】 --environment development --file _schema/CloudKitSchema.ckdb
```

---

## 1. 前提条件と初期セットアップ

### 1.1 必要要件
- macOS + Xcode 13 以降 (cktool は Xcode に同梱される)
- Apple Developer Program (Individual / Organization / Enterprise) の有効なメンバーシップ
- CloudKit Console で発行済みの CloudKit Management Token

### 1.2 cktool の存在確認
```bash
# cktool のバージョンとパスを確認
xcrun cktool --version
xcrun -f cktool
```
成功例:
```
$ xcrun cktool --version
1.0.23001

$ xcrun -f cktool
/Applications/Xcode.app/Contents/Developer/usr/bin/cktool
```

### 1.3 管理トークンの保存
```bash
# Safari が起動し、CloudKit Console に貼り付けるプロンプトが表示される
xcrun cktool save-token --type management
```
- デフォルトでは macOS キーチェーンに安全に保存される
- CI で利用する場合は `CLOUDKIT_MANAGEMENT_TOKEN` を設定し、例として `xcrun cktool save-token --type management --destination file --filepath 【例：/tmp/cktool_token.json】` のように指定できる

### 1.4 トークンの確認 & 削除
```bash
# 保存済みトークンが有効か、チームが取得できるか確認
xcrun cktool get-teams

# 不要な場合は削除
xcrun cktool remove-token --type management
```

---

## 2. Team ID と Container ID の取得手順

### 2.1 Team ID
```bash
xcrun cktool get-teams
```
出力例:
```
2YQ8WT2BZY: Yoshiki Tamura
```
- 左側の `2YQ8WT2BZY` が Team ID (プロジェクトごとに異なる)

### 2.2 Container ID
CloudKit の Container ID は以下のいずれかで確認できる。

**A. CloudKit Console で確認**
1. https://icloud.developer.apple.com/ にアクセス
2. 対象アプリの Container を開く (例: `iCloud.com.example.app`)
3. 画面右上の情報パネルに Container Identifier が表示される

**B. Xcode の Signing & Capabilities で確認**
1. Xcode でターゲットを選択
2. `Signing & Capabilities` → `iCloud` → `Containers`
3. チェックされているエントリが Container ID (例: `iCloud.forMarin-test`)

**C. コマンドラインで entitlements から抽出**
```bash
plutil -extract "com.apple.developer.icloud-container-identifiers" json -o - 【例：forMarin/forMarin.entitlements】
```
出力例:
```
[
  "iCloud.forMarin-test"
]
```
- 複数ターゲットがある場合はそれぞれの entitlements を確認する

---

## 3. ディレクトリ構成 (推奨)
```
project-root/
├─ _schema/               # CloudKit スキーマのバージョン管理用
│  ├─ CloudKitSchema.ckdb
│  └─ cktool_all_in_one.md (このファイル)
├─ _docs/cktool_setup.md  # プロジェクト固有の詳細ドキュメント (任意)
└─ ...
```
- `_schema/CloudKitSchema.ckdb` を Git 管理して差分レビューする
- プロジェクト固有の手順は `_docs/cktool_setup.md` 等へ追記

---

## 4. 日常運用コマンド集
以降のコマンドはすべて実プロジェクトに合わせて差し替える。例として forMarin の `Team ID=2YQ8WT2BZY`、`Container ID=iCloud.forMarin-test` を使用。

### 4.1 スキーマのエクスポート
```bash
mkdir -p _schema
xcrun cktool export-schema \
  --team-id 【例：2YQ8WT2BZY】 \
  --container-id 【例：iCloud.forMarin-test】 \
  --environment development \
  --output-file _schema/CloudKitSchema.ckdb
```
- `--environment production` に切り替えれば本番スキーマを取得できる

### 4.2 スキーマの整合性検証 (必須)
```bash
xcrun cktool validate-schema \
  --team-id 【例：2YQ8WT2BZY】 \
  --container-id 【例：iCloud.forMarin-test】 \
  --environment development \
  --file _schema/CloudKitSchema.ckdb
```
- 成功時: `✅ Schema is valid.`

### 4.3 開発環境へのインポート
```bash
xcrun cktool import-schema \
  --team-id 【例：2YQ8WT2BZY】 \
  --container-id 【例：iCloud.forMarin-test】 \
  --environment development \
  --file _schema/CloudKitSchema.ckdb
```

### 4.4 開発環境のリセット (破壊的)
```bash
xcrun cktool reset-schema \
  --team-id 【例：2YQ8WT2BZY】 \
  --container-id 【例：iCloud.forMarin-test】
```
- production のスキーマをコピーし、development 上のレコードを全削除する

### 4.5 任意: レコード疎通テスト
```bash
xcrun cktool query-records \
  --team-id 【例：2YQ8WT2BZY】 \
  --container-id 【例：iCloud.forMarin-test】 \
  --zone-name 【例：_defaultZone】 \
  --database-type public \
  --environment development \
  --record-type 【例：Room】
```
- ユーザートークン (`xcrun cktool save-token --type user`) が別途必要

---

## 5. トラブルシューティング
| 症状 | 主な原因 | 対処 |
| --- | --- | --- |
| `NSURLErrorDomain Code=-1003` | Apple API ドメインへ到達できない (ネットワーク制限) | VPN / FW / DNS 設定を確認し、`api.icloud.apple.com` への接続を許可 |
| `401 Unauthorized` | トークン未保存 / 期限切れ | `xcrun cktool save-token --type management` で再保存、CloudKit Console で再発行 |
| `Schema validation failed` | `.ckdb` 内に不整合 | エラーメッセージに従いフィールド定義を修正し、再度 `validate-schema` |
| `No such container` | Container ID のタイプミス | `plutil -extract ...` で再確認 (例: `iCloud.forMarin-test`)
