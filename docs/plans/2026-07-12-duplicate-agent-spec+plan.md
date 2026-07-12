# Duplicate Agent — Spec + Plan

Date: 2026-07-12  
Status: Implemented (full v1 — service, sheet, list/Abilities entry, env daemon sync, tests)  
Related: Abilities tab (`AgentAbilitiesView`), agent create (`AddProjectSheet` / `ProjectService`), env/tasks identity (`.codeagents/codeagents.json`)

## 1) Problem

Users often want **several agents with the same toolbox and personality**, each bound to a **different project workspace**:

- Agent A manages WordPress blog A  
- Agent B manages WordPress blog B  

Same skills / MCP tools / rules template; **separate** paths, env, files, chat, and scheduled tasks.

Today the only path is **New Agent** from scratch (empty folder + manual re-setup of skills, rules, MCP, env). There is no “clone this agent’s setup into a new workspace.”

## 2) Goal

Ship **Duplicate Agent**: create a **new** `RemoteProject` (new id, new remote directory, new daemon identity) that inherits selected configuration from a source agent, with an **empty chat** and no shared runtime session.

This is **not** multi-session chat on one agent. One agent remains one workspace + one active OpenCode session pin (current model).

## 3) Non-goals (v1)

- Multiple chats / threads under one agent  
- Full recursive copy of the entire project tree by default (can be a later option)  
- Cross-server duplicate (source and clone on different servers) in v1  
- Agent “templates” library (can build on duplicate later)  
- Sharing one OpenCode session, daemon `agent_id`, or task `remoteId` between source and clone  
- Automatic git clone of an external repo (user can do that in Files / chat after)

## 4) Product definition

### 4.1 Mental model

| Concept | Meaning |
|--------|---------|
| **Agent** | One remote folder + local `RemoteProject` + abilities + tasks + one chat |
| **Duplicate** | New agent folder + remapped local config derived from source |
| **Shared toolbox** | Global skills library + global MCP; clone re-enables the same set for the new agent |
| **Private data** | Path, env values, chat, tasks, project MCP, identity file |

### 4.2 User-facing copy

- Action label: **Duplicate Agent…**  
- Sheet title: **Duplicate Agent**  
- Primary button: **Duplicate**  
- Success: new agent appears in Agents list; optional “Open”  

Avoid “Copy chat” / “New chat” language.

## 5) Current baseline (code)

| Area | Today |
|------|--------|
| Agent model | `RemoteProject` — `id`, `name`, `displayName`, `path`, `serverId`, runtime/session fields |
| Create | `ProjectService.createProject` → `mkdir` under base path; `AddProjectSheet` inserts SwiftData |
| Delete | Local delete ± `deleteProject` remote `rm -rf` |
| Chat | Messages by `projectId`; `openCodeSessionId` single pin; clear wipes messages + pin |
| Skills | Global `AgentSkill` + per-agent `AgentSkillAssignment(projectId, skillSlug)` + remote `.opencode/skills` sync |
| Rules | `AGENTS.md` (and legacy paths) under agent path via `AgentRulesViewModel` |
| MCP | Project + global scopes via `CodingAgentMCPService` / OpenCode config on server |
| Env | `AgentEnvironmentVariable` by `projectId`; daemon `/v1/agent/env` keyed by `agent_id` |
| Tasks | `AgentScheduledTask.projectId`; daemon tasks by `agent_id` + cwd; run target `active_agent_chat` |
| Permissions | `ToolApprovalStore` keyed by agent UUID |
| Identity | `.codeagents/codeagents.json` (`proxyAgentId`); must be **new** on clone |
| AI provider | Per **server**, not per agent — clone on same server keeps provider |

## 6) Desired behavior (v1)

### 6.1 Entry points

1. Agents list row **swipe** (trailing): **Duplicate**  
2. Agents list row **context / edit menu** (same as Edit / Delete): **Duplicate Agent…**  
3. Optional later: inside agent (Abilities or overflow) — not required for v1  

### 6.2 Duplicate sheet fields

| Field | Default | Notes |
|-------|---------|--------|
| **Display name** | `"{source.displayTitle} Copy"` | User-editable; shown in list |
| **Folder name** | Sanitized from display name (unique under base path) | Same rules as `AddProjectSheet` / `SSHShellQuoting.sanitizedPathComponent` |
| **Server** | Source server (read-only in v1) | Cross-server = v2 |
| **Location** | Parent of source path (or server default projects path) | New path = `{parent}/{folderName}` |
| **Copy personality (AGENTS.md)** | On | Read source rules → write to new path |
| **Copy skill enables** | On | Same global skill slugs assigned + remote install sync |
| **Copy project MCP servers** | On | Non-managed project-scope MCP only; re-provision managed scheduler MCP via existing ensure |
| **Copy environment variables** | **Off** by default | If on: copy keys+values (user must understand secrets leave the source agent). Alternative sub-option: **keys only** (empty values) — prefer **keys only** as the safe default when section is expanded |
| **Copy tool permissions** | On | Clone `ToolApprovalStore` decisions for source agent id → new id |
| **Copy scheduled tasks** | **Off** by default | If on: local clones **disabled** (`isEnabled = false`), new ids, no `remoteId` until user enables + sync |
| **Copy project files** | **Off** (v1: omit from UI or show disabled “Coming soon”) | Avoid surprise `cp -a` of large trees / secrets |

Validation:

- Folder name must sanitize successfully and not collide with an existing directory on the server (probe `test -d`).  
- Display name may duplicate (allowed); folder name must be unique on server.  
- Source agent must still resolve a `Server`.

### 6.3 Always true for the clone (non-negotiable)

| Item | Clone behavior |
|------|----------------|
| `RemoteProject.id` | New UUID |
| `path` | New directory |
| `openCodeSessionId` + hydration anchors | Empty / reset |
| Local `Message`s | None |
| Unread cursors | Zero / unbound |
| `proxyAgentId` | Nil until first ensure; **new** identity file on new path (never copy source JSON) |
| `claudeSessionId` / proxy conversation fields | Nil |
| `createdAt` / `lastMessageAt` | Now / nil |
| Runtime | OpenCode defaults as for new agents (`openCodeMigrationVersion` current) |
| Active pin on daemon | None until first chat/session ensure |

### 6.4 Post-success UX

1. Insert clone into SwiftData; save.  
2. `ShortcutSyncService.sync` (same as create/delete).  
3. Dismiss sheet; Agents list shows new row (sort by `agentsListSortDate` → near top if `createdAt` used).  
4. Optional alert/toast: **Open agent** → `ProjectContext` activate clone.  
5. Do **not** auto-open chat stream until user opens (keeps list snappy).

### 6.5 Failure / partial failure

Prefer **transactional where possible**, with explicit cleanup:

1. Create remote directory  
2. Write copied remote artifacts (rules, skills, MCP)  
3. Insert local models  

If remote mkdir fails → no local row.  
If local save fails after remote create → attempt remote `rm -rf` new path (best effort) and surface error.  
If skill/MCP sync partially fails → keep agent, show non-blocking error: “Agent created; some setup failed: …” with Retry on Abilities later.

Never leave two agents sharing one path or one `proxyAgentId` file.

## 7) Copy matrix (normative)

### 7.1 Copy

| Source | Destination | How |
|--------|-------------|-----|
| Display title pattern | New `displayName` | User field |
| Folder name | New `name` + `path` | User field + mkdir |
| `serverId` | Same | v1 |
| Rules content | New `AGENTS.md` (primary write path) | SSH read source selection via existing rules loader; write primary path |
| Skill assignments | New `AgentSkillAssignment` rows | Same slugs; then `AgentSkillSyncService.installSkill` per skill |
| Project-scope MCP | New project OpenCode MCP config | Fetch source project servers; add each non-managed; call `ensureManagedSchedulerServerIfNeeded` on clone |
| Permissions | New agent id in `ToolApprovalStore` | Enumerate known tools + decisions; `setDecision` on new id |
| Env (if opted) | New `AgentEnvironmentVariable` rows | New `projectId`; mark `envVarsPendingSync`; sync after identity ensure |
| Tasks (if opted) | New `AgentScheduledTask` rows | New UUID; `isEnabled = false`; `remoteId = nil`; same schedule/prompt fields |

### 7.2 Do not copy

| Source | Reason |
|--------|--------|
| Chat messages | Separate work |
| `openCodeSessionId` / part digests | New conversation |
| Unread state | Fresh agent |
| `.codeagents/codeagents.json` | New daemon identity |
| Attachments under `.codeagents/attachments` | Belong to old chats |
| Managed MCP server row as editable clone | Re-provision via ensure |
| Server AI provider profile | Already server-scoped |
| Global MCP / global skills library rows | Shared already; only re-link assignments |
| `lastSuccessful*` provider markers | Fresh |

### 7.3 Env safety (v1 policy)

Default UI:

- **Copy environment: Off**  
- If user enables: **Keys only** (values empty) as default mode  
- Advanced: “Include values” with footnote: *Secrets will exist on both agents until you change them.*

After local insert with env keys, run identity ensure + `AgentEnvService.replaceEnv` for the **new** `agent_id` only.

### 7.4 Tasks safety (v1 policy)

If copy tasks is on:

- All clones start **disabled**  
- User reviews in Regular Tasks and enables  
- No daemon create until enable/sync (existing upsert path)  
- Prompts may still reference old blog URLs — user responsibility; optional footer warning

## 8) UX flows

### 8.1 Happy path

1. User swipes agent **Blog A** → Duplicate  
2. Sheet: name “Blog B”, folder `blog-b`, defaults (rules+skills+MCP+permissions on; env/tasks off)  
3. Duplicate → progress  
4. List shows **Blog B**; user opens → empty chat; Abilities shows same skills/MCP/rules; Files empty (or only rules/skills dirs)  

### 8.2 Name collision

Folder `blog-b` exists → inline error “A folder with this name already exists on the server.” Suggest `-2` suffix.

### 8.3 Offline / SSH failure

Error alert with underlying message; no orphan local agent if mkdir failed.

## 9) API / services (implementation target)

### 9.1 New types

```text
struct DuplicateAgentRequest {
  source: RemoteProject
  displayName: String
  folderName: String          // sanitized path component
  copyRules: Bool
  copySkills: Bool
  copyProjectMCP: Bool
  copyPermissions: Bool
  envMode: Enum { off, keysOnly, keysAndValues }
  copyTasks: Bool             // always disabled clones
}

struct DuplicateAgentResult {
  project: RemoteProject
  warnings: [String]          // partial skill/MCP failures
}
```

### 9.2 New service

`AgentDuplicationService` (name flexible) `@MainActor`:

1. Validate request + resolve `Server`  
2. Compute `path` (parent of source.path or server default)  
3. `ProjectService.createProject(name:on:customPath:)` or shared mkdir helper with full path  
4. Insert `RemoteProject` (OpenCode defaults, empty session)  
5. Optionally copy rules (SSH)  
6. Optionally copy skill assignments + sync installs  
7. Optionally copy project MCP  
8. Optionally copy permissions  
9. Optionally copy env (+ later sync)  
10. Optionally copy tasks (disabled)  
11. Save context; return result  

Keep `ProjectService` focused on filesystem; orchestration in duplication service.

### 9.3 Rules copy detail

Reuse rules load path resolution (`AgentRulesViewModel` / `AgentProjectFileLayout` candidates):

- Read effective content from source (including legacy fallbacks)  
- Write **primary** `AGENTS.md` on clone (migration-friendly; don’t copy legacy path layout unless content only)

### 9.4 Skills copy detail

For each `AgentSkillAssignment` where `projectId == source.id`:

- Insert assignment for clone id  
- `AgentSkillSyncService.installSkill` to clone path  

If skill missing from global library, skip + warning.

### 9.5 MCP copy detail

- `fetchServers(for: source, scope: .project)`  
- Skip managed scheduler server  
- `addServer(..., scope: .project, for: clone)`  
- `ensureManagedSchedulerServerIfNeeded(for: clone)`  
- Global MCP is not re-copied (already global on server)

### 9.6 Identity

Do not write identity during duplicate. First chat/tasks/env sync uses existing `ProxyAgentIdentityService.ensureAgentId` → creates **new** file on new path.

## 10) UI implementation sketch

| File / area | Change |
|-------------|--------|
| `ProjectsView` / `AgentChatListRow` | Swipe + menu: Duplicate |
| New `DuplicateAgentSheet` | Form fields + progress + errors |
| New `AgentDuplicationService` | Orchestration |
| `ProjectService` | Maybe `createProjectAtFullPath` if needed |
| Tests | See §12 |

Accessibility ids (suggested):

- `agent-duplicate-button`  
- `duplicate-agent-sheet`  
- `duplicate-agent-display-name-field`  
- `duplicate-agent-folder-name-field`  
- `duplicate-agent-confirm-button`  

## 11) Security & privacy

- Never log env values, prompts, or file contents in duplication logs (paths, ids, flags only).  
- Default env copy off / keys-only.  
- No copy of attachment trees.  
- Folder name sanitization must block path traversal (`sanitizedPathComponent`).  
- Duplicate is same-server only in v1 (credentials already on that server).

## 12) Testing

### 12.1 Unit

- Request validation (empty name, invalid folder, collision helper)  
- Copy matrix pure helpers: skill slug list remap, task clone fields (`isEnabled == false`, new ids, nil remoteId)  
- Env mode: keysOnly clears values  

### 12.2 Integration (mocked SSH)

- mkdir called with expected path  
- Rules write to `AGENTS.md`  
- Identity file **not** copied  
- `RemoteProject` session fields empty  

### 12.3 Manual / E2E

- Duplicate blog-style agent; open clone; chat empty; skills present; send one message (new session)  
- Source agent chat unchanged  
- Tasks not running on clone until enabled (if copied)

## 13) Acceptance criteria

1. User can duplicate an agent from the Agents list.  
2. Clone has new id, new path, new directory on server.  
3. Clone has empty chat and no OpenCode session pin.  
4. With defaults: rules + skills + project MCP + permissions copied; env and tasks not copied.  
5. Source agent unchanged (messages, session, tasks, env).  
6. Daemon identity is not shared (new `.codeagents/codeagents.json` on first ensure).  
7. Folder name collision is blocked with a clear error.  
8. Partial remote setup failures do not delete a successfully created agent without explanation; warnings are visible.  
9. No multi-session / thread UI is introduced.

## 14) Implementation plan (PR-sized)

### PR 1 — Core service + empty agent shell

- `AgentDuplicationService`: mkdir + `RemoteProject` insert only  
- Sheet with display name + folder name  
- List entry point  
- Unit tests for path/name validation  

### PR 2 — Abilities copy

- Rules, skills, project MCP, permissions  
- Warnings array + UI  
- Tests with fakes  

### PR 3 — Optional env + tasks

- Env modes + disabled task clones  
- Sync hooks  
- Copy warnings in footer  

### PR 4 (optional later)

- Copy selected project files / rsync exclude list  
- Cross-server duplicate  
- “Save as template”  

## 15) Open questions (resolved for v1)

| Question | Decision |
|----------|----------|
| Multi-chat vs duplicate? | **Duplicate only** for this use case |
| Same server only? | **Yes** v1 |
| Copy full tree? | **No** v1 |
| Env default? | **Off**; keys-only if enabled |
| Tasks default? | **Off**; disabled if enabled |
| Auto-open clone? | Optional button; default stay on list |
| Global MCP? | Not copied; already shared on server |

## 16) Future: templates

Duplicate v1 is the primitive. Later:

- “Save agent setup as template” (rules + skill slugs + MCP list, no path)  
- “New agent from template” without picking a live source  

No schema for templates required in v1.

## 17) Code review vs plan (2026-07-12)

Review of this plan against current create/delete, MCP, skills, permissions, push, soft-sync, and identity code. **Must-fix before implement** are marked 🔴; product clarifications 🟡; already safe ✅.

### 17.1 Gaps / missing from plan

| # | Severity | Finding | Spec amendment |
|---|----------|---------|----------------|
| 1 | 🔴 | **`ProjectService.createProject` does not return the real path** and can silently create under `/root/projects` on write failure while the UI still stores `basePath/name` (`ProjectService` lines 71–88 + `AddProjectSheet` 558–573). Reusing it as-is can leave clone with **wrong `RemoteProject.path`**. | Duplication must use a mkdir helper that **returns the path actually created**, or verify `test -d` on the intended path only and **never** accept fallback without updating local path. Prefer **no silent fallback** for duplicate. |
| 2 | 🔴 | **Collision not enforced today.** `mkdir -p` succeeds if the directory already exists. Plan says `test -d` probe — must run **before** mkdir and fail closed. | Explicit `directoryAlreadyExists` error; do not write rules/MCP into an existing foreign tree. |
| 3 | 🔴 | **Permissions copy is incomplete if implemented as “setDecision per known tool” only.** `ToolApprovalStore` has: allow/deny sets, **known tools**, **`agentPolicy` (allow-all/deny-all)**, and **`defaultsApplied` version**. `setDecision` **clears `agentPolicy`**. | Add `ToolApprovalStore.copyAgentApprovals(from:to:)` (or equivalent) that bulk-copies allow, deny, known, policy, and marks `defaultsApplied` at current `defaultsVersion` (2). Copy **policy last**. Do not loop `setDecision` if policy is set. |
| 4 | 🔴 | **Push registration not automatic on create.** New agents only get push via `ensureAppDefaultPush` (5‑min cooldown → only `refreshSubscriptions` of **already stored** cwds) or `registerProjectSubscription` when agent becomes **active** (`ContentView`). | After successful insert, call `PushNotificationsManager.registerProjectSubscription` for the clone (best-effort), even if not auto-opening. |
| 5 | 🔴 | **MCP `enabled: false` is lost** if copy uses `fetchServers` → `addServer`. `MCPServer` only maps disabled → `status: .disconnected`; `addServer` uses `previousEnabled ?? true` on empty clone → **re-enables** disabled servers. | Read source `OpenCodeMCPConfigDocument.serverConfigurations()` (or pass `enabled` through) and write with same `enabled` flag. |
| 6 | 🟡 | **Project model preference lives in `opencode.json`** (`OpenCodeProviderService` `setModelSelection`), not only server AI provider. Plan matrix omits it → clone falls back to server/global default model. | v1: document as **do not copy** (or optional “Copy model selection” later). Do **not** wholesale-copy `opencode.json` (would risk identity-ish / provider secrets / wrong MCP headers). |
| 7 | 🟡 | **Skills install only from local library** (`AgentSkillSyncService.installSkill` requires local folder). Assignments whose slug is missing on-device → warning only; **remote-edited skill files** on source are not mirrored (re-upload from library). | Keep as v1; surface warning “Skill X not on this device.” Optional later: `cp -a` remote skill dir source→clone. |
| 8 | 🟡 | **Rules write should reuse save path semantics.** `AgentRulesViewModel.save` applies `CodeAgentsUIRules.ensuringToolCallGuard` + `ensureRulesFile`. Raw content write alone can omit guard. | Rules copy: write primary `AGENTS.md` then `CodeAgentsUIRules.ensureRulesFile(..., onlyIfMissing: false)` (or shared helper). |
| 9 | 🟡 | **Managed scheduler ensure order vs identity.** Headers use `proxyAgentId` or fallback `project.id`. Ensure-before-identity is OK (uses new UUID); after first `ensureAgentId`, headers may need refresh — already happens on activate via `configureManagers`. | Order: mkdir → local insert → abilities copy → **optional** `ensureManagedSchedulerServerIfNeeded` **after** identity only if env/tasks need daemon now; else first open is enough. Never copy managed server row from source. |
| 10 | 🟡 | **Task clone fields.** Spec disables tasks and clears `remoteId`; also clear **`lastRunAt` / `nextRunAt`** (or recompute next only after enable) so UI doesn’t show source run history. | Normative: `lastRunAt = nil`, `nextRunAt = nil` until user enables. |
| 11 | 🟡 | **Env opt-in still needs identity + `AgentEnvService.replaceEnv` for new agent only.** Keys-only mode: empty values + `isEnabled` preserved; mark `envVarsPendingSync` if remote sync deferred. | Keep; do not call replaceEnv with source `proxyAgentId`. |
| 12 | 🟡 | **Delete cascade is pre-existing gap**, amplified by more agents: delete removes `RemoteProject` + optional remote dir + push unregister; **does not** cascade `Message`, `AgentSkillAssignment`, env, tasks, or `ToolApprovalStore` keys. | Out of scope for duplicate PR; note orphan risk. Optional follow-up: cascade on delete. |
| 13 | ✅ | **Soft sync** skips agents without `openCodeSessionId` — empty clone is safe. | No change. |
| 14 | ✅ | **Identity** not copied — correct; first `ProxyAgentIdentityService.ensureAgentId` writes new `.codeagents/codeagents.json`. | No change. |
| 15 | ✅ | **Global MCP / global skills** already shared — only re-link assignments. | No change. |
| 16 | 🟡 | **Create auto-activates** (`setActiveProject` + dismiss). Duplicate plan says stay on list — **must not** call `setActiveProject` unless user taps Open. Stealing active project mid-chat is a real regression. | Explicit non-goal: no auto-activate. |
| 17 | 🟡 | **Entry points:** swipe today is Rename + Delete only; edit mode has Edit/Delete buttons — add Duplicate to **both** swipe and edit-mode row actions. | Match plan §6.1. |
| 18 | 🟡 | **Parent path derivation:** use parent of `source.path`, not always server default (source may live outside `defaultProjectsPath`). Sanitize folder component only; never accept `..` in folder name (`sanitizedPathComponent`). | Spec already implies; tests should cover nested parent. |
| 19 | 🟡 | **User MCP headers** may embed source path/agent id (custom remotes). Blind copy keeps stale headers. | v1: copy as-is + warning if headers contain source `path` or `proxyAgentId`; do not auto-rewrite arbitrary headers. |
| 20 | 🟡 | **Partial failure cleanup:** if mkdir succeeds and local insert fails, `rm -rf` new path only (never source). If insert succeeds and skill/MCP fails, keep agent + warnings (plan OK). | Also: do not leave half-written `opencode.json` without warning. |
| 21 | 🟡 | **`ShortcutSyncService.sync`** after insert — required (create does this). | Keep. |
| 22 | 🟡 | **Cloud-init incomplete servers:** create already can fail SSH; duplicate should surface same class of errors; no special path. | Keep. |

### 17.2 Regression checklist (must not break)

| Area | Risk if wrong | Guard |
|------|----------------|-------|
| Source agent | Session, messages, env, tasks, MCP, rules mutated | Read-only against source except listing; never write under `source.path` |
| Active chat | Switch to clone mid-stream | No `setActiveProject` unless Open |
| Path identity | Chat/files/push hit wrong dir | Local `path` == verified remote mkdir path |
| Daemon agent_id | Tasks/env for source polluted | New identity file; never copy `codeagents.json` |
| Managed MCP | Scheduler tasks under wrong agent | Re-provision with clone id/path only |
| Tool policy | Clone asks for every tool again or inherits global only | Full UserDefaults agent map copy |
| Push | Clone never gets reply-finished | Explicit register after create |
| Soft list poll | N/A for empty session | Already skipped |
| Clear chat | Unrelated | Still only messages + session pin; does not affect clone |
| Global MCP | Accidental edit of global config | Only `scope: .project` writes on clone path |
| `opencode.json` model/provider keys | Overwrite server-wide by writing global path | Only project path config |
| Delete source after duplicate | Orphan local rows | Pre-existing; document |

### 17.3 Implementation order tweaks (from review)

1. **PR1** — mkdir **with collision probe + returned path**, `RemoteProject` shell, **no auto-activate**, **push register**, shortcut sync, unit tests for path/collision.  
2. **PR2** — rules (with UI guard), skills (library + warnings), MCP (enabled preserved, skip managed, ensure managed for clone), **permissions bulk copy**.  
3. **PR3** — env modes + disabled tasks (clear run timestamps) + identity-before-env-sync.  
4. Later — remote skill dir copy, model selection copy, file tree copy, delete cascade, cross-server.

### 17.4 Acceptance criteria additions

10. Clone `path` matches the directory verified on the server (no silent fallback mismatch).  
11. Existing directory name is rejected before any write.  
12. Agent-level allow/deny/**policy**/known tools match source for the new id.  
13. Disabled project MCP servers remain disabled on the clone.  
14. Source agent’s `openCodeSessionId`, messages, and path contents are unchanged after duplicate.  
15. Clone is registered for push (or warning if push unavailable) without requiring it to become the active agent.  
16. Duplicate does not change `ProjectContext.activeProject` unless the user chooses Open.

## 18) Summary

**Duplicate Agent** creates a **sibling workspace** with a similar toolbox for a different project (e.g. another WordPress site). It reuses existing per-agent isolation (path, env, tasks, chat) and fills the gap left by empty **New Agent**. It does **not** change the one-agent-one-chat model or require backend multi-session work.

**Plan is product-correct** but incomplete for several real code paths (path/fallback, collision, ToolApprovalStore shape, MCP enabled, push register, no auto-activate). Treat §17 as normative before coding.
