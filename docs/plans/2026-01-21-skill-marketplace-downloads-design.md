# Skill Marketplace Full Folder Downloads

## Summary
Enable full-folder skill downloads from marketplaces and GitHub folder URLs, while excluding tooling metadata folders. Skills are installed into the global library and can then be copied to agent folders as before.

## Additional Requirements
- Marketplace installs are idempotent: installing the same marketplace skill twice should be prevented or treated as a no-op.
- When adding a marketplace, allow a custom display name (not just owner/repo).
- Skill display names should be user-friendly: capitalize and replace hyphens with spaces in the UI.
- Global skills list should be compact, with a details view on tap (name, source, author, preview).
- Agent skills view should show installed skills with on/off toggles plus a clear action to add from global skills or install via link/marketplace (adds to global first, then to the agent).

## Goals
- Download complete skill folders (not just `SKILL.md`) from marketplace entries and GitHub folder URLs.
- Preserve directory structure under the skill root.
- Skip tooling metadata (`.git`, `.github`, `.claude-plugin`, `.mcp-bundler`, `.DS_Store`, `Thumbs.db`).
- Keep existing UI flows for marketplace/GitHub install and agent copy.

## Non-goals
- Support non-GitHub marketplaces or private repos.
- Implement archive/zip downloads.
- Guarantee plugin source `.url` entries provide full folders (treated as file URL fallback).

## Architecture
- `SkillMarketplaceService` gains a GitHub tree-based downloader that enumerates all files under a plugin path.
- `SkillLibraryService` adds `installSkill(from directoryURL:)` to install a staged folder into the global library.
- UI sheets (`SkillMarketplaceInstallSheet`, `SkillAddFromGitHubSheet`) switch from single-file fetch to folder download + install.
- Agent sync (`AgentSkillSyncService`) continues to copy full folders to `\(project.path)/.claude/skills/<slug>`.

## Data Flow
1. User selects a marketplace entry or GitHub folder URL.
2. `SkillMarketplaceService` resolves the plugin path and calls `downloadSkillFolder(...)`.
3. `downloadSkillFolder` calls GitHub `git/trees?recursive=1` to list files, filters by `pluginPath/`, excludes metadata folders, and downloads each file via `raw.githubusercontent.com` into a temp staging directory.
4. `SkillLibraryService.installSkill(from:)` validates `SKILL.md`, parses front matter, resolves slug conflicts, and moves the staged folder into the library root.
5. UI inserts `AgentSkill` and can optionally add it to the active agent (copy to remote folder).

## Filtering Rules
- Skip any file whose path components include: `.git`, `.github`, `.claude-plugin`, `.mcp-bundler`, `.DS_Store`, `Thumbs.db`.
- Everything else under the plugin root is downloaded and preserved.

## Error Handling
- Surface missing `SKILL.md` as a user-facing error.
- On network or 404 errors, abort install and clean staging directories.
- If the staging folder exists or a slug already exists, resolve to a unique slug before move.
- If GitHub tree listing fails, fallback to error with clear message.

## Testing
- Unit tests for:
  - Skip-list filtering by path components.
  - Tree-to-local path mapping.
  - Slug conflict resolution with folder installs.
  - Missing `SKILL.md` handling.

## Rollout
- No migration needed; new installs use full folder download.
- Existing skills remain untouched.
