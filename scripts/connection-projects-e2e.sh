#!/bin/sh
# End-to-end run for project lists changed by a mandated connection (card E71B0FF1): native backend, empty scratch SQLite,
# two accounts, REST for the person and MCP with real OAuth tokens (brain, watcher, a stranger's connection).
# Usage: scripts/connection-projects-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App)
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/connection-projects-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28951}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"

uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; }
"$native" migrate --yes >/dev/null
"$native" migrate --yes 2>&1 | tail -1
sqlite3 "$scratch/e2e.sqlite" "SELECT 'tables: ' || group_concat(name) FROM sqlite_master WHERE name IN ('brain_mandates','brain_connection_audits');"
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
a=$(mk "Person"); b=$(mk "Stranger")
python3 scripts/connection-projects-e2e.py "http://localhost:$port" "$a" "$b"
# The quotes of the person are stored, but the backend log must not contain them.
if grep -q "Lino: gib dem Waechter" "$scratch/backend.log"; then echo "FAIL quote found in backend.log"; exit 1; else echo "ok   no quote in backend.log"; fi
