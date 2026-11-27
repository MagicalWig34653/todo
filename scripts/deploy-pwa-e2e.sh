#!/bin/sh
# Browser E2E for deploy targets in the PWA, phase 1b (card 354ADE12): native backend with an empty SQLite database and
# DEPLOY_ALLOW_PRIVATE_HOSTS=1, real SFTP/FTPS servers in containers (scripts/test-deploy-servers.sh), Vite dev server, Playwright
# Chromium with web/e2e/deploy-targets.spec.ts (all tests, including the one against the real SFTP server).
# Usage: scripts/deploy-pwa-e2e.sh [scratch-dir]
#   E2E_NATIVE  App binary (default .build/debug/App)    E2E_PORT  PWA port (default 25183)    BACKEND_PORT (default 28983)
#   E2E_SHOTS   folder for the light/dark screenshots (optional)
set -eu
cd "$(dirname "$0")/.."
# First call: start the servers, then run this script again inside that environment.
if [ -z "${TODO_TEST_DEPLOY_DIR:-}" ]; then exec scripts/test-deploy-servers.sh --exec scripts/deploy-pwa-e2e.sh "$@"; fi
scratch="${1:-${TMPDIR:-/tmp}/deploy-pwa-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-25183}"
backend_port="${BACKEND_PORT:-28983}"
export RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=dev-bootstrap-only DEPLOY_ALLOW_PRIVATE_HOSTS=1
SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32)"; export SETTINGS_ENCRYPTION_KEY
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite"

"$native" migrate --yes >/dev/null
"$native" serve --hostname 127.0.0.1 --port "$backend_port" >>"$scratch/backend.log" 2>&1 & backend_pid=$!
ready=0
for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$backend_port/health/ready" >/dev/null 2>&1 && { ready=1; break; }; sleep 1; done
[ "$ready" = 1 ] || { echo "FAIL backend not ready"; cat "$scratch/backend.log"; exit 1; }

status=0
(cd web && E2E_PORT="$port" BACKEND_URL="http://127.0.0.1:$backend_port" E2E_DEPLOY_SFTP_PORT="$TODO_TEST_DEPLOY_SFTP_PORT" \
  npx playwright test e2e/deploy-targets.spec.ts --project=chromium --reporter=line) || status=$?
# No secret may reach the backend log (the spec types these passwords).
if grep -q -e 'geheim-Pass-771' -e 'alt-Pass-552' -e 'sftp-Geheim-41d9' "$scratch/backend.log"; then echo "FAIL secret in backend log"; status=1; else echo "ok   no secret in backend log"; fi
exit "$status"
