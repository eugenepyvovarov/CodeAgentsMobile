#!/usr/bin/env python3
"""Check and optionally install WP-CLI on the remote host for a site key."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

DEFAULT_CONFIG = Path(".skills-data") / "wordpress-manager" / "sites.yaml"
DEFAULT_LOCAL_WP = Path(".skills-data") / "wordpress-manager" / "bin" / "wp"
DEFAULT_BUILD_URL = (
    "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
)


def parse_scalar(value: str):
    if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
        return value[1:-1]
    if value.isdigit():
        return int(value)
    lowered = value.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"
    return value


def parse_simple_yaml(path: Path) -> dict:
    data: dict = {}
    stack = [(0, data)]
    for raw_line in path.read_text().splitlines():
        if not raw_line.strip():
            continue
        stripped = raw_line.lstrip(" ")
        if stripped.startswith("#"):
            continue
        indent = len(raw_line) - len(stripped)
        if indent % 2 != 0:
            raise ValueError(f"Unsupported indentation at: {raw_line}")
        while stack and indent < stack[-1][0]:
            stack.pop()
        if not stack:
            raise ValueError(f"Invalid indentation at: {raw_line}")
        if ":" not in stripped:
            raise ValueError(f"Invalid line (missing ':'): {raw_line}")
        key, rest = stripped.split(":", 1)
        key = key.strip()
        value = rest.strip()
        current = stack[-1][1]
        if value == "":
            child: dict = {}
            current[key] = child
            stack.append((indent + 2, child))
        else:
            current[key] = parse_scalar(value)
    return data


def deep_merge(base: dict, override: dict) -> dict:
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def build_ssh_args(ssh_cfg: dict, prefer_host_alias: bool) -> list[str]:
    host_alias = ssh_cfg.get("host_alias")
    if prefer_host_alias and host_alias:
        return ["ssh", host_alias]
    host = ssh_cfg.get("host")
    if host:
        user = ssh_cfg.get("user")
        target = f"{user}@{host}" if user else host
        args = ["ssh"]
        port = ssh_cfg.get("port")
        if port:
            args.extend(["-p", str(port)])
        identity_file = ssh_cfg.get("identity_file")
        if identity_file:
            args.extend(["-i", os.path.expanduser(str(identity_file))])
        args.append(target)
        return args
    if host_alias:
        return ["ssh", host_alias]
    raise ValueError("Missing ssh.host or ssh.host_alias in site config.")


def run_remote(ssh_args: list[str], command: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ssh_args + [command],
        check=False,
        text=True,
        capture_output=True,
    )


def run_local(command: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        check=False,
        text=True,
        capture_output=True,
    )


def parse_version(raw: str | None) -> tuple[int, ...] | None:
    if not raw:
        return None
    match = re.search(r"(\d+(?:\.\d+)+)", raw)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def version_to_str(version: tuple[int, ...]) -> str:
    return ".".join(str(part) for part in version)


def is_version_at_least(actual: tuple[int, ...], minimum: tuple[int, ...]) -> bool:
    max_len = max(len(actual), len(minimum))
    padded_actual = actual + (0,) * (max_len - len(actual))
    padded_minimum = minimum + (0,) * (max_len - len(minimum))
    return padded_actual >= padded_minimum


def get_local_wp_version(local_wp: Path) -> tuple[int, ...] | None:
    if not local_wp.exists():
        return None
    result = run_local([str(local_wp), "--version"])
    if result.returncode != 0:
        return None
    return parse_version(result.stdout)


def fetch_latest_release() -> tuple[tuple[int, ...], str] | None:
    result = run_local(
        ["git", "ls-remote", "--tags", "--refs", "https://github.com/wp-cli/wp-cli.git"]
    )
    if result.returncode != 0:
        return None
    best_version = None
    for line in result.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        ref = parts[1].strip()
        tag = ref.rsplit("/", 1)[-1]
        if "-" in tag:
            continue
        parsed = parse_version(tag)
        if not parsed:
            continue
        if best_version is None or parsed > best_version:
            best_version = parsed
    if not best_version:
        return None
    return best_version, build_release_phar_url(best_version)


def build_release_phar_url(version: tuple[int, ...]) -> str:
    version_str = version_to_str(version)
    return (
        "https://github.com/wp-cli/wp-cli/releases/download/"
        f"v{version_str}/wp-cli-{version_str}.phar"
    )


def update_local_wp(local_wp: Path, download_url: str) -> bool:
    local_wp.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = local_wp.parent / "wp-cli.phar"
    result = run_local(["curl", "-fL", "-o", str(tmp_path), download_url])
    if result.returncode != 0:
        return False
    os.chmod(tmp_path, 0o755)
    os.replace(tmp_path, local_wp)
    return True


def get_remote_wp_version(ssh_args: list[str]) -> tuple[int, ...] | None:
    cmd = "export PATH=$HOME/bin:$PATH; WP_CLI_ALLOW_ROOT=1 wp --version"
    result = run_remote(ssh_args, cmd)
    if result.returncode != 0:
        return None
    return parse_version(result.stdout)


def get_remote_wp_php_binary(ssh_args: list[str]) -> str | None:
    cmd = "export PATH=$HOME/bin:$PATH; WP_CLI_ALLOW_ROOT=1 wp --info"
    result = run_remote(ssh_args, cmd)
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if line.strip().startswith("PHP binary:"):
            _, value = line.split(":", 1)
            return value.strip()
    return None


def php_has_mysqli(ssh_args: list[str], php_path: str) -> bool:
    cmd = f"{shlex.quote(php_path)} -m 2>/dev/null | grep -i '^mysqli$' >/dev/null"
    result = run_remote(ssh_args, cmd)
    return result.returncode == 0


def select_php_with_mysqli(ssh_args: list[str]) -> tuple[str, tuple[int, ...]] | None:
    cmd = (
        "for php in /usr/bin/php /usr/local/bin/php /opt/plesk/php/*/bin/php; do "
        "[ -x \"$php\" ] || continue; "
        "if $php -m 2>/dev/null | grep -i \"^mysqli$\" >/dev/null; then "
        "ver=$($php -r 'echo PHP_VERSION;' 2>/dev/null); "
        "echo \"$php|$ver\"; "
        "fi; "
        "done"
    )
    result = run_remote(ssh_args, cmd)
    if result.returncode != 0:
        return None
    best_path = None
    best_version: tuple[int, ...] | None = None
    for line in result.stdout.splitlines():
        if "|" not in line:
            continue
        path, ver = line.split("|", 1)
        parsed = parse_version(ver.strip())
        if not parsed:
            continue
        if best_version is None or parsed > best_version:
            best_version = parsed
            best_path = path.strip()
    if best_path and best_version:
        return best_path, best_version
    return None


def write_remote_wrapper(ssh_args: list[str], php_path: str) -> subprocess.CompletedProcess:
    cmd = (
        "cat > ~/bin/wp <<'SH'\n"
        "#!/bin/sh\n"
        f"PHP_CLI=\"{php_path}\"\n"
        "PHAR=\"$HOME/bin/wp-cli.phar\"\n"
        "export WP_CLI_ALLOW_ROOT=1\n"
        "if [ ! -x \"$PHP_CLI\" ]; then\n"
        "  PHP_CLI=\"php\"\n"
        "fi\n"
        "exec \"$PHP_CLI\" \"$PHAR\" \"$@\"\n"
        "SH\n"
        "chmod +x ~/bin/wp"
    )
    return run_remote(ssh_args, cmd)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Ensure wp-cli is present on the remote host for a site key."
    )
    parser.add_argument("--site-key", required=True, help="Site key from sites.yaml")
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG),
        help="Path to sites.yaml (default: .skills-data/wordpress-manager/sites.yaml)",
    )
    parser.add_argument(
        "--install",
        action="store_true",
        help="Install or upgrade local and remote wp-cli if needed",
    )
    parser.add_argument(
        "--local-wp",
        default=str(DEFAULT_LOCAL_WP),
        help="Path to local wp binary (default: .skills-data/wordpress-manager/bin/wp)",
    )
    parser.add_argument(
        "--skip-local-update",
        action="store_true",
        help="Skip checking for the latest wp-cli release",
    )
    args = parser.parse_args()

    config_path = Path(args.config).expanduser()
    if not config_path.exists():
        print(f"Config not found: {config_path}", file=sys.stderr)
        return 1

    try:
        config = parse_simple_yaml(config_path)
    except ValueError as exc:
        print(f"Failed to parse config: {exc}", file=sys.stderr)
        return 1

    defaults = config.get("defaults", {})
    sites = config.get("sites", {})
    site_cfg = sites.get(args.site_key)
    if not site_cfg:
        print(f"Unknown site key: {args.site_key}", file=sys.stderr)
        return 1

    merged = deep_merge(defaults, site_cfg)
    ssh_cfg = merged.get("ssh", {})
    site_ssh_cfg = site_cfg.get("ssh", {})
    prefer_host_alias = "host_alias" in site_ssh_cfg
    ssh_args = build_ssh_args(ssh_cfg, prefer_host_alias)

    local_wp = Path(args.local_wp).expanduser()

    latest_version = None
    latest_url = None
    if not args.skip_local_update:
        latest = fetch_latest_release()
        if latest:
            latest_version, latest_url = latest
        else:
            print("Could not determine latest wp-cli release.", file=sys.stderr)

    local_version = get_local_wp_version(local_wp)
    if local_version is None:
        if not args.install:
            print("Local wp-cli not found. Re-run with --install to install.", file=sys.stderr)
            return 2
        download_url = latest_url or DEFAULT_BUILD_URL
        if not update_local_wp(local_wp, download_url):
            print("Failed to install local wp-cli.", file=sys.stderr)
            return 1
        local_version = get_local_wp_version(local_wp)
        if local_version is None:
            print("Local wp-cli installed but version could not be determined.", file=sys.stderr)
            return 1

    if latest_version and not is_version_at_least(local_version, latest_version):
        if not args.install:
            print(
                "Local wp-cli is outdated "
                f"(local {version_to_str(local_version)}, latest {version_to_str(latest_version)}). "
                "Re-run with --install to update.",
                file=sys.stderr,
            )
            return 2
        download_url = latest_url or DEFAULT_BUILD_URL
        if not update_local_wp(local_wp, download_url):
            print("Failed to update local wp-cli.", file=sys.stderr)
            return 1
        local_version = get_local_wp_version(local_wp)
        if local_version is None:
            print("Local wp-cli updated but version could not be determined.", file=sys.stderr)
            return 1
        if latest_version and not is_version_at_least(local_version, latest_version):
            print(
                "Local wp-cli updated but still behind latest release.",
                file=sys.stderr,
            )

    remote_version = get_remote_wp_version(ssh_args)
    remote_php = get_remote_wp_php_binary(ssh_args)
    remote_php_ok = bool(remote_php) and php_has_mysqli(ssh_args, remote_php)
    remote_version_ok = bool(remote_version) and is_version_at_least(
        remote_version, local_version
    )

    if remote_version_ok and remote_php_ok:
        print(
            "Remote wp-cli detected "
            f"(version {version_to_str(remote_version)})."
        )
        return 0

    if not args.install:
        reasons = []
        if not remote_version:
            reasons.append("remote wp-cli not found")
        elif not remote_version_ok:
            reasons.append(
                "remote wp-cli is older than local "
                f"({version_to_str(remote_version)} < {version_to_str(local_version)})"
            )
        if not remote_php_ok:
            reasons.append("remote wp-cli PHP lacks mysqli")
        print("; ".join(reasons) + ". Re-run with --install to fix.", file=sys.stderr)
        return 2

    php_choice = select_php_with_mysqli(ssh_args)
    if not php_choice:
        print(
            "No PHP CLI with mysqli found on the remote host. "
            "Install a PHP CLI with the mysqli extension and re-run.",
            file=sys.stderr,
        )
        return 4
    php_path, php_version = php_choice

    if latest_version and is_version_at_least(local_version, latest_version):
        primary_url = latest_url or build_release_phar_url(local_version)
    else:
        primary_url = build_release_phar_url(local_version)
    fallback_url = DEFAULT_BUILD_URL if primary_url != DEFAULT_BUILD_URL else None

    if fallback_url:
        install_cmd = (
            "mkdir -p ~/bin && ("
            f"curl -fL -o ~/bin/wp-cli.phar {primary_url} "
            f"|| curl -fL -o ~/bin/wp-cli.phar {fallback_url}"
            ") && chmod +x ~/bin/wp-cli.phar"
        )
    else:
        install_cmd = (
            "mkdir -p ~/bin && "
            f"curl -fL -o ~/bin/wp-cli.phar {primary_url} "
            "&& chmod +x ~/bin/wp-cli.phar"
        )

    install = run_remote(ssh_args, install_cmd)
    if install.returncode != 0:
        print("Remote wp-cli install failed.", file=sys.stderr)
        if install.stdout:
            print(install.stdout, file=sys.stderr)
        if install.stderr:
            print(install.stderr, file=sys.stderr)
        return install.returncode

    wrapper = write_remote_wrapper(ssh_args, php_path)
    if wrapper.returncode != 0:
        print("Failed to write wp wrapper script on remote host.", file=sys.stderr)
        if wrapper.stdout:
            print(wrapper.stdout, file=sys.stderr)
        if wrapper.stderr:
            print(wrapper.stderr, file=sys.stderr)
        return wrapper.returncode

    verify_version = get_remote_wp_version(ssh_args)
    verify_php = get_remote_wp_php_binary(ssh_args)
    verify_php_ok = bool(verify_php) and php_has_mysqli(ssh_args, verify_php)

    if (
        verify_version
        and is_version_at_least(verify_version, local_version)
        and verify_php_ok
    ):
        print(
            "Remote wp-cli installed and verified "
            f"(wp-cli {version_to_str(verify_version)}, php {version_to_str(php_version)})."
        )
        return 0

    print("Remote wp-cli install completed, but verification failed.", file=sys.stderr)
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
