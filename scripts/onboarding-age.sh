#!/bin/sh
# Helper of onboarding-e2e.sh: moves last_synced_at of $PROJECT_ID back by 4 days (simulated time).
set -eu
case "$MODE" in
  sqlite)
    id=$(printf '%s' "$PROJECT_ID" | tr 'a-f' 'A-F')
    sqlite3 "$SCRATCH/e2e.sqlite" "UPDATE project_bindings SET last_synced_at = last_synced_at - 345600 WHERE id = '$id'" ;;
  devdb)
    docker exec -i todo-dev-db-1 mariadb -uroot -pdev-root-only todo_onboard_e2e -e "UPDATE project_bindings SET last_synced_at = DATE_SUB(NOW(), INTERVAL 4 DAY) WHERE id = UNHEX(REPLACE('$PROJECT_ID','-',''))" ;;
  compose)
    docker compose exec -T db mariadb -uroot -pe2e-root-only todo -e "UPDATE project_bindings SET last_synced_at = DATE_SUB(NOW(), INTERVAL 4 DAY) WHERE id = UNHEX(REPLACE('$PROJECT_ID','-',''))" ;;
esac
