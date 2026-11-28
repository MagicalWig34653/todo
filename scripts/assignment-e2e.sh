#!/bin/sh
# End-to-end run for responsibility (card 8B4BAC2E, ADR 0043): native backend, empty database, three accounts, a real OAuth
# token for /mcp; an agent assigns over MCP and "for me" over REST and MCP delivers it to that person only. Push recipients
# are covered by AssignmentPushTests (no APNs here).
# Usage: scripts/assignment-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App; E2E_PORT the port)
#
# Database: SQLite in the scratch directory (default). For MariaDB set E2E_DB=mariadb, E2E_MARIADB_CONTAINER (a throwaway
# container with root password DB_ROOT_PASSWORD, default e2e-root-only) and DB_PORT (its published port). The script
# DROPS and recreates the database E2E_MARIADB_NAME (default todo_assignment_e2e) inside that container.
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/assignment-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28953}"
db="${E2E_DB:-sqlite}"
export RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch"

case "$db" in
sqlite)
  export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite"
  ;;
mariadb)
  : "${E2E_MARIADB_CONTAINER:?set E2E_MARIADB_CONTAINER to your throwaway MariaDB container}"
  : "${DB_PORT:?set DB_PORT to the published port of that container}"
  root="${DB_ROOT_PASSWORD:-e2e-root-only}"
  export DATABASE_DRIVER=mariadb DB_HOST=127.0.0.1 DB_PORT DB_NAME="${E2E_MARIADB_NAME:-todo_assignment_e2e}" DB_USER=root DB_PASSWORD="$root"
  docker exec "$E2E_MARIADB_CONTAINER" mariadb -uroot -p"$root" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  ;;
*) echo "E2E_DB must be sqlite or mariadb" >&2; exit 2 ;;
esac

"$native" migrate --yes >/dev/null
"$native" migrate --yes >/dev/null 2>&1 && echo "ok   second migrate succeeds ($db)"
"$native" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
ready=
for i in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && { ready=1; break; }; sleep 1; done
[ -n "$ready" ] || { echo "FAIL backend not ready"; cat "$scratch/backend.log"; exit 1; }
python3 scripts/assignment-e2e.py "http://localhost:$port" "$db"
