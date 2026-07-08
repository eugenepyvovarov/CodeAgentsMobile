#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=".skills-data/wordpress-manager"
FORCE=0
DRY_RUN=0
SKIP_CHECKS=0

usage() {
  cat <<'USAGE'
Usage: install_wp_cli.sh [options]

Options:
  --base-dir PATH   Base directory for wordpress-manager data (default: .skills-data/wordpress-manager)
  --force           Overwrite existing wp binary if present
  --dry-run         Print commands without executing them
  --skip-checks     Skip tool checks (php/curl/wget); intended for dry-run testing
  -h, --help        Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir)
      BASE_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-checks)
      SKIP_CHECKS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
 done

BIN_DIR="$BASE_DIR/bin"
PHAR_PATH="$BIN_DIR/wp-cli.phar"
WP_BIN="$BIN_DIR/wp"
WP_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "+ $*"
  else
    "$@"
  fi
}

if [ "$SKIP_CHECKS" -ne 1 ]; then
  if ! command -v php >/dev/null 2>&1; then
    echo "php not found on PATH. Install PHP before installing wp-cli." >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "Neither curl nor wget is available. Install one to download wp-cli." >&2
    exit 1
  fi
fi

if [ -e "$WP_BIN" ] && [ "$FORCE" -ne 1 ]; then
  echo "wp already exists at $WP_BIN. Use --force to overwrite." >&2
  exit 1
fi

run mkdir -p "$BIN_DIR"

if command -v curl >/dev/null 2>&1; then
  run curl -fL -o "$PHAR_PATH" "$WP_URL"
elif command -v wget >/dev/null 2>&1; then
  run wget -O "$PHAR_PATH" "$WP_URL"
else
  run curl -fL -o "$PHAR_PATH" "$WP_URL"
fi

run php "$PHAR_PATH" --info
run chmod +x "$PHAR_PATH"
run mv -f "$PHAR_PATH" "$WP_BIN"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run complete. wp-cli would be installed at $WP_BIN"
else
  echo "Installed wp-cli to $WP_BIN"
fi
