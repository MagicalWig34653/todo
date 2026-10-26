#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker info >/dev/null
work=$(mktemp -d)
name="todo-restore-smoke-$(date +%s)-$$"
created=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ $created == 1 ]]; then docker rm -f "$name" >/dev/null || result=1; fi
  rm -rf "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
openssl rand -hex 32 > "$work/password"
docker create --name "$name" --tmpfs /var/lib/mysql \
  --mount "type=bind,src=$work/password,dst=/run/secrets/root,readonly" \
  -e MARIADB_ROOT_PASSWORD_FILE=/run/secrets/root -e MARIADB_DATABASE=todo mariadb:12.3 >/dev/null
created=1
docker start "$name" >/dev/null
export DB_CONTAINER=$name DB_NAME=todo
source scripts/db-common.sh
for ((i=0; i<90; i++)); do
  if db_tool mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1; then break; fi
  sleep 2
done
[[ $i -lt 90 ]] || exit 1
db_tool mariadb -uroot todo <<'SQL'
CREATE TABLE projects (id INT PRIMARY KEY, name VARCHAR(100)) ENGINE=InnoDB;
CREATE TABLE tasks (id INT PRIMARY KEY, project_id INT, payload BLOB, FOREIGN KEY (project_id) REFERENCES projects(id)) ENGINE=InnoDB;
CREATE TABLE empty_table (id INT PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO projects VALUES (1, 'Restore probe'), (2, 'Second project');
INSERT INTO tasks VALUES (1, 1, X'00010AFF'), (2, 1, NULL), (3, 2, X'FF');
SQL
scripts/backup-db.sh "$work/backup"
scripts/restore-db.sh "$work/backup" restore_smoke
