---
name: wordpress-manager
description: Manage WordPress remotely via local wp-cli over SSH. In this CodeAgents Mobile repo, primary use is selfhosted-ninja-prod — keep https://selfhosted.ninja/projects/codeagents-mobile/ in sync when product features, links, screenshots, or public copy change. Also supports updates, backups, restores, content, and custom plugins for configured sites.
---

# WordPress Manager

## This repository (CodeAgents Mobile)

See also `.agents/skills/skills.md` for when agents **must** use this skill.

- **Site key:** `selfhosted-ninja-prod` only in the committed template (`sites.selfhosted.yaml`).
- **Project pages (parent Projects **196**):** CodeAgents Mobile **203** — https://selfhosted.ninja/projects/codeagents-mobile/ ; MCP Bundler **224** — https://selfhosted.ninja/projects/mcp-bundler/ (links out to https://mcp-bundler.com/ — **never** 302 the product domain here).
- **Blog:** posts page **225** — https://selfhosted.ninja/blog/ ; categories `videos`, `codeagents-mobile`, `mcp-bundler`, `projects`. Prefer short posts with `core/embed` (YouTube) + project category for updates/videos so the blog is used often; project pages only link to categories.
- **Config:** `.skills-data/wordpress-manager/sites.yaml` (copy from `sites.selfhosted.yaml` in this skill folder if missing).
- **When product info changes** (features, App Store / TestFlight / GitHub links, screenshots, FAQ, iOS requirements, README highlights): update page **203** (and the Projects index blurb on **196** if needed) before considering the task done. Prefer core blocks (see `references/wp-7-block-themes.md`); use **`core/gallery`** for screenshots.
- Legacy `codeagentsmobile.maketry.xyz` is a **302** to the project page — do not maintain that static site as the source of truth.

## Quick start
- Install wp-cli locally (see "wp-cli installation").
- Ensure wp-cli is installed and on PATH for the remote SSH user (see "wp-cli installation (remote)").
- Initialize or copy the site registry to `.skills-data/wordpress-manager/sites.yaml` (this repo: start from `sites.selfhosted.yaml` in this skill directory).
- Pick the target site key (`selfhosted-ninja-prod` here), load its config, and build a base `wp` command.
- Run a read-only command first to validate connectivity.
- Apply the task-specific workflow below.

## wp-cli installation (local)
Requirements:
- Unix-like environment (macOS, Linux, FreeBSD, Cygwin).
- PHP 5.6 or later available on PATH.
- Remote WordPress 3.7 or later (older versions may have degraded functionality).

Install to the skill-local bin directory.

Preferred (scripted):
```
scripts/install_wp_cli.sh --base-dir .skills-data/wordpress-manager
```

Manual steps:
```
mkdir -p .skills-data/wordpress-manager/bin
curl -o .skills-data/wordpress-manager/bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
php .skills-data/wordpress-manager/bin/wp-cli.phar --info
chmod +x .skills-data/wordpress-manager/bin/wp-cli.phar
mv .skills-data/wordpress-manager/bin/wp-cli.phar .skills-data/wordpress-manager/bin/wp
```

Usage options:
- Call directly: `.skills-data/wordpress-manager/bin/wp --info`
- Or add to PATH for the session:
  `export PATH="$PWD/.skills-data/wordpress-manager/bin:$PATH"`

## wp-cli installation (remote)
When using `--ssh=...`, WP-CLI runs on the remote host, so the remote user must have `wp` on PATH.

Check if wp-cli is present on the remote host:
```
ssh <user@host> 'command -v wp >/dev/null && wp --info'
```

Helper script (uses sites.yaml):
```
scripts/ensure_remote_wp_cli.py --site-key <site_key> --install
```
Notes:
- The helper checks local wp-cli, updates it to the latest release (using git tags) when needed, then compares remote against local.
- It installs `~/bin/wp-cli.phar` and writes a `~/bin/wp` wrapper that uses a PHP CLI with `mysqli` when available.
- If no PHP CLI with `mysqli` is found, it will prompt you to install one.
- Override the local binary path with `--local-wp`, or skip the latest-release check with `--skip-local-update`.

Install to the remote user's home bin directory:
```
ssh <user@host> 'mkdir -p ~/bin && curl -o ~/bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x ~/bin/wp-cli.phar && mv ~/bin/wp-cli.phar ~/bin/wp'
```

If non-interactive shells do not include `~/bin`, set it explicitly:
- Client-side (per command): `WP_CLI_SSH_PRE_CMD='export PATH=$HOME/bin:$PATH'`
- Server-side: add `PATH="$HOME/bin:$PATH"` in the remote user's shell profile.

## wp-cli references
- Load `references/wp-cli-usage.md` for common command patterns and doc links.
- Load `references/wp-7-block-themes.md` for WordPress **7.0** block themes, template parts/sections, core blocks (Gallery, lightbox, Breadcrumbs, Icon, Navigation overlays), hybrid-theme limits (Blocksy), and safe `post_content` editing for marketing pages.
- Always verify flags with `wp <command> --help` before running writes.

## Local tooling (required)
- Keep all tool environments in `.skills-data/wordpress-manager/`.
- Create a Python venv at `.skills-data/wordpress-manager/venv` when a script needs dependencies.
- Create a PHP deps directory at `.skills-data/wordpress-manager/php-env` and install composer dependencies there when needed.
- Current scripts use Python standard library only; no pip installs required.
- Never install requirements globally.

## Site registry
- Use `.skills-data/wordpress-manager/sites.yaml` for multi-site configuration.
- Load `references/site-config.md` for the full schema.
- Prefer `ssh.host_alias` with `~/.ssh/config` for nonstandard ports or keys.
- Avoid storing passwords in YAML; use SSH keys and config.

## Build the base wp command
- Use the local binary: `.skills-data/wordpress-manager/bin/wp`.
- Remote execution: `wp --ssh=<user@host>:<wp_path>` and append `--url=<site_url>` when needed.
- If `host_alias` is set, use `wp --ssh=<host_alias>:<wp_path>`.
- Include `--allow-root` by default; omit it only when using a non-root SSH user.
- If remote wp-cli is installed in `~/bin`, set `WP_CLI_SSH_PRE_CMD='export PATH=$HOME/bin:$PATH'` for remote discovery.
- Validate with a read-only command such as `wp core version` or `wp option get siteurl`.

## Updates workflow
- If `update.pre_backup` is true, run the backup workflow first.
- If `update.maintenance_mode` is true, run `wp maintenance-mode activate` before updates and deactivate afterward.
- If `update.dry_run` is true, use `--dry-run` where supported or list pending updates.
- Update order: plugins, themes, then core unless the user specifies otherwise.
- Confirm with the user before core updates or major version jumps.

## Backups
- Respect `backups.include_db` and `backups.include_files`.
- For DB backups: run `wp db export` to `backups.remote_tmp_dir`, then `scp` to local.
- For file backups: use `rsync -az` for the `files_subdir` (default `wp-content`).
- Store backups in `.skills-data/wordpress-manager/backups/<site_key>/<timestamp>/`.
- Remove remote temp files after download and prune local backups when asked.

## Restores
- Recommend maintenance mode before restoring.
- For DB restores: upload the dump to `backups.remote_tmp_dir` and run `wp db import`.
- For file restores: `rsync -az` the backup `wp-content` to the remote `wp-content`.
- Confirm target site and backup timestamp before any restore.

## Content operations
- Ask for title, status, author, and slug when creating posts.
- Use `wp post create`, `wp post update`, `wp media import`, and `wp term` as needed.
- For multisite, pass `--url` from the site config.
- **Block markup (WordPress 7.0):** prefer core blocks in `post_content` over freeform HTML when a block exists. Load `references/wp-7-block-themes.md` for:
  - Block theme layers (templates, template parts / “sections”, patterns, global styles vs post content)
  - Hybrid themes (e.g. Blocksy on selfhosted.ninja): page title/hero is theme-owned; body is `post_content`
  - WP 7.0 additions: `core/breadcrumbs`, `core/icon`, `core/navigation-overlay-close`, gallery lightbox navigation, per-image lightbox, responsive visibility, pattern `contentOnly`
  - Recommended **Gallery** markup for product screenshots (`core/gallery` + nested `core/image` + `lightbox`)
  - Core block inventory and WP-CLI patterns for serialized content
- For screenshots / image grids on marketing pages, use a **`core/gallery`** block (not a bare list of `<img>` tags). Enable lightbox when enlarge-on-click is desired.
- Round-trip the **full** `post_content` when editing so block comment delimiters stay valid.

## Code changes (functions/plugins)
- Always ask whether the change should be a new plugin, a mu-plugin, or theme `functions.php`.
- Prefer a custom plugin for reusable logic; start from `assets/plugin-template.php`.
- For theme functions, confirm the active theme and whether a child theme exists before editing.
- Upload changes with `rsync` or `scp`; avoid editing directly on the server.
- Reactivate plugins or clear caches if needed.

## Validation and safety
- Confirm site key and target environment (prod/staging) before any write.
- Run a read-only command at the start of each session.
- Ensure local `ssh`, `scp`, and `rsync` are available; remote host must have PHP for `wp --ssh`.
- If `chrome-web-tools` is available and UI verification is needed, use it to spot-check admin pages.

## Example prompts
- "Update all plugins and themes on site marketing-prod with maintenance mode."
- "Backup database only for store staging."
- "Restore files and database from last night's backup on store staging."
- "Create a custom plugin that adds a [site_year] shortcode on client-a."
- "Add a function to disable comments in the active theme on blog-prod."
- "Create a draft post from markdown on docs site."
- "Put CodeAgents screenshots in a WP 7 gallery block with lightbox on selfhosted-ninja-prod."
- "Add the app logo before the page title on the CodeAgents Mobile project page."
