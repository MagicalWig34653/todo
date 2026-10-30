#!/bin/sh
# Runs the backend tests against the dev MariaDB (docker compose up -d db). Creates database todo_test
# (override with TODO_TEST_DB). S3 is NOT needed: attachments use the database store; only the optional S3 test
# runs when S3_ENDPOINT/S3_BUCKET are set (docker compose --profile s3 up -d s3).
set -e
cd "$(dirname "$0")/.."
docker compose up -d --wait db
docker compose exec -T db mariadb -uroot -p"${DB_ROOT_PASSWORD:-dev-root-only}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${TODO_TEST_DB:-todo_test}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
# --scratch-path may be needed when the checkout sits in a File-Provider folder (codesign xattr issue).
TODO_TEST_MARIADB=1 swift test --no-parallel "$@"
