CloudKit スキーマ設計（改訂・完全版）—「1チャット=1ゾーン」の哲学に沿った設計書

本書は CloudKit の思想・仕様 を先に明確化し、その上で iOS 17+／1対1主体（将来3–10人の小規模グループ） を満たす実運用レベルのスキーマ＆実装をまとめたものです。要点は 「1チャット＝1カスタムRecord Zone」＋「ゾーン共有（Zone Sharing）」、通知は サーバ差分トークン駆動、メディアは CKAsset＋遅延取得 です。

⸻

0. CloudKit の“思想”を設計に落とす
	• コンテナ/データベース/ゾーンの三層
	1つのコンテナに、Private / Public / Shared の3つのデータベースがあり、ゾーンはデータの粒度の良い隔離・同期単位です。ゾーンを分ける＝責務と所有の分離であり、クエリ・差分・運用の境界にもなります。データは CKRecord、関連は CKRecord.Reference で表現します。  ￼
	• 共有の二方式
		• 階層（レコード）共有：1つの“ルートレコード”を共有し、その子孫階層が対象。
		• ゾーン共有（Zone Sharing）：ゾーン全体を共有（iOS 15+）。チャットのように関連レコードが多数・同粒度で増える用途に好適。1ゾーンに対して CKShare は1つ。  ￼
	• Shared DB の本質
	共有を受けた参加者側にはオーナーPrivateのレコード群が Shared DB に“投影”されます。参加者は Shared DB に対して読み書きし、CloudKit がオーナーPrivateへ反映します。Shared DBに新規ゾーンを作ることはできません（ゾーンはオーナー側で作成）。  ￼

⸻

1. スキーマ概観：1チャット=1ゾーン、ゾーン全体を共有

1.1 ゾーンと共有の基本方針
	• 新規チャット作成時に、オーナーの Private DB にカスタム CKRecordZone を1つ作成。
	• そのゾーンを `CKShare(recordZoneID:)` で共有。ゾーン内の全レコード（メタ/メッセージ/付帯情報）が自動的に共有対象になります。  ￼
	• 招待・参加処理は `UICloudSharingController` に委ね、アプリ標準の共有UIで人・権限・リンクを扱います。  ￼
	• 公開可否は原則 招待制（`publicPermission = .none`）。公開リンク参加が要件なら `.readOnly`/`.readWrite` を慎重に使用。  ￼

1.2 データ所有・格納と書き込み先
	• 物理的な所有・課金はオーナー側の Private（共有は“見せる/書かせる”仕組み）。参加者は自分の Shared DB でレコードを扱い、実体はオーナー側に反映されます。  ￼

⸻

2. レコードタイプとフィールド（クエリ/ソートを意識した最小完結型）

2.1 ChatSession（各チャットのメタ）
	• 配置：各“チャット用ゾーン”に1件のみ
	• 推奨フィールド
		• name: String … グループ名（1:1は空でも可。表示名は参加者から導出可能）
		• createdAt: Date … 任意
		• lastMessageAt: Date … Queryable / 必要に応じ Sortable（一覧ソート・未読算出）
	• 参加者情報は保持しない：`CKShare.participants` が唯一の真実（重複保持しない）。  ￼

2.2 Message（メッセージ）
	• 推奨フィールド
		• text: String … 本文
		• attachment: CKAsset … 画像/動画。数KB超は Asset 推奨、ファイル名などは別フィールドで管理。  ￼
		• senderID: String … UIと集計用（`creatorUserRecordID` でも推定可）
		• timestamp: Date … Queryable / 必要に応じ Sortable（時系列・範囲）
		• chatRef: CKRecord.Reference … 任意。ゾーン単位で所属は暗黙に一意だが、将来の横断クエリ要件があれば付与
	• インデックスの原則：フィルタ条件は Queryable、並び替えは Sortable。用途が両方なら両方付与。  ￼

2.3 拡張（任意）
	• MessageReaction（正規化）
		• messageRef: Reference（Queryable 推奨） / userID: String / emoji: String / createdAt: Date
		• ID規約：`reaction_<messageRecordName>_<userID>_<emoji>`（冪等・重複防止）
	• MessageRead（必要時の既読）
		• messageRef: Reference / userID: String / readAt: Date
		• ID規約：`read_<messageRecordName>_<userID>`

⸻

3. 招待・受け入れ UX（標準UI＋最短導線）
	1. ゾーン作成→共有作成
	`let share = CKShare(recordZoneID: zoneID)` をオーナーの Private DB へ保存。ゾーン共有の開始点です。  ￼
	2. `UICloudSharingController`
	招待UIをそのまま出す（権限やサムネイル/タイトルの指定も可能）。  ￼
	3. 受け入れ（参加者側）
	`application(_:userDidAcceptCloudKitShareWith:)` で `CKContainer.accept(...)` する。以後、Shared DB に共有ゾーンが現れる。SwiftUI ライフサイクルでも AppDelegate/SceneDelegate 経由で取り回し可能。  ￼

⸻

4. 同期モデル（通知と差分）— DB購読＋差分トークン が基軸

4.1 サブスクリプション設計（※Shared DBの制約に注意）
	• `CKQuerySubscription` は Shared DB 非対応。`CKRecordZoneSubscription` も Public/Shared では保存不可（Private のみ）。両DBで使えるのは `CKDatabaseSubscription`。  ￼
	• 実装指針
		• Private DB：`CKDatabaseSubscription` 1つ（全ゾーン）または、ゾーン単位運用なら `CKRecordZoneSubscription`（Private に限る）
		• Shared DB：`CKDatabaseSubscription` 一択（ゾーン/クエリ購読は不可）

4.2 差分取得（サーバチェンジトークン駆動）
	• 手順
		1. プッシュ受信後、`CKFetchDatabaseChangesOperation`（DB変更一覧）で変更のあった `zoneID` を取得
		2. 各 `zoneID` に対して `CKFetchRecordZoneChangesOperation`（ゾーン内レコード差分）を 保存済み `CKServerChangeToken` から再開
		3. 受け取った作成/更新/削除を適用し、新トークンを永続化
		4. `moreComing` があれば続行（追いかけ）
	起動時/復帰時にも同ルーチンで取りこぼしを回収します。  ￼

⸻

5. 書き込み先の切替（所有者判定のルール）
	• オーナーのゾーン → `privateCloudDatabase` に保存/取得
	• 他者所有（共有受け）のゾーン → `sharedCloudDatabase` に保存/取得
	Shared DB は“投影”なので、参加者の書き込みもここに行います。  ￼

⸻

6. メディア最適化（CKAsset／遅延取得／長時間実行）
	• CKAsset を一貫利用：画像/動画などは一時ファイル→`CKAsset(fileURL:)` で保存。ファイル名などは別フィールドで持つ。  ￼
	• `desiredKeys` で“一覧は軽く・詳細で重く”：リスト取得では `attachment` を除外、タップ時に当該レコードのみ `desiredKeys=["attachment"]` で再フェッチ。  ￼
	• 大容量の送信：`CKModifyRecordsOperation` を使い `isLongLived = true` でバックグラウンド継続アップロード。再起動時の“再アタッチ”で完了まで運ぶ。  ￼

⸻

7. 代表的なクエリ & インデックス付与
	• チャット一覧：全ゾーンの `ChatSession` を集約し `lastMessageAt` 降順。→ `lastMessageAt`: Sortable（必要なら Queryable も）。  ￼
	• メッセージ一覧：該当ゾーンの `Message` を `timestamp` 昇順（ページング）。→ `timestamp`: Sortable（範囲フィルタ用に Queryable も）。  ￼
	• レコード名直参照や復旧用途：必要に応じ recordID 系をクエリ可能にする設計（CloudKit Console での索引管理を前提）。  ￼

補足：フィルタ＝Queryable、ソート＝Sortable は別物。どちらの用途にも使うキーは両方付与するのが鉄則です。  ￼

⸻

8. リアクション/既読（任意機能）の指針
	• MessageReaction 正規化
		• 1ユーザ×1メッセージ×1絵文字＝1レコード、レコード名規約で冪等化。
		• 集計はクライアント側で `messageRef` 絞り込み→絵文字ごとに集約。`messageRef` は Queryable。
	• MessageRead
		• 必要最小限で（例：最新N件のみ既読を記録）。未読バッジは `lastSeenAt` をローカル保持＋`lastMessageAt` 比較でも成立。

⸻

9. セキュリティ設計の事実関係
	• 暗号化の前提
	通常フィールドは転送・保存時に保護されますが、端末間 E2E でサーバでも復号不能にしたい値は `CKRecord.encryptedValues` を使います（アセットは既定で暗号化）。初期設計時に適用可否を決め、後からの切替は不可なので要計画。  ￼
	• 共有の受け入れ要件
	共有URLを開くと AppDelegate/SceneDelegate の該当メソッドが呼ばれ、accept することで参加確定。Info.plist の `CKSharingSupported` を ON に。  ￼

⸻

10. 画面/レイヤ分離（MVVM想定・実装メモ）
	• ChatListViewModel
		• Private/Shared の両 DB から「自分が関与するゾーン」を列挙し、各ゾーンの `ChatSession` をまとめて `lastMessageAt` 降順。
		• `CKDatabaseSubscription`（Private/Shared）の通知を受け→差分フェッチ（§4.2）→モデル更新。  ￼
	• ChatViewModel
		• 対象ゾーンで `Message` を `timestamp` 昇順取得（ページング）。
		• 送信は所有者判定→DB切替→`CKModifyRecordsOperation`（メディアは `isLongLived`）。  ￼

⸻

11. 運用・テスト・移行のポイント
	• Shared DB の購読は DB購読のみ（クエリ/ゾーン購読は不可）。Private 側は要件次第でゾーン購読も選択可。  ￼
	• 差分トークンは永続化し、起動時に追いかけ同期で欠落を回収。  ￼
	• CKAsset の遅延取得で初期表示の体感改善（`desiredKeys` を徹底）。  ￼
	• ゾーン共有実装の正解例は Apple のサンプルも参照（Zone Sharing デモ）。  ￼

⸻

12. 仕様サマリ（抜粋）
	• 共有モデル：ゾーン共有（`CKShare(recordZoneID:)` / 1ゾーン1共有）。  ￼
	• 書き込み先：オーナー＝Private、参加者＝Shared。  ￼
	• 通知：Private＝DB購読 or ゾーン購読、Shared＝DB購読のみ。  ￼
	• 差分：DB変更一覧→ゾーン差分（サーバトークン）。  ￼
	• メディア：CKAsset＋`desiredKeys`、大容量は `isLongLived`。  ￼
	• 暗号化：機密値は `encryptedValues` を採用（アセットは既定で暗号化）。  ￼

⸻

付録：CloudKit Console/Schema 反映の実務メモ
	• `ChatSession.lastMessageAt` と `Message.timestamp` に Queryable/SORTABLE を個別付与。
	• 本番昇格前にインデックス整備とフィールド型を確定（後から E2E 暗号化へ変更は不可）。  ￼

⸻

これで、CloudKit の設計思想（ゾーン＝隔離・同期単位／ゾーン共有で協調編集／Shared DB は投影／DB購読＋差分）を忠実に反映した、堅牢で拡張可能なチャット・スキーマが完成です。1対1から 3–10人のグループまで、ゾーン単位の独立性を保ちながら安全・効率的に運用できます。

### 現状実装との差分（forMarin 実装 vs 本ドキュメントの理想）

- **ゾーン設計と共有方式**

  - **理想**: チャット毎に専用カスタム Zone を作成し、その Zone を CKShare で「ゾーン共有」する。
  - **現状**: 統一ゾーン `SharedRooms` を使用し、その中に `CD_ChatRoom` と `CD_Message` を格納。共有は `CD_ChatRoom` レコードを root とした「レコード共有」ベース。ゾーン=チャットの 1 対 1 対応になっていない。
  - **所在**: `CloudKitChatManager.createSharedChatRoom`、`CloudKitChatManager.getRoomRecord`、`CloudKitChatManager.createSharedDatabaseSchema`
  - **影響**: データ隔離/購読・差分トークンの粒度が悪化し、退会/削除や将来のゾーン分割移行が複雑化。誤共有・誤取得のリスク増。

- **レコードタイプ/フィールド命名**

  - **理想**: `ChatSession`/`Message`、フィールドは `text`/`attachment`/`senderID`/`timestamp`（必要に応じて `chatRef`）。
  - **現状**: `CD_ChatRoom`/`CD_Message`、フィールドは `body`/`asset`/`senderID`/`createdAt`/`roomID`、および `reactionEmoji`/`reactions`。`ChatSession` は不在。`participants` をレコード側に保持。
  - **影響**: スキーマ/クエリ/インデックス設計（`lastMessageAt`/`timestamp` の queryable など）が理想と異なる。

- **参加者管理/招待 UI・受け入れフロー**

  - **理想**: `UICloudSharingController` を用いた招待・受け入れ。`application(_:userDidAcceptCloudKitShareWith:)` での受け入れハンドラを実装。
  - **現状**: ID ベースの `PairingView` 等で接続。`UICloudSharingController` の使用痕跡なし。受け入れハンドラ実装なし（`AppDelegate`/Scene 経路に該当処理なし）。
  - **所在**: `AppDelegate.swift`（受け入れ処理なし）、`InviteModalView`（UI 連携は未確認だが SharingController の利用は見当たらず）
  - **影響**: 共有受け入れの失敗/未反映や権限不整合が起きやすく、UX と復旧ロジックの負担増。

- **CKShare の publicPermission 設定**

  - **理想**: 招待制とするため `publicPermission = .none`。
  - **現状**: 既定で `publicPermission = .readWrite` を設定。
  - **所在**: `CloudKitChatManager.createSharedChatRoom`、`CloudKitChatManager.createSharedDatabaseSchema`
  - **影響**: 招待制が崩れリンク拡散で不特定多数が参加可能に。個別招待の併用不可・セキュリティ/運用リスク増。

- **書き込み先データベースの選択（送信経路）**

  - **理想**: オーナーは自分の PrivateDB の対象ゾーンへ、参加者は SharedDB へ書き込む。
  - **現状**: 常に `privateCloudDatabase` に対して保存しており、参加者側の書き込み経路が SharedDB を経由していない。
  - **影響**: 参加者端末での送信互換性に問題が生じる可能性。
  - **所在**: `CloudKitChatManager.sendMessage`、`MessageSyncService.sendMessage`/`updateMessage`/`deleteMessage`

- **同期サブスクリプションの粒度**

  - **理想**: Shared DB は `CKDatabaseSubscription` のみ。Private DB は `CKDatabaseSubscription`（全ゾーン監視）またはゾーン単位の `CKRecordZoneSubscription`（Private のみ）を選択。
  - **現状**: Private/Shared ともに `CKDatabaseSubscription` を使用しつつ、ルーム単位の `CKQuerySubscription` も併用。ゾーン=チャットの前提ではない構成。
  - **所在**: `CloudKitChatManager.setupSharedDatabaseSubscriptions`、`CloudKitChatManager.setupRoomSubscription`、`MessageStore.setupRoomPushNotifications`
  - **影響**: 通知ノイズや無駄フェッチが増え、電池/帯域コスト上昇。チャット特定・再同期のロジックが複雑化。

- **差分取得 API の使い方**

  - **理想**: DB変更一覧→ゾーン差分（`CKFetchDatabaseChangesOperation`→`CKFetchRecordZoneChangesOperation`）を各チャット Zone ごとに `CKServerChangeToken` で厳密に差分取得。
  - **現状**: SharedDB では `CKFetchRecordZoneChangesOperation` を使用する一方、PrivateDB 側は複数ゾーンを `CKQuery` で横断取得する実装が中心。
  - **影響**: 履歴が多い場合にフルスキャンが増える可能性。
  - **所在**: `MessageSyncService.queryPrivateDatabase`/`querySharedZones`/`fetchRecordsFromSharedZone`

- **長時間実行アップロード（大容量メディア）**

  - **理想**: `CKModifyRecordsOperation.isLongLived = true` によるバックグラウンド継続アップロード。
  - **現状**: 直接 `save` を使用し、長時間実行オペレーション未使用。
  - **所在**: `MessageSyncService.sendMessage`、`CloudKitChatManager.sendMessage`
  - **影響**: バックグラウンド移行やアプリ終了で送信が中断/失敗し、メディア欠落・再送負荷が発生。

- **desiredKeys によるフィールド最適化**

  - **理想**: 一覧フェッチ時は `attachment` を除外し、詳細表示で個別に取得。
  - **現状**: クエリでの `desiredKeys` 未使用（通知の `desiredKeys` 指定はあり）。
  - **所在**: `MessageSyncService.queryDatabase`/`queryPrivateDatabase`/`querySharedDatabase`
  - **影響**: 不要なアセット転送で表示遅延/帯域浪費。一覧の体感性能が低下。

- **MVVM アーキテクチャの徹底度**

  - **理想**: 画面ごとに ViewModel を定義し、UI とデータアクセスを明確分離。
  - **現状**: `MessageStore`/各種 *Manager がロジックを担う構成で、View からサービス直呼び出し箇所もあり、ViewModel 分離は部分的。
  - **所在**: `MessageStore`、各種 `*Manager`、各 View からの直接呼び出し箇所
  - **影響**: 関心分離不足によりテスト性/可読性/変更容易性が低下。UI と同期処理のカップリング増。

- **インデックス（Queryable）設計**

  - **理想**: `lastMessageAt`/`timestamp` に Queryable インデックスを付与。
  - **現状**: `recordName` に対する queryable 強制作成は試行しているが、上記フィールドのインデックス整備は未実装。
  - **所在**: `CloudKitChatManager.forceCreateQueryableIndexes`
  - **影響**: 最新/未読/ソート系のクエリが重くスケールしない。端末/サーバ負荷とレイテンシ増。

- **その他スキーマ周りの差分**
  - `ChatSession` レコード不在（`CD_ChatRoom` で代替）。
  - 共有受け入れ後のゾーン列挙・管理はあるが、ゾーン=チャットの 1 対 1 前提にはなっていない。
  - **影響**: 理想スキーマ前提の最適化/移行手順を適用しづらく、移行・運用コストが増大。
