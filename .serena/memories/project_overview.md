# Project Overview

- Purpose: iOS SwiftUI app enabling two-person shared chat with CloudKit shared zones, media attachments, and reactions.
- Tech stack: Swift, SwiftUI, SwiftData (local persistence), CloudKit (private/shared DB + record zones and CKShare), Combine.
- Key components:
  - Controllers: CloudKitChatManager (CloudKit orchestration), MessageSyncService (sync + fetch), MessageStore (UI-facing store and send orchestration), OfflineManager (offline queue), InvitationManager (share accept), ReactionManager (UI), PerformanceOptimizer (batching, optional).
  - Models: Message, ChatRoom, MessageReaction, Anniversary, MediaItem.
  - Views: ChatView and related UI components.
- Build/run: Open the Xcode project in `forMarin`, build/run to device (CloudKit requires real device or appropriate simulator entitlements).
- Notable behaviors: Per-room custom CKRecordZone using zoneName equal to `roomID` (e.g., `chat-XXXX`). Owner writes to private DB zone, participants write to shared DB zone.
- Logging: Custom `log(_, category:)` used extensively. Reaction-related logs can be noisy; current code reduces them.
