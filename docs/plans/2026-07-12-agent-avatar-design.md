# Agent Avatar Design

Date: 2026-07-12  
Status: approved for implementation

## Goals

- User can set an agent avatar from Abilities: **emoji**, **Photos**, or **Files**.
- Avatar is stored on the **remote agent folder** (multi-device SOT).
- Agent can set its own avatar from chat via a **managed local MCP**.
- **Duplicate Agent** can copy avatar (default on).

## Storage

### Identity (SOT metadata)

Path: `{project.path}/.codeagents/codeagents.json`

```json
{
  "schema_version": 2,
  "agent_id": "<uuid>",
  "avatar": {
    "kind": "emoji" | "image" | "none",
    "emoji": "🚀",
    "image": ".codeagents/avatar.png",
    "updated_at": "2026-07-12T12:00:00Z",
    "updated_by": "user" | "mcp"
  }
}
```

### Image bytes

- Relative path under project, default `.codeagents/avatar.png`
- App resizes/compresses before upload (max edge 256px, JPEG quality ~0.85 when needed)
- Missing/corrupt image → monogram fallback

### Local cache (`RemoteProject`)

Optional fields for list paint: kind, emoji, local thumbnail path, remote `updated_at`.  
Remote identity always wins on refresh.

### Identity write safety

`ProxyAgentIdentityService` / avatar writers **must merge**: never wipe `agent_id` when updating avatar; never wipe `avatar` when ensuring `agent_id`.

## UI

- Entry: Abilities overview — tappable avatar + “Change Avatar” sheet
- Actions: Emoji · Photo · File · Clear
- `AgentAvatarView`: monogram | emoji | image
- Agents list uses cached/remote-refreshed avatar

## MCP

Managed local MCP `codeagents-avatar`:

- Provisioned into project OpenCode MCP config (command + env `CODEAGENTS_PROJECT_PATH`)
- Script deployed to `.codeagents/mcp/codeagents_avatar_mcp.py`
- **Stdio wire format: NDJSON** (one JSON-RPC message per line) — OpenCode uses
  `@modelcontextprotocol/sdk` `StdioClientTransport`. Content-Length-only framing
  hangs the handshake until timeout (seen as “Operation timed out after 30000ms”).
- `SCRIPT_VERSION` in the script is matched by the app; stale remotes are force-redeployed.
- Tools:
  - `get_agent_avatar`
  - `set_agent_avatar_emoji` `{ emoji }`
  - `set_agent_avatar_image` `{ path }` (project-relative; copy into `.codeagents/avatar.png`)
  - `clear_agent_avatar`
- Protected as managed (not user-deletable without allowManaged)
- Agents must use these tools (not hand-edit `codeagents.json`) — see UI rules + MCP instructions

## Duplicate

- Toggle **Copy avatar** (default **on**)
- After new identity: merge source `avatar` + copy image file if present
- Failures → warning only

## Out of scope (v1)

- Camera capture
- Animated avatars
- Push/live avatar updates mid-chat
- MCP download-from-URL (agent downloads then sets path)

## Testing

- Identity merge encode/decode
- Path validation for MCP image paths
- Avatar view monogram/emoji branches
- Duplicate request copies avatar flag
- MCP provision writes expected server name
