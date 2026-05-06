#!/usr/bin/env bash
set -euo pipefail

echo "Replace scripts/destroy-preview.sh with this repository's real preview teardown routine before enabling preview support." >&2
echo "This script should tear down the live preview created by scripts/preview.sh for the current PR context." >&2
echo "If preview creation uses OPENCODE_PREVIEW_REF worktrees, this script should also remove the detached worktree during teardown." >&2
exit 1
