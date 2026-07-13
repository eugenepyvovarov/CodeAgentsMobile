# Privacy Policy for CodeAgents Mobile

**Last Updated: 2026-07-10**

## Summary

**CodeAgents Mobile stores most data on your iPhone/iPad.** We do not operate a general-purpose backend that reads your chat history or server passwords. Some optional features use third-party processors you enable.

## What Stays on Your Device

- **Server details**: SSH hostnames, usernames, ports, and related settings
- **Passwords & keys**: Stored in the iOS Keychain
- **Host key pins**: Trust-on-first-use SSH host public keys in Keychain
- **Projects & files**: Project names and local file-browser state
- **Chat history**: Conversations with the coding agent runtime (OpenCode), stored with SwiftData
- **Settings**: Preferences, tool approvals, and runtime selection
- **Photos library (optional)**: When you tap **Save to Photos** on an image or video, the media is written into your local Photos library with add-only access. We do not browse or upload your existing library for this feature.

## When Data Leaves Your Device

Data leaves the device only when you use a feature that requires it:

1. **SSH to servers you configure** — encrypted SSH sessions to hosts you add (including LAN hosts). Commands, files, and chat prompts may traverse that path.
2. **OpenCode on your server** — chat prompts and tool traffic go to the OpenCode process on *your* server; model providers (for example Anthropic, OpenAI, or others you configure) process messages under *their* policies.
3. **Agent daemon (optional)** — scheduled tasks and environment metadata may be stored on your server under `/opt/codeagents-daemon` (or equivalent). Access requires a per-install bearer token when enabled.
4. **Push notifications (optional)** — if you enable push, a device/installation identifier, server association metadata, and notification payloads may be sent via Apple Push Notification service (APNs) and Firebase Cloud Messaging / Cloud Functions. Lock-screen text defaults to a generic “Reply ready” body; content previews are only included when explicitly opted in.
5. **Cloud server providers (optional)** — if you create droplets/VMs through DigitalOcean or Hetzner integrations, API tokens you provide are used only to manage *your* resources with those providers.

## What We Do Not Do

- No advertising trackers
- No sale of personal data
- No access to your Keychain secrets from our servers (we do not hold them)

## Third Parties

| Processor | When used | Data |
|-----------|-----------|------|
| **Your SSH / OpenCode host** | Chat, files, tasks | Prompts, files, task schedules as you send them |
| **Model providers** (e.g. Anthropic) | When the agent calls a model | Prompts and tool results per that provider’s policy |
| **Apple APNs** | Push enabled | Device tokens, notification payloads |
| **Google Firebase** (Messaging / Functions / Firestore) | Push / registration enabled | Installation identifiers, hashed server keys, notification metadata |
| **DigitalOcean / Hetzner** | Cloud create flows | API tokens you enter; provisioned VM metadata |

Review each vendor’s privacy policy for processing details.

## Local Network

The app may connect to hosts on your local network (for example `192.168.x.x` or mDNS names) when you add them as SSH targets. iOS may show a local-network permission prompt for this purpose.

## Your Control

- Delete servers, projects, chats, and keys in the app (server/project deletion unregisters the device from the push gateway when a push secret is present)
- Uninstall the app to remove on-device data
- Disable push notifications in iOS Settings
- Rotate SSH keys, host-key pins, and daemon tokens by reconfiguring or reinstalling on the server

## Retention

- On-device data remains until you delete it or uninstall
- Server-side daemon task/env data remains on *your* server until you remove it
- Push registration records in Firebase are removed when you delete the related server/project in the app (unregister API), and stale unused registrations are purged after about 90 days

## Security

- Credentials and host pins use the iOS Keychain
- SSH transport is encrypted
- Daemon HTTP on the server prefers loopback (`127.0.0.1`) and bearer authentication when configured

## Updates

We will update this policy when product data flows change and surface material updates through the app or repository.

## Contact

Questions? Open an issue on the project’s GitHub repository.

---

**Bottom line:** Your coding data is under your control—on your device and on servers you choose. Optional push and cloud features use third-party processors only when enabled.

*Part of the open-source CodeAgents Mobile project.*
