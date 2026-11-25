#!/bin/sh
# End-to-end run of pipeline stage 3 (card F5DD1C00) through the REAL Mac runner: native backend with an empty scratch SQLite,
# the built `todo-runner` binary (paired, own state folder, TODO_RUNNER_SECRETS=file, never the keychain) and a FAKE claude
# script written by the test (deterministic stream-json, logs its argv; the real claude is never called, no tokens).
# Usage: scripts/pipeline-runner-e2e.sh [scratch-dir]
#   E2E_NATIVE      backend binary (default /private/tmp/claude-501/f5dd-backend/App)
#   TODO_RUNNER_BIN runner binary (default ../../Xcode/todo/TodoRunner/.build/debug/todo-runner)
#   E2E_PORT        backend port (default 28974)
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/pipeline-runner-e2e}"
native="${E2E_NATIVE:-/private/tmp/claude-501/f5dd-backend/App}"
runner_bin="${TODO_RUNNER_BIN:-../../Xcode/todo/TodoRunner/.build/debug/todo-runner}"
port="${E2E_PORT:-28974}"
[ -x "$native" ] || { echo "backend binary missing: $native"; exit 2; }
[ -x "$runner_bin" ] || { echo "runner binary missing: $runner_bin"; exit 2; }
runner_bin="$(cd "$(dirname "$runner_bin")" && pwd)/$(basename "$runner_bin")"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; [ "${E2E_KEEP:-}" = 1 ] || rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"

uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; }
"$native" migrate --yes >/dev/null
"$native" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
for i in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && break; sleep 1; done
now=$(date +%s); exp=$((now + 86400))
s=$(openssl rand -hex 24); h=$(printf '%s' "$s" | openssl dgst -sha256 -r | cut -d' ' -f1)
u=$(uuidgen | tr 'A-Z' 'a-z'); i=$(uuidgen | tr 'A-Z' 'a-z')
sqlite3 "$scratch/e2e.sqlite" "INSERT INTO users (id, display_name, is_admin, created_at) VALUES ($(uuid_sql "$u"),'Runner Person',0,$now);
INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ($(uuid_sql "$i"),$(uuid_sql "$u"),'$h',$exp,$now);"
export E2E_RUNNER_BIN="$runner_bin"
python3 scripts/pipeline-runner-e2e.py "http://127.0.0.1:$port" "$s" "$scratch"
