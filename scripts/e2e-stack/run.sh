#!/bin/sh
# Production-like browser E2E (card DA09D11A): MariaDB + 3 replicas of a published backend image + nginx (TLS, HTTP/2).
# Usage: scripts/e2e-stack/run.sh [image-tag] [playwright args...]   e.g. run.sh sha-2722385 e2e/comment-compare.spec.ts --project=firefox
# Needs Docker (Colima) and a Playwright browser. The database is wiped on every start (the bootstrap account is single use).
# The stack is stopped and removed afterwards. Port 28111 (https), nothing else is published.
set -e
cd "$(dirname "$0")"
TAG="${1:-edge}"; [ $# -gt 0 ] && shift
[ $# -gt 0 ] || set -- e2e/comment-compare.spec.ts --project=firefox
mkdir -p .tls
[ -f .tls/cert.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout .tls/key.pem -out .tls/cert.pem -days 7 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
export CC_TAG="$TAG" CC_ORIGIN=https://localhost:28111
docker compose down -v >/dev/null 2>&1 || true
trap 'docker compose down -v >/dev/null 2>&1' EXIT
docker compose up -d --wait
(cd ../../web && E2E_BASE_URL=$CC_ORIGIN E2E_IGNORE_HTTPS_ERRORS=1 npx playwright test "$@" --reporter=line)
