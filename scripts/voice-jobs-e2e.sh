#!/bin/sh
# End-to-end run for voice jobs and the runner capability "sprache" (ADR 0030 step 3): native backend, empty scratch SQLite,
# two accounts, three simulated Mac runners (real HTTP, real device tokens), real M4A recordings. Time is moved by rewriting
# timestamps in the scratch database, not by waiting.
# Usage: scripts/voice-jobs-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App; E2E_PORT the port)
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/voice-jobs-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28933}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch/files"

if command -v say >/dev/null && command -v afconvert >/dev/null; then
  say -o "$scratch/files/speech.aiff" "Das ist eine kurze Sprachnachricht fuer den Kanal."
  afconvert -f m4af -d aac -c 1 "$scratch/files/speech.aiff" "$scratch/files/speech.m4a"
else
  ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -ac 1 -c:a aac "$scratch/files/speech.m4a"
fi

uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; }
"$native" migrate --yes >/dev/null
"$native" migrate --yes 2>&1 | tail -2
sqlite3 "$scratch/e2e.sqlite" "SELECT 'tables/columns: ' || (SELECT group_concat(name) FROM sqlite_master WHERE name = 'voice_jobs') || ' ' || (SELECT group_concat(name) FROM pragma_table_info('runner_devices') WHERE name IN ('capabilities','disabled_capabilities','last_seen_at'));"
"$native" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
for i in $(seq 1 40); do curl -fs "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1 && break; sleep 1; done
now=$(date +%s); exp=$((now + 86400))
mk() { # name -> prints session token
  s=$(openssl rand -hex 24); h=$(printf '%s' "$s" | shasum -a 256 | cut -d' ' -f1)
  u=$(uuidgen | tr 'A-Z' 'a-z'); i=$(uuidgen | tr 'A-Z' 'a-z')
  sqlite3 "$scratch/e2e.sqlite" "INSERT INTO users (id, display_name, is_admin, created_at) VALUES ($(uuid_sql "$u"),'$1',0,$now);
  INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ($(uuid_sql "$i"),$(uuid_sql "$u"),'$h',$exp,$now);"
  printf '%s' "$s"
}
a=$(mk "Voice A"); b=$(mk "Voice B")
python3 -I scripts/voice-jobs-e2e.py "http://localhost:$port" "$scratch/e2e.sqlite" "$a" "$b" "$scratch/files/speech.m4a"
# No audio, transcript or reply text in the server log.
if grep -q "Wie ist die Lage\|Alles ruhig\|Sprachnachricht fuer" "$scratch/backend.log"; then echo "FAIL message content found in backend.log"; exit 1; else echo "ok   no transcript or reply text in backend.log"; fi
