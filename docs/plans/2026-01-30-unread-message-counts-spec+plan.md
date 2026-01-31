# Unread Message Counts on Agents List (Push + Proxy Cursor)

## Specification

### Overview
Show an unread message count badge (capped at `99+`) for each agent/chat in the Agents list (`ProjectsView`). Counts reflect “rendered incoming bubbles” produced by the agent (assistant output), including tool-use/tool-result, excluding thinking-only/empty content. Counts are per-device (no cross-device read sync). If pushes don’t arrive, counts may be stale/missing (acceptable).

### Goals
- Display an unread count per `RemoteProject` row in `ProjectsView`.
- Definition of unread messages matches what the chat UI renders as distinct bubbles:
  - Count assistant “message bubbles” derived from content blocks of type:
    - `text` (non-empty after trimming)
    - `tool_use`
    - `tool_result`
  - Do **not** count:
    - thinking blocks
    - empty/whitespace-only text blocks
    - `system` messages
    - `result` messages
    - user messages (outgoing prompts)
- Mark as read **only after**:
  - chat is fully synced, and
  - user has scrolled to the bottom (latest content is visible).

### Non-goals
- No background polling or list-time proxy sync when pushes don’t arrive.
- No cross-device read state.
- No app icon badge requirements (only in-list badge).

---

## Definitions

### “Renderable assistant bubble”
A single unit counted toward unread. It maps to what `StructuredMessageBubble` renders as separate bubbles.

- One per `ContentBlock` where:
  - `.text` with non-empty trimmed text → counts `+1`
  - `.toolUse` → counts `+1`
  - `.toolResult` → counts `+1`
- `.unknown` (including proxy “thinking”) → counts `+0`

### “Unread cursor”
A monotonic integer maintained by the proxy per conversation representing:

> Total number of renderable assistant bubbles emitted so far for this conversation.

### “Unread count”
Per agent (per device):

`unreadCount = max(0, lastKnownUnreadCursor - lastReadUnreadCursor)`

Displayed as:
- `1…99` as number
- `99+` if `>= 100`
- hidden if `0`

---

## Data model (iOS)

Add unread tracking fields to `RemoteProject` (SwiftData `@Model`), stored per device:
- `unreadConversationId: String?`
  - Conversation identifier associated with the unread counters (keep separate from `proxyConversationId` to avoid coupling unread tracking to transport state).
- `lastKnownUnreadCursor: Int` (default `0`)
  - Latest absolute cursor value learned from push and/or proxy headers.
- `lastReadUnreadCursor: Int` (default `0`)
  - Cursor value at the moment the user is considered to have read everything (after sync + scroll-to-bottom).

Derived:
- `unreadCount: Int` computed at runtime from the formula above.

Conversation mismatch behavior:
- If an incoming update references a different `conversation_id` than `unreadConversationId`:
  - Reset unread tracking epoch:
    - `unreadConversationId = incomingConversationId`
    - `lastKnownUnreadCursor = incomingCursor`
    - `lastReadUnreadCursor = 0`

---

## Proxy changes (`server/claude-proxy`)

### Maintain `renderable_assistant_bubble_count`
For each conversation, maintain a monotonic counter:
- Increment only when a new conversation event is appended of type `assistant`.
- For that assistant payload, increment by:
  - number of `content` blocks where `type` in `{ "text", "tool_use", "tool_result" }`, excluding:
    - `text` blocks whose trimmed text is empty
    - `thinking` blocks
    - any unknown/unhandled blocks

This counter must:
- survive restarts (persisted in conversation meta or derived on load from event log)
- be consistent with replay (NDJSON) and stream (SSE) behavior

### Expose cursor to clients
Add response header to:
- `POST /v1/agent/stream`
- `GET /v1/conversations/{conversation_id}/events`

Header name (proposed): `X-Proxy-Renderable-Assistant-Count: <int>`

Continue to include `X-Proxy-Last-Event-Id` as already present.

### Push trigger payload
When a run finishes, trigger push including absolute cursor:
- Extend push trigger payload to include:
  - `renderable_assistant_count` (absolute unread cursor)
  - (optional) `last_event_id` for diagnostics only

Trigger conditions:
- Recommended: trigger whenever a run finishes and the cursor may have increased (including error runs if they produced assistant/tool output).

---

## Firebase function changes (`server/firebase-functions`)

Update `triggerReplyFinished` to accept and forward the new fields:
- Accept `renderable_assistant_count` (int or string that parses to int).
- Include it in `dataPayload` so the iOS app can compute unread locally.

Keep `apns-collapse-id` behavior:
- APNs collapsing means you must send an **absolute** cursor, not deltas. The latest delivered push always carries the latest cursor.

---

## iOS push handling changes

### Parse push payload
Extend push payload parsing to include:
- `conversation_id` (optional)
- `renderable_assistant_count` (required for unread updates)

### Update per-agent unread state
When a `reply_finished` push is received or observed in delivered notifications:
1) Map `(server_key, cwd)` to `RemoteProject` (existing logic already maps push to project for routing).
2) Apply conversation epoch logic:
   - If `unreadConversationId` is nil, set it.
   - If mismatch, reset read cursor to 0 as described above.
3) Set `lastKnownUnreadCursor = max(existing, incomingCursor)` for same conversation id.
4) UI updates automatically via SwiftData observation.

### Handling pushes that aren’t tapped
On app foreground / Agents list appear:
- Optionally scan `UNUserNotificationCenter.current().getDeliveredNotifications()` and process any `reply_finished` notifications to update `lastKnownUnreadCursor`.
- This improves “open app, see counts” without requiring a tap.

(Still acceptable if counts don’t update when pushes don’t arrive or notifications were cleared.)

---

## Mark-as-read behavior (sync + scroll-to-bottom)

### “Fully synced”
A chat is considered fully synced when:
- `ChatViewModel` is not loading previous session (`isLoadingPreviousSession == false`)
- not processing (`isProcessing == false`)
- not showing active session recovery (`showActiveSessionIndicator == false`)
- no active streaming message (`streamingMessage == nil` or it’s complete)

### “Scrolled to bottom”
Because ExyteChat is used and per-bubble scroll state isn’t currently tracked, implement a practical definition:
- The latest message row is visible (e.g., detect `.onAppear` of the last rendered message bubble), *and* “fully synced” is true.

When both conditions are met:
- Set `lastReadUnreadCursor = lastKnownUnreadCursor` for that agent/conversation.

### Avoid false “read” updates
Do not update `lastReadUnreadCursor` from background/non-UI usage (e.g., Shortcuts creates a `ChatViewModel` headlessly). Read marking must be tied to the actual on-screen chat view + scroll-to-bottom detection.

---

## UX requirements
- In `ProjectsView` row, show a small badge on the right:
  - hidden when `unreadCount == 0`
  - `1…99` otherwise
  - `99+` if `>= 100`

---

## Edge cases
- Agent deleted: unread state deleted with `RemoteProject`.
- Clear chat / new conversation: unread epoch resets by conversation id mismatch or explicit reset when user clears.
- Out-of-order pushes: use `max(existing, incomingCursor)` for same conversation.
- Missing push fields: ignore update; keep existing counts.
- Notifications disabled / undelivered: counts may be stale/missing (acceptable).

---

## Implementation Plan

**Overall Progress:** `88%`

### Decisions (confirmed)
- Count unit = renderable incoming bubbles: assistant `text` + `tool_use` + `tool_result`.
- Exclude thinking-only/empty content.
- Mark read only after chat is fully synced and user has scrolled to bottom.
- Per-device unread state is acceptable (no cross-device syncing).
- UI shows exact count capped at `99+`.
- No fallback polling required when pushes don’t arrive.

### Tasks

- [x] 🟩 **Step 1: Define unread cursor semantics**
  - [x] 🟩 Document the exact block-counting rules (text non-empty, include tool_use/tool_result, exclude thinking/unknown/system/result).
  - [x] 🟩 Choose header + payload field names (`X-Proxy-Renderable-Assistant-Count`, `renderable_assistant_count`).

- [x] 🟩 **Step 2: Add unread cursor to proxy**
  - [x] 🟩 Maintain `renderable_assistant_bubble_count` per conversation (increment based on assistant payload blocks).
  - [x] 🟩 Persist the counter (reconstructed on load from events).
  - [x] 🟩 Return the counter via response headers on stream + replay endpoints.
  - [x] 🟩 Include the counter in push trigger calls.

- [x] 🟩 **Step 3: Extend Firebase push gateway**
  - [x] 🟩 Update `triggerReplyFinished` to accept `renderable_assistant_count`.
  - [x] 🟩 Forward it in the notification `data` payload (absolute value, not delta).

- [x] 🟩 **Step 4: Add unread fields to iOS model**
  - [x] 🟩 Add `unreadConversationId`, `lastKnownUnreadCursor`, `lastReadUnreadCursor` to `RemoteProject`.
  - [x] 🟩 Add helper computed property/function to derive `unreadCount` and cap display text (`99+`).

- [x] 🟩 **Step 5: Update iOS push handling**
  - [x] 🟩 Extend push payload parsing to read `conversation_id` + `renderable_assistant_count`.
  - [x] 🟩 On receipt / delivered-scan, map `(server_key, cwd)` to `RemoteProject` and update unread fields with epoch rules.
  - [x] 🟩 Ensure out-of-order pushes don’t decrease `lastKnownUnreadCursor`.

- [x] 🟩 **Step 6: Show unread badge in Agents list**
  - [x] 🟩 Add badge UI to `ProjectRow` (right side), hidden at 0, capped at `99+`.
  - [x] 🟩 Verify layout in both normal and edit modes.

- [x] 🟩 **Step 7: Mark-as-read when synced + bottom**
  - [x] 🟩 Implement “fully synced” + “bottom visible” detection in `ChatDetailView`.
  - [x] 🟩 When satisfied, set `lastReadUnreadCursor = lastKnownUnreadCursor` for the active project.
  - [x] 🟩 Ensure this is only driven by the on-screen chat UI (not by Shortcuts/background view models).

- [ ] 🟨 **Step 8: Tests & validation**
  - [x] 🟩 Proxy unit tests for block-counting rules (thinking excluded, empty text excluded, tool blocks included).
  - [ ] 🟥 iOS unit tests for unread epoch logic + cap formatting (`99+`).
  - [ ] 🟥 Manual test matrix: multiple pushes collapsed, conversation reset, scroll not at bottom, scroll to bottom.

### Important Implementation Details
- Use **absolute** cursor in push payload to survive APNs collapsing (`apns-collapse-id`).
- Keep unread tracking conversation-id scoped (reset counters when conversation id changes).
- “Unread messages” are **blocks** (bubbles), not SwiftData `Message` rows.
- Mark-as-read must not be triggered by non-UI code paths (Shortcuts / headless runs).

### File-level Changes (key insertion points)

- **Modify**
  - `server/claude-proxy/claude_proxy/conversation_manager.py` — maintain/persist renderable cursor; include in push trigger.
  - `server/claude-proxy/claude_proxy/push_notifications.py` — send `renderable_assistant_count`.
  - `server/claude-proxy/app.py` — add `X-Proxy-Renderable-Assistant-Count` headers for stream/replay.
  - `server/firebase-functions/functions/src/index.ts` — accept/forward `renderable_assistant_count` in push data.
  - `MobileCode/Models/Project.swift` — add unread cursor fields to `RemoteProject`.
  - `MobileCode/Services/PushNotificationsManager.swift` — parse/apply cursor updates; optional delivered-notification scan.
  - `MobileCode/Views/ProjectsView.swift` — display unread badge in `ProjectRow`.
  - `MobileCode/Views/Chat/ChatDetailView.swift` — detect synced+bottom and mark as read.

- **Add (optional)**
  - `MobileCode/Utils/UnreadCountFormatter.swift` — centralize cap formatting / display string.
  - Proxy test files under `server/claude-proxy/tests/` for cursor counting behavior.
  - iOS tests under `MobileCodeTests/` for unread logic.

- **Keep**
  - Existing message persistence model (`Message`) unchanged (unread is tracked per project via cursors).

### Progress Calculations
- Total steps: 8
- Completed: 7
- Overall Progress: `88%`
