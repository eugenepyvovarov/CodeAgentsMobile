# Agent skills (this repo)

Skills live under `.agents/skills/<skill-name>/` with a `SKILL.md` entrypoint.

## wordpress-manager

**Use whenever project-facing information for CodeAgents Mobile changes** and the public write-up on Selfhosted Ninja should stay in sync.

### When to load and apply this skill

Trigger **wordpress-manager** (site key `selfhosted-ninja-prod`) if any of the following change in this repository or related release channels:

- User-facing features (chat, SSH, files, skills, MCP, providers, cloud provisioning, etc.)
- Download / distribution links (App Store, TestFlight, GitHub, support links)
- Screenshots under `screenshots/` that should appear on the marketing page
- README / `project_description.md` / `CHANGELOG.md` highlights that affect how the product is described
- Privacy, security, requirements (e.g. minimum iOS version), or FAQ-worthy behavior
- Rebranding, new videos, or links that replace outdated marketing copy

Do **not** wait for an explicit “update the website” request when those changes are part of the task outcome—update the project page as part of finishing the work (or ask once if the change is ambiguous).

### Target page

| Item | Value |
| --- | --- |
| Site key | `selfhosted-ninja-prod` |
| Page | [CodeAgents Mobile](https://selfhosted.ninja/projects/codeagents-mobile/) (`/projects/codeagents-mobile/`, WP post ID **203**) |
| Parent | [Projects](https://selfhosted.ninja/projects/) (WP post ID **196**) |
| Legacy host | `https://codeagentsmobile.maketry.xyz/` — **302** to the page above (nginx); do not revive that landing as the source of truth |

### Config & tooling

- Skill: `.agents/skills/wordpress-manager/SKILL.md`
- Site registry (local, may be gitignored under `.skills-data/`): `.skills-data/wordpress-manager/sites.yaml`
- Committed template (selfhosted only): `.agents/skills/wordpress-manager/sites.selfhosted.yaml` — copy to `.skills-data/wordpress-manager/sites.yaml` if missing
- Local WP-CLI: `.skills-data/wordpress-manager/bin/wp` (install via skill scripts if absent)
- Remote SSH uses key from sites config (default `~/.ssh/eugene_rsa`); set `WP_CLI_SSH_PRE_CMD='export PATH=$HOME/bin:$PATH'` when needed

### Update workflow (project info)

1. Read current page: `wp post get 203` (via SSH / skill base command) and compare to README / changelog / this PR’s changes.
2. Prefer updating **203** (and Projects index **196** blurb if the one-liner is wrong); keep Gutenberg-friendly blocks and the icon CTA HTML pattern already on the page when possible.
3. Import new screenshots with `wp media import` when assets change; attach into the gallery on the page.
4. Validate with a read-only check, then optionally Chrome DevTools on the live URL.
5. Do **not** edit the legacy static landing; redirects are server-side.

### Safety

- Confirm site key **selfhosted-ninja-prod** before writes.
- Respect `update.pre_backup` / maintenance flags for plugin/theme/core updates (separate from copy updates).
- Never commit secrets; SSH keys stay in `~/.ssh` / agent config, not in the repo.
