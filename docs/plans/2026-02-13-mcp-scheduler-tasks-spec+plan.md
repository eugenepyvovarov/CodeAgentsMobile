# MCP-powered Scheduled Tasks (Create / Update / Delete)

Date: 2026-02-13

## Specification

### 1) Goal

Add a built-in MCP server for scheduled tasks so skills can manage task schedules without creating a dedicated custom tool.  
The iOS app keeps the existing Scheduler UI as the single management experience.

### 2) Current baseline

- Scheduler is implemented in:
  - `RegularTasksView`
  - `RegularTaskEditorView`
  - `ProxyTaskService`
- Model: `AgentScheduledTask`
- Sync endpoints used today:
  - `GET /v1/agent/tasks?agent_id=...`
  - `POST /v1/agent/tasks`
  - `PATCH /v1/agent/tasks/{id}`
  - `DELETE /v1/agent/tasks/{id}`
- MCP UI/config already exists via:
  - `MCPService`
  - `MCPServersListView`
  - `GlobalMCPServersListView`
  - `AddMCPServerSheet`
  - `EditMCPServerSheet`

### 3) Desired behavior

1. Add MCP tools (create/update/delete) for scheduled tasks.
2. Tools are auto-scoped to the active project context (no explicit project/agent args in tool payload).
3. MCP must support fields already in the scheduler UI, including:
   - `title`
   - `prompt`
   - `isEnabled`
   - `time_zone`
   - `frequency` (`minutely|hourly|daily|weekly|monthly|yearly`)
   - `interval`
   - `weekday_mask`
   - `monthly_mode`
   - `day_of_month`
   - `weekday_ordinal`
   - `weekday`
   - `month`
   - `time_minutes`
4. MCP should also support skill-driven prompt composition fields:
   - `skill_slug`
   - `skill_name`
   - `file_references`
   - `message`
5. Task list UI remains unchanged visually and shows tasks from normal sync.
6. MCP-created tasks are synced/edited/deleted through existing app sync flow and share same sync state UX.
7. Schedule validation matches the app:
   - minute interval max 60
   - hourly interval max 24
   - existing limits for all other existing fields
8. Add a mandatory, non-deletable MCP server for scheduler tasks:
   - auto-provision if missing/misconfigured
   - cannot be removed or edited from iOS UI
   - service-level guard prevents direct removal/edit attempts
9. No separate MCP-only task list, badge, or audit trail in scheduler UI.
10. No dedicated MCP scheduling permission policy is added in this phase.

### 4) MCP tool contract (implementation target)

- Tool names:
  - `create_scheduled_task`
  - `update_scheduled_task`
  - `delete_scheduled_task`
- Write operations are active-project scoped by server runtime context and `agent_id`.
- Input contract must align with existing task payload naming and parsing behavior used by `ProxyTaskService`.
- For create/update operations:
  - `prompt` can be supplied directly.
  - If prompt is omitted, assemble from `message` + skill + attachments in existing prompt composition style.
- `delete_scheduled_task` requires `task_id` and performs `DELETE /v1/agent/tasks/{task_id}`.

### 5) Mandatory MCP server provisioning

- Provisioning runs automatically for active project usage.
- If required server exists but differs from expected command/name/config, app repairs/re-adds it.
- If removed externally, app re-adds it on next provisioning pass.

### 6) Open items resolved

- Scope: active project only.
- Scope of MCP actions: create/update/delete only.
- Sync UX: reuse existing app scheduler sync states.
- Conflict behavior: accept current app behavior (rare concurrent edge case).
- No badge sectioning by task source.

### 7) Acceptance criteria

- MCP tools can create/update/delete tasks for the active project.
- Scheduled tasks created by MCP appear in existing list/sync without app UI changes.
- Validation and frequency handling in MCP paths match existing scheduler validation behavior.
- Mandatory scheduler MCP server is auto-provisioned and repaired when missing.
- Managed scheduler MCP server cannot be deleted or edited from iOS UI.
- Same sync status/error behavior in `RegularTasksView` applies to MCP-origin changes.

---

## Plan

**Overall Progress:** `50%`

### Decisions (confirmed)

- MCP create/update/delete only.
- Auto-scoped to active project.
- No list/execute-now/status MCP tools.
- Include full recurrence fields and skill composition inputs.
- Mandatory managed MCP server, non-editable/non-removable.
- Same validation as existing UI.
- Same scheduler UI and sync UX for both MCP and user-created tasks.

### Tasks

- [ ] 🟥 **Step 1: Define MCP scheduler schemas and behavior**
  - [ ] 🟥 Define tool names and JSON schema for:
    - `create_scheduled_task`
    - `update_scheduled_task`
    - `delete_scheduled_task`
  - [ ] 🟥 Define required/optional fields and defaults.
  - [ ] 🟥 Define prompt composition behavior for `message` + `skill_slug`/`skill_name` + `file_references`.

- [ ] 🟥 **Step 2: Add MCP task-scheduler server in proxy**
  - [ ] 🟥 Add MCP server entrypoint for scheduling tools (Python proxy side).
  - [ ] 🟥 Implement create mapping to task API `POST /v1/agent/tasks`.
  - [ ] 🟥 Implement update mapping to `PATCH /v1/agent/tasks/{id}`.
  - [ ] 🟥 Implement delete mapping to `DELETE /v1/agent/tasks/{id}`.
  - [ ] 🟥 Add normalized error mapping for tool failures.
  - [ ] 🟥 Ensure project/agent context comes from active project runtime (no user-provided agent/project IDs).

- [x] ✅ **Step 3: Add required MCP server metadata**
  - [x] ✅ Add constant/server definition for mandatory managed scheduler MCP server.
  - [x] ✅ Add helper to identify managed server by name/type/command.

- [x] ✅ **Step 4: Implement iOS auto-provisioning**
  - [x] ✅ Add provisioning service that ensures required scheduler MCP server exists for active project.
  - [x] ✅ Repair missing or malformed managed server config automatically.
  - [x] ✅ Trigger provisioning on project activation and relevant MCP/scheduler entry points.

- [x] ✅ **Step 5: Lock managed server controls**
  - [x] ✅ Update `MCPService.removeServer` to block managed server deletion.
  - [x] ✅ Update `MCPService.editServer`/`addServer` to block managed server mutation.
  - [x] ✅ Return clear, explicit error for blocked operations.

- [x] ✅ **Step 6: Enforce UI restrictions in MCP views**
  - [x] ✅ Update `MCPServersListView` and `GlobalMCPServersListView` to disable/hide delete for managed server.
  - [x] ✅ Prevent edit action for managed server rows.
  - [x] ✅ Show user-facing non-blocking explanation in UI when action is unavailable.

- [x] ✅ **Step 7: Harden edit flow**
  - [x] ✅ Update `EditMCPServerSheet` so managed server cannot be edited.
  - [x] ✅ Keep safe no-op path for managed server edits.

- [ ] 🟥 **Step 8: Verify scheduler continuity**
  - [ ] 🟥 Validate MCP-created/updated/deleted tasks render through existing `RegularTasksView` sync.
  - [ ] 🟥 Confirm `TaskSyncReporter` and status UX behavior remains unchanged.

- [ ] 🟥 **Step 9: Operational resilience**
  - [ ] 🟥 Add provisioning retry/reconcile on transient failure.
  - [ ] 🟥 Keep user-visible error states clear without blocking regular chat tasks.

- [x] ✅ **Step 10: Documentation**
  - [x] ✅ Document MCP tool contract and managed-server behavior.

### Current status note

- Mobile-side provisioning and UI hardening are implemented.
- Proxy-side MCP endpoint implementation is still pending.

### Implementation details confirmed this pass

- Provisioned managed MCP entry is fixed as:
  - `name = codeagents-scheduled-tasks`
  - `url = http://127.0.0.1:8787/mcp`
- Managed-server mutations are blocked unless calls explicitly pass `allowManaged: true`.

### Important implementation details

- Keep scheduler validation and payload serialization in parity with current app behavior.
- No separate code path for task syncing in iOS; continue using `ProxyTaskService` and `RegularTasksView`.
- Use active-project context everywhere; do not add explicit project/agent params to MCP tools.
- Avoid adding a source badge in the scheduler list in this phase.

### File-level changes (target)

- **Add**
  - `MobileCode/docs/plans/2026-02-13-mcp-scheduler-tasks-spec+plan.md` (this file)
  - `MobileCode/MobileCode/Services/MCPTaskSchedulerProvisionService.swift` (managed MCP ensure/repair service)
  - Optional dedicated model/helper for managed-server identity
- **Modify (iOS app)**
  - `MobileCode/MobileCode/Services/MCPService.swift`
  - `MobileCode/MobileCode/Views/MCP/MCPServersListView.swift`
  - `MobileCode/MobileCode/Views/MCP/GlobalMCPServersListView.swift`
  - `MobileCode/MobileCode/Views/MCP/EditMCPServerSheet.swift`
  - Trigger location(s): one of `ContentView`, `RegularTasksView`, MCP views as needed for provisioning.
- **Modify (proxy repo)**
  - MCP scheduler server module and endpoint handlers.
- **Keep**
  - `MobileCode/MobileCode/Services/ProxyTaskService.swift`
  - `MobileCode/MobileCode/Views/Tasks/RegularTasksView.swift`
  - `MobileCode/MobileCode/Views/Tasks/RegularTaskEditorView.swift`

### Progress calculations

- Total major steps: 10
- Completed steps: 5
- Overall progress: `50%`
