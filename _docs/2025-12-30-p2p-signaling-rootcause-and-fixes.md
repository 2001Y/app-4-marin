## P2P ビデオ通話が繋がらない問題（原因・修正内容・通信ステップまとめ）

### 結論（今回の再現で起きていたこと）

- **P2P の接続（ICE/PeerConnection の connected）に至らない**、もしくは **connecting→reset/timeout→ やり直しを繰り返す**状態が発生していた
- 主因は 1 つではなく、**CloudKit シグナリングの取り回し（捨て条件・書き込み頻度・DB/zone 選択）** と、**P2P 状態リセットの発火条件**が複合していた
- 直近の再現（`room_DB76A898` / Marin‑A pid=32142 / Marin‑B pid=32149）では **両端末とも `state changed: connecting -> connected` を確認**（接続自体は成立）

### Marin‑B に「表示されない」のは正常？

まず「何が表示されないか」で正常/異常が変わります。

- **自分（ローカル）映像が表示されない**:
  - **Simulator では正常**です。`P2PController` のログにある通り、Simulator では `startLocalCamera skipped on Simulator` となり、`localTrack=nil` になります。
- **相手（リモート）映像が表示されない**:
  - **相手側が映像を送っていない/送れない（localTrack=nil）なら、こちらが何も表示できないのは正常**です。
  - ただし本プロジェクトの UI は、チャット画面右上の `FloatingVideoOverlay` が `remoteTrack ?? localTrack` を表示するため、**リモート track が存在するなら「オーバーレイ自体」は出る**設計です（黒画面/静止でも View は出る）。
  - もし「オーバーレイ自体が出ない」場合は、次が典型です:
    - **チャットタブ以外を表示している**（`FloatingVideoOverlay()` は `ChatView.chatContentView()` 内にだけ存在）
    - **roomID/参加者解決ができておらず P2P が開始されていない**（`startIfNeeded` が呼ばれていない）

---

### 今回の事象（現象ベースの要約）

- Offer/Answer と ICE が CloudKit 上に作られているのに、**片側で `apply` されない（または適用後にすぐリセットされる）**
- `activeCallEpoch` の進み方と捨て条件により、**同 epoch の ICE が“stale”扱いで破棄される**
- ICE 候補を **1 候補=1 レコードで大量書き込み**して **CloudKit の RateLimit/ZoneBusy** に入り、候補が相手に届かず ICE が失敗する

### 原因候補（優先度つき）

影響度（高）× 発生頻度（高）を上にしています。

- **(A) ICE が epoch 条件で破棄される（stale 判定が強すぎる）**: 高 × 高
- **(B) 接続中に状態リセット（close/reset）が入って交渉文脈が壊れる**: 高 × 中
- **(C) ICE 候補の CloudKit 書き込みが多すぎて RateLimit/ZoneBusy で欠損する**: 高 × 中
- **(D) signal 用途の DB/zone 選択が端末ごとに揃わず、片側が見えない場所に書く**: 高 × 中（環境/参加形態に依存）
- **(E) Offer/Answer の役割（isOfferCreator/isPolite）が揺れて両者が同時に offer する（glare）**: 中 × 低
- **(F) `currentRoomID` が timeout/retry で空になり、incoming signal を捨てる**: 中 × 低（過去の再現で確認）

### 最も可能性が高かった原因（確定したもの）

- **確定 1: stale ICE 破棄**
  - `activeCallEpoch` が先に進む/やり直しが走ることで、同 epoch の ICE でも `stale` になって破棄され、ICE 成立に必要な候補が揃わなかった。
- **確定 2: CloudKit 書き込み過多による RateLimit**
  - ICE 候補を 1 件ずつレコード化して短時間に多数書くため `Server Rejected Request` 等が発生し、候補欠損 →ICE 失敗に繋がった。
- **確定 3: 接続中の不要な close/reset**
  - `remote-participant-resolved` 等のイベントで `closeIfCurrent` が発火して接続文脈が壊れるケースがあった（接続中は defer するよう修正）。

---

## 修正した内容（要点）

※ここでは「何を変えたか」を開発者が追える粒度でまとめます。

### 1) ICE の stale 判定を緩和（SDP に紐づく epoch 基準へ）

- **目的**: offer/answer 自体は適用できているのに、ICE だけが `stale` 判定で捨てられるのを防ぐ
- **変更概要**:
  - `activeCallEpoch` ではなく、**「いま適用している remoteDescription に対応する epoch（floorEpoch）」**を基準に破棄判定する

### 2) 接続中の close/reset を抑止（defer）

- **目的**: `remote-participant-resolved` / `navigation-pop` などで接続中に自爆リセットしない
- **変更概要**:
  - `connecting` 中は `closeIfCurrent` を **defer** し、交渉を壊さない

### 3) ICE 候補の CloudKit 書き込みをバッチ化（batch-v1）

- **目的**: 1 候補=1 レコードの大量書き込みをやめ、RateLimit/ZoneBusy を回避する
- **変更概要**:
  - ICE 候補を **0.4 秒デバウンス / 最大 12 件**でまとめて 1 レコードにし、`candidateType=batch-v1` として送る
  - 受信側は `batch-v1` を展開して個別に `addIce` する

### 4) signal の zone/DB 選択の安定化（環境差で“見えない場所”に書かない）

- **目的**: 参加形態により shared/private が揺れて「片側が見えない DB に書く」事故を減らす
- **変更概要**:
  - `resolveZone(purpose: .signal)` で **shared が存在する場合は shared を優先**
  - signal 用途では `adjustDatabaseIfNeeded` の **強制 override** を避け、決まった scope/zone を維持

---

## 本プロジェクトにおける通信ステップ（テキスト / P2P ビデオ）

### まず登場人物（主要ファイルの責務）

- **`forMarin/Models/`**: アプリ内モデル（Room/Message 等）
- **`forMarin/Controllers/MessageStore.swift`**: テキスト送信・ローカル保存・UI 更新の起点
- **`forMarin/Controllers/CloudKitChatManager.swift`**: CloudKit 操作（zone 解決、record 作成/保存、シグナリング record の encode/decode）
- **`forMarin/Controllers/MessageSyncPipeline.swift`**: CloudKit からの変更（レコード）を取り込み、モデル更新や P2P へディスパッチ
- **`forMarin/Controllers/P2PController.swift`**: WebRTC（Offer/Answer/ICE、PeerConnection）と CloudKit シグナリング適用の中心
- **`forMarin/Views/ChatView.swift`**: 参加者確定時に `P2PController.shared.startIfNeeded(...)` を呼ぶ
- **`forMarin/Views/FloatingVideoOverlay.swift`**: チャット右上の小窓（`remoteTrack ?? localTrack` を表示）
- **`forMarin/Views/RTCVideoView.swift`**: `RTCVideoTrack` を `RTCMTLVideoView` でレンダリングする SwiftUI ブリッジ

---

### テキスト（チャット）通信のステップ（具体例つき）

**例:** Marin‑A が `room_DB76A898` に「こんにちは」を送る

1. **UI 入力**
   - `ChatView` の入力欄 → `MessageStore.sendMessage(...)` が呼ばれる
2. **ローカル反映（即時 UI 更新）**
   - `MessageStore` がローカルモデルに Message を追加（UI に即表示）
3. **CloudKit へ保存**
   - `CloudKitChatManager` が `Message` レコードを作成し保存（zone/DB は部屋・参加形態に依存）
4. **同期（受信側）**
   - Marin‑B 側で `CKSyncEngine` / `MessageSyncPipeline` が変更を検知・取り込み
   - 取り込んだ Message をローカルモデルへ反映 → `ChatView` が更新され表示される

ポイント:

- テキストは **CloudKit の通常データ同期**（Message レコード）で流れる
- P2P の Offer/Answer/ICE は **別系統のシグナリングレコード**（SignalEnvelope/SignalIceChunk）で流れる

---

### P2P ビデオ（WebRTC + CloudKit シグナリング）のステップ（具体例つき）

**例:** `room_DB76A898` で Marin‑A（offer 作成者）→ Marin‑B（answer 作成者）で接続する

#### 0. 開始トリガ

1. `ChatView` が参加者（remoteUserID）を確定
2. `P2PController.shared.startIfNeeded(roomID: room_DB76A898, myID: ..., remoteID: ...)`

#### 1. 役割決定（Perfect Negotiation の前提）

- `P2PController` が `isOfferCreator` / `isPolite` を決める
  - **offer 作成者**: Offer 生成 →publish
  - **answer 作成者**: Offer 受信 →Answer 生成 →publish

#### 2. Offer 生成 → 送信（CloudKit）

1. offer 作成者が `createOffer` → `setLocalDescription(offer)`
2. `publishOfferSDP` で CloudKit に **SignalEnvelope(offer)** を保存
   - 例: `SE_room_DB76A898#..._1767032587531_offer`

#### 3. Answer 生成 → 送信（CloudKit）

1. answer 側が SignalEnvelope(offer) を受信
2. `setRemoteDescription(offer)`
3. `createAnswer` → `setLocalDescription(answer)`
4. `publishAnswerSDP` で CloudKit に **SignalEnvelope(answer)** を保存
   - 例: `SE_room_DB76A898#..._1767032587531_answer`

#### 4. ICE 候補の交換（CloudKit）

1. ICE 候補生成（双方）
2. **バッチ化（batch-v1）**して SignalIceChunk を保存
   - 例: `IC_room_DB76A898#..._1767032587531_... count=9`
3. 受信側が `batch-v1` を展開 → 個別 `addIceCandidate`

#### 5. connected

- ICE/PeerConnection が `connected` になり、映像トラックが流れ始める（のが理想）

UI 表示:

- `FloatingVideoOverlay` は **`remoteTrack ?? localTrack`** を表示
- ただし Simulator では `localTrack` が作れないため、**実機での確認が前提**になりやすい

---

## 今回のログ上の具体例（抜粋）

### 接続成立（connected）

- Marin‑A: `state changed: connecting -> connected` / `✅ Connection established!`
- Marin‑B: `state changed: connecting -> connected`

### Simulator 由来の制約（ローカル映像がない）

- `startLocalCamera skipped on Simulator`
- `Local video track: nil`

---

## 次のフォロー（必要なら）

今回のスコープは「繋がる/繋がらない」でしたが、ログ上は connected でも **video が流れていない**警告が出ています。

- **Simulator での限界**（localTrack が作れない）で黒/無表示になり得る
- 実機で再現する場合、次は以下を点検すると早いです
  - `P2PController` で localTrack を確実に生成して sender にセットできているか
  - `FloatingVideoOverlay` が表示されるタブ/画面条件（チャットタブ）にいるか
  - `RTCVideoView` が `track.add(renderer)` を維持できているか（dismantle で外していないか）
