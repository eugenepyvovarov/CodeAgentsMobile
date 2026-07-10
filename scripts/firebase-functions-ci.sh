#!/usr/bin/env bash
# Validate the Firebase push gateway (lint, unit tests, production audit).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCS="${ROOT}/server/firebase-functions/functions"

cd "${FUNCS}"

if [[ ! -d node_modules ]]; then
  npm ci
else
  # Prefer lockfile-aligned install when modules already exist.
  npm ci --prefer-offline 2>/dev/null || npm install
fi

npm run lint
npm test
npm run audit:prod

echo "firebase-functions CI OK"
