# 改善アイデアログ (2025-10-26)

1. **MessageSyncPipeline 通知の型安全化**
   - 現状: `Notification.userInfo` に `roomID`/`recordName`/`localPath` などの string key を直書きしており、キータイプミスや nil で静かに失敗するリスクが高い。
   - 体験影響: 同期イベントが UI に反映されないと招待遅延や添付表示欠落につながり、利用者が「同期されない」と感じる恐れがある。
   - 提案: `MessagePipelineEvent` 構造体＋`NotificationCenter` の `object` で受け渡すか、`AsyncStream`/`Combine` の型付きチャンネルへ移行する。まずはキー列挙体を定義し、ロギングで強制 unwrap 失敗を検知できるようにする。

