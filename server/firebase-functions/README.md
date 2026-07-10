# Firebase Push Gateway (Cloud Functions + Firestore)

This directory contains the Firebase backend used for push notifications (FCM).

## What’s included

- `registerSubscription` HTTPS function (called by the iOS app)
- `triggerReplyFinished` HTTPS function (called by the CodeAgents daemon on run completion)
- Firestore layout: `servers/{serverKey}/agents/{agentKey}/devices/{installationId}`
- Invalid FCM token pruning when Firebase reports a stale or malformed registration token

## Local setup

1) Install Firebase CLI

2) Create a Firebase project and add the iOS app:
- Bundle ID: `lifeisgoodlabs.CodeAgentsMobile`

3) Ensure Cloud Functions runtime is supported (Node 20+).

4) Install function deps:

```bash
cd functions
npm install
```

## Deploy

From this directory (this runs the TypeScript build automatically via `firebase.json` predeploy):

```bash
firebase deploy --only functions,firestore
```

## Security model

HTTPS functions require:

- `Authorization: Bearer <CODEAGENTS_PUSH_SECRET>`
- Secret must be **≥ 32 characters** and high-entropy (base64 / base64url charset)
- Request body capped at **16 KiB**; individual fields are length-limited
- In-process rate limits per secret hash and client IP; stricter cap on **new** server namespaces
- `triggerReplyFinished` does **not** create Firestore namespaces (register first)
- Firestore client rules deny all; only the Admin SDK (functions) can read/write

The secret is stored on each CodeAgents server environment and managed by the iOS app. Legacy installs
currently keep it in `/etc/claude-proxy.env`; the OpenCode scheduler daemon reads the same
`CODEAGENTS_PUSH_SECRET` / `CODEAGENTS_PUSH_GATEWAY_BASE_URL` values.

The push gateway is not part of foreground OpenCode chat. Foreground chat uses the direct
`iOS app -> SSH -> opencode serve` path; this gateway only handles offline/background completion
notifications from the CodeAgents daemon.

### Endpoints

| Function | Caller | Purpose |
|----------|--------|---------|
| `registerSubscription` | iOS app | Upsert device FCM token for `(secret, cwd)` |
| `unregisterSubscription` | iOS app | Delete device (one `cwd` or all agents for secret) |
| `triggerReplyFinished` | Daemon / iOS | Send completion push to registered devices |
| `cleanupStalePushRegistrations` | Scheduler (daily) | TTL purge of stale devices/agents/servers (90 days) |

### Notification privacy

By default the lock-screen body is **`Reply ready`** and the title is the agent display name
(or `CodeAgents`). Path fragments from `cwd` are never used as the title.

To show a sanitized text preview, callers must set `include_preview: true` and send `message_preview`.
Without that flag, any preview field is ignored.

## Completion sources

`triggerReplyFinished` accepts completion notifications from both supported server-side sources:

- Legacy foreground Claude proxy runs after `ConversationManager` emits the final result.
- OpenCode scheduled-task runs after the daemon sends `prompt_async`, observes the OpenCode session idle,
  hydrates `/session/:id/message`, and computes the assistant preview/count.

For OpenCode scheduled tasks, `conversation_id` should be the OpenCode session id so iOS unread tracking
and chat hydration refer to the same session.

## Notification preview sanitization

`triggerReplyFinished` accepts an optional `message_preview` for the visible push notification body. The
gateway removes fenced `codeagents-ui` and `codeagents_ui` blocks from that preview before whitespace
normalization and truncation, then uses the sanitized text for both the FCM notification body and the
APNs alert body. Text outside those render-only UI blocks is preserved in order.

If sanitization leaves no readable preview text, notifications keep using the existing safe fallback body
instead of exposing raw UI JSON.

## Validate

```bash
cd functions
npm run lint
npm run build
```
