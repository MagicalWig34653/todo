#!/bin/sh
# End-to-end run for deploy targets, phase 1a (card 354ADE12, ADR 0039): native backend, empty database, real SFTP and FTPS
# servers in containers (started by scripts/test-deploy-servers.sh), REST and MCP with a real OAuth token.
# Usage: scripts/deploy-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App; E2E_PORT the port)
#
# Database: SQLite in the scratch directory (default). For MariaDB set E2E_DB=mariadb, E2E_MARIADB_CONTAINER (a throwaway
# container), DB_ROOT_PASSWORD and DB_PORT (its published port). The script DROPS and recreates E2E_MARIADB_NAME
# (default todo_deploy_e2e) inside that container.
set -eu
cd "$(dirname "$0")/.."
# First call: start the servers, then run this script again inside that environment.
if [ -z "${TODO_TEST_DEPLOY_DIR:-}" ]; then exec scripts/test-deploy-servers.sh --exec scripts/deploy-e2e.sh "$@"; fi
scratch="${1:-/private/tmp/claude-501/deploy-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28949}"
db="${E2E_DB:-sqlite}"
export RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32)"; export SETTINGS_ENCRYPTION_KEY
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
  export DATABASE_DRIVER=mariadb DB_HOST=127.0.0.1 DB_PORT DB_NAME="${E2E_MARIADB_NAME:-todo_deploy_e2e}" DB_USER=root DB_PASSWORD="$root"
  docker exec "$E2E_MARIADB_CONTAINER" mariadb -uroot -p"$root" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  ;;
*) echo "E2E_DB must be sqlite or mariadb" >&2; exit 2 ;;
esac

start() {
  "$native" serve --hostname 127.0.0.1 --port "$port" >>"$scratch/backend.log" 2>&1 & backend_pid=$!
  for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "FAIL backend not ready"; cat "$scratch/backend.log"; exit 1
}

"$native" migrate --yes >/dev/null
"$native" migrate --yes >/dev/null 2>&1 && echo "ok   second migrate succeeds ($db)"
# 1. Default server: private targets are refused. 2. With DEPLOY_ALLOW_PRIVATE_HOSTS=1 the containers are reachable.
start
python3 scripts/deploy-e2e.py "http://localhost:$port" "$db" blocked "$scratch"
kill "$backend_pid"; wait "$backend_pid" 2>/dev/null || true
export DEPLOY_ALLOW_PRIVATE_HOSTS=1
start
python3 scripts/deploy-e2e.py "http://localhost:$port" "$db" full "$scratch"
