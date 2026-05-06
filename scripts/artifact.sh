#!/usr/bin/env bash
set -euo pipefail

echo "Replace scripts/artifact.sh with this repository's real artifact routine before enabling preview support." >&2
echo "This script should produce the runnable artifact consumed by scripts/preview.sh, such as a Docker image, bundle, binary, or archive." >&2
echo "When OPENCODE_PREVIEW_REF is set, build the artifact from that exact commit in an isolated detached worktree instead of the current branch checkout." >&2
echo "If this same script is also the repo's real post-merge publish entrypoint, set production_artifact.command explicitly after replacing this placeholder." >&2
echo "Prefer one mode-aware artifact.sh entrypoint (for example: preview vs production) instead of introducing a second production-artifact script." >&2
exit 1
