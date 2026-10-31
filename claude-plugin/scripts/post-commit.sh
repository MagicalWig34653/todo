#!/bin/sh
# PostToolUse after "git commit": in bound repositories remind the agent to mirror the work on the board.
. "$(dirname "$0")/lib.sh" 2>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
cwd=$(json_field cwd); [ -n "$cwd" ] || cwd=$(pwd)
find_marker "$cwd" >/dev/null || exit 0
emit_context PostToolUse "Todolino reminder: you just committed. If this finished or advanced a task, call post_progress (or request_review) now, and call record_sync before the session ends."
exit 0
