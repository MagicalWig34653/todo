#!/bin/sh
# Runs the backend tests against the dev MariaDB (docker compose up -d db). Creates database todo_test.
set -e
cd "$(dirname "$0")/.."
docker compose up -d --wait db
docker compose exec -T db mariadb -uroot -p"${DB_ROOT_PASSWORD:-dev-root-only}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${TODO_TEST_DB:-todo_test}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
# --scratch-path may be needed when the checkout sits in a File-Provider folder (codesign xattr issue).
TODO_TEST_MARIADB=1 swift test --no-parallel "$@"
