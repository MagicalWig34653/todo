#!/bin/sh
# End-to-end run for operator commands that need --yes (card 300B3A20): the real App binary parses the command line, so
# ConsoleKit's global --yes handling is covered (a unit call of run(using:signature:) cannot see it).
# Cases: `settings rotate-key` and `push-test` abort without --yes (confirmation_required) and get past the confirmation with --yes
# (rotate-key reports "re-encrypted 0 secret(s)", push-test stops at push_disabled because APNs is off in this run).
# Usage: scripts/operator-commands-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App)
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/operator-commands-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN=http://localhost:1 BOOTSTRAP_TOKEN=e2e-bootstrap-only
export SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')"
trap 'rm -rf "$scratch"' EXIT
rm -rf "$scratch"; mkdir -p "$scratch"
fail=0
check() { if [ "$2" = ok ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
has() { printf '%s' "$1" | grep -q "$2" && echo ok || echo no; }

"$native" migrate --yes >/dev/null 2>&1
id=$(uuidgen | tr 'A-Z' 'a-z')

out=$("$native" settings rotate-key 2>&1 || true);               check "rotate-key without --yes asks for confirmation" "$(has "$out" confirmation_required)"
out=$("$native" settings rotate-key --yes 2>&1 || true);               check "rotate-key --yes runs" "$(has "$out" 're-encrypted 0 secret')"
out=$("$native" push-test "$id" 2>&1 || true);                  check "push-test without --yes asks for confirmation" "$(has "$out" confirmation_required)"
out=$("$native" push-test "$id" --yes 2>&1 || true);            check "push-test --yes gets past the confirmation" "$(has "$out" push_disabled)"
exit $fail
