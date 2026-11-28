#!/bin/sh
# End-to-end run for deploy targets (card 354ADE12, ADR 0039, 0041, 0042): native backend, empty database, real SFTP and FTPS
# servers in containers (started by scripts/test-deploy-servers.sh), REST and MCP with a real OAuth token; for the pull request
# (phase 2b) a GitHub API stand-in over a bare git repository (E2E_GITHUB_PORT, default 28950). Nothing leaves the machine.
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
cleanup() {
  [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true
  [ -n "${github_pid:-}" ] && kill "$github_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
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
# 3. Phase 2b (ADR 0042): the same database, the backend now with a GitHub App whose API is a stand-in over a bare git repository.
kill "$backend_pid"; wait "$backend_pid" 2>/dev/null || true
github_port="${E2E_GITHUB_PORT:-28950}"
openssl genrsa -out "$scratch/github-app.pem" 2048 2>/dev/null
openssl rsa -in "$scratch/github-app.pem" -pubout -out "$scratch/github-app.pub" 2>/dev/null
git init -q --bare -b main "$scratch/github.git"
python3 scripts/fake-github-api.py "$github_port" "$scratch/github.git" "$scratch/github-app.pub" "$scratch/github-journal.jsonl" \
  424242 777 acme/kubus >>"$scratch/github.log" 2>&1 & github_pid=$!
project="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project"])' "$scratch/state.json")"
export GITHUB_API_URL="http://127.0.0.1:$github_port" GITHUB_APP_ID=424242 GITHUB_APP_INSTALLATION_ID=777
export GITHUB_APP_PRIVATE_KEY_FILE="$scratch/github-app.pem" GITHUB_APP_REPOSITORIES="$project=acme/kubus"
: >"$scratch/backend.log"
start
python3 scripts/deploy-e2e.py "http://localhost:$port" "$db" github "$scratch"

