#!/usr/bin/env bash
# Deliberately restores only into a NEW disposable database, never over an existing database.
set -euo pipefail
# shellcheck source=scripts/db-common.sh
source "$(dirname "$0")/db-common.sh"
backup=${1:?Usage: restore-db.sh BACKUP_DIRECTORY NEW_restore_DATABASE}
target=${2:?Missing target database}
[[ "$target" =~ ^restore_[a-zA-Z0-9_]+$ ]] || { echo 'Target must start with restore_' >&2; exit 2; }
(cd "$backup" && shasum -a 256 -c SHA256SUMS)
db_tool mariadb -uroot -e "CREATE DATABASE \`$target\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
db_tool mariadb -uroot "$target" < "$backup/database.sql"
actual=$(mktemp)
trap 'rm -f "$actual"' EXIT
db_counts "$target" > "$actual"
diff -u "$backup/counts.tsv" "$actual"
echo "Restore verified: exact row counts match in $target. Database retained for inspection."
