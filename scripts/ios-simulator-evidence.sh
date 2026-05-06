#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="/opt/homebrew/bin:${HOME}/.opencode/bin:${PATH}"

XCODEBUILDMCP_BIN="${XCODEBUILDMCP_BIN:-xcodebuildmcp}"
PROJECT_PATH="${CODEAGENTS_XCODE_PROJECT:-${ROOT_DIR}/CodeAgentsMobile.xcodeproj}"
SCHEME="${CODEAGENTS_XCODE_SCHEME:-CodeAgentsMobile}"
SIMULATOR_NAME="${CODEAGENTS_SIMULATOR_NAME:-iPhone 17}"
CONFIGURATION="${CODEAGENTS_CONFIGURATION:-Debug}"
BUNDLE_ID="${CODEAGENTS_BUNDLE_ID:-lifeisgoodlabs.CodeAgentsMobile}"
DERIVED_ROOT="${OPENCODE_EVIDENCE_BUILD_ROOT:-${ROOT_DIR}/.build/opencode-evidence}"
DERIVED_DATA_PATH="${CODEAGENTS_DERIVED_DATA_PATH:-${DERIVED_ROOT}/DerivedData}"
LAUNCH_SETTLE_SECONDS="${CODEAGENTS_EVIDENCE_LAUNCH_SETTLE_SECONDS:-4}"
MODE="${1:-auto}"

if ! command -v "${XCODEBUILDMCP_BIN}" >/dev/null 2>&1; then
  echo "xcodebuildmcp is required for iOS simulator evidence capture." >&2
  exit 1
fi

mkdir -p "${DERIVED_DATA_PATH}"

python_json_text() {
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
print("\n".join(item.get("text", "") for item in data.get("content", []) if isinstance(item, dict)))
'
}

resolve_simulator_id() {
  local simulator_json
  simulator_json="$("${XCODEBUILDMCP_BIN}" simulator list --output json)"
  printf '%s' "${simulator_json}" | python3 -c '
import json
import re
import sys

name = sys.argv[1]
data = json.load(sys.stdin)
text = "\n".join(item.get("text", "") for item in data.get("content", []) if isinstance(item, dict))
match = re.search(r"- " + re.escape(name) + r" \(([A-Fa-f0-9-]+)\)", text)
if not match:
    raise SystemExit(f"Simulator named {name!r} was not found.")
print(match.group(1))
' "${SIMULATOR_NAME}"
}

extract_screenshot_path() {
  python3 -c '
import json
import re
import sys

data = json.load(sys.stdin)
text = "\n".join(item.get("text", "") for item in data.get("content", []) if isinstance(item, dict))
match = re.search(r"Screenshot captured:\s+(.+?)\s+\(", text)
if not match:
    raise SystemExit(f"Unable to parse screenshot path from xcodebuildmcp output: {text}")
print(match.group(1))
'
}

capture_png() {
  local simulator_id="$1"
  local output_path="$2"
  local screenshot_json
  local source_path

  mkdir -p "$(dirname "${output_path}")"
  screenshot_json="$("${XCODEBUILDMCP_BIN}" ui-automation screenshot --simulator-id "${simulator_id}" --return-format path --output json)"
  source_path="$(printf '%s' "${screenshot_json}" | extract_screenshot_path)"
  sips -s format png "${source_path}" --out "${output_path}" >/dev/null
}

copy_screenshot_to_checkpoints() {
  local simulator_id="$1"
  local checkpoints_json="$2"

  printf '%s' "${checkpoints_json}" | python3 -c '
import json
import sys

for checkpoint in json.load(sys.stdin):
    path = checkpoint.get("path")
    if path:
        print(path)
' | while IFS= read -r checkpoint_path; do
    capture_png "${simulator_id}" "${checkpoint_path}"
  done
}

SIMULATOR_ID="${CODEAGENTS_SIMULATOR_ID:-$(resolve_simulator_id)}"
VIDEO_STARTED="false"

cleanup() {
  if [[ "${VIDEO_STARTED}" == "true" ]]; then
    "${XCODEBUILDMCP_BIN}" simulator record-video --simulator-id "${SIMULATOR_ID}" --stop >/dev/null 2>&1 || true
  fi
  "${XCODEBUILDMCP_BIN}" simulator stop --simulator-id "${SIMULATOR_ID}" --bundle-id "${BUNDLE_ID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${XCODEBUILDMCP_BIN}" simulator-management erase --simulator-id "${SIMULATOR_ID}" --shutdown-first --output json >/dev/null
"${XCODEBUILDMCP_BIN}" simulator build-and-run \
  --project-path "${PROJECT_PATH}" \
  --scheme "${SCHEME}" \
  --simulator-id "${SIMULATOR_ID}" \
  --configuration "${CONFIGURATION}" \
  --derived-data-path "${DERIVED_DATA_PATH}" \
  --output json >/dev/null

sleep "${LAUNCH_SETTLE_SECONDS}"

if [[ "${MODE}" == "demo" || -n "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS:-}" ]]; then
  if [[ "${OPENCODE_DEMO_RECORD_VIDEO:-false}" == "true" && -n "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-}" ]]; then
    "${XCODEBUILDMCP_BIN}" simulator record-video --simulator-id "${SIMULATOR_ID}" --start --fps 30 --output json >/dev/null
    VIDEO_STARTED="true"
    sleep 2
  fi

  if [[ -n "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_checkpoints "${SIMULATOR_ID}" "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS}"
  elif [[ -n "${OPENCODE_DEMO_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${SIMULATOR_ID}" "${OPENCODE_DEMO_SCREENSHOT_DIR}/home.png"
  fi

  if [[ "${VIDEO_STARTED}" == "true" ]]; then
    sleep 2
    "${XCODEBUILDMCP_BIN}" simulator record-video \
      --simulator-id "${SIMULATOR_ID}" \
      --stop \
      --output-file "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}" \
      --output json >/dev/null
    VIDEO_STARTED="false"
  fi
fi

if [[ "${MODE}" == "visual" || -n "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS:-}" ]]; then
  if [[ -n "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_checkpoints "${SIMULATOR_ID}" "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS}"
  elif [[ -n "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${SIMULATOR_ID}" "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR}/home.png"
  fi
fi

"${XCODEBUILDMCP_BIN}" ui-automation snapshot-ui --simulator-id "${SIMULATOR_ID}" --output json | python_json_text >&2 || true
