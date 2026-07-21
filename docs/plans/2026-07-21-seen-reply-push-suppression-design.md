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

Track an assistant-output revision for each interactive send. Assistant-visible message mutations advance the revision. While the matching chat is foreground-visible, the latest revision is recorded as seen. Completion compares the final revision with the seen revision rather than asking only whether the chat happens to be open at that instant.

Apply local completion and remote reply-finished payloads through one cursor policy:

- A seen local completion advances both known and read cursors to the absolute assistant count.
- An unseen local completion advances known while preserving an unread gap for the completed output.
- A same-session remote count at or below the known/read cursor is idempotent and cannot make content unread again.
- A newer same-session count advances known but never decreases read.
- Missing or malformed cursor data never regresses existing state.

Persist finalized messages, session state, and unread cursors on the owning main context before starting the gateway request. Receiving FCM from another context must therefore observe durable completion state.

When the final revision was seen, include the current Keychain installation ID as optional `exclude_installation_id`. The Firebase Function validates it with the existing installation-ID limit and removes only that registration from the multicast batch. It stores no read receipt or presence history and never logs the identifier. Scheduled-task callers omit the field and remain unchanged.

Foreground delivery also checks the durable session and read cursor. A payload already read on this installation is suppressed even after navigating back. Notification processing is deduplicated by delivery/completion identity so the AppDelegate and notification-center delegate cannot post two hydration events for one delivery.

A push is not authoritative enough to replace a different non-empty active OpenCode session. Matching sessions may update cursors normally; a mismatched payload must not clear current hydration anchors. Session adoption from push remains allowed only when no local session exists, or after explicit runtime reconciliation establishes that the pushed session is current.

## Agents List Preview

The list preview is a cached snapshot. In-place hydration of an existing streaming placeholder must invalidate that snapshot when its user-visible content changes. Use a dedicated preview revision or equivalent project-scoped invalidation; do not use generic project metadata or delayed notification time because those would reorder the Agents list on duplicates.

## Error Handling and Compatibility

Deploy the Firebase Function before shipping the iOS build. Old clients omit `exclude_installation_id` and retain current behavior; the updated function remains backward compatible. If the gateway request fails, an unseen reply may use the existing local-notification fallback. A seen reply must not create a local fallback on the source installation.

Payloads without a session or absolute assistant count fail open for presentation and do not mutate session/cursor state. A stale or mismatched session may still route the user to the project when tapped, but it cannot silently replace the active session.

## Testing

- Seen revision, then Back, then completion: read remains caught up and the source installation is excluded.
- Back before new output, then additional output and completion: exactly one unread and no exclusion.
- Background before completion: unseen and pushed.
- Seen completion followed by immediate, delayed, duplicate, and lower-count FCM: no banner, unread, second hydration, or list reorder.
- Newer same-session FCM: one unread and one hydration.
- Session A to B followed by late A: B and its hydration anchors remain intact.
- Cursor state is visible from a second ModelContext before a blocked fake gateway resumes.
- Firebase excludes only the requested registered installation; other devices receive the push.
- Malformed or unknown exclusion IDs are safely ignored or rejected without logging them.
- In-place `Typing…` to final-text hydration invalidates and reloads the list preview.

Run focused cursor, push, SwiftData, preview, and Firebase tests, followed by `./scripts/ci.sh`. Final device verification should reproduce both orderings: completion before Back and Back before completion.
