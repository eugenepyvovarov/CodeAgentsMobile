# Tool approval in chat (Claude Code proxy)

## Summary
Add in-chat approvals for tool permissions (e.g., WebSearch) in the iOS chat UI only. The proxy will surface permission requests as streamed events and wait for client approval/denial using Claude SDK's tool permission callback. The app can allow once or persist approvals per agent or globally.

## Goals
- Show tool permission requests in chat and let the user approve or deny.
- Support three scopes: allow once, always for this agent, always global (plus deny variants).
- Send the approval decision to the proxy and unblock the current run.
- Persist per-agent and global decisions locally on device.

## Non-goals
- Apply approvals to Regular Tasks or other clients.
- Modify MCP tool behavior or add new tools.
- Build a centralized server-side approval store.

## Architecture
- Proxy uses Claude SDK streaming mode with `can_use_tool` callback.
- When the SDK requests permission, the proxy emits a `tool_permission` event into the conversation stream and waits for a client response.
- The iOS app detects `tool_permission`, prompts the user, and POSTs a decision back to the proxy.
- Approval decisions are stored locally (per-agent or global) and auto-applied for future requests.

## Data model (client)
- `ToolApprovalDecision`: allow | deny
- `ToolApprovalScope`: once | agent | global
- `ToolApprovalRecord`: decision + scope
- `ToolApprovalRequest`: permissionId, toolName, input, suggestions, blockedPath

Local storage in `UserDefaults`:
- `toolApproval.global.allow`: [toolName]
- `toolApproval.global.deny`: [toolName]
- `toolApproval.agent.allow`: {agentId: [toolName]}
- `toolApproval.agent.deny`: {agentId: [toolName]}

Decision precedence: once (current request) -> agent -> global. Deny at any scope overrides allow at the same scope.

## Proxy API
### New endpoint
`POST /v1/agent/tool_permission`

Request:
```
{
  "conversation_id": "...",
  "cwd": "/root/projects/WWW",
  "permission_id": "...",
  "behavior": "allow" | "deny",
  "message": "Permission denied by user." // optional
}
```

Response:
```
{ "ok": true }
```

### New stream event
When the proxy receives a permission request from the SDK it appends:
```
{
  "type": "tool_permission",
  "permission_id": "...",
  "tool_name": "WebSearch",
  "input": { ... },
  "permission_suggestions": [ ... ],
  "blocked_path": null
}
```

The proxy awaits a corresponding decision. If no response arrives within a timeout, it returns a deny result.

## Client flow
1) Stream receives `tool_permission`.
2) App checks local approvals.
3) If approved/denied is stored, auto-respond to proxy.
4) Otherwise show approval UI. On decision:
   - Send decision to proxy.
   - If scope is agent/global, persist in `ToolApprovalStore`.

## UI/UX
- Show a chat message like: "Permission required to use WebSearch."
- Present a sheet with actions:
  - Allow once
  - Always for this agent
  - Always (global)
  - Deny
  - Deny & remember
- After decision, dismiss the sheet and continue streaming.

## Error handling
- If proxy response fails, keep the request pending and show a retry message.
- If the proxy times out waiting for approval, it denies by default and the stream continues with a permission error.

## Testing
- Trigger a tool permission (WebSearch) and approve once. Verify stream continues.
- Deny once and ensure CLI receives a permission error.
- Set always-allow for agent and verify no prompt on the next request.
- Set global deny and verify all agents auto-deny.

## Rollout
- Chat-only. No changes to Regular Tasks.
- Proxy restart required after deployment.
