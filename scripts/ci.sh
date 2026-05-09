#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="/opt/homebrew/bin:${HOME}/.opencode/bin:${PATH}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
    if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="${candidate}"
      break
    fi
  done
fi

source "${ROOT_DIR}/scripts/lib/xcodebuildmcp.sh"
PROJECT_PATH="${CODEAGENTS_XCODE_PROJECT:-${ROOT_DIR}/CodeAgentsMobile.xcodeproj}"
SCHEME="${CODEAGENTS_XCODE_SCHEME:-CodeAgentsMobile}"
SIMULATOR_NAME="${CODEAGENTS_SIMULATOR_NAME:-iPhone 17}"
CONFIGURATION="${CODEAGENTS_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${CODEAGENTS_DERIVED_DATA_PATH:-${ROOT_DIR}/.build/opencode-ci/DerivedData}"

xcbmcp_require_min_version

if [[ -n "${GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]]; then
  printf '%s' "${GOOGLE_SERVICE_INFO_PLIST_BASE64}" | base64 --decode > "${ROOT_DIR}/MobileCode/GoogleService-Info.plist"
fi

mkdir -p "${DERIVED_DATA_PATH}"

xcbmcp_run_json simulator build \
  --project-path "${PROJECT_PATH}" \
  --scheme "${SCHEME}" \
  --simulator-name "${SIMULATOR_NAME}" \
  --configuration "${CONFIGURATION}" \
  --derived-data-path "${DERIVED_DATA_PATH}" >/dev/null
