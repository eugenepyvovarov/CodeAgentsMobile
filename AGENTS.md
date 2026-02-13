# Repository Guidelines

## Project Structure & Module Organization
- `MobileCode/`: App source code
  - `Views/`, `ViewModels/`, `Models/`, `Services/`, `Utils/`, `AppIntents/`, `Assets.xcassets`, `CodeAgentsMobileApp.swift`.
- `MobileCodeTests/`: Unit/integration tests (XCTest and Swift Testing).
- `CodeAgentsMobile.xcodeproj/`: Xcode project and workspace files.
- `specs/`, `requirements/`: Product specs and requirement snapshots used to drive features.
- `screenshots/`: Visual assets used in README and PRs.

## Build, Test, and Development Commands
- Open in Xcode: `open CodeAgentsMobile.xcodeproj`
- Current tasks:
  - Allow marketplace installs only once.
  - Allow naming marketplaces when adding them.
  - Capitalize skill names and replace `-` with spaces.
  - Make skills list compact with tap-to-view details (name, source, author, preview).
  - In agent skill install, show installed skills with enable/disable and add from global, link, or marketplace (global first).
- Check date: `date +%Y-%m-%d`
- Build Debug (simulator):
  `xcodebuild -scheme CodeAgentsMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build`
- Run all tests (unit + UI):
  `xcodebuild test -scheme CodeAgentsMobile -destination 'platform=iOS Simulator,name=iPhone 15'`
- Scope/skip tests:
  `-only-testing:CodeAgentsMobileTests/ShortcutPromptBuilderTests` or `-skip-testing:CodeAgentsMobileTests/DirectSSHTest`
- Clean: `xcodebuild -scheme CodeAgentsMobile clean`

## Coding Style & Naming Conventions
- Swift 5+; 4‑space indentation, no tabs. Keep lines readable (~120 chars).
- Types `PascalCase`; methods, vars, and cases `camelCase`. File names match primary type (e.g., `ChatViewModel.swift`).
- Use `// MARK:` to organize sections; prefer `///` doc comments for public APIs.
- UI-facing types annotate with `@MainActor`; prefer `@Observable` view models.
- No enforced linter in repo; format in Xcode (Editor → Structure → Re-Indent) before committing.

## Testing Guidelines
- Tests live in `MobileCodeTests/`; mix of XCTest and Swift Testing (`@Test`).
- Name files `*Tests.swift`; follow arrange–act–assert; isolate side effects.
- Integration/network tests (e.g., `DirectSSHTest`) may require external services—skip locally unless configured.
- Examples:
  - Single file: `xcodebuild test -scheme CodeAgentsMobile -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CodeAgentsMobileTests/ShortcutPromptBuilderTests`
  - Skip integration: add `-skip-testing:CodeAgentsMobileTests/DirectSSHTest`

## Commit & Pull Request Guidelines
- Commits: concise, imperative mood (e.g., "Fix scrolling in chat view"). Group related changes.
- PRs must include: clear description, linked issues, test plan (commands + expected outcome), screenshots for UI, and note any migrations/config touches. CI/test command above must pass.

## Proxy Deployment
Local proxy repo: `~/Projects/mobilecode.swift/MobileCode/server/claude-proxy`

- Policy: For proxy-only work, do not push iOS app code changes. If a task is MCP/proxy/server related and does not touch `MobileCode/` UI/app logic, update only `server/claude-proxy` and avoid committing/pushing iOS project files.

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
- Never commit secrets or API keys; use Keychain at runtime (see `KeychainManager`).
- Don’t commit local build artifacts or `*.xcuser*`; keep `.gitignore` intact.
- Review `PRIVACY_POLICY.md` and relevant docs in `specs/` when changing data flows.
