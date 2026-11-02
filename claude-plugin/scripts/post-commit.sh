#!/bin/sh
# PostToolUse after "git commit": in bound repositories remind the agent to mirror the work on the board.
. "$(dirname "$0")/lib.sh" 2>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
cwd=$(json_field cwd); [ -n "$cwd" ] || cwd=$(pwd)
find_marker "$cwd" >/dev/null || exit 0
emit_context PostToolUse "Todolino: you just committed. Do it NOW, before the next step: post_progress on the task this commit belongs to (commit hash, what is done, what is next); if no task exists yet, create_task and claim_task first. Update information (this commit, tests) belongs into post_progress, not into a review; request_review only if the user has to look at or decide something concrete (never mark done yourself). Open user decision: ask_question. Keep it short, in bullet points. record_sync before the session ends."
exit 0
