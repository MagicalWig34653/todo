#!/usr/bin/env bash
# Quiesce writes until dump AND exact counts complete. Output is sensitive; encrypt off-host.
set -euo pipefail
# shellcheck source=scripts/db-common.sh
source "$(dirname "$0")/db-common.sh"
output=${1:?Usage: backup-db.sh NEW_BACKUP_DIRECTORY}
umask 077
mkdir "$output"
trap 'echo "Backup failed; discard incomplete backup directory" >&2' ERR
db_tool mariadb-dump -uroot --single-transaction --quick --hex-blob \
  --routines --events --triggers --skip-add-locks "$DB_NAME" > "$output/database.sql"
db_counts "$DB_NAME" > "$output/counts.tsv"
printf '%s\n' "$DB_NAME" > "$output/source-database"
(cd "$output" && shasum -a 256 database.sql counts.tsv source-database > SHA256SUMS)
echo 'Backup and exact row counts written. Keep writes quiesced until this point.'
