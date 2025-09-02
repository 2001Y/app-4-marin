# CloudKit を用いた双方向チャット実装の全体像（現状整理）

本ドキュメントは、forMarin プロジェクトにおける CloudKit ベースの双方向チャット実装について、ユーザーフロー基準で俯瞰しつつ、CloudKit仕様と最新コード実装の対応関係を整理したものです。以前の不具合（招待URL受取・メッセージ受信）に対する修正も反映済みです。

---

## 概要（目的・アーキテクチャ）
- 目的: 2ユーザー間の1対1チャットを CloudKit 共有機能（ゾーン共有 + CKShare）で実現。
- 対応OS: iOS 17以降（本プロジェクトはサポートOSをiOS 17+に制限）。
- ゾーン設計: 1チャット = 1カスタムゾーン（`zoneName = roomID`）。ゾーン所有者が CKShare を作成し、相手を招待して共有。
- データベースの役割:
  - 所有者: 自身の Private DB のカスタムゾーン（所有ゾーン）に対して読み書き。
  - 参加者: Shared DB から所有者の共有ゾーンへ透過アクセス（読み書き）。
- レコード種別（主要）:
  - `ChatSession`（ルート/共有対象）
  - `Message`（メッセージ本体: text/timestamp/attachment）
  - `MessageReaction`（リアクション正規化）

- 通知/同期の前提（重要）:
  - Shared DB では `CKQuerySubscription` は利用不可 → 参加者側は `CKDatabaseSubscription`（silent push）+ 変更トークン同期で差分取得。
  - 所有者側の Private DB は用途に応じて `CKRecordZoneSubscription`/`CKQuerySubscription` も併用可能。
  - iOS 17+ は `CKSyncEngine` により、トークン管理・差分適用を簡潔に実装可能（本実装は独自同期だが移行余地あり）。

---

## Redditの指摘の検証（2021→2025の最新仕様反映）
- 「CloudKitでチャットは作れない」→ 小規模（1対1〜少人数）なら実現可能。リアルタイム性は“ほぼ”レベルで設計する。
- 「レコードの所有者は1人で、複数人での編集ができない」→ `CKShare` によるゾーン共有で、参加者に `.allowReadWrite` を付与すれば複数ユーザーで同一ゾーンへ書き込み可能。
- 「Privateは本人しか見られない」→ 共有受諾後は参加者の Shared DB に所有者ゾーンが出現し、そこで読み書きできる。
- 「Publicは誰でも読めるので不適」→ 本アプリは Public を使用しない。招待ベースのクローズド共有（`publicPermission = .none`）。
- 「共有の受け入れが面倒」→ 公式 URL 受領時は OS が `application(_:userDidAcceptCloudKitShareWith:)` を発火。アプリ内で `CKFetchShareMetadataOperation`→`CKAcceptSharesOperation` により完結可能（メールやiMessageに限定されない）。
- 「Sharedはクエリ購読が使えない」→ 事実。代替として `CKDatabaseSubscription` + 変更トークンで堅牢に同期する（本ドキュメントの推奨構成）。

---

## データモデルと主要CloudKitオブジェクト
- メッセージモデル: `forMarin/Models/Message.swift:4`
  - CloudKit レコード変換: `Message.cloudKitRecord`（text/timestamp/attachment）
  - CloudKit レコード→モデル: `MessageSyncService` 内で作成（`text`/`timestamp`/`attachment` のみ使用。`reactions`/`isSent` はCloudKitへ保存しない）
- チャットルームID生成（HMACで決定的生成）: `forMarin/Models/ChatRoom.swift:33` → `generateDeterministicRoomID(myID:remoteID:)`
- 共有ルーム生成（ゾーン + ChatSession + CKShare バッチ保存）: `forMarin/Controllers/CloudKitChatManager.swift:396` → `createSharedChatRoom(roomID:invitedUserID:)`
- 共有DB用DBサブスクリプション作成: `forMarin/Controllers/CloudKitChatManager.swift:502` → `setupSharedDatabaseSubscriptions()`
- ルーム単位クエリサブスクリプション（所有者のPrivate DB向け）: `forMarin/Controllers/CloudKitChatManager.swift:683` → `setupRoomSubscription(for:)`

- 添付（メディア）:
  - 画像/動画は `CKAsset` を利用。必要に応じて軽量なサムネイルを別レコードとして切り出し、UI初期表示の体感を向上。
  - 大容量運用に備え、メッセージ本体と添付を分離し、転送・再送の失敗時にも部分的に復旧可能にする。

---

## ユーザーフロー別 詳解（CloudKit仕様と実装の対応）

### 1) アプリ起動（初期化・購読）
- 処理:
  - Push 登録 + CloudKit 初期化 + 共有DBサブスクリプション作成。
- 実装:
  - AppDelegate 起動時: `forMarin/AppDelegate.swift:5` → `didFinishLaunchingWithOptions`
    - `CloudKitChatManager.shared` 初期化・内部で現在ユーザーID取得、スキーマ作成/リセットなどを実行。
    - `CloudKitChatManager.shared.setupSharedDatabaseSubscriptions()` 呼び出し（共有DB全体の変更監視: `CKDatabaseSubscription`）。
    - iOS17+: `MessageSyncService.shared` を初期化。
  - CloudKit 的ポイント:
    - 共有DBの `CKDatabaseSubscription` により、共有ゾーンの変更（参加者側の書き込み等）でサイレントPushを受ける。
    - 所有者側のプライベートゾーンの変更通知は、別途ゾーン/クエリサブスクリプションを張る必要がある（実装は存在: `setupRoomSubscription`）。
    - iOS 17+ では `CKSyncEngine` の採用により、変更トークン管理・差分適用・リカバリー処理をフレームワーク側に委譲でき、コード量とバグ要因を減らせる（将来移行候補）。
    - 前提: 本プロジェクトは iOS 17 以降のみをサポート（Xcode の iOS Deployment Target を 17.0 以上に設定）。

### 2) チャット作成・招待URL生成
- 処理:
  - 所有者がカスタムゾーンを作成、`ChatSession` レコードと `CKShare` を同一バッチ保存。UICloudSharingController で招待を共有。
- 実装:
  - 共有ルーム作成: `forMarin/Controllers/CloudKitChatManager.swift:396` → `createSharedChatRoom(roomID:invitedUserID:)`
    - `privateDB.save(CKRecordZone)` → `CKShare(rootRecord: ChatSession)` → `privateDB.modifyRecords(saving: [chatRecord, share])`
    - 生成された `CKShare.url` をログ出力。
  - 招待UI提示: `forMarin/Controllers/InvitationManager.swift:29` → `createAndShareInvitation(for:from:)`
    - 上記メソッドで `CKShare` を取得し `UICloudSharingController` を提示。
    - 保存時に `share.url` が `lastInvitationURL` に保存される。
  - CloudKit 的ポイント:
    - 共有は「ゾーン共有」。参加者は Shared DB 越しに所有者ゾーンへアクセス。
    - `CKShare.publicPermission = .none`（完全クローズド招待）
    - 必要に応じて階層共有（ルートレコード共有）も選択肢だが、チャットではゾーン共有（会話=ゾーン）がシンプルで拡張・運用に向く（大量履歴のローテーション/アーカイブが容易）。

### 3) 招待URL受信
- パスA: CloudKit 公式の招待URL（`https://*.icloud.com/...`）
  - OSが `application(_:userDidAcceptCloudKitShareWith:)` を呼び出す。
  - 実装:
    - AppDelegate: `forMarin/AppDelegate.swift:39`
      - 受信メタデータを `CloudKitShareHandler.shared.acceptShare(from:)` へ委譲。
    - 受諾実処理: `forMarin/Controllers/CloudKitShareHandler.swift:72` 以降
      - `CKAcceptSharesOperation` で受諾。
      - 成功後に `MessageSyncService.shared.checkForUpdates()` を呼びメッセージ再取得を促進。
  - 前提（Info.plist/Entitlements）:
    - `CKSharingSupported = YES` → `forMarin/Info.plist`
    - `com.apple.developer.icloud-container-identifiers` に `iCloud.forMarin-test` 設定 → `forMarin/forMarin.entitlements`

- パスB: カスタム招待URL（`fourmarin://invite?userID=...`）
  - SwiftUI の `.onOpenURL` から処理。
  - 実装:
    - エントリ: `forMarin/forMarinApp.swift:236` → `handleIncomingURL(_:)`
      - `icloud.com` を含むURLは CloudKit 招待と判定（実質 AppDelegate 側が処理）。
      - カスタムURLは `handleInviteURL(_:)` へ。
    - パース/ローカル部屋作成: `forMarin/Controllers/URLManager.swift:22` → `parseInviteURL(_:)` / `createChatFromInvite(userID:modelContext:)`
      - SwiftData に `ChatRoom` を作成（CloudKitの共有受諾はしない）。
  - 注意:
    - カスタムURLは CloudKit の共有受諾を行わないため、これ単体では共有ゾーンに接続されない（チャットは作れても CloudKit 的にリンクされない）。

### 4) メッセージ送信
- 送信トリガ:
  - UI → `MessageStore.sendMessage(...)` → `syncToCloudKit(_:)`
- 実装:
  - `forMarin/Controllers/MessageStore.swift:436` → `syncToCloudKit(_:)`
    - ルーム存在確認に `CloudKitChatManager.getRoomRecord(roomID:)` を使用。
    - 無い場合は（暫定）`createSharedChatRoom` を呼んで作成を試行。
    - メッセージ送信本体は `CloudKitChatManager.sendMessage(_:to:)` を呼び出し。
  - 実際のレコード保存: `forMarin/Controllers/CloudKitChatManager.swift:703`
    - 常に `privateDB.save(record)` を使用（添付ありは長時間実行UPLOAD）。
- CloudKit 的ポイントと現状の懸念:
  - 参加者端末でも `privateDB` を使用している点が不整合の可能性（本来は Shared DB 越しに所有者ゾーンへ書き込む）。
  - ただし CloudKit の共有仕様的には、所有者は Private DB（自分のゾーン）に書けば共有側へ反映される。一方、参加者は Shared DB から同ゾーンへ書くのが正道。

### 5) メッセージ受信（購読/同期）
- Push → 同期トリガ:
  - 共有DBサブスクリプション（`CKDatabaseSubscription`）でサイレントPushを受信。
  - AppDelegate: `forMarin/AppDelegate.swift:106` → `didReceiveRemoteNotification` で iOS17+ の場合 `MessageSyncService.shared.checkForUpdates()` を実行。
- 同期実装:
  - `forMarin/Controllers/MessageSyncService.swift:463` → `checkForUpdates(roomID:)`
  - `performQuery(roomID:)` にて役割別に検索。
    - 所有者: `queryPrivateDatabase(roomID:)`（デフォルトゾーン）+ `querySharedZones(roomID:)`（自分のPrivate DB内の全カスタムゾーン）
    - 参加者: `querySharedDatabase(roomID:)`（Shared DB・2段階）
  - 取得レコードを `Message` に変換して `messageReceived` をPublish。`MessageStore` が roomID でフィルタして採用。
- 追加購読（ルーム単位）:
  - `MessageStore.init` 内: `setupRoomPushNotifications()` → `CloudKitChatManager.setupRoomSubscription(for:)` を呼び、クエリサブスクリプションを作成（Private DB 側）。

---

## 事象: 「招待URL受取」と「メッセージ受信」が動かない

### A) 招待URL受取
- CloudKit招待URL（公式）経路は AppDelegate 実装がある（`userDidAcceptCloudKitShareWith`）。
  - 受諾処理は `CloudKitShareHandler` で `CKAcceptSharesOperation` を使って正しく実装されている。
  - 受諾成功時に `MessageSyncService.checkForUpdates()` を呼び出し同期を促す実装もある。
- 一方、カスタム招待URL（`fourmarin://invite?...`）は共有受諾を行わず、SwiftData にローカルな `ChatRoom` を作るのみ。
  - そのため「招待URLをシェアしたのに共有が繋がらない」事象が発生し得る。
- 可能性の高い原因:
  1. 実利用でカスタムURLを用いている（＝CloudKit共有は未受諾）。
  2. 共有URLタップ後に OS が `userDidAcceptCloudKitShareWith` を呼ばない状況（デバイスのiCloudログイン/権限/ネットワーク問題）。`CloudKitShareHandler` は診断ログ（アカウント状態/ゾーン列挙）を含むため、ログで切り分け可能。

### B) メッセージ受信
- Push・同期の一連は実装されているが、いくつかの設計/実装ギャップが受信不全を招く可能性あり:
  1. 参加者送信メッセージの購読経路
     - 所有者側は Private DB のカスタムゾーンを `querySharedZones` で列挙して取得する設計。基本的にはこれで参加者の投稿も見える（参加者は Shared DB から所有者ゾーンへ書き込むため）。
     - ただし、ルーム単位のクエリサブスクリプションは Private DB 側にしか張っていないため、Shared DB 側の細粒度Pushには非対応。Pushトリガは共有DBサブスクに依存。
  2. 初期同期の呼び出し文脈
     - Chat表示直後は `MessageStore.loadInitialMessages()` 内で iOS17+ のとき `syncService.checkForUpdates(roomID: roomID)` を呼ぶ。所有者ロール時に sharedDB も見るべきかは要検討（現状は Private DB default + Private DB 全カスタムゾーンのみ）。
  3. 「共有が確立していない」状態での送受信
     - 共有未受諾/未作成のままメッセージ送受信を試みると、レコードが想定ゾーンに存在せず、同期パスに乗らない。

---

## 実施済みの変更（詳細）

1) 送信データベースの自動選択（参加者/所有者）
- `CloudKitChatManager.resolveDatabaseAndZone(for:)` で (DB, zoneID) を解決し、`sendMessage(_:to:)` から自動切替: `forMarin/Controllers/CloudKitChatManager.swift:537`, `:860`

2) ルームレコード取得のDB考慮
- `getRoomRecord(roomID:)` は Private → Shared の順で探索。レガシー`SharedRooms` フォールバックは廃止: `forMarin/Controllers/CloudKitChatManager.swift:472`

3) 購読とPushハンドリング
- 参加者: Shared DB に `CKDatabaseSubscription`（silent）を作成。
- 所有者: Private DB に `CKQuerySubscription`（任意）または Database サブスク。
- `AppDelegate.didReceiveRemoteNotification` で `CKQueryNotification/CKRecordZoneNotification` を優先解析し、対象ルームのみ同期: `forMarin/AppDelegate.swift:108`

4) 初期同期の網羅性
- `MessageSyncService.performQuery(roomID:)` が役割に応じて Private/Shared を切替。`roomID=nil` 時は全域を差分取得: `forMarin/Controllers/MessageSyncService.swift:514`

5) 共有URLの取り扱い
- 公式URLのみを導線に採用。受諾後は Shared DB にゾーン追加→差分同期。

---

## 動作確認のためのチェックリスト
- 共有招待:
  - 招待作成: `CloudKitShare URL` が生成・共有されること（UICloudSharingController）。
  - 受諾ログ: `AppDelegate.userDidAcceptCloudKitShareWith` → `CloudKitShareHandler` の成功ログが出ること。
- 送信:
  - 所有者→参加者: 所有者送信時に Private DB の対象ゾーンへ保存されること。
  - 参加者→所有者: 参加者送信時に Shared DB 越しで所有者ゾーンへ保存されること（保存DB切替の実装確認）。
- 受信:
  - Push到達（共有DBサブスク）。
  - `MessageSyncService.checkForUpdates()` が実行され、`messageReceived` が発火すること。
  - ルーム画面で `MessageStore` によりUIへ反映されること。

---

## 参考：主要コード参照
- 共有ルーム作成: `forMarin/Controllers/CloudKitChatManager.swift:396`
- 共有DBサブスクリプション: `forMarin/Controllers/CloudKitChatManager.swift:502`
- ルーム購読（Private DB）: `forMarin/Controllers/CloudKitChatManager.swift:683`
- DB/ゾーン解決: `forMarin/Controllers/CloudKitChatManager.swift:537`
- 送信（DB自動選択）: `forMarin/Controllers/CloudKitChatManager.swift:860`
- 受信（Push/手動）: `forMarin/Controllers/MessageSyncService.swift:479` / `:514`
- 共有受諾エントリ: `forMarin/AppDelegate.swift:39`
- 共有受諾実処理: `forMarin/Controllers/CloudKitShareHandler.swift:72`

---

## まとめ（実施済みの要点）
- 送信DBはロールに応じて自動切替（Private/Shared）。
- 共有受諾は公式URL経由でアプリ内受け入れ、受諾後の同期導線を整備。
- Pushはルーム限定同期を優先し、対象不明時は全体同期。
- レガシー実装・レガシー互換コードは削除（CKSync・旧MVVM・レガシー変換API）。

---

# CloudKitでのチャット実装可否と推奨アーキテクチャ（総論）

以下は、CloudKitを使ったチャット実装の可否、推奨アーキテクチャ、制約、具体手順を、既存実装（本リポジトリ）に整合する形で統合した指針です。

## CloudKitでチャットは可能か
- 結論: CloudKitだけで1対1や小規模グループのチャットは十分実現可能。
  - CloudKitは「共有と同期」の基盤であり、レコード更新をサイレントプッシュで端末へ伝達する仕組み。Slackのような完全リアルタイム性はないが、小規模用途なら実用的。
  - iCloudアカウント必須。未ログイン・無効化中はCloudKit不可のため、UI上で案内/制限が必要（本アプリもアカウント状態確認とエラーハンドリングを実装）。

## グループチャット（〜5人程度）への拡張
- 現設計（1チャット=1ゾーン）をそのまま拡張可能。CKShareの招待は最大100人まで可能なため、5人規模は余裕。
- 推奨:
  - ゾーン設計: 「1チャット=1カスタムゾーン」を継続。
  - 共有: ルート`ChatSession`に対して`CKShare`を作成し複数参加者を招待。
  - 招待: 公式UI（`UICloudSharingController`）と公式共有URLを必ず利用。OSが`application(_:userDidAcceptCloudKitShareWith:)`を呼び、共有ゾーンがShared DBに自動追加される。カスタムURLでは受諾されないため、本番導線から外す（本実装の不具合原因の一つ）。
  - 権限: 参加者には`.allowReadWrite`（読書き可）、公開権限は`.none`（招待者限定）。

## 推奨データモデルとアクセス方法（実装現況）
- チャットゾーン: オーナーのPrivate DBに作成（既存実装と一致）。
- `ChatSession`: ルートレコード（メタ情報集約）。ゾーン共有主体でも、ルーム一覧やメタ管理に有用（既存実装で運用）。
- `Message`: 各メッセージは独立レコード。親参照は任意（ゾーン共有なら不要でもよい）。`roomID`でフィルタ運用。
- `MessageReaction`: ゾーン内で正規化レコードとして管理（既存実装対応済）。

### データベースの使い分け
- オーナー: Private DBへ書き込み（既存実装OK）。
- 参加者: Shared DBを通じてオーナーゾーンへ書き込み（`CloudKitChatManager.resolveDatabaseAndZone(for:)` により自動切替）。

---

## トラブルシュート: 共有URL受諾で「項目がオーナーによって共有設定にされていません」

受信側でこのiOS標準アラートが表示される典型原因と対処（o3 MCPでの確認結果に基づく）：

1) （誤解しやすい）Record sharing のコンソール設定を探している
- 最新のCloudKit Consoleには“レコードタイプごとのRecord sharingトグル”はありません。共有はコード（CKShare）で成立します。
- ゾーン共有（推奨）: `CKShare(recordZoneID:)` を使い、カスタムゾーンを共有。
- レコード共有を使う場合: `CKShare(rootRecord:)` の階層に含めるため、子レコード（Message等）に `parent` を必ず設定。

2) デフォルトゾーンを共有しようとしている
- デフォルトゾーンは共有不可。必ずカスタムゾーンで root レコード（`ChatSession`）を作成。

3) CKShare と root レコードを同一バッチで保存していない（レコード共有の場合）
- 新規共有作成時は `CKShare(rootRecord:)` と root を同じ `modifyRecords` で保存。

4) 環境/コンテナ不一致
- 作成側がDevelopment・受諾側ビルドがProductionなど。受諾は `CKShare.Metadata.containerIdentifier` で示されたコンテナを使って `CKAcceptSharesOperation` を実行（本実装は対応済み）。

5) 参加者追加の導線不足
- 共有UIから参加者を追加できるよう `UICloudSharingController.availablePermissions` に `.allowPrivate` を含める（本リポで対応済み）。

チェックリスト（短縮）
- カスタムゾーン使用（デフォルトゾーン不可）。
- ゾーン共有なら `CKShare(recordZoneID:)` を作成（本実装はこの方式に対応）。
- レコード共有なら `parent` で階層を構成し、`root` と `CKShare` を同一バッチ保存。
- コンテナID・環境一致、Info.plist に `CKSharingSupported`。
- 共有UIに `.allowPrivate` を付与し、参加者を追加して招待URLを配布。

## 購読と同期（推奨運用）
- オーナー: Private DBの対象ゾーンに`CKQuerySubscription`（既存の`setupRoomSubscription`）。
- 参加者: Shared DBに`CKDatabaseSubscription`（既存の`setupSharedDatabaseSubscriptions`）。Pushを受けたら対象ゾーンをフェッチ。
- 初期/再表示時: 差分/全量フェッチで履歴取得（既存の`MessageSyncService.checkForUpdates`）。

- 運用Tips:
  - 変更通知は“何か変わった”を示すだけ（DBサブスク）→ 各ゾーンの `CKServerChangeToken` を永続化し、差分取得で必ず最終整合。
  - フェッチのバーストはスロットリング対象になりうるため、短時間の変更を集約し、指数バックオフ/再試行を実装。
  - プッシュ取りこぼし時は BGAppRefresh（定期ポーリング）で救済。

## CloudKit特有の制約と注意点
- 全員iCloud必須。未ログイン時はCloudKit不可（UI/導線で案内）。
- ストレージ課金はオーナー側に集中。画像/動画が増えると容量圧迫に注意。
- 通知はサイレントプッシュが基本。ユーザー向け可視通知が必要なら、端末側でローカル通知生成（もしくは別Push基盤）。
- 同期遅延はあり得る（数秒〜オフライン時は後配信）。
- 競合: メッセージはappend中心で問題になりにくいが、同一フィールドの並行編集は「最後の勝ち」。

- 追加の現実的制約:
  - Shared DB で `CKQuerySubscription` は使えない（本設計は Database サブスク基準）。
  - レート制限/スロットリング: 連続保存・連続フェッチは抑制される可能性。バッチ保存/バッチ処理で負荷を平準化。
  - E2E暗号ではない: CloudKitは転送/保存時暗号化はあるがE2Eではない。必要ならアプリ側で本文を暗号化し、CloudKitには暗号化済みペイロードを保存。
  - SwiftDataのCloudKit共有は（2025時点）未対応。共有前提の永続化には Core Data + `NSPersistentCloudKitContainer`（共有対応）か、現行どおりCloudKit API直叩き（必要なら `CKSyncEngine`）が安定。

---

## 1) 明確な回答（推奨構成）
- CloudKitのみで、ユーザーに見える通知つきの1on1/小規模グループ（〜5人）チャットは実現可能。
- ただし Shared DB では `CKQuerySubscription` が使えないため、参加者側の“直接可視”は取れない。最適解は「Database Subscription（silent）＋端末側ローカル通知」。

### 推奨アーキテクチャ（統一パス）: すべて silent → 端末で可視化
1. `CKDatabaseSubscription` を作成
   - オーナー: Private DB
   - 参加者: Shared DB
   - いずれも `NotificationInfo.shouldSendContentAvailable = true`（silent）
2. 端末がサイレントPush受信 → 差分フェッチで新規`Message`取得 → `UNUserNotificationCenter` でローカル通知生成
3. ミュート・既読・@メンション等は端末ロジックで制御してから通知可視化

補足: silent は配信保証がなくスロットリングされ得る。BGAppRefresh での定期ポーリングを併用して堅牢化。

### 代替（併用）: オーナーだけ「直接可視」
- オーナー（Private DB）は `CKQuerySubscription` が使えるため、`Message`作成時にタイトル/本文入りの可視通知をCloudKitから直接送らせる構成も併用可。
- 参加者（Shared DB）は不可のため、上記 silent→ローカル通知とのハイブリッドになる（ロール差のUXは要考慮）。

注: `CKRecordZoneSubscription` は共有DBでは不可。Shared向けは`CKDatabaseSubscription`のみ。

---

## 2) なぜこの結論か（仕様根拠）
- `CKQuerySubscription` の適用範囲は Public/Private のみ（Shared不可）。
- `CKDatabaseSubscription` は Private/Shared で有効（Public不可）。参加者側の変更検知はこれで取得。
- Database Subscription は「何か変わった」しか分からないため、端末でフェッチ→ローカル通知が定石。
- silent は配信保証なし/レート制限ありのため、フォールバック（BGAppRefresh等）が必要。

- 実装スタックに関する補足:
  - Core Data + CloudKit 共有（`NSPersistentCloudKitContainer`）は成熟しており、レコード/共有の多くを自動化可能。既存モデルがCore Dataなら有力候補。
  - 生の CloudKit API を使う場合、iOS 17+ は `CKSyncEngine` が推奨。ローカルストアとCloudKit の差分同期を安全に実装できる。

---

## 3) 代替視点・発展案
- `UNNotificationServiceExtension` による“可視Remote通知の差し替え”
  - Database Subscriptionを可視（`title/body + shouldSendMutableContent = true`）にし、拡張でCloudKitから本文を取得して差し替える。
  - ただし拡張は「通知を必ず出す」前提。ミュートや抑止を端末判断に任せたいなら silent→ローカル通知の方が運用容易。
- 可視を全部Query（オーナーのみ）/Sharedはsilent のハイブリッドも可。

- 強リアルタイムが必須な場合のハイブリッド:
  - 送受信は Firebase/Firestore や Supabase（Edge Functions + WebSocket）で即時配信、CloudKit は履歴/メディア保管・バックアップに限定する構成も現実的。
  - 近距離はP2Pで即時配信、未到達はCloudKitで最終同期（本アプリの`P2PController`と相性良）。

---

## 4) 具体的な実装手順（最小差分）

### A. サブスクリプション作成/更新
1) Shared DB（参加者）

```swift
let sub = CKDatabaseSubscription(subscriptionID: "shared-db-changes-v1")
let info = CKSubscription.NotificationInfo()
info.shouldSendContentAvailable = true // silent
sub.notificationInfo = info
container.sharedCloudDatabase.save(sub) { _, _ in }
```

※ CloudKit Dashboard で Production へデプロイを忘れずに。

2) Private DB（オーナー）
- まずは DatabaseSubscription（silent）を入れて統一。
- 追加で必要なら `CKQuerySubscription`（可視）を併用（`firesOnRecordCreation`、`desiredKeys = ["senderName","text"]` 等）。

### B. 通知受信〜差分フェッチ〜ローカル通知
- `didReceiveRemoteNotification` で `CKNotification` をパースし、DBスコープに応じて:
  1. DB変更トークン管理（`CKFetchDatabaseChangesOperation`）
  2. 変更ゾーンごとに `CKFetchRecordZoneChangesOperation` で新規`Message`取得
  3. ミュート/既読/自分の送信を除外し `UNUserNotificationCenter` でローカル通知（`threadIdentifier = roomID` など）

### C. フォールバック
- `BGAppRefreshTask` で定期チェック（数時間に1回）。silent取りこぼしの救済。重複通知抑止/集約も併用。

### D. 招待と権限
- 招待は `UICloudSharingController` / 公式URLのみを導線に。受諾時に `application(_:userDidAcceptCloudKitShareWith:)` が呼ばれる。権限は `.allowReadWrite`。
- 受諾後は Shared DB に共有ゾーンが追加され、`MessageSyncService` が差分同期を行う。

---

## 5) 実装チェックリスト
- サポートOS設定:
  - Xcode の iOS Deployment Target を 17.0 以上に設定（iOS 17+ 前提）。
  - Capabilities: iCloud（CloudKit）を有効化。
  - Background Modes: `Remote notifications`（必須）と `Background fetch`（任意/推奨）を有効化。
- Private/Shared 両DBに `CKDatabaseSubscription` を作成（重複作成の防止・ID固定）
- サイレント受信（Background Modes: `remote-notification`）と通知権限（`UNUserNotificationCenter`）
- 変更トークン（DB/Zoneごと）を永続化（`CKServerChangeToken`）
- 既読・ミュート・@メンションのローカル管理（SwiftData）
- ローカル通知のグルーピング（`threadIdentifier`、`summaryArgument`）
- Dashboard で Production 反映/本番・開発切替の確認（サブスクは本番へ）

---

## 6) まとめ（要点）
- Shared DB には `CKQuerySubscription` が使えない → 「DatabaseSubscription（silent）＋端末でローカル通知」が王道。
- 可視通知の品質・文言は端末で自由に整形可能（ミュート/既読反映）。
- silentは配信保証なしだが、実用レベル＋BGフォールバックで堅牢化できる。

---

## 参考リンク（仕様・公式サンプル）
- CloudKit 概要/設計
  - https://developer.apple.com/icloud/cloudkit/
  - https://developer.apple.com/icloud/cloudkit/designing/
- 共有の受け入れ（アプリ内）
  - `CKFetchShareMetadataOperation` / `CKAcceptSharesOperation` フロー（Appleフォーラムの実装解説が参考）
- 共有DBの通知（QA1917）
  - Sharedでは `CKQuerySubscription` 不可 → `CKDatabaseSubscription` + 変更トークン同期
- 公式サンプル
  - Zone Sharing: https://github.com/apple/sample-cloudkit-zonesharing
  - Sharing（階層共有）: https://github.com/apple/sample-cloudkit-sharing
  - Private DB + Push 同期: https://github.com/apple/sample-cloudkit-privatedb-sync
  - CKSyncEngine: https://github.com/apple/sample-cloudkit-sync-engine
- コミュニティ事例（CloudKitメッセージング/共有）
  - EVCloudKitDao（AppMessageデモ）: https://github.com/evermeer/EVCloudKitDao
  - Simple chat: https://github.com/alexbutenko/simplechat
