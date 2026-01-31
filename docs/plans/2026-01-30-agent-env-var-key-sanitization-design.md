# Agent Env Var Key Live Sanitization

## Summary
Add live sanitization to the Agent Environment variable key editor so users immediately see uppercase, underscore-separated keys while typing. Validation remains on Save only.

## Goals
- Uppercase letters as the user types.
- Replace whitespace with `_` during editing.
- Strip disallowed characters (anything outside `A-Z`, `0-9`, `_`).
- Keep Save-time validation and duplicate checks as-is.

## Non-Goals
- Change storage format or server payloads.
- Add new validation UI or warnings during editing.
- Update MCP server env var editors.

## Approach
- In `AgentEnvironmentVariableEditorView`, replace the key `TextField` binding with a sanitizing binding that transforms input on every edit.
- Reuse the same sanitization logic in `normalizeKey` so Save-time normalization matches the live editing behavior.
- Keep existing validation rules (`[A-Z_][A-Z0-9_]*`) and duplicate key checks on Save.

## Data Flow
- Editing updates local `@State` via the sanitizing binding.
- Save normalizes the key (using the shared sanitization helper), validates, then persists to SwiftData.
- Sync logic remains unchanged.

## Risks
- Cursor may jump to the end when sanitization alters the text, a common SwiftUI input trade-off.

## Test Plan
- Manually edit a key with lowercase letters, spaces, and special characters; verify live sanitization.
- Save a valid key; verify it persists and syncs.
- Attempt to save an invalid/duplicate key; verify error messaging.
