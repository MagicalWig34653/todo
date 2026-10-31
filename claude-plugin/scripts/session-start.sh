#!/bin/sh
# SessionStart: tells the agent whether the working directory is bound to a Todolino project and what the routine is.
# Reads only local files. Fails open (prints nothing) on any problem.
. "$(dirname "$0")/lib.sh" 2>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
cwd=$(json_field cwd); [ -n "$cwd" ] || cwd=$(pwd)
marker=$(find_marker "$cwd") || marker=""
if [ -n "$marker" ]; then
  pid=$(marker_field "$marker" projectID)
  case "$pid" in *[!0-9a-fA-F-]*|"") pid="" ;; esac
  emit_context SessionStart "Todolino: this repository is bound to the Todolino project ${pid:-unknown} (see .todolino.json). Todolino must stay current. Start: run the todolino session_start prompt or call get_sync_status and get_command_center; if the state is stale or never, run sync_project first. Work: claim_task, post_progress after each meaningful step, ask_question instead of guessing, request_review when finished. End: update statuses and call record_sync. A task is not done until Todolino reflects it."
else
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  emit_context SessionStart "Todolino: this repository is not set up in Todolino yet (no .todolino.json). If the user wants it tracked, run the skill /todolino:setup (set this project up in Todolino). Do not set it up unasked."
fi
exit 0
