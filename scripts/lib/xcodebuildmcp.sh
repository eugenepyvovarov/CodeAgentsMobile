#!/usr/bin/env bash

XCODEBUILDMCP_BIN="${XCODEBUILDMCP_BIN:-xcodebuildmcp}"
XCODEBUILDMCP_MIN_VERSION="${XCODEBUILDMCP_MIN_VERSION:-2.5.0}"

xcbmcp_resolve_binary() {
  if ! command -v "${XCODEBUILDMCP_BIN}" >/dev/null 2>&1; then
    echo "xcodebuildmcp is required but was not found: ${XCODEBUILDMCP_BIN}" >&2
    echo "Install XcodeBuildMCP ${XCODEBUILDMCP_MIN_VERSION} or newer, for example: brew install xcodebuildmcp" >&2
    return 1
  fi
}

xcbmcp_version() {
  "${XCODEBUILDMCP_BIN}" --version 2>/dev/null || "${XCODEBUILDMCP_BIN}" version 2>/dev/null || true
}

xcbmcp_require_min_version() {
  xcbmcp_resolve_binary || return 1

  local version_output
  version_output="$(xcbmcp_version)"
  if [[ -z "${version_output}" ]]; then
    echo "Unable to determine XcodeBuildMCP version from ${XCODEBUILDMCP_BIN}." >&2
    echo "XcodeBuildMCP ${XCODEBUILDMCP_MIN_VERSION} or newer is required." >&2
    return 1
  fi

  echo "XcodeBuildMCP version: ${version_output}" >&2

  python3 - "${version_output}" "${XCODEBUILDMCP_MIN_VERSION}" <<'PY'
import re
import sys

version_output = sys.argv[1]
minimum = sys.argv[2]

match = re.search(r"(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?", version_output)
if not match:
    raise SystemExit(f"Unable to parse XcodeBuildMCP version from: {version_output}")

detected = tuple(int(part) for part in match.groups())
required = tuple(int(part) for part in minimum.split("."))
if detected < required:
    raise SystemExit(
        f"XcodeBuildMCP {minimum} or newer is required; detected {'.'.join(map(str, detected))}. "
        "Upgrade explicitly before retrying."
    )
PY
}

xcbmcp_format_diagnostics() {
  local response_path="$1"
  local context="${2:-XcodeBuildMCP command}"

  if [[ ! -s "${response_path}" ]]; then
    echo "${context} produced no machine-readable output." >&2
    return 0
  fi

  python3 - "${response_path}" "${context}" <<'PY' >&2
import json
import sys

path, context = sys.argv[1], sys.argv[2]

def load_objects(raw):
    raw = raw.strip()
    if not raw:
        return []
    try:
        return [json.loads(raw)]
    except json.JSONDecodeError:
        objects = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                objects.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        return objects

def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]

def print_value(label, value):
    if value is None or value == "":
        return
    print(f"{label}: {value}")

with open(path, encoding="utf-8", errors="replace") as fh:
    objects = load_objects(fh.read())

if not objects:
    print(f"{context} did not return valid JSON/jsonl diagnostics.")
    return_code = 0
else:
    print(f"{context} diagnostics:")
    for obj in objects:
        if not isinstance(obj, dict):
            continue
        data = obj.get("data") if isinstance(obj.get("data"), dict) else {}
        summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
        artifacts = data.get("artifacts") if isinstance(data.get("artifacts"), dict) else {}
        diagnostics = data.get("diagnostics") if isinstance(data.get("diagnostics"), dict) else {}

        print_value("  status", summary.get("status") or obj.get("status"))
        print_value("  build log", artifacts.get("buildLogPath"))
        print_value("  runtime log", artifacts.get("runtimeLogPath"))
        print_value("  OS log", artifacts.get("osLogPath"))

        for label, values in (("error", diagnostics.get("errors")), ("warning", diagnostics.get("warnings"))):
            for item in as_list(values):
                if isinstance(item, dict):
                    message = item.get("message") or item.get("text") or json.dumps(item, sort_keys=True)
                else:
                    message = str(item)
                if message:
                    print(f"  {label}: {message}")
PY
}

xcbmcp_assert_success_file() {
  local response_path="$1"
  local context="${2:-XcodeBuildMCP command}"

  python3 - "${response_path}" "${context}" <<'PY'
import json
import sys

path, context = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8", errors="replace") as fh:
    raw = fh.read().strip()

if not raw:
    raise SystemExit(f"{context} returned empty output")

try:
    objects = [json.loads(raw)]
except json.JSONDecodeError:
    objects = []
    for line_number, line in enumerate(raw.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            objects.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise SystemExit(f"{context} returned invalid jsonl on line {line_number}: {error}") from error

if not objects:
    raise SystemExit(f"{context} returned no JSON/jsonl objects")

failure_statuses = {"error", "failed", "failure", "cancelled", "canceled"}
for obj in objects:
    if not isinstance(obj, dict):
        continue
    if obj.get("didError") is True:
        raise SystemExit(f"{context} reported didError=true")
    data = obj.get("data") if isinstance(obj.get("data"), dict) else {}
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    status = summary.get("status")
    if isinstance(status, str) and status.lower() in failure_statuses:
        raise SystemExit(f"{context} reported status={status}")
PY
}

xcbmcp_extract_simulator_id() {
  local simulator_name="$1"

  python3 -c '
import json
import sys

name = sys.argv[1]
payload = json.load(sys.stdin)
data = payload.get("data") if isinstance(payload, dict) else {}
simulators = data.get("simulators") if isinstance(data, dict) else []
for simulator in simulators:
    if not isinstance(simulator, dict):
        continue
    if simulator.get("name") == name and simulator.get("simulatorId"):
        print(simulator["simulatorId"])
        raise SystemExit(0)
available = ", ".join(
    str(simulator.get("name"))
    for simulator in simulators
    if isinstance(simulator, dict) and simulator.get("name")
)
if not available:
    available = "(none)"
raise SystemExit(f"Simulator named {name!r} was not found in data.simulators[]. Available: {available}")
' "${simulator_name}"
}

xcbmcp_extract_screenshot_path() {
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
data = payload.get("data") if isinstance(payload, dict) else {}
artifacts = data.get("artifacts") if isinstance(data, dict) else {}
path = artifacts.get("screenshotPath") if isinstance(artifacts, dict) else None
if not path:
    raise SystemExit("Unable to read screenshot path from data.artifacts.screenshotPath")
print(path)
'
}

xcbmcp_extract_app_path() {
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
data = payload.get("data") if isinstance(payload, dict) else {}
artifacts = data.get("artifacts") if isinstance(data, dict) else {}
path = artifacts.get("appPath") if isinstance(artifacts, dict) else None
if not path:
    raise SystemExit("Unable to read app path from data.artifacts.appPath")
print(path)
'
}

xcbmcp_extract_json_text() {
  python3 -c '
import json
import sys

def walk(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)
    elif isinstance(value, dict):
        for key in ("label", "title", "value", "text", "name", "identifier"):
            item = value.get(key)
            if isinstance(item, str):
                yield item
        for item in value.values():
            if isinstance(item, (dict, list)):
                yield from walk(item)

payload = json.load(sys.stdin)
texts = []
data = payload.get("data") if isinstance(payload, dict) else None
if data is not None:
    texts.extend(walk(data))

content = payload.get("content") if isinstance(payload, dict) else None
if isinstance(content, list):
    for item in content:
        if isinstance(item, dict) and isinstance(item.get("text"), str):
            texts.append(item["text"])

print("\n".join(texts))
'
}

xcbmcp_run_json() {
  local response_path
  response_path="$(mktemp "${TMPDIR:-/tmp}/xcodebuildmcp-json.XXXXXX")"
  local status=0

  set +e
  "${XCODEBUILDMCP_BIN}" "$@" --output json >"${response_path}"
  status=$?
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "XcodeBuildMCP command failed (${status}): ${XCODEBUILDMCP_BIN} $* --output json" >&2
    xcbmcp_format_diagnostics "${response_path}" "XcodeBuildMCP command"
    rm -f "${response_path}"
    return "${status}"
  fi

  if ! xcbmcp_assert_success_file "${response_path}" "XcodeBuildMCP command"; then
    status=1
    xcbmcp_format_diagnostics "${response_path}" "XcodeBuildMCP command"
    rm -f "${response_path}"
    return "${status}"
  fi

  cat "${response_path}"
  rm -f "${response_path}"
}

xcbmcp_run_jsonl() {
  local response_path
  response_path="$(mktemp "${TMPDIR:-/tmp}/xcodebuildmcp-jsonl.XXXXXX")"
  local status=0

  set +e
  "${XCODEBUILDMCP_BIN}" "$@" --output jsonl >"${response_path}"
  status=$?
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "XcodeBuildMCP command failed (${status}): ${XCODEBUILDMCP_BIN} $* --output jsonl" >&2
    xcbmcp_format_diagnostics "${response_path}" "XcodeBuildMCP command"
    rm -f "${response_path}"
    return "${status}"
  fi

  if ! xcbmcp_assert_success_file "${response_path}" "XcodeBuildMCP command"; then
    status=1
    xcbmcp_format_diagnostics "${response_path}" "XcodeBuildMCP command"
    rm -f "${response_path}"
    return "${status}"
  fi

  cat "${response_path}"
  rm -f "${response_path}"
}
