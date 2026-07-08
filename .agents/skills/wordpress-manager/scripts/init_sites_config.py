#!/usr/bin/env python3
"""Initialize the wordpress-manager sites.yaml config file."""

from __future__ import annotations

import argparse
from pathlib import Path
import textwrap

DEFAULT_BASE_DIR = Path(".skills-data") / "wordpress-manager"
DEFAULT_CONFIG_NAME = "sites.yaml"


def build_template(base_dir: Path) -> str:
    base_dir_str = str(base_dir)
    return textwrap.dedent(
        f"""
        # wordpress-manager sites config
        # Store this file in {base_dir_str}/sites.yaml
        # Local tool dirs:
        #   WP-CLI bin: {base_dir_str}/bin
        #   Python venv: {base_dir_str}/venv
        #   PHP deps: {base_dir_str}/php-env

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
            base_dir: {base_dir_str}/backups
            include_db: true
            include_files: true
            retention_days: 14
            remote_tmp_dir: /tmp
            files_subdir: wp-content
          content:
            default_author: 1
            default_status: draft

        sites:
          example-site:
            label: Example Site
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
              base_dir: {base_dir_str}/backups/example-site
              include_db: true
              include_files: true
              retention_days: 14
              remote_tmp_dir: /tmp
              files_subdir: wp-content
            content:
              default_author: 1
              default_status: draft
        """
    ).lstrip()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a wordpress-manager sites.yaml template."
    )
    parser.add_argument(
        "--base-dir",
        default=str(DEFAULT_BASE_DIR),
        help="Base directory for config and backups (default: .skills-data/wordpress-manager)",
    )
    parser.add_argument(
        "--print",
        action="store_true",
        help="Print the template to stdout without writing files",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing sites.yaml if it exists",
    )
    args = parser.parse_args()

    base_dir = Path(args.base_dir).expanduser()
    template = build_template(base_dir)

    if args.print:
        print(template)
        return 0

    config_path = base_dir / DEFAULT_CONFIG_NAME
    base_dir.mkdir(parents=True, exist_ok=True)
    (base_dir / "backups").mkdir(parents=True, exist_ok=True)

    if config_path.exists() and not args.force:
        print(f"Config already exists at {config_path}. Use --force to overwrite.")
        return 1

    config_path.write_text(template)
    print(f"Wrote template config to {config_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
