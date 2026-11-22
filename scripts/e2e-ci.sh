#!/bin/sh
# Browser E2E against a published backend image (production bundle, SQLite), one fresh container and database per spec and
# browser: the bootstrap account is single use and the specs share state, so a spec never meets another spec's data.
# Used by .github/workflows/e2e.yml (cards D434B3FD, 330C57F8, A7865053, DA09D11A); runs the same way on a Mac with Docker.
# Usage: scripts/e2e-ci.sh <image> [spec:browser,browser ...]      e.g. scripts/e2e-ci.sh ghcr.io/magicalwig34653/todo-backend:sha-5e609bd
# Without specs the curated list below runs. Needs Docker, curl and `npx playwright install` for the browsers in web/.
set -u
IMAGE="${1:?usage: e2e-ci.sh <image> [spec:browsers ...]}"; shift
PORT="${E2E_PORT:-25173}"
ORIGIN="http://localhost:$PORT"
# Curated: specs verified in all three browsers (Chromium, Firefox, WebKit), each on its own database.
DEFAULT_SPECS="timestamps:chromium,firefox,webkit repo-line-refresh:chromium,firefox,webkit comment-limits:chromium,firefox,webkit comment-compare:chromium,firefox,webkit repo-line-stability:chromium"
# shellcheck disable=SC2086  # the list is meant to split into one entry per word
[ $# -gt 0 ] || set -- $DEFAULT_SPECS
NAME="e2e-ci-$$"
failed=""; ran=0
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

start_backend() {
  cleanup
  docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:8080" \
    -e DATABASE_DRIVER=sqlite -e DB_NAME=/tmp/e2e.sqlite \
    -e RP_ID=localhost -e RP_NAME=Todolino -e RP_ORIGIN="$ORIGIN" -e OAUTH_ISSUER="$ORIGIN" -e BOOTSTRAP_TOKEN=dev-bootstrap-only \
    --entrypoint sh "$IMAGE" -c 'todo-app migrate --yes && exec todo-app serve --env production --hostname 0.0.0.0 --port 8080' >/dev/null || return 1
  i=0
  until curl -fsS -o /dev/null "$ORIGIN/health/live" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt 60 ] && { echo "backend did not start:"; docker logs "$NAME" 2>&1 | tail -20; return 1; }
    sleep 1
  done
}

for entry in "$@"; do
  spec="${entry%%:*}"; browsers="${entry#*:}"
  for browser in $(echo "$browsers" | tr ',' ' '); do
    ran=$((ran + 1))
    echo "=== $spec [$browser] ==="
    if ! start_backend; then failed="$failed $spec:$browser(start)"; continue; fi
    if ! (cd "$(dirname "$0")/../web" && E2E_BASE_URL="$ORIGIN" npx playwright test "e2e/$spec.spec.ts" --project="$browser" --reporter=line); then
      failed="$failed $spec:$browser"
      docker logs "$NAME" 2>&1 | tail -15
    fi
  done
done
echo
if [ -n "$failed" ]; then echo "E2E FAILED ($ran runs):$failed"; exit 1; fi
echo "E2E OK ($ran runs)"
