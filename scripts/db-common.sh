#!/usr/bin/env bash
# Shared by backup/restore. Explicit container selection avoids touching other projects.
: "${DB_CONTAINER:?Set DB_CONTAINER to the intended MariaDB container ID}"
DB_NAME=${DB_NAME:-todo}
[[ "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] || { echo 'Invalid database name' >&2; exit 2; }
db_tool() {
  docker exec -i "$DB_CONTAINER" sh -eu -c '
    if [ -n "${MARIADB_ROOT_PASSWORD_FILE:-}" ]; then
      MYSQL_PWD=$(cat "$MARIADB_ROOT_PASSWORD_FILE")
    else
      MYSQL_PWD=${MARIADB_ROOT_PASSWORD:?Missing root credentials}
    fi
    export MYSQL_PWD
    exec "$@"
  ' sh "$@"
}
db_counts() {
  local database=$1
  db_tool mariadb -uroot -N -B "$database" -e \
    "SELECT CONCAT('SELECT ', QUOTE(TABLE_NAME), ', COUNT(*) FROM ', CHAR(96), REPLACE(TABLE_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CONCAT(CHAR(96), ';')) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$database' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME" |
    db_tool mariadb -uroot -N -B "$database" | LC_ALL=C sort
}
