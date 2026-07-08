# Changelog

## 1.6 (Unreleased)

### Runtime migration
- **OpenCode is the only chat runtime.** Legacy Claude Proxy projects auto-migrate on open/send (runtime promote, MCP import from `.mcp.json`, optional API key copy, soft `AGENTS.md` rules copy).
- Local chat history is kept; remote OpenCode sessions start fresh (no Claude SSE history import).
- Managed task-scheduler MCP is re-provisioned on OpenCode; Claude CLI is not required to manage MCP after migration.

### Chat & settings UX
- Use the active agent name in chat UI (no more “Claude” labels).
- Settings and chat menus are **OpenCode-first**: runtime health, providers, and MCP without a Claude runtime picker or dual-mode segment.
- Shorter chat overflow labels (OpenCode, Environment, Refresh, Stop).
- When switching AI providers, existing chats now require a reset before you can continue (shows a banner with actions).
- Render richer “embedded UI” blocks in chat messages (with more stable media loading).
- Open existing chats local-first by deferring MCP/rules/media startup work until after chat recovery completes.

### Maintainability
- Remove dead Claude proxy chat recovery from `ChatViewModel` (~1.5k lines); chat no longer references `ClaudeCodeService`.
- Split `ChatViewModel` into focused files: send, hydration, MCP, tool approval, persistence, media prefetch, deferred startup, plus pure helpers.
- Collapse coding-agent runtime registry to **OpenCode-only**; delete production `ClaudeProxyRuntimeService` (legacy enum case kept for migration decode).
- Split runtime service blob into `CodingAgentRuntimeTypes`, `OpenCodeRuntimeService`, and `CodingAgentRuntimeRegistry`.
- Extract `AgentDaemonAuthService` (Anthropic API key vs token preference) so installer/task provider UI no longer depend on the Claude chat service for auth.
- Delete `ClaudeCodeService` chat stack and `ClaudeNotInstalledView`; keep shared `MessageChunk` / `LineBuffer` for OpenCode.
- Tasks “clear chat” uses OpenCode session reset only (no Claude proxy conversation path).
- Remove unused Settings API key / Claude token entry sheets.
- Split oversized views: OpenCode AI providers, Create Cloud Server, CodeAgents UI renderer, ChatView bubbles, Settings rows/SSH detail.
- Strip obsolete agent-daemon chat APIs from `ProxyStreamClient` (SSE stream, event replay, activate conversation, tool permission); keep canonical conversation resolve for tasks. Delete unused `ProxyEventRecovery`.
- Delete dead Claude stream decode stack: `StreamingJSONParser`, `ClaudeStreamingModels`, and `StreamingJSONParserTests` (OpenCode chat does not use them).

### Attachments & Media
- Add camera + photo library pickers for image attachments.
- Improve image preview rendering, sizing, caching, and prefetching.

### Files
- Add a file browser for easier navigation and sharing.

### Fixes
- Fix attachment chip clearing.
- Fix heatmap layout issues.
- Make Settings lists for Cloud Providers and SSH Keys use consistent grouped row styling.

## 1.5 (2026-01-30)

### Highlights
- **A rebuilt chat experience**: faster, clearer messages, and a smoother overall feel.
- **Background tasks**: start longer actions and keep using the app while they run.
- **Skills support**: add, manage, and use skills to expand what your agent can do.
- **Better file tools**: create, edit, upload, and share files more easily.
- **Agent controls**: set agent rules, manage permissions, and add custom environment variables (advanced settings).
- **More provider choices**: pick your AI provider — Anthropic, Z.ai, Minimax, or Moonshot.
