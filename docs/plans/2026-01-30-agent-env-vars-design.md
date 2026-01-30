# Agent Environment Variables (per-agent) — Design

Date: 2026-01-30

## Summary

Add per-agent environment variables (name/value) editable in the app. Variables are applied server-side (proxy + scheduler) so that tool/command execution actually sees them, and the model is informed (names only) as part of the system prompt. Env variables are **proxy-only** (not supported for the legacy “claude over SSH” transport).

## Goals

- Let users define per-agent env vars (`KEY=VALUE`) with enable/disable.
- Apply env vars to **every proxy run** (interactive chat and scheduled tasks).
- Inform the model once per conversation (or when keys change) that env vars are set (names only).
- Support offline edits: save locally, mark “Pending sync”, and retry later.
- Make env/tasks portable across app reinstalls by persisting a stable proxy agent id in the agent folder.

## Non-goals (for initial version)

- Secrets management (values stored as plain text, not Keychain).
- Global env vars (only per-agent).
- Using env vars in the non-proxy SSH `claude` path.
- Fine-grained conflict resolution (server is overwritten by the last successful client sync).

## UX

- New sheet from the agent menu: “Environment Variables”.
- List of variables with:
  - Key (normalized + validated)
  - Value
  - Enabled toggle
  - Add/Edit/Delete
- Status at top:
  - Synced
  - Syncing…
  - Pending sync (offline or last sync failed)
  - Error (last error message)

### Key normalization / validation

On save:
- Trim
- Uppercase
- Replace whitespace runs with `_`
- Validate strict shell-safe format: `^[A-Z_][A-Z0-9_]*$`
- Reject duplicates after normalization.

## Identity: stable proxy agent id

To make tasks/env portable across app reinstalls, the proxy identity is stored in the agent folder:

- Path: `<agent cwd>/.claude/codeagents.json`
- Shape: `{"schema_version":1,"agent_id":"<uuid>"}`

Rules:
- On first open/chat: if missing, create it with the current local agent UUID.
- If present but does not match the local UUID, **server `agent_id` wins**; the app adopts it as `proxyAgentId` for all proxy calls.

## iOS storage model

- Add `RemoteProject.proxyAgentId: String?` (stable id used for proxy tasks/env).
- Add `RemoteProject.envVarsPendingSync: Bool` (+ optional `envVarsLastSyncError` / `envVarsLastSyncedAt`).
- Add a new SwiftData model `AgentEnvironmentVariable` scoped by `projectId`:
  - `projectId: UUID`
  - `key: String`
  - `value: String`
  - `isEnabled: Bool`
  - timestamps

## Proxy storage (SQLite)

Store env vars in the proxy scheduler DB (`tasks.db`) keyed by `agent_id`:

Table: `agent_env_vars`
- `agent_id TEXT NOT NULL`
- `key TEXT NOT NULL`
- `value TEXT NOT NULL`
- `enabled INTEGER NOT NULL`
- `updated_at TEXT NOT NULL`
- PRIMARY KEY (`agent_id`, `key`)

## Proxy API

- `GET /v1/agent/env?agent_id=...`
  - Response: `{ "env": [ { "key": "...", "value": "...", "enabled": true } ] }`
- `PUT /v1/agent/env`
  - Body: `{ "agent_id": "...", "env": [ ... ] }`
  - Replaces full set for the agent (simple “source of truth” sync).

## Applying env vars to runs

All proxy runs include `agent_id` in the request body:
- Interactive chat: iOS includes `agent_id` when calling `/v1/agent/stream`.
- Scheduled tasks: scheduler injects `agent_id` into `request_body` before starting a run.

The conversation manager loads enabled env vars for the agent and applies them to the runtime environment for the duration of the run.

## “Tell the model once” (names only)

The proxy injects a system prompt fragment on first run (or whenever enabled keys change):
- Compute `env_keys_hash = sha1(",".join(sorted(keys)))`
- Persist `env_keys_hash` in conversation `meta.json`.
- If hash differs, set/append a system prompt fragment like:
  - “Env vars set for this agent: `FOO`, `BAR` (names only).”

This works for scheduled tasks too, because it is server-side.

## Deletion behavior

- If the user deletes an agent locally **without** deleting server files: do **not** delete proxy env/tasks.
- If server files are deleted, proxy cleanup is optional/best-effort (not required for initial version).

