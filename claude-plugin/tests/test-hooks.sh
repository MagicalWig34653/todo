#!/bin/sh
# Shell tests for the Todolino hooks. Feeds JSON on stdin like Claude Code does. Uses a private temp dir only.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/todolino-hooktest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1" ;; *) echo "FAIL $1: [$3] lacks [$2]"; fail=1 ;; esac; }

bound="$tmp/bound/sub"; mkdir -p "$bound"
printf '{"schema":1,"server":"https://todo.example/mcp","projectID":"11111111-2222-3333-4444-555555555555","repository":"local/x"}\n' > "$tmp/bound/.todolino.json"
plain="$tmp/plain"; mkdir -p "$plain"; git -C "$plain" init -q
none="$tmp/none"; mkdir -p "$none"

# SessionStart
out=$("$here/scripts/session-start.sh" <<EOF2
{"hook_event_name":"SessionStart","cwd":"$bound","session_id":"s1"}
EOF2
)
has "start bound mentions project id" "11111111-2222-3333-4444-555555555555" "$out"
has "start bound is SessionStart JSON" '"hookEventName":"SessionStart"' "$out"
out=$("$here/scripts/session-start.sh" <<EOF2
{"cwd":"$plain"}
EOF2
)
has "start unbound git repo hints setup" "not set up in Todolino" "$out"
out=$("$here/scripts/session-start.sh" <<EOF2
{"cwd":"$none"}
EOF2
)
check "start outside git and unbound is silent" "" "$out"
out=$(printf 'garbage' | "$here/scripts/session-start.sh"); check "start garbage input exits 0" "0" "$?"

# transcripts
edit="$tmp/edit.jsonl"; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}\n' > "$edit"
synced="$tmp/synced.jsonl"; cp "$edit" "$synced"; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name": "mcp__plugin_todolino_todolino__record_sync","input":{}}]}}\n' >> "$synced"
readonly_t="$tmp/ro.jsonl"; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}\n' > "$readonly_t"
mention="$tmp/mention.jsonl"; cp "$edit" "$mention"; printf '{"type":"user","message":"remember record_sync at the end"}\n' >> "$mention"

stop() { # session cwd transcript [stop_hook_active]
  "$here/scripts/stop.sh" <<EOF2
{"hook_event_name":"Stop","session_id":"$1","cwd":"$2","transcript_path":"$3","stop_hook_active":${4:-false}}
EOF2
}
out=$(stop sA "$none" "$edit"); check "stop unbound is silent" "" "$out"
out=$(stop sB "$bound" "$readonly_t"); check "stop bound without edits is silent" "" "$out"
out=$(stop sC "$bound" "$synced"); check "stop bound and synced is silent" "" "$out"
out=$(stop sD "$bound" "$edit" true); check "stop with stop_hook_active is silent" "" "$out"
out=$(stop sE "$bound" "$tmp/missing.jsonl"); check "stop with unreadable transcript fails open" "" "$out"
out=$(stop sF "$bound" "$edit"); has "stop bound, edits, stale blocks" '"decision":"block"' "$out"
out=$(stop sF "$bound" "$edit"); check "stop blocks at most once per session" "" "$out"
out=$(stop sG "$bound" "$mention"); has "stop: mere mention of record_sync does not count" '"decision":"block"' "$out"
out=$(TODOLINO_HOOKS_OFF=1 stop sH "$bound" "$edit"); check "stop honours TODOLINO_HOOKS_OFF" "" "$out"
out=$(stop "bad/../id" "$bound" "$edit"); check "stop rejects unsafe session id" "" "$out"
printf '%s' "$(stop sI "$bound" "$edit")" | sed 's/.*/&/' | grep -q '^{' && echo "ok   stop output is JSON" || { echo "FAIL stop output is JSON"; fail=1; }

# PostToolUse after commit
out=$("$here/scripts/post-commit.sh" <<EOF2
{"cwd":"$bound","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}
EOF2
)
has "post-commit bound reminds" "record_sync" "$out"
out=$("$here/scripts/post-commit.sh" <<EOF2
{"cwd":"$none"}
EOF2
)
check "post-commit unbound is silent" "" "$out"

# JSON validity of every emitted document
for f in "$here/hooks/hooks.json" "$here/.mcp.json" "$here/.claude-plugin/plugin.json" "$here/../.claude-plugin/marketplace.json"; do
  python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null && echo "ok   valid JSON $(basename "$f")" || { echo "FAIL invalid JSON $f"; fail=1; }
done
exit $fail
