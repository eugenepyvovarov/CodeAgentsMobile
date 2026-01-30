# Chat Incremental Sync Spec + Plan (Proxy)

## spec.md

### Overview
We will replace "full reload on re-entry" with incremental delta sync using the proxy event stream. The client should load only new changes since the last known event, keep the server authoritative, and only perform a full resync when the conversation changes or local state is corrupted.

### Problems to Solve
- Re-entering chat reloads from the beginning (slow).
- Tool calls sometimes appear as user messages.
- Messages can appear in the wrong order during updates.
- "Session Info" system block adds noise.
- Tool approval prompts are missing; tool_use/tool_result can appear without approval.

### Goals
- Incremental sync on re-entry, polling, and manual refresh.
- Avoid full list rebuilds; update in place.
- Correct ordering (no mix with older messages).
- Tool use/result always render as assistant bubbles.
- Hide "Session Info" system blocks only.
- Silent retries with low-friction UX.
- Restore tool approval flow in chat with per-agent remember.
- Provide a Permissions screen to manage allow/deny/ask per tool.

### Non-Goals
- Non-proxy chat flows.
- Large-scale optimization beyond ~200 messages.
- UI redesign beyond the specific fixes above.
- Server-side persistence of approvals (client-only).

### Delta Sync Patterns (Source-Based Guidance)
**Microsoft Graph delta queries** establish a pattern for incremental change tracking:
- Initial delta request returns current state plus a state token via `@odata.nextLink` (pagination) and ends with `@odata.deltaLink` for future change checks.
- Tokens are opaque; the client should replay the provided URLs rather than reconstructing them, and should not assume response ordering.
- Delta responses can include replays (the same item can appear multiple times) and items can appear in any page; merge logic must handle duplicates.
- If the service indicates a sync reset (e.g., HTTP 410 Gone with an empty delta token) or the delta token expires, the client must perform a full resync.
- Changes can have replication delays; retrying later is expected.
- Deleted items can be represented as "removed" objects.
These behaviors guide our incremental sync logic (dedupe, stable ordering, resync on invalid cursor).
Source: https://learn.microsoft.com/en-us/graph/delta-query-overview

**Salesforce Mobile SDK reSync** describes a similar incremental approach:
- reSync performs a full sync on first run, then returns only deltas since last run.
- It tracks the most recent modification timestamp and requests only records created/updated since that time.
- After incremental sync, deleted or filtered-out records may remain locally (ghosts) unless cleaned via a full sync or a cleanup method.
This informs our approach: incremental fetch by last event id, dedupe, and full resync when we must clean inconsistencies.
Source: https://developer.salesforce.com/docs/atlas.en-us.mobile_sdk.meta/mobile_sdk/entity_framework_native_inc_sync.htm

### Proposed Sync Strategy (Proxy)
#### State to Track
- Project-level cursor: `proxyLastEventId` (already present).
- Conversation identity: `proxyConversationId` + version/startedAt.
- Per-message metadata: add optional `proxyEventId` to Message (or store in a stable map keyed by Message.id) for deterministic ordering/deduping.

#### Incremental Sync Flow
1. On re-entry / refresh / poll: fetch proxy events since `proxyLastEventId`.
2. If no events returned, do nothing (no UI update).
3. If proxy indicates conversation changed or cursor invalid (sync reset / corrupted state), full resync:
   - clear local messages for this conversation
   - fetch events from `since=0`
4. Apply deltas:
   - parse each event
   - dedupe by `proxyEventId`
   - insert/append into `messages` using eventId ordering
   - if an event arrives out-of-order, insert at the correct index (fixes wrong order)
5. Update `proxyLastEventId` to max seen and persist.

#### Full Resync Conditions
- Proxy conversation ID change.
- Proxy signals invalid/expired cursor (server-authoritative reset).
- Detect corruption (e.g., eventId regression, duplicate storms, or parse failures).

### Ordering and Dedupe
- Canonical sort key: proxyEventId (server authoritative).
- If eventId missing, fallback to timestamp.
- Dedupe by eventId to handle replays (per delta-query behavior).

### Tool Call Rendering
- Any tool_use / tool_result events should be forced to assistant role for rendering.
- Always display as assistant bubbles.

### Tool Approval Strategy (Proxy + Client)
- Use per-agent allow/deny lists stored client-side (UserDefaults via ToolApprovalStore).
- Default allow list: Read, Grep, Glob.
- Any tool not in allow/deny is Ask (requires approval).
- Deny is a hard block with no prompt (server returns deny immediately).
- Approvals are sent with each proxy stream request so the proxy can pre-approve/deny.
- If not pre-approved, proxy emits tool_permission events; client displays approval sheet.
- Remembered decisions are per-agent; global scope is not used by default.

### Permissions UI
- New menu item below Agent Skills: "Permissions".
- List all known tools for the agent (defaults + tools observed in stream events).
- Each row shows:
  - Tool name
  - Allow/Deny two-way toggle
  - Swipe action "Reset to Ask" (removes tool from both allow/deny lists).
- Deny immediately blocks tool usage with no prompt.
- Allow skips future prompts.

### "Session Info" Filtering
- Hide only system messages whose display label is "Session Info."
- Other system or result messages remain visible.

### UI Update Strategy (Performance)
- Avoid `resetMessagesForProxySync` unless full resync is required.
- Update `messages` array in place (append/insert), not rebuild.
- Bump `messagesRevision` only when actual list changes.
- Keep streaming updates localized to the active message.

### Error Handling and Retry
- Silent retry with exponential backoff for 3 attempts.
- After 3 failures, show a subtle status pill ("Reconnecting...") until sync succeeds.

### Current Implementation Notes (Mobile + Proxy)
- Proxy already supports delta replay via `GET /v1/conversations/{conversation_id}/events?since=<event_id>` and SSE `Last-Event-ID`.
- Client already stores `proxyLastEventId` and passes it to `ProxyStreamClient`.
- Proxy emits `proxy_session` switch events and stable per-event ids.
- Current client resets on proxy version/startedAt changes, which triggers full reload.
- Current ordering is by timestamp; late events cause "wrong order".
- Tool calls can appear as user due to role inference logic.
- System messages always render as the Session Info view.
- Tool approval flow depends on receiving tool_permission events from the proxy.

### Detailed Change Set (Adapt Spec to Current Code)
#### Mobile (required)
1) **Persist proxyEventId per message**
- Add `proxyEventId: Int?` to `Message` model.
- Set it in `upsertStreamMessage` when `metadata["proxyEventId"]` exists.

2) **Event-id ordering + dedupe**
- Insert messages into `messages` by `proxyEventId` order (fallback to timestamp).
- Dedupe by `proxyEventId` first (fallback to JSON line if missing).

3) **Reduce full-resync triggers**
- Remove `versionChanged` (proxy version/startedAt) as a trigger to reset.
- If messages are empty, fetch `since=0` without deleting and rebuilding.
- Treat proxy `conversation_unknown` (404) as a full resync trigger.

4) **Force tool blocks to assistant role**
- If message blocks include `tool_use` or `tool_result`, force role = assistant.
- Apply in `upsertStreamMessage` and defensively in `ChatMessageAdapter`.

5) **Hide only Session Info**
- Filter system messages whose label is "Session Info" (keep other system/result messages).

6) **Retry behavior**
- Add 3 silent retry attempts with backoff; show status pill after failures.

7) **Tool approval storage + request payload**
- Persist per-agent allow/deny lists (already in ToolApprovalStore) and expose read APIs.
- When sending proxy stream requests, include tool approvals payload (allow/deny) for the agent.
- Default allow list populated once (Read, Grep, Glob).

8) **Tool approval prompt reliability**
- Ensure proxy emits tool_permission events (see proxy section) and client handles them in live stream.
- Deny returns immediately without prompt if tool is in deny list.

9) **Permissions UI**
- Add "Permissions" menu item below "Agent Skills".
- Permissions screen lists tools with Allow/Deny toggle and swipe "Reset to Ask".
- Unknown tools default to Ask (neither allowed nor denied).

#### Proxy Server (required for approvals)
1) **Expose last event id in headers**
- Add `X-Proxy-Last-Event-Id: <int>` on replay/stream responses for cheap “has changes” probes.

2) **Return explicit reset signals**
- Optional: on invalid cursor, return a structured error code or header to prompt full resync.

3) **Approval pre-filter**
- Accept `tool_approvals` payload on `/v1/agent/stream`.
- If tool in deny list: return PermissionResultDeny without prompting.
- If tool in allow list: return PermissionResultAllow without prompting.

4) **Python SDK streaming permission hook**
- Add PreToolUse hook that returns {"continue_": true} to ensure can_use_tool fires in streaming mode.

### Testing Scope (No Implementation Yet)
- Incremental re-entry: no full reload, no duplicate items.
- Out-of-order event arrival results in correct ordering.
- tool_use/tool_result always assistant.
- Session Info hidden; other system/result visible.
- Cursor invalid => full resync.
- Conversation change => clear local + full resync.
- Tool approval prompt appears when tool not pre-approved.
- Allow/Deny defaults honored; deny blocks without prompt.
- Permissions UI reflects allow/deny/ask correctly.

---

## plan.md

# Chat Incremental Sync Plan (Proxy)

**Overall Progress:** `0%`

## Decisions (confirmed)
- Incremental delta sync on re-entry/poll/refresh; avoid full reload.
- Server authoritative; full resync only on conversation change or corrupted state.
- Use eventId ordering with dedupe; allow late-event insert.
- Tool use/result always assistant bubbles.
- Hide only "Session Info" system block.
- Silent retry with 3 attempts then status pill.
- Tool approvals are per-agent with default allow list (Read, Grep, Glob).
- Deny blocks without prompting; Ask is undecided state.
- Permissions screen lists tools with Allow/Deny toggle + swipe reset to Ask.

## Tasks

- [ ] 🟥 **Step 1: Data and ordering foundations**
  - [ ] 🟥 Add per-message `proxyEventId` (or equivalent mapping)
  - [ ] 🟥 Define canonical ordering by eventId (fallback to timestamp)

- [ ] 🟥 **Step 2: Incremental sync algorithm**
  - [ ] 🟥 Update `syncProxyHistoryIfNeeded` to apply deltas without reset
  - [ ] 🟥 Full resync only on conversation change or cursor invalidation
  - [ ] 🟥 Dedupe replays and insert late events in correct order

- [ ] 🟥 **Step 3: Rendering fixes**
  - [ ] 🟥 Force tool_use/tool_result to assistant role
  - [ ] 🟥 Filter out "Session Info" system block only
  - [ ] 🟥 Ensure UI updates are in-place (no list rebuild)

- [ ] 🟥 **Step 4: Retry behavior**
  - [ ] 🟥 Add 3-step silent backoff retry
  - [ ] 🟥 Show/hide minimal status pill after repeated failures

- [ ] 🟥 **Step 5: Tool approvals**
  - [ ] 🟥 Add approvals payload to proxy stream requests
  - [ ] 🟥 Default allow list initialization
  - [ ] 🟥 Proxy pre-filter allow/deny and PreToolUse hook
  - [ ] 🟥 Permissions UI (Allow/Deny + swipe reset)

- [ ] 🟥 **Step 6: Tests and verification**
  - [ ] 🟥 Incremental re-entry (no full reload)
  - [ ] 🟥 Out-of-order events maintain correct ordering
  - [ ] 🟥 Tool calls always assistant
  - [ ] 🟥 Session Info hidden only
  - [ ] 🟥 Tool approvals prompt/allow/deny behave correctly

## Important Implementation Details
- Dedupe by eventId to handle replayed changes (delta-query behavior).
- Full resync when cursor is invalid or conversation changes (delta reset pattern).
- Incremental reSync uses last-known modification state; deletions/filters can leave ghosts unless full resync is done.
- Default allow list should be applied once per agent to avoid overwriting user choices.
- Deny has priority over allow; ask if neither present.

## File-level Changes (key insertion points)

- **Add**
  - (If needed) new lightweight helper for delta apply / ordering

- **Modify**
  - `MobileCode/ViewModels/ChatViewModel.swift` - incremental delta apply, dedupe, ordering, retry
  - `MobileCode/Models/Message.swift` - store `proxyEventId` or equivalent
  - `MobileCode/Views/Chat/ChatMessageAdapter.swift` - session info filter, tool role enforcement
  - `MobileCode/Views/Chat/ChatView.swift` - hide Session Info system block only
  - `MobileCode/Services/ClaudeCodeService.swift` - include tool approvals in proxy request
  - `MobileCode/Services/ToolApprovalStore.swift` - expose per-agent allow/deny and default initialization
  - `MobileCode/Views/Settings/PermissionsView.swift` (new) - permissions list UI
  - `MobileCode/Views/Settings/SettingsView.swift` (or agent settings menu) - add Permissions entry

- **Keep** (unchanged)
  - `MobileCode/Services/ProxyStreamClient.swift` - request/response transport unchanged

## Progress Calculations
- Total steps: 6 major steps
- Completed: 0
- Overall Progress: `0%`
