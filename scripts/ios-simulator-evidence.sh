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
BUNDLE_ID="${CODEAGENTS_BUNDLE_ID:-lifeisgoodlabs.CodeAgentsMobile}"
FUNCTIONS_DIR="${ROOT_DIR}/server/firebase-functions/functions"
PUSH_PREVIEW_FIXTURE="${CODEAGENTS_PUSH_PREVIEW_FIXTURE:-${FUNCTIONS_DIR}/test/fixtures/pushNotificationPreview.json}"
DERIVED_ROOT="${OPENCODE_EVIDENCE_BUILD_ROOT:-${ROOT_DIR}/.build/opencode-evidence}"
DERIVED_DATA_PATH="${CODEAGENTS_DERIVED_DATA_PATH:-${DERIVED_ROOT}/DerivedData}"
LAUNCH_SETTLE_SECONDS="${CODEAGENTS_EVIDENCE_LAUNCH_SETTLE_SECONDS:-4}"
MODE="${1:-auto}"
SCENARIO="${OPENCODE_EVIDENCE_SCENARIO:-${CODEAGENTS_EVIDENCE_SCENARIO:-agents-create-agent-flow}}"
VISUAL_VALIDATION_IDENTIFIER="agents-create-agent-orange"
AGENTS_CTA_CHECKPOINT="agents-empty-create-agent"
NEW_AGENT_SHEET_CHECKPOINT="new-agent-sheet"
PUSH_NOTIFICATION_CHECKPOINT="push-notification-sanitized-preview"
AI_PROVIDERS_VISUAL_VALIDATION_IDENTIFIER="ai-providers-settings-unified"
SETTINGS_AI_PROVIDERS_ENTRY_CHECKPOINT="settings-ai-providers-entry"
AI_PROVIDERS_OPENCODE_DEFAULT_CHECKPOINT="ai-providers-opencode-default"
AI_PROVIDERS_CLAUDE_PROXY_MODE_CHECKPOINT="ai-providers-claude-proxy-mode"
LEGACY_ENTRY_AI_PROVIDERS_CLAUDE_PROXY_CHECKPOINT="legacy-entry-ai-providers-claude-proxy"
USE_FOR_OPENCODE_COPY_OFFER_CHECKPOINT="use-for-opencode-copy-offer"
ARTIFACT_ROOT="${OPENCODE_EVIDENCE_ARTIFACT_ROOT:-${DERIVED_ROOT}/artifacts/${SCENARIO}}"

case "${SCENARIO}" in
  agents-create-agent-flow)
    ;;
  push-notification-preview-sanitizer)
    VISUAL_VALIDATION_IDENTIFIER="push-notification-preview-sanitizer"
    ;;
  ai-providers-settings-unified)
    VISUAL_VALIDATION_IDENTIFIER="${AI_PROVIDERS_VISUAL_VALIDATION_IDENTIFIER}"
    ;;
  *)
    echo "Unsupported iOS simulator evidence scenario: ${SCENARIO}" >&2
    exit 1
    ;;
esac

DEMO_CAPTURE_REQUESTED="false"
VISUAL_CAPTURE_REQUESTED="false"

if [[ "${MODE}" == "demo" \
  || -n "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS:-}" \
  || -n "${OPENCODE_DEMO_SCREENSHOT_DIR:-}" \
  || -n "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-}" ]]; then
  DEMO_CAPTURE_REQUESTED="true"
  export OPENCODE_DEMO_SCREENSHOT_DIR="${OPENCODE_DEMO_SCREENSHOT_DIR:-${ARTIFACT_ROOT}/demo/screenshots}"
  export OPENCODE_DEMO_RECORD_VIDEO="${OPENCODE_DEMO_RECORD_VIDEO:-true}"
  export OPENCODE_DEMO_VIDEO_OUTPUT_PATH="${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-${ARTIFACT_ROOT}/demo/${SCENARIO}.mp4}"
fi

if [[ "${MODE}" == "visual" \
  || -n "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS:-}" \
  || -n "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR:-}" ]]; then
  VISUAL_CAPTURE_REQUESTED="true"
  export OPENCODE_VISUAL_VALIDATION_IDENTIFIER="${OPENCODE_VISUAL_VALIDATION_IDENTIFIER:-${VISUAL_VALIDATION_IDENTIFIER}}"
  export OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR="${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR:-${ARTIFACT_ROOT}/visual/screenshots}"
fi

xcbmcp_require_min_version

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

extract_app_path() {
  python3 -c '
import json
import re
import sys

data = json.load(sys.stdin)
text = "\n".join(item.get("text", "") for item in data.get("content", []) if isinstance(item, dict))
match = re.search(r"(/[^\n]+?\.app)", text)
if not match:
    raise SystemExit(f"Unable to parse app path from xcodebuildmcp output: {text}")
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

ui_snapshot_text() {
  local simulator_id="$1"

  "${XCODEBUILDMCP_BIN}" ui-automation snapshot-ui --simulator-id "${simulator_id}" --output json | python_json_text
}

ui_contains_label() {
  local simulator_id="$1"
  local label="$2"

  ui_snapshot_text "${simulator_id}" | python3 -c '
import sys

label = sys.argv[1]
text = sys.stdin.read()
raise SystemExit(0 if label in text else 1)
' "${label}"
}

wait_for_ui_label() {
  local simulator_id="$1"
  local label="$2"
  local attempts="${3:-8}"
  local delay_seconds="${4:-1}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ui_contains_label "${simulator_id}" "${label}"; then
      return 0
    fi
    sleep "${delay_seconds}"
  done

  return 1
}

navigate_to_agents_screen() {
  local simulator_id="$1"

  if wait_for_ui_label "${simulator_id}" "Create Agent" 2 1; then
    return 0
  fi

  if ui_contains_label "${simulator_id}" "Agents"; then
    "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${simulator_id}" --label "Agents" --post-delay 1 --output json >/dev/null || true
  fi

  if ! wait_for_ui_label "${simulator_id}" "Create Agent" 8 1; then
    echo "Unable to navigate to the Agents screen Create Agent CTA for ${SCENARIO}." >&2
    ui_snapshot_text "${simulator_id}" >&2 || true
    exit 1
  fi
}

navigate_to_settings_screen() {
  local simulator_id="$1"

  navigate_to_agents_screen "${simulator_id}"
  "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${simulator_id}" --id "agents-settings-button" --post-delay 1 --output json >/dev/null
  if ! wait_for_ui_label "${simulator_id}" "Settings" 8 1; then
    echo "Unable to navigate to Settings for ${SCENARIO}." >&2
    ui_snapshot_text "${simulator_id}" >&2 || true
    exit 1
  fi
}

launch_app() {
  local simulator_id="$1"
  shift
  local launch_command=("${XCODEBUILDMCP_BIN}" simulator launch-app --simulator-id "${simulator_id}" --bundle-id "${BUNDLE_ID}")

  for launch_arg in "$@"; do
    launch_command+=("--args=${launch_arg}")
  done

  "${launch_command[@]}" --output json >/dev/null
}

build_install_and_launch_app() {
  local simulator_id="$1"
  shift
  local app_path_json
  local app_path
  local derived_app_path

  "${XCODEBUILDMCP_BIN}" simulator build \
    --project-path "${PROJECT_PATH}" \
    --scheme "${SCHEME}" \
    --simulator-id "${simulator_id}" \
    --configuration "${CONFIGURATION}" \
    --derived-data-path "${DERIVED_DATA_PATH}" \
    --output json >/dev/null

  app_path_json="$("${XCODEBUILDMCP_BIN}" simulator get-app-path \
    --project-path "${PROJECT_PATH}" \
    --scheme "${SCHEME}" \
    --platform "iOS Simulator" \
    --simulator-id "${simulator_id}" \
    --configuration "${CONFIGURATION}" \
    --output json)"
  app_path="$(printf '%s' "${app_path_json}" | extract_app_path)"
  derived_app_path="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphonesimulator/${SCHEME}.app"
  if [[ ! -d "${app_path}" && -d "${derived_app_path}" ]]; then
    app_path="${derived_app_path}"
  fi

  "${XCODEBUILDMCP_BIN}" simulator-management boot --simulator-id "${simulator_id}" --output json >/dev/null
  "${XCODEBUILDMCP_BIN}" simulator install --simulator-id "${simulator_id}" --app-path "${app_path}" --output json >/dev/null
  launch_app "${simulator_id}" "$@"
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

copy_screenshot_to_named_checkpoint() {
  local simulator_id="$1"
  local checkpoints_json="$2"
  local checkpoint_name="$3"
  local fallback_index="${4:-}"

  printf '%s' "${checkpoints_json}" | python3 -c '
import json
import os
import sys

checkpoint_name = sys.argv[1]
fallback_index = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
raw_checkpoints = json.load(sys.stdin)

if isinstance(raw_checkpoints, dict):
    checkpoints = raw_checkpoints.get("checkpoints") or raw_checkpoints.get("screenshots") or []
    if not checkpoints:
        checkpoints = []
        for name, value in raw_checkpoints.items():
            if isinstance(value, str):
                checkpoints.append({"name": name, "path": value})
            elif isinstance(value, dict):
                checkpoint = dict(value)
                checkpoint.setdefault("name", name)
                checkpoints.append(checkpoint)
elif isinstance(raw_checkpoints, list):
    checkpoints = raw_checkpoints
else:
    checkpoints = []

matches = []
for checkpoint in checkpoints:
    if isinstance(checkpoint, str):
        path = checkpoint
        checkpoint = {}
    elif isinstance(checkpoint, dict):
        path = checkpoint.get("path")
    else:
        path = None
    if not path:
        continue
    names = [
        str(checkpoint.get("name", "")),
        str(checkpoint.get("id", "")),
        str(checkpoint.get("checkpoint", "")),
        os.path.splitext(os.path.basename(path))[0],
    ]
    if checkpoint_name in names or checkpoint_name in path:
        matches.append(path)
if not matches and fallback_index is not None and fallback_index < len(checkpoints):
    fallback = checkpoints[fallback_index]
    path = fallback if isinstance(fallback, str) else fallback.get("path") if isinstance(fallback, dict) else None
    if path:
        matches.append(path)
for path in matches:
    print(path)
' "${checkpoint_name}" "${fallback_index}" | while IFS= read -r checkpoint_path; do
    capture_png "${simulator_id}" "${checkpoint_path}"
  done
}

capture_demo_agents_screen() {
  local simulator_id="$1"

  if [[ -n "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_named_checkpoint "${simulator_id}" "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS}" "${AGENTS_CTA_CHECKPOINT}" "0"
  elif [[ -n "${OPENCODE_DEMO_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${simulator_id}" "${OPENCODE_DEMO_SCREENSHOT_DIR}/${AGENTS_CTA_CHECKPOINT}.png"
  fi
}

capture_demo_new_agent_sheet() {
  local simulator_id="$1"

  if [[ -n "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_named_checkpoint "${simulator_id}" "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS}" "${NEW_AGENT_SHEET_CHECKPOINT}" "1"
  elif [[ -n "${OPENCODE_DEMO_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${simulator_id}" "${OPENCODE_DEMO_SCREENSHOT_DIR}/${NEW_AGENT_SHEET_CHECKPOINT}.png"
  fi
}

capture_visual_agents_screen() {
  local simulator_id="$1"

  if [[ -n "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_named_checkpoint \
      "${simulator_id}" \
      "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS}" \
      "${AGENTS_CTA_CHECKPOINT}" \
      "0"
  elif [[ -n "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${simulator_id}" "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR}/${AGENTS_CTA_CHECKPOINT}.png"
  fi
}

build_push_notification_payload() {
  local output_path="$1"
  local preview_output_path="$2"

  mkdir -p "$(dirname "${output_path}")"
  npm --prefix "${FUNCTIONS_DIR}" run build >/dev/null

  node - "${PUSH_PREVIEW_FIXTURE}" "${FUNCTIONS_DIR}/lib/notificationPreview.js" "${BUNDLE_ID}" "${output_path}" "${preview_output_path}" <<'NODE'
const fs = require("fs");

const [fixturePath, sanitizerPath, bundleId, outputPath, previewOutputPath] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
const { sanitizeNotificationPreview } = require(sanitizerPath);

const sanitizedBody = sanitizeNotificationPreview(fixture.issueShapedPreview) || "CodeAgents reply finished.";
const payload = {
  "Simulator Target Bundle": bundleId,
  aps: {
    alert: {
      title: "@op",
      body: sanitizedBody,
    },
    sound: "default",
    badge: 1,
  },
  conversation_id: "evidence-conversation",
  server_id: "evidence-server",
  project_path: "/tmp/codeagents-evidence",
  agent_display_name: "op",
  event_type: "reply_finished",
};

fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`);
fs.writeFileSync(previewOutputPath, `${sanitizedBody}\n`);
NODE
}

deliver_synthetic_push_notification() {
  local simulator_id="$1"
  local payload_path="$2"

  xcrun simctl push "${simulator_id}" "${BUNDLE_ID}" "${payload_path}" >/dev/null
}

capture_named_visual_checkpoint() {
  local simulator_id="$1"
  local checkpoint_name="$2"
  local fallback_index="$3"

  if [[ -n "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_named_checkpoint \
      "${simulator_id}" \
      "${OPENCODE_VISUAL_VALIDATION_FULL_PAGE_CHECKPOINTS}" \
      "${checkpoint_name}" \
      "${fallback_index}"
  elif [[ -n "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${simulator_id}" "${OPENCODE_VISUAL_VALIDATION_SCREENSHOT_DIR}/${checkpoint_name}.png"
  fi
}

capture_named_demo_checkpoint() {
  local simulator_id="$1"
  local checkpoint_name="$2"
  local fallback_index="$3"

  if [[ -n "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS:-}" ]]; then
    copy_screenshot_to_named_checkpoint \
      "${simulator_id}" \
      "${OPENCODE_DEMO_SCREENSHOT_CHECKPOINTS}" \
      "${checkpoint_name}" \
      "${fallback_index}"
  elif [[ -n "${OPENCODE_DEMO_SCREENSHOT_DIR:-}" ]]; then
    capture_png "${simulator_id}" "${OPENCODE_DEMO_SCREENSHOT_DIR}/${checkpoint_name}.png"
  fi
}

capture_ai_providers_checkpoint() {
  local simulator_id="$1"
  local checkpoint_name="$2"
  local fallback_index="$3"

  if [[ "${VISUAL_CAPTURE_REQUESTED}" == "true" ]]; then
    capture_named_visual_checkpoint "${simulator_id}" "${checkpoint_name}" "${fallback_index}"
  fi
  if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" ]]; then
    capture_named_demo_checkpoint "${simulator_id}" "${checkpoint_name}" "${fallback_index}"
  fi
}

capture_push_notification_checkpoint() {
  local simulator_id="$1"

  if [[ "${VISUAL_CAPTURE_REQUESTED}" == "true" ]]; then
    capture_named_visual_checkpoint "${simulator_id}" "${PUSH_NOTIFICATION_CHECKPOINT}" "0"
  fi
  if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" ]]; then
    capture_named_demo_checkpoint "${simulator_id}" "${PUSH_NOTIFICATION_CHECKPOINT}" "0"
  fi
}

run_push_notification_preview_sanitizer() {
  local simulator_id="$1"
  local payload_path="${ARTIFACT_ROOT}/synthetic-push/push-notification-preview-sanitizer.apns"
  local preview_output_path="${ARTIFACT_ROOT}/synthetic-push/sanitized-preview.txt"

  build_push_notification_payload "${payload_path}" "${preview_output_path}"

  if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" \
    && "${OPENCODE_DEMO_RECORD_VIDEO:-false}" == "true" \
    && -n "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-}" ]]; then
    mkdir -p "$(dirname "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}")"
    "${XCODEBUILDMCP_BIN}" simulator record-video \
      --simulator-id "${simulator_id}" \
      --stop \
      --output-file "${ARTIFACT_ROOT}/stale-recording.mp4" \
      --output json >/dev/null 2>&1 || true
    "${XCODEBUILDMCP_BIN}" simulator record-video --simulator-id "${simulator_id}" --start --fps 30 --output json >/dev/null
    VIDEO_STARTED="true"
    sleep 1
  fi

  "${XCODEBUILDMCP_BIN}" ui-automation button --simulator-id "${simulator_id}" --button-type lock --output json >/dev/null || true
  sleep 1
  deliver_synthetic_push_notification "${simulator_id}" "${payload_path}"
  sleep 2

  capture_push_notification_checkpoint "${simulator_id}"

  if [[ "${VIDEO_STARTED}" == "true" ]]; then
    sleep 2
    "${XCODEBUILDMCP_BIN}" simulator record-video \
      --simulator-id "${simulator_id}" \
      --stop \
      --output-file "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}" \
      --output json >/dev/null
    VIDEO_STARTED="false"
  fi
}

run_ai_providers_settings_unified_scenario() {
  local simulator_id="$1"
  local normal_launch_args=(--ui-testing --reset-ui-test-defaults)
  if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" ]]; then
    normal_launch_args+=(--ui-test-ai-providers-legacy-key)
  fi

  build_install_and_launch_app "${simulator_id}" "${normal_launch_args[@]}"
  sleep "${LAUNCH_SETTLE_SECONDS}"

  if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" && "${OPENCODE_DEMO_RECORD_VIDEO:-false}" == "true" && -n "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-}" ]]; then
    mkdir -p "$(dirname "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}")"
    "${XCODEBUILDMCP_BIN}" simulator record-video \
      --simulator-id "${simulator_id}" \
      --stop \
      --output-file "${ARTIFACT_ROOT}/stale-recording.mp4" \
      --output json >/dev/null 2>&1 || true
    "${XCODEBUILDMCP_BIN}" simulator record-video --simulator-id "${simulator_id}" --start --fps 30 --output json >/dev/null
    VIDEO_STARTED="true"
    sleep 2
  fi

  navigate_to_settings_screen "${simulator_id}"
  capture_ai_providers_checkpoint "${simulator_id}" "${SETTINGS_AI_PROVIDERS_ENTRY_CHECKPOINT}" "0"

  "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${simulator_id}" --id "settings-ai-providers-link" --post-delay 1 --output json >/dev/null
  if ! wait_for_ui_label "${simulator_id}" "OpenCode" 8 1; then
    echo "AI Providers did not open in OpenCode mode for ${SCENARIO}." >&2
    ui_snapshot_text "${simulator_id}" >&2 || true
    exit 1
  fi
  capture_ai_providers_checkpoint "${simulator_id}" "${AI_PROVIDERS_OPENCODE_DEFAULT_CHECKPOINT}" "1"

  if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" ]]; then
    capture_named_demo_checkpoint "${simulator_id}" "${USE_FOR_OPENCODE_COPY_OFFER_CHECKPOINT}" "4"
  fi

  "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${simulator_id}" --id "ai-provider-mode-claude-proxy" --post-delay 1 --output json >/dev/null \
    || "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${simulator_id}" -x 280 -y 115 --post-delay 1 --output json >/dev/null
  if ! wait_for_ui_label "${simulator_id}" "Provider" 8 1; then
    echo "Claude Code Proxy mode did not become visible for ${SCENARIO}." >&2
    ui_snapshot_text "${simulator_id}" >&2 || true
    exit 1
  fi
  capture_ai_providers_checkpoint "${simulator_id}" "${AI_PROVIDERS_CLAUDE_PROXY_MODE_CHECKPOINT}" "2"

  "${XCODEBUILDMCP_BIN}" simulator stop --simulator-id "${simulator_id}" --bundle-id "${BUNDLE_ID}" --output json >/dev/null || true
  launch_app "${simulator_id}" --ui-testing --reset-ui-test-defaults --ui-test-ai-providers-legacy-project
  sleep "${LAUNCH_SETTLE_SECONDS}"

  if ! wait_for_ui_label "${simulator_id}" "Change Provider" 10 1; then
    echo "Legacy Change Provider route was not visible for ${SCENARIO}." >&2
    ui_snapshot_text "${simulator_id}" >&2 || true
    exit 1
  fi
  "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${simulator_id}" --label "Change Provider" --post-delay 1 --output json >/dev/null
  if ! wait_for_ui_label "${simulator_id}" "Endpoint, timeouts, and model defaults are preconfigured for each provider." 8 1; then
    echo "Legacy Change Provider did not open AI Providers in Claude Code Proxy mode for ${SCENARIO}." >&2
    ui_snapshot_text "${simulator_id}" >&2 || true
    exit 1
  fi
  capture_ai_providers_checkpoint "${simulator_id}" "${LEGACY_ENTRY_AI_PROVIDERS_CLAUDE_PROXY_CHECKPOINT}" "3"

  if [[ "${VIDEO_STARTED}" == "true" ]]; then
    sleep 2
    "${XCODEBUILDMCP_BIN}" simulator record-video \
      --simulator-id "${simulator_id}" \
      --stop \
      --output-file "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}" \
      --output json >/dev/null
    VIDEO_STARTED="false"
  fi
}

SIMULATOR_ID="${CODEAGENTS_SIMULATOR_ID:-$(resolve_simulator_id)}"
VIDEO_STARTED="false"

cleanup() {
  if [[ "${VIDEO_STARTED}" == "true" ]]; then
    if [[ -n "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-}" ]]; then
      mkdir -p "$(dirname "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}")"
      "${XCODEBUILDMCP_BIN}" simulator record-video \
        --simulator-id "${SIMULATOR_ID}" \
        --stop \
        --output-file "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}" >/dev/null 2>&1 || true
    fi
  fi
  "${XCODEBUILDMCP_BIN}" simulator stop --simulator-id "${SIMULATOR_ID}" --bundle-id "${BUNDLE_ID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${XCODEBUILDMCP_BIN}" simulator-management erase --simulator-id "${SIMULATOR_ID}" --shutdown-first --output json >/dev/null

if [[ "${SCENARIO}" == "ai-providers-settings-unified" ]]; then
  run_ai_providers_settings_unified_scenario "${SIMULATOR_ID}"
  "${XCODEBUILDMCP_BIN}" ui-automation snapshot-ui --simulator-id "${SIMULATOR_ID}" --output json | python_json_text >&2 || true
  exit 0
fi

"${XCODEBUILDMCP_BIN}" simulator build-and-run \
  --project-path "${PROJECT_PATH}" \
  --scheme "${SCHEME}" \
  --simulator-id "${SIMULATOR_ID}" \
  --configuration "${CONFIGURATION}" \
  --derived-data-path "${DERIVED_DATA_PATH}" \
  --output json >/dev/null

sleep "${LAUNCH_SETTLE_SECONDS}"

if [[ "${SCENARIO}" == "push-notification-preview-sanitizer" ]]; then
  run_push_notification_preview_sanitizer "${SIMULATOR_ID}"
  "${XCODEBUILDMCP_BIN}" ui-automation snapshot-ui --simulator-id "${SIMULATOR_ID}" --output json | python_json_text >&2 || true
  exit 0
fi

navigate_to_agents_screen "${SIMULATOR_ID}"

if [[ "${VISUAL_CAPTURE_REQUESTED}" == "true" ]]; then
  capture_visual_agents_screen "${SIMULATOR_ID}"
fi

if [[ "${DEMO_CAPTURE_REQUESTED}" == "true" ]]; then
  if [[ "${OPENCODE_DEMO_RECORD_VIDEO:-false}" == "true" && -n "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH:-}" ]]; then
    mkdir -p "$(dirname "${OPENCODE_DEMO_VIDEO_OUTPUT_PATH}")"
    "${XCODEBUILDMCP_BIN}" simulator record-video \
      --simulator-id "${SIMULATOR_ID}" \
      --stop \
      --output-file "${ARTIFACT_ROOT}/stale-recording.mp4" \
      --output json >/dev/null 2>&1 || true
    "${XCODEBUILDMCP_BIN}" simulator record-video --simulator-id "${SIMULATOR_ID}" --start --fps 30 --output json >/dev/null
    VIDEO_STARTED="true"
    sleep 2
  fi

  capture_demo_agents_screen "${SIMULATOR_ID}"
  "${XCODEBUILDMCP_BIN}" ui-automation tap --simulator-id "${SIMULATOR_ID}" --label "Create Agent" --post-delay 1 --output json >/dev/null
  if ! wait_for_ui_label "${SIMULATOR_ID}" "New Agent" 8 1; then
    echo "Create Agent did not present the New Agent sheet for ${SCENARIO}." >&2
    ui_snapshot_text "${SIMULATOR_ID}" >&2 || true
    exit 1
  fi
  capture_demo_new_agent_sheet "${SIMULATOR_ID}"

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

"${XCODEBUILDMCP_BIN}" ui-automation snapshot-ui --simulator-id "${SIMULATOR_ID}" --output json | python_json_text >&2 || true
