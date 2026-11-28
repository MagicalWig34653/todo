#!/bin/sh
# End-to-end run for card 395200D3: native backend, empty SQLite database, SIGTERM while long polls are open.
# Usage: scripts/shutdown-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App; E2E_PORT the port)
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-${TMPDIR:-/tmp}/todo-shutdown-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28957}"
trap 'rm -rf "$scratch"' EXIT
rm -rf "$scratch"; mkdir -p "$scratch"
python3 scripts/shutdown-e2e.py "$native" "$scratch" "$port"
