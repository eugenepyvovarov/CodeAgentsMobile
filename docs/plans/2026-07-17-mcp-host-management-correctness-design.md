# MCP Host Management Correctness

## Goal

Host-level MCP management must never apply data fetched for a stale host, discard valid OpenCode configuration, or leave the running OpenCode process out of sync with the configuration shown in the app.

## Design

Host and import views bind each asynchronous load to both a unique request generation and the selected server ID. A response may update loading, list, selection, or error state only when both still match. Rendered rows are also bound to the ID that produced them, so a newly selected host cannot expose actions backed by the previous host while its request is pending. SwiftUI selection tasks are keyed by server ID so superseded work is cancelled, while the generation check remains authoritative when SSH work does not observe cancellation.

`OpenCodeMCPServerConfiguration` remains the shared disk and live-API value, but gains lossless Codable behavior. Known properties stay strongly typed and unknown properties are retained in an additional-properties map. Editing starts from the existing full configuration and overlays only fields exposed by the editor. This preserves `enabled`, `timeout`, OAuth, `cwd`, and future OpenCode properties when their semantics remain compatible. Cross-host import copies the same lossless value with exact replacement semantics, including removal of destination-only OAuth settings.

Managed scheduler and avatar presence is evaluated only from project configuration because their paths, headers, and environment are project-specific. Writing a project disable stub also posts `enabled: false` to the active project runtime through a strict operation that requires OpenCode to report the target as disabled. If transport or returned status validation fails, the prior project entry and live configuration are restored. Reverting an override similarly removes the project entry and dynamically applies the full host configuration as one compensating operation; only connected or explicit OAuth/client-registration states count as applied, and other results restore the raw project override so the action remains retryable. The override editor has an explicit creation mode that uses the supplied host details without trying to load a nonexistent project entry.

## Verification

Regression coverage exercises stale-load admission and presentation binding, override edit mode, project-only managed assessment, unknown-field round trips, exact lossless host import, advanced-field preservation across edits, and disable/revert compensation after live transport failures. Focused MCP tests run first, followed by the repository’s canonical iOS unit suite.
