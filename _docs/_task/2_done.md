# Done / Completed Worklog

## APNs/Push & Sync 計測・制御の実装 (2025-09-24)
- Push登録計測: 生トークンのログを廃止し、`env`/`tokenHash(SHA-256)`/`timestamp`/通知権限/`backgroundRefreshStatus` を `push.register` で記録（forMarin/AppDelegate.swift: didRegister...）。
- 受信テレメトリ: `push.receive` に処理時間 `duration_ms`、ネットワーク状態、CloudKit ID（`ck_sid`/`ck_nid`）を記録（forMarin/AppDelegate.swift: didReceiveRemoteNotification）。
- Pushルータ: `ck.sid` を `db-sub-private/shared` にマップしてスコープを決定（forMarin/Controllers/CKSyncEngineManager.swift）。
- スコープ別直列スケジューラ: Pushバーストをスコープ単位でコアレスして `fetchChanges` を直列実行（同上）。
- BGタスク可観測性: スケジュール/実行ログのカテゴリを `bg.task` に統一（forMarin/Controllers/OfflineDetectionManager.swift）。

## CKSyncEngine 可観測性の拡充 (2025-09-24)
- 永続化メトリクス: `metric=engine_state_persisted key=<...> bytes=<N>` を `metrics` カテゴリで記録（forMarin/Controllers/CKSyncEngineManager.swift）。
- フェッチ結果: `pendingZones` を含むサマリを出力、失敗時は `retry_after_seconds` を記録（同上）。
- シリアライズ未実装検知: 送信バッチ組成時に outbox 不在レコード件数を `serialize.coverage` として出力（同上）。
- ゾーン差分通知: フェッチ完了イベントからゾーン単位の変更/削除件数を `MessageSyncPipeline` へ通知（forMarin/Controllers/CKSyncEngineManager.swift → MessageSyncPipeline.onZoneChangeHint）。

## PiP / P2P オーバーレイ方針の反映 (2025-09-24)
- システムPiPは不採用に変更。オーバーレイはアプリ内のみで自動表示/非表示。
- 依存削減: サンプルバッファ系とPiPマネージャを削除、Metalレンダラ（`RTCMTLVideoView`）に統一（forMarin/Views/FloatingVideoOverlay.swift, forMarin/Views/RTCVideoView.swift）。
- ブリッジ/呼び出しを削除し、P2PControllerからのPiP依存を排除（forMarin/Controllers/P2PController.swift）。
- 非対応デバイスの検知とエラーログ（`overlay.unsupported.*`）は存続（forMarin/Controllers/OverlaySupport.swift）。

## 招待参照クリーンアップ（冪等）(2025-09-24)
- `InvitationManager.cleanupOrphanedInviteReferences()` を追加し、`performInviteMaintenance` 実行時に無効なローカル招待URL（`unknownItem`）を除去。SwiftData/トークン/キャッシュと併せて健全化（forMarin/Controllers/InvitationManager.swift, CloudKitChatManager.swift）。
## CKAcceptSharesOperation ハンドリング再設計 (2025-09-22)
- 受諾統合: `CloudKitShareHandler` を導入して `CKAcceptSharesOperation` を一元処理。重複受諾を `handledShareIDs` で防止。
- 事後処理: 受諾後に共有ゾーンへ参加完了システムメッセージを保存し、`MessageSyncPipeline.checkForUpdates(roomID:)` を起動。
- 可観測性: メタデータ解析・検証・バッチ結果をカテゴリ `CloudKitShareHandler` でログ化（本番ではレベル調整予定）。
- 参照: forMarin/Controllers/CloudKitShareHandler.swift

## サブスクリプション方針の確定 (2025-09-22)
- 結論: ゾーン購読（`CKRecordZoneSubscription`）は採用せず、固定IDの `CKDatabaseSubscription`（`db-sub-private`/`db-sub-shared`）のみを使用。
- 根拠: 公式推奨のDBサブ＋差分同期（`fetchDatabaseChanges`→`fetchRecordZoneChanges`）で要件を満たすため。運用と冪等性が単純。
- 実装: `CloudKitChatManager.ensureSubscriptions()` にて DB サブを冪等作成。`fetchSubscriptions` は使用せず、未知/欠損は再作成で回復。
- 参照: forMarin/Controllers/CloudKitChatManager.swift:1541

## CloudKit 同期/リアクション ビルドエラー修正 (2025-09-22)
- 修正: `CloudKitChatError` のネスト型参照を統一、MainActor 呼び出しを是正、`self` 明示。
- 追加: `CloudKitChatManager.getReactionsForMessage`, `bootstrapSharedRooms`, `bootstrapOwnedRooms`。
- 検証: 共有/所有ルームのブートストラップ件数、同期開始/終了、リアクション取得件数のログで確認。
- 方針: 公式APIに準拠した最小実装。旧スキーマは軽量フォールバックのみ、冗長な暫定フラグは不採用。

### 追補: フォールバック撤廃 (2025-09-22)
- `getReactionsForMessage` の旧 `MessageReaction` 参照フォールバックを削除（Reaction のみ）。
- `ConflictResolver` の `timestamp` 不在フォールバック（`creationDate` 使用）を撤廃。
- 方向性: 不整合はフォールバックせず、既存の完全リセット検知（MessageSyncPipeline）で健全化する。

## Push & Sync 起動フロー整備 (2025-09-22)
- `AppDelegate.application(_:didFinishLaunchingWithOptions:)` で `UIApplication.registerForRemoteNotifications()` を起動直後に実行し、`CloudKitChatManager.bootstrapIfNeeded()` → `CKSyncEngineManager.start()`（iOS 17+）の初期化パイプラインを Task 内で待機させる構成に統一。起動ログでコンテナ/ビルドチャネルを明示し、bootstrap 失敗は `lastError` へ格納。
- `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` は受信トレース（signpost + `log`) を揃えつつ `CKSyncEngineManager.shared.handleRemoteNotification(userInfo:)` を await し、roomID ヒントがある場合は `P2PController.shared.onZoneChanged` をキックするよう確定。fetch 結果は `UIBackgroundFetchResult` に反映し、CloudKit 非対応端末では `.noData` を返す運用を整理。
- フォールバック経路として `.active` 遷移時に `CKSyncEngineManager.shared.fetchChanges(reason:)` を呼び出し、`BackgroundTaskManager` 経由で `BGAppRefreshTask` をスケジュール。タスク実行時は `CKSyncEngine` の fetch 結果と Connectivity 状態をログ化し、デバッグモードの通知挙動も制御した。

## CloudKit Sharing & Invite Flow (2025-09-22)
- `CloudKitChatManager.createSharedChatRoom` を zone-wide share 前提で刷新し、`CKShare(recordZoneID:)` + `CKContainer.fetchShareParticipant` による参加者特定を必須化。`.userDiscoverability` 許可が得られない場合は `CloudKitChatError.discoverabilityDenied`、特定不可は `.userNotFound` を即時 throw。
- root `ChatSession` レコードと `CKShare` を単一 `CKModifyRecordsOperation` (`share.create.<roomID>`) で保存し、`share.url` を検証後 UI に返却する `ChatShareDescriptor` を導入。
- 既存共有の再取得は `fetchShare(for:)`（zone-wide share 前提）に統一。UI は `InviteModalView` / `InviteUnifiedSheet` を介してメール・電話・recordName 入力から URL をコピー／共有するのみとし、`UICloudSharingController` 系ビューロジックを廃止。
- `InvitationManager` は URL 生成＋`UIActivityViewController` 共有の単機能へ再設計。既存／新規どちらの CKShare も `lastInvitationURL` に追跡。

## CloudKit 招待 UI / 運用アップデート (2025-09-22)
- `InviteUnifiedSheet` に `UICloudSharingController` の SwiftUI ラッパーを統合し、チャット作成直後および再共有時にシステム共有 UI を提示できるよう調整。
- `InvitationManager` を `UICloudSharingControllerDelegate` 化し、シェア完了／失敗のログを集中管理。`UIActivityViewController` ベースの旧共有ロジックを廃止。
- `CloudKitChatManager` のゾーン生成ロジックを冪等化し、既存 share の再利用・チュートリアルメッセージ重複防止を実装。
- `ModelContainerBroker` に `#Predicate<Message>` を復活（Foundation import 追加）させ、SwiftData 側で `ckRecordName == nil` をストアフィルタできるよう修正。
- 未同期メッセージ件数が 50 件以上の場合に警告ログを出すことで、運用時の監視フックを追加。

## Sync & CloudKit 管理
- `ensureSubscriptions` を固定 ID (`db-sub-private`, `db-sub-shared`) の `CKDatabaseSubscription` だけに集約し、ゾーン購読や旧キャッシュロジックを削除。冪等作成は `ensureDatabaseSubscription` で共通化。
- `fetchDatabaseChanges` → `fetchRecordZoneChanges` を `CloudKitChatManager` 側に実装。`MessageSyncPipeline` は該当 API を利用した差分同期に置き換え、非メッセージレコード（リアクション／添付）も `processNonMessageRecords` で即時反映。
- 変更トークンは UserDefaults に永続化し、`CloudKitChatError.requiresFullReset` を返して完全リセットを誘発。`handleAccountChanged` 時にキャッシュ＋トークンをクリアして健全状態へ復帰。
- `performInviteMaintenance` を実装し、`remoteUserID` が空のチャットや "pending" 招待を 7 日後に完全削除。CloudKit ゾーン削除と SwiftData 整合性を同時に保つルーチンを追加。

## CKSyncEngine Migration (Complete)
| フェーズ | ステータス | 主な成果 |
| --- | --- | --- |
| Phase 0 | ✅ | CKSyncEngine state を Application Support に永続化し、ロード/保存/リセットの整合性を確保。 |
| Phase 1 | ✅ | `CKSyncEngineManager.handleEvent` → `MessageSyncPipeline` 通知バスへ移行し、Combine ベースの旧経路を停止。 |
| Phase 2 | ✅ | `MessageSyncPipeline` へ CloudKit クエリ/トークン管理を集約、`requestLegacyRefresh` は薄いラッパのみとした。 |
| Phase 3 | ✅ | `MessageSyncService` を削除し、同期経路を `MessageSyncPipeline` に一本化。`MessageStore` / `OfflineManager` から旧参照を排除。 |
| Rollback 禁止 | ✅ | Combine 経路復活に伴う二重書き込み・競合条件を防ぐため、旧サービスへ戻さない方針を明文化。 |

## P2P / PiP 改善 (2025-09-21–22)
- 共有受諾直後にシステムメッセージ (`Message.makeParticipantJoinedBody`) を書き込み、参加完了イベントを CloudKit / SwiftData 双方で可視化。`[SYSJOIN]` ログで成否を追跡。
- `CloudKitChatManager` が `RoomMember` レコードとシステムメッセージから `remoteUserID` を推定するロジックを実装。`localParticipantInfo`→`apply` で SwiftData を更新し、空 UID 状態を解消。
- `ModelContainerBroker` を導入して mainContext の共有化と `inferRemoteParticipantAndUpdateRoom` 呼び出しを容易にし、プロフィール更新 API (`fetchParticipantProfile`/`upsertParticipantProfile`) を整備。
- `FloatingVideoOverlayBridge.activate()` から `P2PPictureInPictureManager` を呼ぶことで PiP を自動起動。PiP 非対応デバイスではデバッグログのみ残す。

## 参考ドキュメント統合
- Apple 公式ドキュメント「Sharing CloudKit Data with Other iCloud Users」「CKContainer.fetchShareParticipant」「CKDatabaseSubscription」を参照し、zone-wide share / 参加者追加 / サブスクリプション構成を公式推奨に合わせた。
- o3 MCP (2025-09-22) から得たガイダンス（`CKShare(recordZoneID:)`, `CKRecordNameZoneWideShare`, partial failure 取り扱い、token reset 対応）を実装へ反映済み。

## Historical Note (CloudKitChatManager 修正メモ 2025-09-22)
- 旧 UICloudSharingController ベースの招待再設計では、`CloudSharingControllerView` を SwiftUI に統合し、`InvitationManager` を delegate 化してシステム共有 UI を常時表示する構成を採用していた。
- その際 `ChatShareDescriptor` を `Identifiable` 化し、ゾーン/シェア生成の冪等化・チュートリアルメッセージの重複防止・`CKOperationGroup` 利用など Swift 6 互換修正を実施。
- ログ制御・ビルド検証 (`xcodebuild`/`swiftc`)・連絡先ピッカー統合は未対応としてフォローアップ扱いになっていた点を記録しておく。
## 2025-09-22 招待UI統一・P2P診断ほか（実装完了）

実装概要（完了）
- 招待UIの統一: 旧 InviteModalView を削除し、InviteUnifiedSheet に一本化。ChatList の「＋」「招待する」、Features の「はじめる」、ChatView（相手未参加時）から同一モーダルを使用。
- ルーム詳細モーダル: ProfileDetailView を RoomDetailSheet に改名し、SwiftUIモダン化（.presentationDetents、右上×、inline タイトル、メンバー一覧）。
- 参加直後メッセージ: CloudKitShareHandler が metadata.rootRecord == nil でも share.recordID.zoneID で推定し、"〇〇が参加しました" を投稿。
- SharedDB検証: SharedDB のゾーン横断クエリを撤去（一覧ログのみ）。
- P2P起動動線: MessageSyncPipeline が RTCSignal（offer/answer/ice）を適用し、成功時 consumed=true を保存。必要キーを desiredKeys に追加。
- ローディング終了: 共有受諾完了時に hideGlobalLoading をポスト（経路によらずクローズ）。
- モーダル右上×の共通化: InviteUnifiedSheet / RoomDetailSheet / NameInputSheet / ReactionListSheet / QRScannerSheet（QRは左=戻るアイコン）。
- ウェルカム判定: CloudKit の MyProfilePrivate.displayName を取得して未設定なら FeaturesPage を表示。NameInputSheet 保存時に displayNameUpdated 通知で即反映。

テスト観点（ログ）
- 招待UI: ChatView で evaluateOwnerInvitePromptIfNeeded → .sheet(InviteUnifiedSheet)。
- 参加直後: CloudKitShareHandler → "Participant joined" → "Posted join system message"。
- P2P: MessageSyncPipeline → "Applied RTCSignal records: N" → P2PController の Offer/Answer/ICE ログ。
- ローディング: 受諾成功後に "UI: hideGlobalLoading"。

主な変更ファイル
- Views: InviteUnifiedSheet.swift, RoomDetailSheet.swift（旧 ProfileDetailView.swift）, QRScannerSheet.swift, NameInputSheet.swift, ReactionListSheet.swift, ChatListView.swift, ChatView.swift
- Controllers: CloudKitShareHandler.swift, MessageSyncPipeline.swift, P2PController.swift, CloudKitChatManager.swift, CKSyncEngineManager.swift
- App: forMarinApp.swift（RootView）
