#!/bin/sh
# Bounded Linux reproduction of E2E specs: backend image + official Playwright container (same Playwright version as web/),
# one fresh backend and database per run, fixed number of repetitions, one log file per run.
# Usage: scripts/e2e-linux.sh <image> <spec> <runs> [logdir]     e.g. scripts/e2e-linux.sh ghcr.io/magicalwig34653/todo-backend:sha-b64438b calendar 6
# Optional: PW_ARGS="--trace=retain-on-failure" adds Playwright arguments (the trace ends up in results-<spec>-<n>/).
# Optional: PW_CPUS=1 limits the browser container (the CI runner is slower than a Mac and shows races earlier).
# Needs Docker with the log directory (default ~/.cache/e2e-linux) shared into the VM (about 3.6 GB for the Playwright image). Chromium only. Note: on an Apple Silicon Mac this is Linux/arm64
# with the VM's CPUs, CI is Linux/amd64; timing differs, the Linux-specific rendering and scrollbars are the same.
set -u
IMAGE="${1:?image}"; SPEC="${2:?spec}"; RUNS="${3:?runs}"; LOGDIR="${4:-$HOME/.cache/e2e-linux}"
PW="mcr.microsoft.com/playwright:v$(sed -n 's/.*"@playwright\/test": "\([0-9.]*\)".*/\1/p' "$(dirname "$0")/../web/package.json")-noble"
WORK="$LOGDIR/work"; mkdir -p "$LOGDIR"
if [ ! -d "$WORK/node_modules" ]; then
  mkdir -p "$WORK"
  (cd "$(dirname "$0")/../web" && tar --exclude=node_modules --exclude=test-results --exclude=.svelte-kit --exclude=build -cf - .) | tar -xf - -C "$WORK"
  docker run --rm -v "$WORK:/work" -w /work "$PW" npm ci --no-audit --no-fund >"$LOGDIR/npm-ci.log" 2>&1 || { echo "npm ci failed, see $LOGDIR/npm-ci.log"; exit 2; }
fi
cp "$(dirname "$0")/../web/e2e/"*.ts "$WORK/e2e/" 2>/dev/null; cp "$(dirname "$0")/../web/e2e/support/"* "$WORK/e2e/support/" 2>/dev/null
pass=0; fail=0
for i in $(seq 1 "$RUNS"); do
  NAME="e2e-linux-$$"
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --rm --name "$NAME" -e DATABASE_DRIVER=sqlite -e DB_NAME=/tmp/e2e.sqlite -e RP_ID=localhost -e RP_NAME=Todolino \
    -e RP_ORIGIN=http://localhost:8080 -e OAUTH_ISSUER=http://localhost:8080 -e BOOTSTRAP_TOKEN=dev-bootstrap-only \
    --entrypoint sh "$IMAGE" -c 'todo-app migrate --yes && exec todo-app serve --env production --hostname 0.0.0.0 --port 8080' >/dev/null
  # Playwright shares the backend's network namespace, so "localhost:8080" is the backend for the browser too.
  docker run --rm ${PW_CPUS:+--cpus "$PW_CPUS"} --network "container:$NAME" -v "$WORK:/work" -w /work -e E2E_BASE_URL=http://localhost:8080 "$PW" sh -c '
    n=0; until curl -fsS -o /dev/null http://localhost:8080/health/live; do n=$((n+1)); [ $n -gt 60 ] && exit 3; sleep 1; done
    npx playwright test e2e/'"$SPEC"'.spec.ts --project=chromium --reporter=line --output=test-results/run '"${PW_ARGS:-}" >"$LOGDIR/$SPEC-$i.log" 2>&1
  rc=$?
  mkdir -p "$LOGDIR/results-$SPEC-$i"; [ -d "$WORK/test-results/run" ] && cp -R "$WORK/test-results/run/." "$LOGDIR/results-$SPEC-$i/" 2>/dev/null; rm -rf "$WORK/test-results"
  docker rm -f "$NAME" >/dev/null 2>&1
  if [ $rc -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  echo "$SPEC run $i/$RUNS exit=$rc"
done
echo "$SPEC: $pass passed, $fail failed of $RUNS (logs in $LOGDIR)"
[ $fail -eq 0 ]
