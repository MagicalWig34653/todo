#!/bin/sh
# End-to-end run for the card pipeline, stages 1 to 3 (cards 74EC341D, B926E7D8, F5DD1C00): native backend, empty scratch SQLite, REST and MCP with real OAuth tokens.
# Plan over MCP, refused agent decisions, changes requested, new plan, approval by the person, step states, audit trail, a decision
# under the brain mandate and removal with the card; a second migrate must change nothing.
# Usage: scripts/pipeline-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App)
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/pipeline-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28973}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"

uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; }
"$native" migrate --yes >/dev/null
before=$(sqlite3 "$scratch/e2e.sqlite" "SELECT count(*) FROM _fluent_migrations;")
"$native" migrate --yes >/dev/null 2>&1
after=$(sqlite3 "$scratch/e2e.sqlite" "SELECT count(*) FROM _fluent_migrations;")
if [ "$before" = "$after" ]; then echo "ok   second migrate is a no-op ($after migrations recorded)"; else echo "FAIL migrate changed the migration log ($before -> $after)"; exit 1; fi
"$native" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
for i in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && break; sleep 1; done
now=$(date +%s); exp=$((now + 86400))
mk() { # name -> prints the session token
  s=$(openssl rand -hex 24); h=$(printf '%s' "$s" | openssl dgst -sha256 -r | cut -d' ' -f1)
  u=$(uuidgen | tr 'A-Z' 'a-z'); i=$(uuidgen | tr 'A-Z' 'a-z')
  sqlite3 "$scratch/e2e.sqlite" "INSERT INTO users (id, display_name, is_admin, created_at) VALUES ($(uuid_sql "$u"),'$1',0,$now);
  INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ($(uuid_sql "$i"),$(uuid_sql "$u"),'$h',$exp,$now);"
  printf '%s' "$s"
}
a=$(mk "Pipeline Person")
python3 scripts/pipeline-e2e.py "http://localhost:$port" "$a" "$scratch/e2e.sqlite"
