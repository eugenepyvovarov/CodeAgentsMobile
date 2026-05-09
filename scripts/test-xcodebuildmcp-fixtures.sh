#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${ROOT_DIR}/scripts/testdata/xcodebuildmcp"

source "${ROOT_DIR}/scripts/lib/xcodebuildmcp.sh"

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "${label}: expected output to contain '${needle}'" >&2
    echo "--- output ---" >&2
    printf '%s\n' "${haystack}" >&2
    exit 1
  fi
}

simulator_id="$(xcbmcp_extract_simulator_id "iPhone 17" < "${FIXTURE_DIR}/simulator-list.json")"
assert_equals "SIM-17" "${simulator_id}" "simulator list parser"

screenshot_path="$(xcbmcp_extract_screenshot_path < "${FIXTURE_DIR}/screenshot-path.json")"
assert_equals "/tmp/xcodebuildmcp/screenshot.png" "${screenshot_path}" "screenshot path parser"

app_path="$(xcbmcp_extract_app_path < "${FIXTURE_DIR}/app-path.json")"
assert_equals "/tmp/DerivedData/Build/Products/Debug-iphonesimulator/CodeAgentsMobile.app" "${app_path}" "app path parser"

snapshot_text="$(xcbmcp_extract_json_text < "${FIXTURE_DIR}/snapshot-data-tree.json")"
assert_contains "${snapshot_text}" "Create Agent" "snapshot data-tree parser"
assert_contains "${snapshot_text}" "agents-create-button" "snapshot identifier parser"

xcbmcp_assert_success_file "${FIXTURE_DIR}/build-success.json" "fixture build success"
xcbmcp_assert_success_file "${FIXTURE_DIR}/build-stream.jsonl" "fixture jsonl stream"

failure_output="$(xcbmcp_format_diagnostics "${FIXTURE_DIR}/build-failure-with-log-paths.json" "fixture build failure" 2>&1)"
assert_contains "${failure_output}" "build log: /tmp/xcodebuildmcp/build-failure.log" "failure build log diagnostics"
assert_contains "${failure_output}" "runtime log: /tmp/xcodebuildmcp/runtime.log" "failure runtime log diagnostics"
assert_contains "${failure_output}" "OS log: /tmp/xcodebuildmcp/os.log" "failure OS log diagnostics"
assert_contains "${failure_output}" "error: Swift compile failed" "failure error diagnostics"
assert_contains "${failure_output}" "warning: Deployment target warning" "failure warning diagnostics"

if xcbmcp_assert_success_file "${FIXTURE_DIR}/build-failure-with-log-paths.json" "fixture build failure" 2>/dev/null; then
  echo "build failure fixture unexpectedly passed success assertion" >&2
  exit 1
fi

fake_bin="$(mktemp "${TMPDIR:-/tmp}/xcodebuildmcp-fake.XXXXXX")"
cat > "${fake_bin}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${XCODEBUILDMCP_FIXTURE_DIR:?}"

if [[ "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
  printf 'XcodeBuildMCP 2.5.1\n'
  exit 0
fi

output="json"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--output" && $((i + 1)) -lt ${#args[@]} ]]; then
    output="${args[$((i + 1))]}"
  fi
done

case "${args[0]:-} ${args[1]:-}" in
  "simulator list") cat "${fixture_dir}/simulator-list.json" ;;
  "ui-automation screenshot") cat "${fixture_dir}/screenshot-path.json" ;;
  "simulator get-app-path") cat "${fixture_dir}/app-path.json" ;;
  "simulator build") cat "${fixture_dir}/build-success.json" ;;
  "simulator build-and-run")
    if [[ "${output}" == "jsonl" ]]; then
      cat "${fixture_dir}/build-stream.jsonl"
    else
      cat "${fixture_dir}/build-success.json"
    fi
    ;;
  "ui-automation snapshot-ui") cat "${fixture_dir}/snapshot-data-tree.json" ;;
  *) cat "${fixture_dir}/build-success.json" ;;
esac
FAKE
chmod +x "${fake_bin}"
trap 'rm -f "${fake_bin}"' EXIT

XCODEBUILDMCP_BIN="${fake_bin}"
XCODEBUILDMCP_FIXTURE_DIR="${FIXTURE_DIR}"
export XCODEBUILDMCP_BIN XCODEBUILDMCP_FIXTURE_DIR

xcbmcp_require_min_version >/dev/null
xcbmcp_run_json simulator build >/dev/null
xcbmcp_run_jsonl simulator build-and-run >/dev/null

fake_simulator_id="$(xcbmcp_run_json simulator list | xcbmcp_extract_simulator_id "iPhone 17")"
assert_equals "SIM-17" "${fake_simulator_id}" "fake CLI simulator parser"

echo "XcodeBuildMCP fixture smoke tests passed."
