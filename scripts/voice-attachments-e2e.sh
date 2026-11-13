#!/bin/sh
# End-to-end run for voice attachments (ADR 0030 step 1): native backend, empty scratch SQLite, real M4A/WAV files.
# Usage: scripts/voice-attachments-e2e.sh [scratch-dir]   (E2E_NATIVE overrides the App binary, default .build/debug/App)
# Needs afconvert (macOS) or ffmpeg; the boundary files are built by scripts/voice-fixtures.py around real audio.
set -eu
cd "$(dirname "$0")/.."
scratch="${1:-/private/tmp/claude-501/voice-e2e}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-28931}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=e2e-bootstrap-only
cleanup() { [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
rm -rf "$scratch"; mkdir -p "$scratch/files"

say="Das ist eine kurze Sprachnachricht fuer den Test."
if command -v say >/dev/null && command -v afconvert >/dev/null; then
  say -o "$scratch/files/speech.aiff" "$say"
  afconvert -f m4af -d aac -c 1 "$scratch/files/speech.aiff" "$scratch/files/speech.m4a"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$scratch/files/speech.aiff" "$scratch/files/speech.wav"
else
  ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -ac 1 -c:a aac "$scratch/files/speech.m4a"
  ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -ac 1 -ar 16000 "$scratch/files/speech.wav"
fi
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a libmp3lame "$scratch/files/tone.mp3"
python3 scripts/voice-fixtures.py "$scratch/files"

uuid_sql() { printf "'%s'" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; }
"$native" migrate --yes >/dev/null
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
python3 scripts/voice-attachments-e2e.py "http://127.0.0.1:$port" "$a" "$b" "$scratch/files"
