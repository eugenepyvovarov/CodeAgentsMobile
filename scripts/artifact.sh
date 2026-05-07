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

XCODEBUILDMCP_BIN="${XCODEBUILDMCP_BIN:-xcodebuildmcp}"
ASC_BIN="${ASC_BIN:-asc}"
PROJECT_PATH="${CODEAGENTS_XCODE_PROJECT:-${ROOT_DIR}/CodeAgentsMobile.xcodeproj}"
PROJECT_FILE="${PROJECT_PATH}/project.pbxproj"
SCHEME="${CODEAGENTS_XCODE_SCHEME:-CodeAgentsMobile}"
SIMULATOR_NAME="${CODEAGENTS_SIMULATOR_NAME:-iPhone 17}"
CONFIGURATION="${CODEAGENTS_CONFIGURATION:-Release}"
APP_BUNDLE_ID="${CODEAGENTS_BUNDLE_ID:-lifeisgoodlabs.CodeAgentsMobile}"
MODE="${OPENCODE_ARTIFACT_MODE:-${1:-review}}"
DIST_DIR="${OPENCODE_ARTIFACT_DIST_DIR:-${ROOT_DIR}/dist}"
DERIVED_DATA_PATH="${CODEAGENTS_DERIVED_DATA_PATH:-${ROOT_DIR}/.build/opencode-artifact/DerivedData}"
VERSION_FILE="${CODEAGENTS_VERSION_FILE:-${ROOT_DIR}/VERSIONS.TXT}"

mkdir -p "${DIST_DIR}" "${DERIVED_DATA_PATH}"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

read_project_setting() {
  local setting="$1"
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    return 0
  fi
  awk -v setting="${setting}" -F ' = ' '
    $1 ~ setting {
      value = $2
      gsub(/[;[:space:]]/, "", value)
      if (value != "") {
        print value
        exit
      }
    }
  ' "${PROJECT_FILE}"
}

read_release_version() {
  if [[ -n "${RELEASE_VERSION:-}" ]]; then
    printf '%s\n' "${RELEASE_VERSION}"
    return 0
  fi

  if [[ -f "${VERSION_FILE}" ]]; then
    awk -F '=' '
      /^[[:space:]]*(#|$)/ { next }
      {
        sub(/[[:space:]]*#.*/, "", $0)
        if (index($0, "=") > 0) {
          key = $1
          value = substr($0, index($0, "=") + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          if ((key == "RELEASE_VERSION" || key == "VERSION") && value != "") {
            print value
            exit
          }
        } else {
          value = $0
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          if (value != "") {
            print value
            exit
          }
        }
      }
    ' "${VERSION_FILE}"
    return 0
  fi

  read_project_setting "MARKETING_VERSION"
}

read_release_build() {
  if [[ -n "${RELEASE_BUILD:-}" ]]; then
    printf '%s\n' "${RELEASE_BUILD}"
    return 0
  fi
  if [[ -n "${OPENCODE_PRODUCTION_ARTIFACT_RUN_NUMBER:-}" ]]; then
    printf '%s\n' "${OPENCODE_PRODUCTION_ARTIFACT_RUN_NUMBER}"
    return 0
  fi
  if [[ -n "${GITEA_RUN_NUMBER:-}" ]]; then
    printf '%s\n' "${GITEA_RUN_NUMBER}"
    return 0
  fi
  read_project_setting "CURRENT_PROJECT_VERSION"
}

RELEASE_VERSION_RESOLVED="$(read_release_version)"
if [[ -z "${RELEASE_VERSION_RESOLVED}" ]]; then
  RELEASE_VERSION_RESOLVED="1.0"
fi

RELEASE_BUILD_RESOLVED="$(read_release_build)"
if [[ -z "${RELEASE_BUILD_RESOLVED}" ]]; then
  RELEASE_BUILD_RESOLVED="1"
fi

RELEASE_TAG="${CODEAGENTS_RELEASE_TAG:-v${RELEASE_VERSION_RESOLVED}-${RELEASE_BUILD_RESOLVED}}"

if [[ "${MODE}" == "production" || "${MODE}" == "testflight" ]]; then
  if ! command -v "${ASC_BIN}" >/dev/null 2>&1; then
    echo "asc is required for TestFlight production artifacts." >&2
    exit 1
  fi

  : "${ASC_APP_ID:?ASC_APP_ID is required for TestFlight publishing}"
  : "${TESTFLIGHT_GROUP:?TESTFLIGHT_GROUP is required for TestFlight publishing}"
  : "${ASC_KEY_ID:?ASC_KEY_ID is required for asc auth}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required for asc auth}"

  PRIVATE_KEY_FILE="${ASC_PRIVATE_KEY_FILE:-}"
  if [[ -z "${PRIVATE_KEY_FILE}" ]]; then
    : "${ASC_PRIVATE_KEY_P8:?ASC_PRIVATE_KEY_P8 or ASC_PRIVATE_KEY_FILE is required for asc auth}"
    PRIVATE_KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/codeagents-asc-key.XXXXXX.p8")"
    printf '%s\n' "${ASC_PRIVATE_KEY_P8}" > "${PRIVATE_KEY_FILE}"
    trap 'rm -f "${PRIVATE_KEY_FILE}"' EXIT
  fi

  VERSION_ARG=(--version "${RELEASE_VERSION_RESOLVED}")
  BUILD_ARG=(--build-number "${RELEASE_BUILD_RESOLVED}")

  EXPORT_OPTIONS="${CODEAGENTS_EXPORT_OPTIONS_PLIST:-${DIST_DIR}/ExportOptions-AppStore.plist}"
  if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
    cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>VXRLZNZH2E</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST
  fi

  "${ASC_BIN}" auth login \
    --local \
    --bypass-keychain \
    --name "CodeAgents CI" \
    --key-id "${ASC_KEY_ID}" \
    --issuer-id "${ASC_ISSUER_ID}" \
    --private-key "${PRIVATE_KEY_FILE}" >/dev/null

  ASC_OUTPUT="$(
    "${ASC_BIN}" publish testflight \
      --app "${ASC_APP_ID}" \
      --project "${PROJECT_PATH}" \
      --scheme "${SCHEME}" \
      --configuration "${CONFIGURATION}" \
      --archive-path "${DIST_DIR}/CodeAgentsMobile-${RELEASE_VERSION_RESOLVED}-${RELEASE_BUILD_RESOLVED}.xcarchive" \
      --ipa-path "${DIST_DIR}/CodeAgentsMobile-${RELEASE_VERSION_RESOLVED}-${RELEASE_BUILD_RESOLVED}.ipa" \
      --export-options "${EXPORT_OPTIONS}" \
      --group "${TESTFLIGHT_GROUP}" \
      --wait \
      --poll-interval "${ASC_POLL_INTERVAL:-30s}" \
      --timeout "${ASC_TIMEOUT:-45m}" \
      --archive-xcodebuild-flag=-allowProvisioningUpdates \
      --export-xcodebuild-flag=-allowProvisioningUpdates \
      "${VERSION_ARG[@]}" \
      "${BUILD_ARG[@]}" \
      --output json
  )"

  IPA_PATH="${DIST_DIR}/CodeAgentsMobile-${RELEASE_VERSION_RESOLVED}-${RELEASE_BUILD_RESOLVED}.ipa"
  IPA_SHA_PATH="${IPA_PATH}.sha256"
  if [[ ! -f "${IPA_PATH}" ]]; then
    echo "Expected TestFlight IPA was not produced at ${IPA_PATH}" >&2
    exit 1
  fi
  IPA_SHA256="$(shasum -a 256 "${IPA_PATH}" | awk '{print $1}')"
  printf "%s  %s\n" "${IPA_SHA256}" "$(basename "${IPA_PATH}")" > "${IPA_SHA_PATH}"
  IPA_DIGEST="sha256:${IPA_SHA256}"

  export ASC_OUTPUT
  export IPA_PATH IPA_SHA_PATH IPA_DIGEST
  export RELEASE_VERSION_RESOLVED RELEASE_BUILD_RESOLVED RELEASE_TAG
  python3 -c '
import json
import os
import sys

data = json.loads(os.environ["ASC_OUTPUT"])
reference = data.get("buildId") or data.get("id") or data.get("buildNumber") or "uploaded"
artifacts = [{
    "name": "TestFlight build",
    "type": "testflight-build",
    "reference": str(reference),
    "version": os.environ["RELEASE_VERSION_RESOLVED"],
    "build_number": os.environ["RELEASE_BUILD_RESOLVED"],
}]
ipa_path = os.environ["IPA_PATH"]
ipa_digest = os.environ.get("IPA_DIGEST") or ""
if os.path.exists(ipa_path):
    artifact = {
        "name": "CodeAgentsMobile IPA",
        "type": "ipa",
        "reference": ipa_path,
        "path": ipa_path,
        "sha256_path": os.environ["IPA_SHA_PATH"],
        "version": os.environ["RELEASE_VERSION_RESOLVED"],
        "build_number": os.environ["RELEASE_BUILD_RESOLVED"],
    }
    if ipa_digest:
        artifact["digest"] = ipa_digest
    artifacts.append(artifact)
print(json.dumps({
    "published_artifacts": artifacts,
    "summary": "Uploaded CodeAgentsMobile to TestFlight.",
    "release_tag": os.environ["RELEASE_TAG"],
    "version": os.environ["RELEASE_VERSION_RESOLVED"],
    "build_number": os.environ["RELEASE_BUILD_RESOLVED"],
}, indent=2))
'
  exit 0
fi

if ! command -v "${XCODEBUILDMCP_BIN}" >/dev/null 2>&1; then
  echo "xcodebuildmcp is required for review artifacts." >&2
  exit 1
fi

"${XCODEBUILDMCP_BIN}" simulator build \
  --project-path "${PROJECT_PATH}" \
  --scheme "${SCHEME}" \
  --simulator-name "${SIMULATOR_NAME}" \
  --configuration Debug \
  --derived-data-path "${DERIVED_DATA_PATH}" \
  --output json >/dev/null

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug-iphonesimulator/${SCHEME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Expected simulator app was not produced at ${APP_PATH}" >&2
  exit 1
fi
ZIP_PATH="${DIST_DIR}/CodeAgentsMobile-simulator-${RELEASE_VERSION_RESOLVED}-${RELEASE_BUILD_RESOLVED}.app.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
SHA_PATH="${ZIP_PATH}.sha256"
SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
printf "%s  %s\n" "${SHA256}" "$(basename "${ZIP_PATH}")" > "${SHA_PATH}"

cat <<JSON
{
  "published_artifacts": [
    {
      "name": "CodeAgentsMobile simulator app",
      "type": "zip",
      "reference": $(printf '%s' "${ZIP_PATH}" | json_escape),
      "path": $(printf '%s' "${ZIP_PATH}" | json_escape),
      "sha256_path": $(printf '%s' "${SHA_PATH}" | json_escape),
      "digest": "sha256:${SHA256}",
      "version": $(printf '%s' "${RELEASE_VERSION_RESOLVED}" | json_escape),
      "build_number": $(printf '%s' "${RELEASE_BUILD_RESOLVED}" | json_escape),
      "bundle_id": $(printf '%s' "${APP_BUNDLE_ID}" | json_escape)
    }
  ],
  "summary": "Built CodeAgentsMobile simulator app artifact.",
  "release_tag": $(printf '%s' "${RELEASE_TAG}" | json_escape),
  "version": $(printf '%s' "${RELEASE_VERSION_RESOLVED}" | json_escape),
  "build_number": $(printf '%s' "${RELEASE_BUILD_RESOLVED}" | json_escape)
}
JSON
