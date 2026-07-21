# Seen Reply Push Suppression

## Problem

An interactive OpenCode reply can render useful text while the session still reports that it is processing. If the user reads that text and returns to the Agents list before the session becomes idle, completion is classified only from the current navigation state. The client then forces one unread message, always calls the Firebase gateway, and presents the delayed push because the chat is no longer active.

The same local completion and its FCM echo are handled as separate state changes. Cursor mutations are not saved until after the gateway request, so the FCM handler can read stale SwiftData state from another context. A delayed push carrying an older OpenCode session can also replace a newer active session and clear its hydration anchors.

## Invariant

Notify an installation only when the final rendered revision contains assistant output that installation has not seen.

- If the user leaves after seeing the latest revision and no more output appears, the reply remains read and that installation receives no push.
- If assistant output changes after the user leaves or backgrounds the app, the final revision is unseen and the installation receives a push.
- Other registered installations still receive the completion push.
- Duplicate, stale, or delayed FCM delivery must not reopen unread state, repeat hydration, or repin an older OpenCode session.

## Design

Track assistant-output revisions per send and per rendered message. Assistant-visible message mutations advance that message's revision. While the matching chat is foreground-visible, each changed bubble is recorded only when its tail is geometrically inside the message-list viewport (above the composer). Deleted transient progress rows are removed from the observation. Completion is seen only when every retained changed row is visible at its latest revision.

An unseen observation is retained until its unresolved rows are actually rendered or the project is left. It is not cleared on the notification delay: removing the evidence would incorrectly turn an offscreen row into read eligibility. Geometry evidence is bound to message ID, per-message reply revision, and global layout revision so a pre-update frame cannot acknowledge longer replacement content.

Apply local completion and remote reply-finished payloads through one versioned cursor policy. Cursor v2 is the count of unique, finalized OpenCode assistant runtime message IDs in one session. It is carried in the distinct `assistant_message_cursor` field; `renderable_assistant_count` keeps its legacy bubble-count meaning for already-installed builds, and `cursor_version` is emitted only with the new field. Live tool/text rows sharing a runtime ID count once, hydrated messages use the same unit, and the daemon counts assistant messages rather than their individual parts. Legacy row/part cursors are reset before accepting v2 so a genuinely newer completion cannot look numerically older.

REST hydration preserves `info.time.completed`; an in-progress assistant row stays streaming and does not advance v2. Completion is part of the hydration digest so a same-text transition from unfinished to finished is merged even when the runtime message and part IDs do not change. A full bounded soft-sync page triggers an unbounded snapshot before cursor mutation, so a recent-window count is never mislabeled as absolute. The scheduler fetches full session history for the absolute total, ignores non-text/tool-only rows that iOS does not persist, submits a generated `messageID`, and requires a renderable assistant with matching `parentID` and `time.completed` before a later idle sample can send push.

Interactive sends use the same exact parent correlation. A normal SSE terminal is verified against an unbounded REST snapshot before notification. If SSE closes early, fallback hydration preserves the server completion flag and succeeds only when the exact submitted prompt has a finalized renderable assistant; a partial or unrelated reply is surfaced as a stream failure and cannot advance unread or schedule a completion alert.

The exact matching assistant runtime ID is re-yielded from that REST snapshot and tagged as the submitted reply. Notification eligibility and preview selection require that tagged finalized ID, rather than accepting any interleaved session row. Existing installations migrate to v2 by baselining historical finality backfill as read; only post-migration incomplete-to-complete transitions count as newly unread. Soft-sync persists merged rows before advancing hydration anchors, and advances anchors without reordering the Agents list.

The cursor policy is:

- A seen local completion advances known to the absolute assistant count and read through that absolute count, without incorrectly consuming a newer count learned concurrently.
- An unseen local completion advances known while preserving an unread gap for the completed output.
- A same-session remote count at or below the known/read cursor is idempotent and cannot make content unread again.
- A newer same-session count advances known but never decreases read.
- Missing or malformed cursor data never regresses existing state.

Persist finalized messages, session state, and unread cursors on the owning main context before starting the gateway request. Receiving FCM from another context must therefore observe durable completion state.

Every interactive completion includes the current Keychain installation ID as `exclude_installation_id` and the current bounded token hint as `exclude_fcm_token`. The Firebase Function validates both with existing limits, removes the installation plus every stale registration carrying either its stored token or the hint, and deduplicates the remaining multicast tokens. The token hint is used in memory only, including when the installation document has not been stored yet; neither source identifier is logged or persisted by this path. If the source identity cannot be read, the client keeps its local coverage and skips multicast rather than risking a self-FCM echo. Scheduled-task callers omit both fields and remain compatible.

The initiating installation uses a revocable, one-second local request only when the final output is unread. Reading the exact reply cancels pending and delivered local requests. Completion-specific request IDs and their project mapping are persisted so cancellation still works after relaunch; the scheduler rechecks durable read state after `UNUserNotificationCenter.add` returns to close the add/remove race. Local taps carry project/server IDs and are accepted only with the app-generated request-identifier prefix, so they still route when no push secret exists while remote payloads continue to require the hashed server secret.

Push installation IDs and per-server push secrets remain device-local but use `AfterFirstUnlockThisDeviceOnly`, with best-effort migration from the prior protection class. This lets a reply that began while unlocked finish notification delivery after the phone locks.

Foreground delivery also checks the durable session and read cursor. A payload already read on this installation is suppressed even after navigating back. Notification state processing and foreground presentation are independently deduplicated by delivery/completion identity, so the AppDelegate and notification-center delegate cannot post two hydration events or show two banners for one completion. Invalid legacy IDs and conflicting OpenCode sessions are project-only task refreshes; tapping them opens Regular Tasks instead of an unrelated current chat.

Each v2 delivery also registers a canonical session/cursor dedupe alias alongside any completion or FCM delivery ID. This lets a cursor-only soft-sync fallback suppress a later daemon/APNs callback for the same finalized session state.

The source local request does not feed itself through the remote-push handler: its cursor was already saved and its exact stream rows provide visibility evidence. On reopen, persisted v2 content can satisfy the unread gate without a redundant network request.

When a remote payload raises unread before its content is local, Chat retains the advertised v2 session/count as a content requirement. Read acknowledgement waits until the local store actually contains at least that many unique finalized assistant runtime messages for the session, plus a finalized bottom row and revision-current geometry. Merely completing an empty or stale hydration cannot satisfy the gate, and app-generated error, permission, and question rows never contribute to the count. A send that produces only a local fallback/error schedules no reply-finished alert.

A push is not authoritative enough to replace a different non-empty active OpenCode session. Matching sessions may update cursors normally; a mismatched payload must not clear current hydration anchors. Session adoption from push remains allowed only when no local session exists, or after explicit runtime reconciliation establishes that the pushed session is current.

## Agents List Preview

The list preview reads a small project-filtered live SwiftData query. In-place hydration of an existing streaming placeholder therefore refreshes its user-visible content without depending on delayed notification time or generic project metadata that could reorder the Agents list on duplicates.

## Error Handling and Compatibility

Deploy the Firebase Function before shipping the iOS build. Old clients omit the source-exclusion fields and continue consuming the unchanged legacy count; the updated function and daemon remain backward compatible. The source local request is scheduled before gateway I/O, so APNs/gateway failure does not remove source-device coverage. UI processing state ends before notification I/O, while a generation-scoped UIKit background assertion remains alive through cursor persistence, local scheduling, and gateway delivery.

Payloads without a valid OpenCode session, v2 cursor marker, or absolute assistant count fail open for presentation and do not mutate v2 session/cursor state. A stale, malformed, or mismatched session routes to project task status when tapped and cannot silently replace the active chat session.

iOS background execution is finite. This change keeps short/normal interactive completions alive through notification scheduling, but it cannot guarantee observing a very long OpenCode reply after iOS suspends the app. Full long-running reliability requires a daemon-owned OpenCode completion watcher with exact source-installation/read-revision coordination; that is separate from suppressing the delayed alert after a reply was already rendered.

## Testing

- Seen revisions, then Back, then completion: read remains caught up, no local request survives, and the source installation is excluded from FCM.
- Back before new output, then additional output and completion: exactly one unread and no exclusion.
- Background before completion: unseen and pushed.
- Seen completion followed by immediate, delayed, duplicate, and lower-count FCM: no banner, unread, second hydration, or list reorder.
- Newer same-session FCM: one unread and one hydration.
- Session A to B followed by late A: B and its hydration anchors remain intact.
- Cursor state is visible from a second ModelContext before a blocked fake gateway resumes.
- Firebase excludes the source installation plus stale registrations with its token, deduplicates other tokens, and still notifies distinct devices.
- An empty/stale hydration cannot acknowledge an advertised v2 count that is not present locally.
- Tool and text rows sharing one OpenCode runtime message ID increment the cursor only once; daemon and iOS totals agree.
- A partial REST message cannot advance unread; its completion-only transition is rehydrated and advances once.
- The daemon does not accept a pre-start idle sample, and sessions beyond 100 messages still produce a monotonic full-history cursor.
- SSE disconnect with partial or unrelated completed content cannot finalize the submitted prompt or schedule push.
- Reading while local `add` is suspended, and reading after relaunch, both revoke the completion-specific request.
- Locked-device completion can retrieve the installation ID and push secret after first unlock.
- Malformed or unknown exclusion IDs are safely ignored or rejected without logging them.
- In-place `Typing…` to final-text hydration invalidates and reloads the list preview.

Run focused cursor, push, SwiftData, preview, and Firebase tests, followed by `./scripts/ci.sh`. Final device verification should reproduce both orderings: completion before Back and Back before completion.
