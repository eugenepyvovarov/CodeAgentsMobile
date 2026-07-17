# Chat Crash and Crashlytics Design

## Goal

Fix the TestFlight crash caused by chat UI reading an invalidated SwiftData `Message`, and add reliable automatic crash reporting without collecting chat content, user identity, project paths, server addresses, credentials, URLs, or analytics events.

## SwiftData Crash Fix

The symbolicated TestFlight reports fail in `ChatMessageAdapter` while reading `Message.role`. The chat view still observes live `Message` models while deletion can invalidate their SwiftData backing storage. Chat deletion must therefore update all observable UI ownership before deleting persisted models.

`ChatViewModel.clearChat()` will capture the persisted messages, clear `messages`, `streamingMessage`, and related streaming UI state, and publish a message revision before it calls `ModelContext.delete` and saves. Transient OpenCode placeholder removal will likewise clear any streaming reference before deleting its model. This ensures SwiftUI and ExyteChat no longer receive a model after its backing data is invalidated.

Focused tests will cover both deletion paths with an in-memory SwiftData container. They will verify that observable chat state contains no deleted model after the operation and that persistence is cleared.

## Crashlytics Configuration

The existing Firebase Swift package and `FirebaseApp` bootstrap will be extended with the `FirebaseCrashlytics` product. Collection will be automatic for configured release builds. Firebase Analytics will not be linked or enabled.

The app will not call Crashlytics custom logging, user-ID, custom-key, breadcrumb, or nonfatal-error APIs. Consequently, reports are limited to Firebase's standard pseudonymous installation identifiers, crash stack/application state, and device/app/OS metadata. Crashlytics is not described as anonymous.

The Xcode target will run Firebase's supported Crashlytics symbol-upload script as its final build phase with the documented input files so TestFlight reports remain symbolicated. Debug builds will disable collection to prevent development crashes from polluting production diagnostics.

## Privacy and Publication

`PRIVACY_POLICY.md` and the Apple privacy manifest will disclose pseudonymous diagnostics, Google Firebase processing, automatic collection, and Firebase's current retention terms. The public CodeAgents Mobile project page will be checked and updated if its privacy copy would otherwise conflict with the new behavior.

## Validation

Run the focused chat deletion tests, inspect the resolved target dependencies and build phases, then run the canonical `./scripts/ci.sh` workflow through the repository's XcodeBuildMCP-backed automation. A deliberate production crash will not be added to app code; live Crashlytics delivery will be verified after a TestFlight build reports naturally or through a separate developer-only Firebase console procedure.
