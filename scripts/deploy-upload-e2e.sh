#!/bin/sh
# End-to-end run for deploy uploads to test targets (card 354ADE12, ADR 0044): native backend, empty SQLite database, real SFTP
# and FTPS servers in own containers (scripts/test-deploy-servers.sh), REST with a person session and MCP with a real OAuth token.
# Nothing leaves the machine; the containers are removed afterwards.
# Usage: scripts/deploy-upload-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App; E2E_PORT the port)
set -eu
cd "$(dirname "$0")/.."
# First call: start the servers, then run this script again inside that environment.
if [ -z "${TODO_TEST_DEPLOY_DIR:-}" ]; then exec scripts/test-deploy-servers.sh --exec scripts/deploy-upload-e2e.sh "$@"; fi
scratch="${1:-${TMPDIR:-/tmp}/todo-deploy-upload-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28961}"
export RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" DEPLOY_ALLOW_PRIVATE_HOSTS=1
SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32)"; export SETTINGS_ENCRYPTION_KEY
cleanup() {
  [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"
"$native" migrate --yes >/dev/null
"$native" migrate --yes >/dev/null 2>&1 && echo "ok   second migrate succeeds"
"$native" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
ready=
for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && { ready=1; break; }; sleep 1; done
[ -n "$ready" ] || { echo "FAIL backend not ready"; cat "$scratch/backend.log"; exit 1; }
python3 scripts/deploy-upload-e2e.py "http://localhost:$port" "$scratch" "$scratch/backend.log"
