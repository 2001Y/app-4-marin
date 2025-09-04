# Suggested Commands

- Open project: `open forMarin.xcodeproj` (or workspace if present)
- Clean build: Xcode Product > Clean Build Folder
- Run on device: Select a physical device target (CloudKit shared DB requires proper entitlements).
- View logs: Xcode Debug console; filter by categories like `CloudKitChatManager`, `MessageStore`, `MessageSyncService`.
- Reset local/Cloud data (from code via debug UI or temporary call): `CloudKitChatManager.shared.performLocalReset()` / `performCompleteCloudReset()` (use with caution in development).
- Lint/format: No configured CLI formatter in repo; rely on Xcode’s Swift formatting.
