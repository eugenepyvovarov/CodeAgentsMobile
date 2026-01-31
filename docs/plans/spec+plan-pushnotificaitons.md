# Firebase Push Notifications (Proxy Chat) — Spec + Plan

> Status: Draft (for review)

## spec.md

### Overview

Add push notifications to the **official App Store** build using **Firebase Cloud Messaging (FCM)**. Notifications are triggered **only when a proxy chat run finishes** (`type == "result"` emitted by `server/claude-proxy`) and deep-link to the **exact agent (project) chat**.

This integrates three parts:
1) iOS app (Firebase Messaging + deep linking)
2) `server/claude-proxy` (trigger push on run completion)
3) Firebase backend (Cloud Functions + Firestore) as the push gateway

### Goals

- Send a push notification when a proxy chat reply finishes.
- Notification content includes the agent name and a short preview of the final assistant reply.
- Tapping the push opens the app to the **exact agent chat**.
- Notify **all devices** subscribed for that agent (multi-device).
- Auto-subscribe a device to pushes for an agent **when the chat is opened** (no per-agent toggle yet).
- Suppress notification banner **when the app is foreground AND already in that chat**.
- App automatically configures the remote proxy by ensuring a per-server push secret in `/etc/claude-proxy.env`.

### Non-goals (for now)

- Push for non-proxy (SSH stream-json) mode.
- Push for intermediate streaming chunks; only final completion.
- Per-agent toggle UI.
- User accounts / auth (we rely on unguessable per-server secret).

### Key identifiers & security model

#### Per-server secret (shared across devices)

- Remote server stores `CODEAGENTS_PUSH_SECRET` in `/etc/claude-proxy.env`.
- Each device enabling push for that server reads existing secret; if absent, generates and writes one.
- Secret is **never** included in push payloads.

#### `serverKey`

- `serverKey = sha256(CODEAGENTS_PUSH_SECRET)` (hex).
- Used as the stable server identifier in Firestore and in push payloads.

#### `agentKey`

- `agentKey = sha256(cwd)` (hex), where `cwd` is the agent folder path on the server (e.g. `/root/projects/my-agent`).
- Used as the stable agent identifier in Firestore.

#### Deep-link payload (no host/username)

Push payload includes:
- `server_key` (`serverKey`)
- `cwd` (project path)
- (optional) `agent_key` (`agentKey`)

On device, the app maps:
- `server_key` → local `Server` by hashing locally stored secrets and matching
- `cwd` → local `RemoteProject` via `RemoteProject.path == cwd`

---

## Firebase backend (Cloud Functions + Firestore)

### Firestore data model

Collection layout:

- `servers/{serverKey}`
    - `createdAt`, `lastSeenAt` (timestamps)
    - optional cached display fields (best-effort): `serverDisplayName`

- `servers/{serverKey}/agents/{agentKey}`
    - `cwd` (string)
    - `agentDisplayName` (string, e.g. `project@server`) (best-effort)
    - `updatedAt`

- `servers/{serverKey}/agents/{agentKey}/devices/{installationId}`
    - `fcmToken` (string)
    - `platform` = `"ios"`
    - `updatedAt`
    - optional: `appVersion`, `bundleId`

Notes:
- `installationId` is a stable UUID generated on-device and stored in Keychain.
- Token rotation updates the existing `devices/{installationId}` doc.

### Cloud Functions (HTTPS)

#### 1) `registerSubscription`

Called by the iOS app whenever:
- the chat opens (auto-subscribe), and
- the FCM token changes (refresh all known subscriptions)

Auth header:
- `Authorization: Bearer <CODEAGENTS_PUSH_SECRET>`

Request JSON:
- `cwd` (string)
- `installation_id` (string UUID)
- `fcm_token` (string)
- `agent_display_name` (string, e.g. `project@server`) (optional but preferred)

Action:
- Compute `serverKey = sha256(secret)` and `agentKey = sha256(cwd)`
- Upsert `servers/{serverKey}`
- Upsert `agents/{agentKey}` with `cwd` and `agentDisplayName` (latest write wins)
- Upsert `devices/{installationId}` with `fcmToken`, timestamps

#### 2) `triggerReplyFinished`

Called by `server/claude-proxy` after a run completes.

Auth header:
- `Authorization: Bearer <CODEAGENTS_PUSH_SECRET>`

Request JSON:
- `cwd` (string)
- `conversation_id` (string) (optional; debug/tracing)
- `message_preview` (string) (optional; assistant final reply text)
- `finished_at` (timestamp string) (optional)

Action:
- Compute `serverKey = sha256(secret)`
- Compute `agentKey = sha256(cwd)`
- Load all `devices/*` under that agent
- Send FCM notification to all tokens (chunked to <= 500 per multicast)
- Remove invalid/unregistered tokens from Firestore based on send results

### Notification payload

- Title: `agentDisplayName` if available, else `basename(cwd)` (fallback: `Reply ready`)
- Body: `message_preview` if provided (truncated), else `Reply ready`
- Data payload:
    - `type = reply_finished`
    - `server_key = <serverKey>`
    - `cwd = <cwd>`

Recommended APNs collapsing:
- `apns.headers["apns-collapse-id"] = agentKey` (APNs limit: <= 64 bytes; `agentKey` is 64-char hex)

### Firebase project setup requirements

- Create Firebase project (owned by the official app).
- Add iOS app with bundle id: `lifeisgoodlabs.CodeAgentsMobile`
- Enable Cloud Messaging.
- Upload APNs auth key in Firebase Console (production for App Store).
- Enable Firestore.
- Enable Cloud Functions; deploy functions via Firebase CLI.
- Keep Firebase Admin service account credentials **out of git** (default Functions runtime service account is sufficient).

---

## iOS app changes

### Dependencies & config

- Add Firebase via SPM:
    - `FirebaseCore`
    - `FirebaseMessaging`
    - (optional) `FirebaseInstallations` (if needed; otherwise use local UUID)
- Add `GoogleService-Info.plist` to the Xcode target.
- Enable Xcode capabilities:
    - Push Notifications
    - Background Modes → Remote notifications

### App lifecycle integration

Add an `AppDelegate` (via `@UIApplicationDelegateAdaptor`) to:
- `FirebaseApp.configure()`
- register for remote notifications
- forward APNs token to FCM (`Messaging.messaging().apnsToken = deviceToken`)
- implement `UNUserNotificationCenterDelegate`:
    - `willPresent`: suppress if payload matches current active chat
    - `didReceive`: route to the matching agent chat and select Chat tab

### Local storage (Keychain)

Add Keychain entries:
- `push_secret_<serverId>`: `CODEAGENTS_PUSH_SECRET` (string)
- `push_installation_id`: stable UUID for this device/app install

### Push enabling per server (auto server config)

Add a Settings UI entry to “Enable Push Notifications” for a server that:
1) Requests notification permission (once).
2) Ensures FCM token is available.
3) Reads `/etc/claude-proxy.env` for `CODEAGENTS_PUSH_SECRET` (passwordless sudo).
    - If present: store in Keychain.
    - If absent: generate random secret (32 bytes base64), write to env file, store in Keychain.
4) Restarts `claude-proxy` service (same mechanism as current credential sync).

Important: update env-file writing logic to **preserve existing keys** and only upsert:
- `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` (existing behavior)
- `CODEAGENTS_PUSH_SECRET` (new)
- `CODEAGENTS_PUSH_GATEWAY_BASE_URL` (new)

### Auto-subscribe on chat open

On `ChatView` appear (proxy mode only):
- If push is enabled for the active server (secret exists in Keychain), call `registerSubscription`.
- Payload includes `server_key`, `agent_key`, `cwd`, `installation_id`, `fcm_token`, `agent_display_name`.

### Token refresh handling

When FCM token changes:
- Re-register all known subscriptions for this device (store a local list of `(serverId, cwd)` subscribed pairs, updated when chats open).

### Deep linking / navigation

When a notification is tapped:
- Extract `server_key` and `cwd`.
- Find matching `Server` by hashing each stored `push_secret_<serverId>` to `serverKey`.
- Find matching `RemoteProject` with `serverId == server.id && project.path == cwd`.
- Set `ProjectContext.activeProject` and force tab selection to Chat.

---

## server/claude-proxy changes

### Environment variables

`/etc/claude-proxy.env`:
- `CODEAGENTS_PUSH_SECRET=...` (required to enable push triggers)
- `CODEAGENTS_PUSH_GATEWAY_BASE_URL=https://us-central1-<firebase-project-id>.cloudfunctions.net` (required)

### Trigger on run finished

After emitting the final `result` event in `ConversationManager._run_agent`, call `triggerReplyFinished` Cloud Function:
- HTTPS POST with `Authorization: Bearer <secret>`
- JSON body includes `cwd` and `conversation_id`

Requirements:
- Must be non-blocking and non-fatal (short timeout; failures logged but do not affect the run).

### Dependencies

Add a lightweight HTTP client dependency (e.g., `httpx`) or use stdlib; keep minimal.

---

## Observability & troubleshooting

- Add structured logs in proxy for push trigger attempts (status code, response).
- Add debug logging in app for subscription registration (without logging secrets/tokens).

---

## plan.md

# Firebase Push Notifications (Proxy Chat) Implementation Plan

**Overall Progress:** `0%`

### Decisions (confirmed)
- Official **App Store** build supports push.
- Use **Firebase Cloud Functions + Firestore** as push gateway.
- Trigger only on proxy run completion (`type="result"`).
- Scope: **proxy chat only** (not SSH streaming mode).
- Deep link to exact chat via `serverKey = sha256(pushSecret)` + `cwd`.
- Notification content includes agent name (use `agentDisplayName` from app registrations).
- Multi-device: notify all devices subscribed for that agent.
- Auth: per-server secret stored in `/etc/claude-proxy.env`, shared across devices.
- Auto-subscribe when chat opens; no per-agent toggle yet.
- Suppress banner in foreground if already in that chat.
- `GoogleService-Info.plist` should **not** be committed; inject it in CI (Xcode Cloud secret) and keep only an example file in git.

### Tasks

- [ ] 🟥 **Step 1: Firebase project setup**
  - [ ] 🟥 Create Firebase project and add iOS app (`lifeisgoodlabs.CodeAgentsMobile`)
  - [ ] 🟥 Enable FCM + upload APNs key (production)
  - [ ] 🟥 Enable Firestore (locked down; Functions write only)
  - [ ] 🟥 Initialize Firebase Functions deployment tooling

- [ ] 🟥 **Step 2: Implement Cloud Functions + Firestore schema**
  - [ ] 🟥 Add `registerSubscription` HTTPS function
  - [ ] 🟥 Add `triggerReplyFinished` HTTPS function (Bearer secret → serverKey)
  - [ ] 🟥 Implement Firestore layout: `servers/{serverKey}/agents/{agentKey}/devices/{installationId}`
  - [ ] 🟥 Implement token cleanup on invalid/unregistered responses
  - [ ] 🟥 Document function URLs and expected payloads

- [ ] 🟥 **Step 3: Add Firebase Messaging to iOS app**
  - [ ] 🟥 Add Firebase SPM deps (`FirebaseCore`, `FirebaseMessaging`)
  - [ ] 🟥 Add `GoogleService-Info.plist` to target
  - [ ] 🟥 Enable Xcode capabilities: Push Notifications + Remote notifications background mode
  - [ ] 🟥 Add AppDelegate bridge to configure Firebase + APNs token forwarding

- [ ] 🟥 **Step 4: Add push secret + installation ID storage**
  - [ ] 🟥 Add Keychain storage for `push_installation_id`
  - [ ] 🟥 Add Keychain storage for `push_secret_<serverId>`
  - [ ] 🟥 Add SHA-256 helper for computing `serverKey`/`agentKey`

- [ ] 🟥 **Step 5: Server push enablement (auto-configure `/etc/claude-proxy.env`)**
  - [ ] 🟥 Update `ProxyInstallerService` to read existing `CODEAGENTS_PUSH_SECRET` (sudo) or generate+write if missing
  - [ ] 🟥 Update env writing logic to preserve existing keys and only upsert managed keys
  - [ ] 🟥 Add Settings UI to enable push per server and request notification permission

- [ ] 🟥 **Step 6: Auto-subscribe on chat open**
  - [ ] 🟥 On `ChatView` appear (proxy mode), call `registerSubscription`
  - [ ] 🟥 Store local list of subscribed `(serverId, cwd)` for token refresh replay
  - [ ] 🟥 Handle FCM token refresh by re-registering known subscriptions

- [ ] 🟥 **Step 7: Handle incoming notifications (foreground + tap)**
  - [ ] 🟥 Implement `UNUserNotificationCenterDelegate`:
    - [ ] 🟥 Suppress foreground banner if push targets current active chat
    - [ ] 🟥 On tap: map `server_key + cwd` → `Server` + `RemoteProject`, activate project, switch to Chat tab

- [ ] 🟥 **Step 8: Add proxy-side push trigger**
  - [ ] 🟥 Add `CODEAGENTS_PUSH_SECRET` support and update env example
  - [ ] 🟥 Add push trigger call in `ConversationManager._run_agent` after final result
  - [ ] 🟥 Ensure timeouts + non-fatal behavior + logging

- [ ] 🟥 **Step 9: Verification**
  - [ ] 🟥 Validate: enable push for server → open chat → receive push on completion
  - [ ] 🟥 Validate multi-device: two devices subscribed receive the same push
  - [ ] 🟥 Validate deep link routing to correct agent chat
  - [ ] 🟥 Validate foreground suppression when already in that chat

### Important Implementation Details

- Use `serverKey = sha256(pushSecret)`; do not include host/username in push payloads.
- Use `agentKey = sha256(cwd)` for direct document addressing (no Firestore queries).
- Keep secrets out of logs and out of push payloads.
- Proxy push trigger must not delay/interrupt Claude runs.

### File-level Changes (key insertion points)

- **Add**
  - `MobileCode/Services/PushNotificationsManager.swift` - FCM token, subscription calls, routing helpers
  - `MobileCode/Services/PushGatewayClient.swift` - HTTP client to Cloud Functions
  - `server/firebase-functions/` - Functions source and deployment config (or chosen equivalent)
  - `server/claude-proxy/claude_proxy/push_notifications.py` - Trigger implementation

- **Modify**
  - `MobileCode/CodeAgentsMobileApp.swift` - AppDelegate adaptor / notification delegate wiring
  - `MobileCode/Services/KeychainManager.swift` - push secret + installation ID
  - `MobileCode/Services/ProxyInstallerService.swift` - read/write `CODEAGENTS_PUSH_SECRET`, preserve env keys
  - `MobileCode/Views/SettingsView.swift` - server push enable UI
  - `MobileCode/Views/Chat/ChatView.swift` - auto-subscribe on appear
  - `server/claude-proxy/claude_proxy/conversation_manager.py` - call push trigger on run finished
  - `server/claude-proxy/deploy/systemd/claude-proxy.env.example` - document new env var
  - `server/claude-proxy/requirements.txt` - if adding http client dep

- **Keep**
  - Existing proxy streaming + replay APIs (unchanged behavior)

### Progress Calculations

- Total steps: 9 major steps
- Completed: 0
- Overall Progress: `0%`
