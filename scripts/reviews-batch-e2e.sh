#!/bin/sh
# End-to-end run for the review bulk decision (card 9791E2C3): native backend, empty scratch SQLite, two accounts, 12 reviews, partial failures.
# Usage: scripts/reviews-batch-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App; E2E_PORT the port)
# Runs `migrate --yes` twice on purpose: the second run must be a no-op (this change has no migration).
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/reviews-batch-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28941}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"

uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; }
"$native" migrate --yes >/dev/null
"$native" migrate --yes 2>&1 | tail -2
"$native" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
for i in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && break; sleep 1; done
now=$(date +%s); exp=$((now + 86400))
mk() { # name -> prints "<session token> <user id>"
  s=$(openssl rand -hex 24); h=$(printf '%s' "$s" | shasum -a 256 | cut -d' ' -f1)
  u=$(uuidgen | tr 'A-Z' 'a-z'); i=$(uuidgen | tr 'A-Z' 'a-z')
  sqlite3 "$scratch/e2e.sqlite" "INSERT INTO users (id, display_name, is_admin, created_at) VALUES ($(uuid_sql "$u"),'$1',0,$now);
  INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ($(uuid_sql "$i"),$(uuid_sql "$u"),'$h',$exp,$now);"
  printf '%s %s' "$s" "$u"
}
set -- $(mk "Reviewer A"); a=$1; a_id=$2
set -- $(mk "Stranger B"); b=$1
set -- $(mk "Reader C"); c=$1; c_id=$2
python3 scripts/reviews-batch-e2e.py "http://localhost:$port" "$a" "$b" "$c" "$c_id" "$scratch/e2e.sqlite"
