#!/usr/bin/env bash
set -euo pipefail

echo "Replace scripts/preview.sh with this repository's real preview routine before enabling preview support." >&2
echo "This script should create or refresh the live preview and print the required JSON result to stdout." >&2
echo "When OPENCODE_PREVIEW_REF is set, create the preview from that exact commit in an isolated detached worktree instead of the current branch checkout." >&2
exit 1
