#!/bin/sh
# End-to-end run of the project onboarding (ADR 0018) with real HTTP, real OAuth (PKCE) and real MCP calls.
# Usage: scripts/onboarding-e2e.sh [scratch-dir]
# Modes (E2E_MODE):
#   compose (default)  own compose project todo-onboard-e2e (MariaDB + backend image), ports 24921/28921, `down -v` afterwards.
#   sqlite             native backend binary (E2E_NATIVE=<path to App>) on a SQLite file; no Docker (use when Docker's disk is full).
#   devdb              native backend against the running dev MariaDB container todo-dev-db-1 in database todo_onboard_e2e (dropped afterwards).
# Never touches other stacks. The placeholder domain is localhost.
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/onboarding-e2e}"
mode="${E2E_MODE:-compose}"
native="${E2E_NATIVE:-}"
export COMPOSE_PROJECT_NAME=todo-onboard-e2e DB_HOST_PORT=24921 BACKEND_HOST_PORT=28921 S3_HOST_PORT=29921
export DB_NAME=todo DB_PASSWORD=e2e-only DB_ROOT_PASSWORD=e2e-root-only
export RP_ID=localhost RP_ORIGIN="http://localhost:28921" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() {
  [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true
  case "$mode" in
    devdb) docker exec todo-dev-db-1 mariadb -uroot -pdev-root-only -e "DROP DATABASE IF EXISTS todo_onboard_e2e" >/dev/null 2>&1 || true ;;
    compose) docker compose --profile app down -v >/dev/null 2>&1 || true; docker image rm todo-dev-backend:local >/dev/null 2>&1 || true ;;
  esac
  rm -rf "$scratch"
}
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch/repo/docs"
git -C "$scratch/repo" init -q
git -C "$scratch/repo" remote add origin "https://github.com/example/sample-project.git"
printf '# Sample\n\nA sample project for the Todolino onboarding test.\n' > "$scratch/repo/README.md"
cat > "$scratch/repo/docs/ARBEITSPLAN.md" <<'PLAN'
# Arbeitsplan

## Phase 1 Grundlagen
- [x] Projektgeruest anlegen
- [x] CI einrichten
- [ ] Datenmodell entwerfen

## Phase 2 Login
- [ ] Passkey-Registrierung
- [ ] Sitzungsverwaltung
PLAN
git -C "$scratch/repo" add -A && git -C "$scratch/repo" -c user.name=e2e -c user.email=e2e@example.invalid commit -qm "Initial sample"

wait_ready() { for i in $(seq 1 40); do curl -fs http://127.0.0.1:28921/health/ready >/dev/null 2>&1 && return 0; sleep 1; done; echo "backend not ready" >&2; return 1; }
case "$mode" in
  compose)
    docker compose --profile app up -d --build --wait backend
    sqlcmd() { docker compose exec -T db mariadb -uroot -pe2e-root-only todo -e "$1"; }
    uuid_sql() { printf "UNHEX(REPLACE('%s','-',''))" "$1"; } ;;
  devdb)
    docker exec todo-dev-db-1 mariadb -uroot -pdev-root-only -e "CREATE DATABASE todo_onboard_e2e CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    export DATABASE_DRIVER=mariadb DB_HOST=127.0.0.1 DB_PORT=23306 DB_NAME=todo_onboard_e2e DB_USER=root DB_PASSWORD=dev-root-only
    "$native" migrate --yes >/dev/null
    "$native" serve --hostname 127.0.0.1 --port 28921 >"$scratch/backend.log" 2>&1 & backend_pid=$!; wait_ready
    sqlcmd() { docker exec -i todo-dev-db-1 mariadb -uroot -pdev-root-only todo_onboard_e2e -e "$1"; }
    uuid_sql() { printf "UNHEX(REPLACE('%s','-',''))" "$1"; } ;;
  sqlite)
    export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite"
    "$native" migrate --yes >/dev/null
    "$native" serve --hostname 127.0.0.1 --port 28921 >"$scratch/backend.log" 2>&1 & backend_pid=$!; wait_ready
    sqlcmd() { sqlite3 "$scratch/e2e.sqlite" "$1"; }
    uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; } ;;
  *) echo "unknown E2E_MODE $mode" >&2; exit 2 ;;
esac

# Test account + session straight in the database (the passkey ceremony needs a browser; OAuth below is the real flow).
session=$(openssl rand -hex 24)
hash=$(printf '%s' "$session" | shasum -a 256 | cut -d' ' -f1)
uid=$(uuidgen | tr 'A-Z' 'a-z'); sid=$(uuidgen | tr 'A-Z' 'a-z')
if [ "$mode" = sqlite ]; then now=$(date +%s); exp=$((now + 86400)); else now="NOW()"; exp="DATE_ADD(NOW(), INTERVAL 1 DAY)"; fi
sqlcmd "INSERT INTO users (id, display_name, is_admin, created_at) VALUES ($(uuid_sql "$uid"),'E2E User',1,$now);
INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ($(uuid_sql "$sid"),$(uuid_sql "$uid"),'$hash',$exp,$now);"
python3 scripts/onboarding-e2e.py "http://127.0.0.1:28921" "$session" "$scratch/repo" "MODE=$mode SCRATCH=$scratch sh \"$PWD/scripts/onboarding-age.sh\""
