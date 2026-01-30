#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLIST_PATH="${REPO_ROOT}/MobileCode/GoogleService-Info.plist"

if [[ -z "${GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]]; then
  echo "error: GOOGLE_SERVICE_INFO_PLIST_BASE64 is not set."
  echo "Add it as a secret environment variable in Xcode Cloud (Workflow -> Environment Variables)."
  exit 1
fi

mkdir -p "$(dirname "$PLIST_PATH")"
printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 -D > "$PLIST_PATH"
plutil -lint "$PLIST_PATH"

echo "Wrote $PLIST_PATH"
