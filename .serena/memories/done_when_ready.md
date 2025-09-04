# Done When Ready Checklist

- Build succeeds in Xcode without new warnings.
- Create a chat room and accept a share on a second device; verify both devices can send/receive messages.
- Confirm that sending the same message does not flip to failed state due to duplicate insert (CKError.serverRecordChanged is treated as success).
- Reaction operations still work; logs for reactions are minimal (no per-message fetch spam when zero reactions).
- Existing non-reaction logs remain visible for debugging.