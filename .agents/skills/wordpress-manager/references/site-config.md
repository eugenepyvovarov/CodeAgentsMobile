# Site Config (sites.yaml)

## Local directories
- Config: `.skills-data/wordpress-manager/sites.yaml`
- Backups: `.skills-data/wordpress-manager/backups/<site_key>/`
- WP-CLI bin: `.skills-data/wordpress-manager/bin`
- Python venv: `.skills-data/wordpress-manager/venv`
- PHP deps: `.skills-data/wordpress-manager/php-env`

## Location
- Default path: `.skills-data/wordpress-manager/sites.yaml`
- Initialize a template with `scripts/init_sites_config.py`

## Precedence
- `defaults` are applied first.
- Per-site values override `defaults` for matching keys.
- Unset per-site fields fall back to `defaults`.

## Schema
`defaults` applies to all sites unless overridden per site.

```
defaults:
  ssh:
    host: example.com
    user: wpadmin
    port: 22
    identity_file: ~/.ssh/id_rsa
    host_alias: wp-prod
  wp_path: /var/www/html
  url: https://example.com
  update:
    maintenance_mode: true
    pre_backup: true
    dry_run: true
  backups:
    base_dir: .skills-data/wordpress-manager/backups
    include_db: true
    include_files: true
    retention_days: 14
    remote_tmp_dir: /tmp
    files_subdir: wp-content
  content:
    default_author: 1
    default_status: draft

sites:
  <site_key>:
    label: Human readable name
    ssh:
      host: example.com
      user: wpadmin
      port: 22
      identity_file: ~/.ssh/id_rsa
      host_alias: wp-prod
    wp_path: /var/www/html
    url: https://example.com
    update:
      maintenance_mode: true
      pre_backup: true
      dry_run: true
    backups:
      base_dir: .skills-data/wordpress-manager/backups/<site_key>
      include_db: true
      include_files: true
      retention_days: 14
      remote_tmp_dir: /tmp
      files_subdir: wp-content
    content:
      default_author: 1
      default_status: draft
```

## Field Notes
- `host_alias` should match an entry in `~/.ssh/config` when you need nonstandard ports or keys.
- `wp_path` is the remote WordPress root used by `wp --ssh=<host>:/path`.
- `url` is optional; use it for multisite or when you need `--url` to target a sub-site.
- `files_subdir` controls what gets backed up via `rsync` (default: `wp-content`).
- Avoid storing passwords in YAML. Use SSH keys and config.
