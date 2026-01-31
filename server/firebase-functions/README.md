# Firebase Push Gateway (Cloud Functions + Firestore)

This directory contains the Firebase backend used for push notifications (FCM).

## What’s included

- `registerSubscription` HTTPS function (called by the iOS app)
- `triggerReplyFinished` HTTPS function (called by `server/claude-proxy` on run completion)
- Firestore layout: `servers/{serverKey}/agents/{agentKey}/devices/{installationId}`

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

Both functions require:

- `Authorization: Bearer <CODEAGENTS_PUSH_SECRET>`

The secret is stored on each proxy server in `/etc/claude-proxy.env` and managed by the iOS app.
