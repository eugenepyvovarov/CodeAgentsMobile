# Repository Guidelines

## Runtime note (important)
- **Claude Code chat is retired.** OpenCode is the only chat runtime (`OpenCodeClient`, `OpenCode*Service`, `CodingAgentRuntimeKind.openCode`).
- **Claude → OpenCode migration** runs automatically per project via `ClaudeToOpenCodeMigrationService` on chat open / send / runtime apply: promotes runtime, clears proxy transport anchors, copies compatible API keys, soft-copies `CLAUDE.md` → `AGENTS.md` when missing, imports `.mcp.json` into `opencode.json(c)`, ensures session + managed scheduler MCP, stamps `openCodeMigrationVersion`.
- Nil/unknown `agentRuntimeRawValue` resolves to **OpenCode** (not Claude).
- **CodingAgentRuntimeRegistry** always returns `OpenCodeRuntimeService` (legacy `.claudeProxy` enum case remains for decode/migration only).
- **Agent daemon** (`:8787`, `ProxyTaskService`, `server/claude-proxy`) remains for tasks/push/scheduled runs until rehomed — do not delete those paths when cleaning chat.
- Daemon Anthropic auth preference lives in **`AgentDaemonAuthService`** (not Claude chat).
- Do not expand Claude Code chat UX. MCP UI/management is OpenCode-primary (`CodingAgentMCPService` → `OpenCodeMCPService`).
- **Chat must not import `ClaudeCodeService`.** Residual CCS usage is tasks/installer/legacy settings only until retirement.

### ChatViewModel module map
| File | Responsibility |
|------|----------------|
| `ChatViewModel.swift` | Lifecycle, configure, public API, thin orchestration |
| `ChatViewModel+OpenCodeSend.swift` | Send / stream / abort |
| `ChatViewModel+OpenCodeHydration.swift` | Hydrate + session reconcile |
| `ChatViewModel+MCP.swift` | MCP cache / fetch / deferred |
| `ChatViewModel+ToolApproval.swift` | Tool permission + OpenCode questions |
| `ChatViewModel+Persistence.swift` | Load/save messages |
| `ChatViewModel+MediaPrefetch.swift` | CodeAgents UI media prefetch |
| `ChatViewModel+DeferredStartup.swift` | Post-ready MCP/rules/media queue |
| `ChatViewModelSupport.swift` | Pure helpers (merge, planners) |

### Runtime service files
| File | Responsibility |
|------|----------------|
| `CodingAgentRuntimeTypes.swift` | Kind, selection store, protocol |
| `OpenCodeRuntimeService.swift` | OpenCode health/send/hydrate/permissions |
| `CodingAgentRuntimeRegistry.swift` | OpenCode-only resolution |
| `AgentDaemonAuthService.swift` | Daemon Anthropic API key vs token preference |

### Retired Claude chat stack
- **`ClaudeCodeService` deleted.** Shared leftovers still used by OpenCode/tasks: `MessageChunk`, `LineBuffer`.
- **`ClaudeNotInstalledView` deleted.** Use `OpenCodeUnavailableView` for chat gates.
- **`StreamingJSONParser` / `ClaudeStreamingModels` / `ProxyEventRecovery` deleted** (Claude chat stream decode + event recovery).
- Task credentials still use `ClaudeProviderSettingsView` via `AIProviderSettingsMode.claudeProxy` labeled **Task Provider**.
- **`ProxyStreamClient`** is **not** a chat client: only `fetchCanonicalConversationId` remains for tasks on `:8787`. Chat stream/replay/permission methods removed.

## Testing principles (always apply)
- **Do not add app/production code solely so tests pass.** No `--ui-testing` / `MOBILECODE_E2E_*` branches, secret seeding, auto-presented sheets, extra invisible buttons, or other harness-only paths inside `MobileCode/` unless they are real product features users need.
- **Tests exist to make the app better**, not to greenwash CI. Prefer fixing real UX/reliability (hittable controls, correct defaults, clearer errors, timeouts/retries that help users) over teaching the app to cheat for XCTest.
- Put harness logic in **`MobileCodeTests/`**, **`MobileCodeUITests/`**, and **`scripts/e2e/`** (launch args only as inputs the *test* uses, not behavior forks in the app).
- Existing evidence/seed helpers under UI-testing flags are legacy; **do not add more**. Prefer deleting or narrowing them when touching that code.
- When a UI test is flaky, fix **test interaction** (waits, scrolling, coordinates) or **product accessibility/layout** that helps everyone — not a test-only overlay.

## Project Structure & Module Organization
- `MobileCode/`: App source code
  - `Views/`, `ViewModels/`, `Models/`, `Services/`, `Utils/`, `AppIntents/`, `Assets.xcassets`, `CodeAgentsMobileApp.swift`, `AppDelegate.swift`
  - Notable service areas: `Services/OpenCode*`, `Services/Skills/`, `Services/SSH/`, `Services/Chat/`, proxy/push (`Proxy*`, `Push*`), cloud providers (DigitalOcean / Hetzner)
- `MobileCodeTests/`: Unit/integration tests (XCTest and Swift Testing)
- `MobileCodeUITests/`: UI / E2E tests
- `CodeAgentsMobile.xcodeproj/`: Xcode project and workspace files
- `scripts/`: Canonical automation entrypoints (`ci.sh`, `coverage.sh`, `artifact.sh`, `ios-simulator-evidence.sh`, deploy/preview helpers)
- `project/`: OpenCode Gitea automation contract (`opencode-managed.json`, `README.md`)
- `server/claude-proxy/`, `server/firebase-functions/`: Backend / proxy and push-related server code
- `specs/`, `docs/plans/`, `docs/specs/`, `requirements/`: Product specs, design plans, and requirement snapshots
- `screenshots/`: Visual assets used in README and PRs
- `VERSIONS.TXT`: Release marketing version

### Version and build numbers

- `VERSIONS.TXT` is the source of truth for `MARKETING_VERSION`.
- Gitea's production-artifact workflow run number is the source of truth for
  `CURRENT_PROJECT_VERSION`; `.gitea/workflows/production-artifact.yml` exports
  it as `OPENCODE_PRODUCTION_ARTIFACT_RUN_NUMBER`.
- `scripts/artifact.sh` must inject both resolved values into the built bundle.
  Do not create timestamp build numbers or manually increment the committed
  fallback build number for agent-driven releases.
- Settings displays the bundled values as `Version (Build)`. When diagnosing a
  reported build, verify both values from the built `.app` or installed app.
- For local physical-device builds, use the committed fallback build number
  unless reproducing a specific Gitea artifact. Never label a local build with
  a Gitea run number unless it was built from that run's exact source revision.

## Build, Test, and Development Commands
- Open in Xcode: `open CodeAgentsMobile.xcodeproj`
- **Preferred validation (matches OpenCode automation):** `./scripts/ci.sh`
  - Uses XcodeBuildMCP, scheme `CodeAgentsMobile`, default simulator **iPhone 17**
  - Runs `CodeAgentsMobileTests` only; skips live SSH suites (`DirectSSHTest`, `SSHClaudeIntegrationTest`)
- Demo / visual evidence (native simulator): `./scripts/ios-simulator-evidence.sh`
- Artifacts: `./scripts/artifact.sh` (simulator `.app.zip` by default; `OPENCODE_ARTIFACT_MODE=testflight` or `./scripts/artifact.sh testflight` for TestFlight publication when credentials are set)
- Check date: `date +%Y-%m-%d`
- Manual Debug build (simulator), if not using scripts:
  `xcodebuild -scheme CodeAgentsMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Manual tests (aligned with CI skips):
  `xcodebuild test -scheme CodeAgentsMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -skip-testing:CodeAgentsMobileUITests -skip-testing:CodeAgentsMobileTests/DirectSSHTest -skip-testing:CodeAgentsMobileTests/SSHClaudeIntegrationTest`
- Scope/skip tests:
  `-only-testing:CodeAgentsMobileTests/ShortcutPromptBuilderTests` or `-skip-testing:CodeAgentsMobileTests/DirectSSHTest`
- Clean: `xcodebuild -scheme CodeAgentsMobile clean`
- Focused recovery coverage to prefer when touching chat open / resume:
  - `ChatDeferredStartupTests`, `ChatRecoveryTimingTests`, `ClaudeToOpenCodeMigrationTests`, OpenCode hydration/session tests under `MobileCodeTests/`

## Chat open / recovery (do not regress)
- **Local-first chat open:** render persisted SwiftData messages before remote recovery / migration side effects.
- On configure: `loadMessages()` first, then `ClaudeToOpenCodeMigrationService.migrateIfNeeded` (must not block showing local messages), then OpenCode hydration decision.
- Defer MCP server refresh, managed rules setup, and broad CodeAgents UI media prefetch until after local messages and required active-session recovery complete — or until explicit MCP/tool UI actions, just-in-time send/action paths, or the project-scoped post-ready background queue.
- Project switches must cancel deferred startup work so it cannot update stale chat state.
- **OpenCode only:** initial recovery fetch is bounded and diffed against stored message/part hydration anchors; full-session refresh may run later in the background when more history may exist.
- **Do not** reintroduce Claude proxy chat poll/sync/recovery on chat open (no `ProxyStreamClient` stream, no event replay, no `ProxyEventRecovery`).
- Prefer OpenCode hydration over full reload on every re-entry.
- Debug builds may emit `[ChatRecoveryTiming]` lines. Timing metadata only: runtimes, project ids, operation labels, elapsed ms, statuses, booleans, counts. **Do not** log prompts, message text, raw payloads, credentials, URLs, project paths, attachment paths, or file contents.
- Focused recovery coverage: `ClaudeToOpenCodeMigrationTests`, `ChatDeferredStartupTests`, `ChatRecoveryTimingTests`, OpenCode hydration/session tests under `MobileCodeTests/`.

## OpenCode automation
- This repo is bootstrap-managed by the OpenCode Gitea automation controller (`project/opencode-managed.json`, see `project/README.md`).
- Validation command for agents/CI: `/bin/bash ./scripts/ci.sh`
- Coverage: `/bin/bash ./scripts/coverage.sh`
- Production artifact (when enabled): `/bin/bash ./scripts/artifact.sh testflight` (Phase app metadata is in managed JSON / README)
- Visual validation and demo evidence use **native iOS simulator** providers; preview support is **not** enabled (`preview.supported: false`)
- Prefer existing `scripts/` entrypoints over inventing new CI; do not fight controller-managed workflows under `.gitea/workflows/`
- Persona/review behavior is configured in the automation **controller** repo, not this one

## Coding Style & Naming Conventions
- Swift 5.9+; 4‑space indentation, no tabs. Keep lines readable (~120 chars).
- Types `PascalCase`; methods, vars, and cases `camelCase`. File names match primary type (e.g., `ChatViewModel.swift`).
- Use `// MARK:` to organize sections; prefer `///` doc comments for public APIs.
- UI-facing types annotate with `@MainActor`; prefer `@Observable` view models.
- No enforced linter in repo; format in Xcode (Editor → Structure → Re-Indent) before committing.

## Testing Guidelines
- Unit/integration tests live in `MobileCodeTests/`; UI/E2E in `MobileCodeUITests/`. Mix of XCTest and Swift Testing (`@Test`).
- Name files `*Tests.swift`; follow arrange–act–assert; isolate side effects.
- Integration/network tests (e.g., `DirectSSHTest`, `SSHClaudeIntegrationTest`) may require external services — skip locally unless configured. Default CI already skips them.
- Prefer `./scripts/ci.sh` over ad-hoc full-suite runs.
- Examples:
  - Single file: `xcodebuild test -scheme CodeAgentsMobile -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CodeAgentsMobileTests/ShortcutPromptBuilderTests`
  - Skip integration: add `-skip-testing:CodeAgentsMobileTests/DirectSSHTest -skip-testing:CodeAgentsMobileTests/SSHClaudeIntegrationTest`

## Commit & Pull Request Guidelines
- Commits: concise, imperative mood (e.g., "Fix scrolling in chat view"). Group related changes.
- PRs must include: clear description, linked issues, test plan (commands + expected outcome), screenshots for UI, and note any migrations/config touches. CI via `./scripts/ci.sh` (or equivalent skips above) must pass.

## Proxy Deployment (legacy Claude proxy)
Local proxy repo: `~/Projects/mobilecode.swift/MobileCode/server/claude-proxy`

- Policy: For proxy-only work, do not push iOS app code changes. If a task is MCP/proxy/server related and does not touch `MobileCode/` UI/app logic, update only `server/claude-proxy` and avoid committing/pushing iOS project files.
- Remember: Claude Code / Claude proxy is **deprecated** relative to OpenCode; only change the proxy when maintaining legacy compatibility.

1. Commit proxy code changes to the proxy repo.
2. Push the proxy repo to GitHub.
3. SSH to the test server (if available).
4. Pull latest: `cd /opt/claude-proxy && git pull`
5. Proxy venv lives at `/opt/claude-proxy/.venv` (created by installer).
6. If requirements changed: `cd /opt/claude-proxy && . .venv/bin/activate && pip install -r requirements.txt`
7. Restart: `supervisorctl restart claude-proxy`

## Firebase Functions Deployment
- Deploy (from repo): `cd server/firebase-functions && firebase deploy --only functions,firestore`
- If `firebase login --reauth` fails due to the localhost callback, use: `firebase login --reauth --no-localhost`
- If the CLI prompts `? Enter authorization code:` and you have a redirect URL like `http://localhost:9005?...&code=XYZ&...`, paste only the `XYZ` part.
- If deploy fails with `HTTP Error: 429, Quota exceeded for quota metric 'Mutate requests'` from `serviceusage.googleapis.com`, wait 1–2 minutes and retry (Firebase CLI sometimes hits a shared API-enable rate limit). If it persists, enable the missing API(s) in Google Cloud Console (often `firebaseextensions.googleapis.com`) and retry.
- If deploy fails at `Error generating the service identity for pubsub.googleapis.com` (or `eventarc.googleapis.com`), wait 1–2 minutes and retry. If it persists, run (in Cloud Shell): `gcloud beta services identity create --project <project-id> --service pubsub.googleapis.com` (and `eventarc.googleapis.com`), then retry deploy.

## Security & Configuration Tips
- Never commit secrets or API keys; use Keychain at runtime (see `KeychainManager`). Do not commit real `GoogleService-Info.plist` contents — use `GoogleService-Info.plist.example` as the template.
- Don’t commit local build artifacts or `*.xcuser*`; keep `.gitignore` intact.
- Review `PRIVACY_POLICY.md` and relevant docs in `specs/` / `docs/plans/` when changing data flows.
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## Public project page (Selfhosted Ninja)
- Agent skills for this repo: `.agents/skills/skills.md`.
- Use the **wordpress-manager** skill (`.agents/skills/wordpress-manager/`) whenever user-facing product info changes so https://selfhosted.ninja/projects/codeagents-mobile/ stays accurate (features, links, screenshots, FAQ, requirements). Note OpenCode as the supported runtime when updating public copy; Claude Code is deprecated.
- Site config (selfhosted only): `.skills-data/wordpress-manager/sites.yaml` or the template at `.agents/skills/wordpress-manager/sites.selfhosted.yaml`.
