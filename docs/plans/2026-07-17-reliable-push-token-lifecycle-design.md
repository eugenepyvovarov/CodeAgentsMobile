# Reliable Push Token Lifecycle

## Problem

The demo server successfully completed a scheduled task but Firebase rejected the only registered device with `messaging/registration-token-not-registered`. The Cloud Function correctly removed that invalid registration, leaving the installation with no push destination until the app registered again.

The client currently calls `Messaging.deleteToken` whenever APNs registration completes. APNs registration can be requested from launch, foreground recovery, and subscription setup, so callbacks may overlap. One refresh can delete a token that another refresh has already uploaded, allowing Firestore to end up with an invalid token. Routine deletion also works against Firebase's lifecycle: Firebase Messaging already emits the current token at startup and whenever it rotates.

Daily inactivity is not a reason for an Apple push token to expire. Reinstalling the app, restoring it, APNs feedback, Firebase rotation, or explicitly deleting the FCM token can invalidate it.

## Design

Treat the FCM token as Firebase-owned state and subscription registration as an idempotent binding operation.

- `AppDelegate` sets the APNs token and asks `PushNotificationsManager` to ensure current subscriptions are registered. It never deletes the FCM token.
- `MessagingDelegate.didReceiveRegistrationToken` remains the authoritative rotation callback. It records the new token and starts the same idempotent subscription sync.
- `PushNotificationsManager` serializes token/subscription synchronization so launch, foreground, APNs, and Firebase callbacks cannot upload out of order.
- A sync fetches the current FCM token only after an APNs token exists, then registers every stored subscription using the stable installation ID. The gateway overwrites the installation's Firestore document with the newest token and updates `updatedAt`.
- If another sync request arrives while one is running, it marks the coordinator dirty and runs one additional pass with the latest token after the current pass finishes. Callers do not create parallel destructive flows.
- Launch and foreground synchronization provide recovery after a transient upload failure or server-side invalid-token pruning. Firebase's token callback provides immediate recovery after rotation.

No raw token is logged or newly persisted by the app. Firebase remains responsible for its local token cache; the existing redacted diagnostics remain Debug-only.

## Error Handling

Registration remains best-effort and does not block app startup. A failed gateway upload is logged without token contents. The next foreground, APNs callback, Firebase token callback, or explicit project subscription triggers another sync. The server continues pruning tokens that Firebase declares permanently invalid; it must not retain or retry an `UNREGISTERED` token.

The app cannot repair a token while uninstalled and cannot be remotely awakened after the only server token has become invalid. Once the app starts again, however, the foreground sync must restore the binding without requiring the user to toggle notifications or edit the server.

## Testing

- Unit-test the single-flight coordinator: concurrent requests produce no overlapping operation and coalesce into one follow-up pass.
- Unit-test that a request arriving during a failed pass still receives a follow-up attempt.
- Parse and project validation cover the AppDelegate and manager wiring.
- Run the focused push tests and the canonical repository CI when the local Xcode platform is available.
- Live verification requires a new TestFlight build: launch once, run the scheduled task, background the app, and confirm the daemon reports `sent=1` instead of `registration-token-not-registered`.

