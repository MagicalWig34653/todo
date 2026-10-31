#!/bin/sh
# Shared helpers for the Todolino hooks. POSIX sh, no network access, no secrets, never fails a session:
# every hook ends with exit 0 unless it deliberately blocks a stop (exit 0 + JSON decision).

# json_field NAME: extracts a top-level string/boolean field from the hook input held in $INPUT (flat scan, good enough
# for the fields we read: cwd, session_id, transcript_path, stop_hook_active).
json_field() {
  printf '%s' "$INPUT" | sed -n 's/.*"'"$1"'" *: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' | head -n 1
}

# find_marker DIR: prints the path of the nearest .todolino.json at or above DIR (stops at the filesystem root).
find_marker() {
  d=$1
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.todolino.json" ]; then printf '%s' "$d/.todolino.json"; return 0; fi
    d=$(dirname "$d")
  done
  return 1
}

# marker_field FILE NAME
marker_field() {
  sed -n 's/.*"'"$2"'" *: *"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# emit_context EVENT TEXT: prints the additionalContext JSON. TEXT must not contain double quotes or backslashes.
emit_context() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$1" "$2"
}
