# TestFlight Version Preflight Design

## Goal

Prevent production automation from spending time resolving packages, signing, and archiving a binary that App Store Connect will reject because its marketing version belongs to a closed release train.

## Design

The TestFlight path in `scripts/artifact.sh` authenticates with App Store Connect first, then lists all iOS App Store versions. A small deterministic helper compares `VERSIONS.TXT` with the highest approved or closed version using numeric version components. The release proceeds only when its version is greater. Editable draft versions do not block a build because they have not closed their train; macOS and other platforms are ignored. Invalid version syntax and malformed App Store responses fail closed.

The gate runs before host cache preparation, package resolution, keychain unlocking, or Xcode archive. For the current live state, `1.6` in `READY_FOR_SALE` rejects another `1.6` build immediately, while `1.7` passes.

The publish command writes its verbose Xcode and upload stream to a release log. If publishing fails, automation prints only actionable diagnostics such as `ITMS-*`, compiler `error:`, archive/export failure markers, and the log path. This keeps the production worker payload small enough to retain the real Apple error instead of replacing it with an HTTP 413 ingestion failure.

Focused tests cover closed-train rejection, a valid version increment, numeric ordering, platform/draft filtering, and malformed versions. The live preflight is also exercised against the current App Store Connect response before the next binary is dispatched.
