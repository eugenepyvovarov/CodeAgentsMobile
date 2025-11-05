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

## Security & Configuration Tips
- Never commit secrets or API keys; use Keychain at runtime (see `KeychainManager`).
- Don’t commit local build artifacts or `*.xcuser*`; keep `.gitignore` intact.
- Review `PRIVACY_POLICY.md` and relevant docs in `specs/` when changing data flows.

