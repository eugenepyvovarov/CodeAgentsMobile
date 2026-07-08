#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-${MOBILECODE_E2E_ENV_FILE:-$HOME/.mobilecode-e2e.env}}"
source "${ROOT_DIR}/scripts/lib/xcodebuildmcp.sh"

load_env_file() {
  local file_path="$1"
  python3 - "$file_path" <<'PY'
import re
import shlex
import sys

path = sys.argv[1]
key_pattern = re.compile(r"^MOBILECODE_E2E_[A-Za-z0-9_]+$")

with open(path, encoding="utf-8") as env_file:
    for raw_line in env_file:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if "=" not in line:
            continue

        key, raw_value = line.split("=", 1)
        key = key.strip()
        if not key_pattern.match(key):
            continue

        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        elif len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1].replace(r"\"", '"').replace(r"\\", "\\")
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()

        print(f"export {key}={shlex.quote(value)}")
PY
}

if [[ -f "$ENV_FILE" ]]; then
  eval "$(load_env_file "$ENV_FILE")"
elif [[ -f "$ROOT_DIR/.mobilecode-e2e.env" ]]; then
  eval "$(load_env_file "$ROOT_DIR/.mobilecode-e2e.env")"
fi

: "${MOBILECODE_E2E_PROVIDER:?Set MOBILECODE_E2E_PROVIDER to digitalocean or hetzner.}"
: "${MOBILECODE_E2E_CLOUD_TOKEN:?Set MOBILECODE_E2E_CLOUD_TOKEN in a local env file.}"

if [[ "${MOBILECODE_E2E_ALLOW_CLOUD_MUTATION:-}" != "1" ]]; then
  echo "Refusing to create/delete cloud resources without MOBILECODE_E2E_ALLOW_CLOUD_MUTATION=1." >&2
  exit 2
fi

export MOBILECODE_E2E_RUN_ID="${MOBILECODE_E2E_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}"
export MOBILECODE_E2E_SERVER_NAME_PREFIX="${MOBILECODE_E2E_SERVER_NAME_PREFIX:-mobilecode-e2e}"
export MOBILECODE_E2E_SERVER_NAME="${MOBILECODE_E2E_SERVER_NAME:-${MOBILECODE_E2E_SERVER_NAME_PREFIX}-${MOBILECODE_E2E_RUN_ID}}"
export MOBILECODE_E2E_SSH_KEY_NAME="${MOBILECODE_E2E_SSH_KEY_NAME:-${MOBILECODE_E2E_SERVER_NAME}-key}"
export MOBILECODE_E2E_AGENT_NAME="${MOBILECODE_E2E_AGENT_NAME:-${MOBILECODE_E2E_SERVER_NAME}-agent}"
export MOBILECODE_E2E_PROVISIONING_TIMEOUT_SECONDS="${MOBILECODE_E2E_PROVISIONING_TIMEOUT_SECONDS:-1800}"
export MOBILECODE_E2E_AI_PROVIDER_ID="${MOBILECODE_E2E_AI_PROVIDER_ID:-minimax}"
normalized_cloud_provider="$(printf '%s' "$MOBILECODE_E2E_PROVIDER" | tr '[:upper:]' '[:lower:]')"
if [[ "$normalized_cloud_provider" == "digitalocean" ]]; then
  export MOBILECODE_E2E_SIZE="${MOBILECODE_E2E_SIZE:-s-1vcpu-1gb}"
elif [[ "$normalized_cloud_provider" == "hetzner" ]]; then
  export MOBILECODE_E2E_SIZE="${MOBILECODE_E2E_SIZE:-cx22}"
fi
export MOBILECODE_E2E_PROVISIONING_DEBUG_LOG=1
if [[ -n "${MOBILECODE_E2E_AI_API_KEY:-}" ]]; then
  export MOBILECODE_E2E_AUTOFILL_AI_API_KEY=1
  normalized_ai_provider="$(printf '%s' "$MOBILECODE_E2E_AI_PROVIDER_ID" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized_ai_provider" == "minimax" ]]; then
    export MOBILECODE_E2E_AI_MODEL_ID="${MOBILECODE_E2E_AI_MODEL_ID:-minimax/MiniMax-M2.7}"
    export MOBILECODE_E2E_AI_SMALL_MODEL_ID="${MOBILECODE_E2E_AI_SMALL_MODEL_ID:-minimax/MiniMax-M2.7}"
  fi
fi

GENERATED_ENV_FILE="$ROOT_DIR/scripts/e2e/.mobilecode-e2e.generated.env"
GENERATED_DIR="$ROOT_DIR/scripts/e2e/.generated"

prepare_local_ssh_key() {
  if [[ -n "${MOBILECODE_E2E_SSH_PRIVATE_KEY_B64:-}" && -n "${MOBILECODE_E2E_SSH_PUBLIC_KEY:-}" ]]; then
    export MOBILECODE_E2E_AUTOUSE_HOST_SSH_KEY=1
    return
  fi

  mkdir -p "$GENERATED_DIR"
  export MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH="${MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH:-$GENERATED_DIR/${MOBILECODE_E2E_SERVER_NAME}_ed25519}"
  export MOBILECODE_E2E_SSH_PUBLIC_KEY_PATH="${MOBILECODE_E2E_SSH_PUBLIC_KEY_PATH:-${MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH}.pub}"

  rm -f "$MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH" "$MOBILECODE_E2E_SSH_PUBLIC_KEY_PATH"
  ssh-keygen -q -t ed25519 -N "" -C "$MOBILECODE_E2E_SSH_KEY_NAME" -f "$MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH"
  chmod 600 "$MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH"

  export MOBILECODE_E2E_SSH_PUBLIC_KEY="$(cat "$MOBILECODE_E2E_SSH_PUBLIC_KEY_PATH")"
  export MOBILECODE_E2E_SSH_PRIVATE_KEY_B64="$(base64 < "$MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH" | tr -d '\n')"
  export MOBILECODE_E2E_AUTOUSE_HOST_SSH_KEY=1
}

prepare_local_ssh_key

write_generated_env_file() {
  umask 077
  python3 - "$GENERATED_ENV_FILE" <<'PY'
import os
import shlex
import sys

path = sys.argv[1]
keys = [
    "MOBILECODE_E2E_PROVIDER",
    "MOBILECODE_E2E_CLOUD_TOKEN",
    "MOBILECODE_E2E_ALLOW_CLOUD_MUTATION",
    "MOBILECODE_E2E_DELETE_CREATED_SERVERS",
    "MOBILECODE_E2E_PROVIDER_NAME",
    "MOBILECODE_E2E_RUN_ID",
    "MOBILECODE_E2E_SERVER_NAME_PREFIX",
    "MOBILECODE_E2E_SERVER_NAME",
    "MOBILECODE_E2E_SSH_KEY_NAME",
    "MOBILECODE_E2E_AGENT_NAME",
    "MOBILECODE_E2E_REGION",
    "MOBILECODE_E2E_SIZE",
    "MOBILECODE_E2E_PROVISIONING_TIMEOUT_SECONDS",
    "MOBILECODE_E2E_AI_PROVIDER_ID",
    "MOBILECODE_E2E_AI_API_KEY",
    "MOBILECODE_E2E_AI_MODEL_ID",
    "MOBILECODE_E2E_AI_SMALL_MODEL_ID",
    "MOBILECODE_E2E_AUTOUSE_HOST_SSH_KEY",
    "MOBILECODE_E2E_SSH_PUBLIC_KEY",
    "MOBILECODE_E2E_SSH_PRIVATE_KEY_B64",
    "MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH",
    "MOBILECODE_E2E_SSH_PUBLIC_KEY_PATH",
    "MOBILECODE_E2E_PROVISIONING_DEBUG_LOG",
]

with open(path, "w", encoding="utf-8") as generated:
    generated.write("# Generated by run-opencode-cloud-ux.sh. Do not commit.\n")
    for key in keys:
        value = os.environ.get(key)
        if value:
            generated.write(f"{key}={shlex.quote(value)}\n")
PY
}

write_generated_env_file

cleanup_cloud_servers() {
  if [[ "${MOBILECODE_E2E_DELETE_CREATED_SERVERS:-1}" != "1" ]]; then
    echo "Skipping cloud cleanup because MOBILECODE_E2E_DELETE_CREATED_SERVERS is not 1."
    return
  fi

  python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

provider = os.environ["MOBILECODE_E2E_PROVIDER"].strip().lower()
token = os.environ["MOBILECODE_E2E_CLOUD_TOKEN"]
prefix = os.environ.get("MOBILECODE_E2E_SERVER_NAME_PREFIX", "mobilecode-e2e")

if len(prefix) < 8 or "e2e" not in prefix.lower():
    print(f"Refusing cleanup for unsafe prefix: {prefix!r}", file=sys.stderr)
    sys.exit(3)

def request(method, url, attempts=3):
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                body = response.read()
                return response.status, body
        except urllib.error.HTTPError as error:
            if method == "DELETE" and error.code == 404:
                return error.code, b""
            body = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {url} failed with HTTP {error.code}: {body}") from error
        except Exception as error:  # noqa: BLE001 - retry transient network failures
            last_error = error
            if attempt < attempts:
                import time
                time.sleep(2 * attempt)
                continue
            raise RuntimeError(f"{method} {url} failed after {attempts} attempts: {error}") from last_error
    raise RuntimeError(f"{method} {url} failed: {last_error}")

def digitalocean_servers():
    url = "https://api.digitalocean.com/v2/droplets?per_page=200"
    while url:
        _, body = request("GET", url)
        payload = json.loads(body or b"{}")
        for droplet in payload.get("droplets", []):
            yield str(droplet["id"]), droplet.get("name", "")
        pages = payload.get("links", {}).get("pages", {})
        url = pages.get("next")

def hetzner_servers():
    page = 1
    while True:
        url = f"https://api.hetzner.cloud/v1/servers?per_page=50&page={page}"
        _, body = request("GET", url)
        payload = json.loads(body or b"{}")
        for server in payload.get("servers", []):
            yield str(server["id"]), server.get("name", "")
        next_page = payload.get("meta", {}).get("pagination", {}).get("next_page")
        if not next_page:
            break
        page = next_page

def digitalocean_ssh_keys():
    url = "https://api.digitalocean.com/v2/account/keys?per_page=200"
    while url:
        _, body = request("GET", url)
        payload = json.loads(body or b"{}")
        for key in payload.get("ssh_keys", []):
            yield str(key["id"]), key.get("name", "")
        pages = payload.get("links", {}).get("pages", {})
        url = pages.get("next")

def hetzner_ssh_keys():
    page = 1
    while True:
        url = f"https://api.hetzner.cloud/v1/ssh_keys?per_page=50&page={page}"
        _, body = request("GET", url)
        payload = json.loads(body or b"{}")
        for key in payload.get("ssh_keys", []):
            yield str(key["id"]), key.get("name", "")
        next_page = payload.get("meta", {}).get("pagination", {}).get("next_page")
        if not next_page:
            break
        page = next_page

if provider == "digitalocean":
    servers = list(digitalocean_servers())
    ssh_keys = list(digitalocean_ssh_keys())
    delete_url = "https://api.digitalocean.com/v2/droplets/{id}"
    key_delete_url = "https://api.digitalocean.com/v2/account/keys/{id}"
elif provider == "hetzner":
    servers = list(hetzner_servers())
    ssh_keys = list(hetzner_ssh_keys())
    delete_url = "https://api.hetzner.cloud/v1/servers/{id}"
    key_delete_url = "https://api.hetzner.cloud/v1/ssh_keys/{id}"
else:
    raise RuntimeError("MOBILECODE_E2E_PROVIDER must be digitalocean or hetzner")

exact_server = (os.environ.get("MOBILECODE_E2E_SERVER_NAME") or "").strip()
exact_key = (os.environ.get("MOBILECODE_E2E_SSH_KEY_NAME") or "").strip()

def should_delete_name(name: str, exact: str) -> bool:
    if name.startswith(prefix):
        return True
    return bool(exact) and name == exact

matches = [
    (server_id, name)
    for server_id, name in servers
    if should_delete_name(name, exact_server)
]
# de-dupe by id
seen_ids = set()
unique_matches = []
for server_id, name in matches:
    if server_id in seen_ids:
        continue
    seen_ids.add(server_id)
    unique_matches.append((server_id, name))

if not unique_matches:
    print(f"No cloud servers matched cleanup prefix {prefix!r} or exact name {exact_server!r}.")
else:
    for server_id, name in unique_matches:
        status, _ = request("DELETE", delete_url.format(id=urllib.parse.quote(server_id)))
        print(f"Deleted {provider} server {name} ({server_id}), HTTP {status}.")

key_matches = [
    (key_id, name)
    for key_id, name in ssh_keys
    if should_delete_name(name, exact_key)
]
seen_keys = set()
unique_keys = []
for key_id, name in key_matches:
    if key_id in seen_keys:
        continue
    seen_keys.add(key_id)
    unique_keys.append((key_id, name))

if not unique_keys:
    print(f"No cloud SSH keys matched cleanup prefix {prefix!r} or exact name {exact_key!r}.")
else:
    for key_id, name in unique_keys:
        status, _ = request("DELETE", key_delete_url.format(id=urllib.parse.quote(key_id)))
        print(f"Deleted {provider} SSH key {name} ({key_id}), HTTP {status}.")
PY
}

resolve_simulator_id() {
  local simulator_name="$1"
  python3 - "$simulator_name" <<'PY'
import json
import re
import subprocess
import sys

name = sys.argv[1]
payload = json.loads(subprocess.check_output([
    "xcrun",
    "simctl",
    "list",
    "devices",
    "available",
    "--json",
], text=True))

def runtime_version(runtime_id):
    match = re.search(r"iOS-([0-9-]+)$", runtime_id)
    if not match:
        return ()
    return tuple(int(part) for part in match.group(1).split("-") if part.isdigit())

candidates = []
for runtime_id, devices in payload.get("devices", {}).items():
    if ".iOS-" not in runtime_id:
        continue
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", True):
            candidates.append((runtime_version(runtime_id), device.get("udid", "")))

if candidates:
    print(sorted(candidates, reverse=True)[0][1])
PY
}

run_cleanup() {
  local phase="$1"
  echo "$phase cloud E2E resources (prefix='$MOBILECODE_E2E_SERVER_NAME_PREFIX', server='${MOBILECODE_E2E_SERVER_NAME:-}', key='${MOBILECODE_E2E_SSH_KEY_NAME:-}')."
  cleanup_cloud_servers
}

# Always attempt API cleanup, including after failed tests. Retries once on failure.
run_cleanup_best_effort() {
  local phase="$1"
  local attempt=1
  local max_attempts=2
  local status=0
  while [[ $attempt -le $max_attempts ]]; do
    set +e
    run_cleanup "$phase (attempt $attempt/$max_attempts)"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      return 0
    fi
    echo "Cloud E2E cleanup attempt $attempt failed (exit $status)." >&2
    attempt=$((attempt + 1))
    sleep 2
  done
  return "$status"
}

reset_simulator_state() {
  if [[ "${MOBILECODE_E2E_SHUTDOWN_OTHER_SIMULATORS:-1}" != "1" ]]; then
    return
  fi

  echo "Shutting down booted simulators before the E2E run."
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  if [[ "${MOBILECODE_E2E_SHOW_SIMULATOR:-0}" != "1" ]]; then
    osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
  fi
}

show_target_simulator() {
  if [[ "${MOBILECODE_E2E_SHOW_SIMULATOR:-0}" != "1" ]]; then
    return
  fi

  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
    open -a Simulator --args -CurrentDeviceUDID "$SIMULATOR_ID" >/dev/null 2>&1 || true
  else
    open -a Simulator >/dev/null 2>&1 || true
  fi
}

FINISH_RAN=0
# Explicit status from the test command; EXIT trap must not rely on $? after other statements.
TEST_EXIT_STATUS=0
finish() {
  # MUST read $? before any other command (including the FINISH_RAN guard).
  local trap_status=$?
  if [[ "$FINISH_RAN" -eq 1 ]]; then
    return
  fi
  FINISH_RAN=1

  local test_status=$TEST_EXIT_STATUS
  # If the script died before the test runner saved status, fall back to trap $?.
  if [[ $test_status -eq 0 && $trap_status -ne 0 ]]; then
    test_status=$trap_status
  fi

  set +e
  echo "Post-run cleanup starting (test exit status=$test_status). Servers are removed even when tests fail."
  run_cleanup_best_effort "Post-cleaning"
  local cleanup_status=$?
  if [[ -n "${MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH:-}" ]]; then
    rm -f "$MOBILECODE_E2E_SSH_PRIVATE_KEY_PATH" "${MOBILECODE_E2E_SSH_PUBLIC_KEY_PATH:-}"
  fi

  if [[ $cleanup_status -ne 0 ]]; then
    echo "Cloud E2E post-clean finished with errors (exit $cleanup_status). Check provider console for leftover '${MOBILECODE_E2E_SERVER_NAME_PREFIX}' resources." >&2
  fi

  # Prefer reporting the test failure; only fail on cleanup alone if tests passed.
  if [[ $test_status -eq 0 && $cleanup_status -ne 0 ]]; then
    echo "Cloud E2E cleanup failed after tests succeeded." >&2
    exit "$cleanup_status"
  fi

  exit "$test_status"
}

trap finish EXIT
trap 'echo "Interrupted - running cloud cleanup..."; exit 130' INT
trap 'echo "Terminated - running cloud cleanup..."; exit 143' TERM

preflight_cloud_token() {
  echo "Preflight: validating cloud API token for ${MOBILECODE_E2E_PROVIDER}..."
  python3 - <<'PY'
import os
import sys
import urllib.error
import urllib.request

provider = (os.environ.get("MOBILECODE_E2E_PROVIDER") or "").strip().lower()
token = (os.environ.get("MOBILECODE_E2E_CLOUD_TOKEN") or "").strip()
if not token:
    print("MOBILECODE_E2E_CLOUD_TOKEN is empty.", file=sys.stderr)
    sys.exit(2)

if provider == "digitalocean":
    url = "https://api.digitalocean.com/v2/account"
elif provider == "hetzner":
    url = "https://api.hetzner.cloud/v1/servers?per_page=1"
else:
    print(f"Unknown provider {provider!r}; skip token preflight.", file=sys.stderr)
    sys.exit(0)

request = urllib.request.Request(
    url,
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": "MobileCode-E2E-Preflight",
    },
)
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        status = response.getcode()
except urllib.error.HTTPError as error:
    body = error.read().decode("utf-8", errors="replace")[:300]
    print(
        f"Cloud token preflight failed for {provider}: HTTP {error.code}. "
        f"Fix MOBILECODE_E2E_CLOUD_TOKEN before running UI tests. Body: {body}",
        file=sys.stderr,
    )
    sys.exit(3)
except Exception as error:  # noqa: BLE001 - surface any network failure clearly
    print(f"Cloud token preflight failed for {provider}: {error}", file=sys.stderr)
    sys.exit(3)

print(f"Cloud token preflight OK for {provider} (HTTP {status}).")
PY
}

cd "$ROOT_DIR"
preflight_cloud_token
run_cleanup "Pre-cleaning stale"
reset_simulator_state

DESTINATION="${MOBILECODE_E2E_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1}"
SIMULATOR_DEVICE="${MOBILECODE_E2E_SIMULATOR_DEVICE:-iPhone 17 Pro}"
SIMULATOR_ID="${MOBILECODE_E2E_SIMULATOR_ID:-$(resolve_simulator_id "$SIMULATOR_DEVICE")}"
echo "Running cloud UX mutation test for server '$MOBILECODE_E2E_SERVER_NAME'."
if [[ -n "$SIMULATOR_ID" ]]; then
  echo "Using simulator '$SIMULATOR_DEVICE' ($SIMULATOR_ID)."
fi

show_target_simulator

build_xcodebuildmcp_extra_args_json() {
  python3 - <<'PY'
import json

payload = {
    "extraArgs": [
        "-parallel-testing-enabled",
        "NO",
        "-maximum-concurrent-test-simulator-destinations",
        "1",
        "-only-testing:CodeAgentsMobileUITests/OpenCodeCloudMutationE2ETests/testCloudServerCanBeCreatedThroughUIWhenMutationIsAllowed",
    ],
}
print(json.dumps(payload))
PY
}

set +e
if command -v "${XCODEBUILDMCP_BIN}" >/dev/null 2>&1; then
  xcbmcp_require_min_version
  XCODEBUILDMCP_EXTRA_ARGS_JSON="$(build_xcodebuildmcp_extra_args_json)"
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcbmcp_run_jsonl simulator test \
      --project-path "$ROOT_DIR/CodeAgentsMobile.xcodeproj" \
      --scheme CodeAgentsMobile \
      --simulator-id "$SIMULATOR_ID" \
      --json "$XCODEBUILDMCP_EXTRA_ARGS_JSON" >/dev/null
  else
    xcbmcp_run_jsonl simulator test \
      --project-path "$ROOT_DIR/CodeAgentsMobile.xcodeproj" \
      --scheme CodeAgentsMobile \
      --simulator-name "$SIMULATOR_DEVICE" \
      --use-latest-os \
      --json "$XCODEBUILDMCP_EXTRA_ARGS_JSON" >/dev/null
  fi
  TEST_EXIT_STATUS=$?
else
  xcodebuild test \
    -scheme CodeAgentsMobile \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:CodeAgentsMobileUITests/OpenCodeCloudMutationE2ETests/testCloudServerCanBeCreatedThroughUIWhenMutationIsAllowed
  TEST_EXIT_STATUS=$?
fi
set -e
exit "$TEST_EXIT_STATUS"
