# WP-CLI Usage Notes

## Official references
- https://github.com/wp-cli/wp-cli?tab=readme-ov-file#using
- https://developer.wordpress.org/cli/commands/
- https://make.wordpress.org/cli/handbook/
- Block / theme content (WP 7.0): see [wp-7-block-themes.md](wp-7-block-themes.md)
  - Core blocks: https://developer.wordpress.org/block-editor/reference-guides/core-blocks/
  - Field guide: https://make.wordpress.org/core/2026/05/14/wordpress-7-0-field-guide/

## Command discovery
- List top-level commands: `wp help`
- Command-specific help: `wp <command> --help`
- Subcommand help: `wp <command> <subcommand> --help`

## Remote usage pattern
```
.skills-data/wordpress-manager/bin/wp --ssh=<user@host>:<wp_path> --allow-root <command> [--url=<site_url>]
```
Notes:
- `--ssh` executes WP-CLI on the remote host; `wp` must be installed and on the remote PATH.
- If PATH is missing in non-interactive shells, set `WP_CLI_SSH_PRE_CMD='export PATH=$HOME/bin:$PATH'`.

## Common tasks (patterns only)
- Core: `wp core version`, `wp core update`, `wp core update-db`
- Plugins: `wp plugin list`, `wp plugin update --all`, `wp plugin update <slug>`
- Themes: `wp theme list`, `wp theme update --all`, `wp theme update <slug>`
- Maintenance mode: `wp maintenance-mode activate|deactivate`
- DB export/import: `wp db export <file.sql>`, `wp db import <file.sql>`
- Posts: `wp post create --post_title=... --post_content=... --post_status=draft`
- Posts (block content): `wp post get <ID> --field=post_content` then `wp post update <ID> /tmp/content.html` with **full** serialized block markup (see wp-7-block-themes.md)
- Media: `wp media import /path/to/file --title=... --alt=... --porcelain`; resolve sizes with `wp eval 'echo wp_get_attachment_image_url(ID, "large");'`
- Terms: `wp term list <taxonomy>`, `wp term create <taxonomy> <name>`
- Blocks on install: list registered `core/*` names via `WP_Block_Type_Registry` (snippet in wp-7-block-themes.md)

## Safety checks
- Always run a read-only command before write operations.
- Verify flags with `wp <command> --help` before executing.
