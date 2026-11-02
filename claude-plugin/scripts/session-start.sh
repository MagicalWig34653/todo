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
  emit_context SessionStart "Todolino: this repository is bound to the Todolino project ${pid:-unknown} (see .todolino.json). MANDATORY, use the board while you work, not only at the end. 1) Now: call get_sync_status (stale or never: run the skill todolino:sync first), get_command_center, list_open_questions with includeAnswered, list_pending_reviews; answered questions, requested changes and tasks already claimed by you come first. 2) Before any work: find the matching task (list_tasks or get_command_center) or create it with create_task (no duplicates), then claim_task. 3) After every finished sub-step or commit: post_progress. 4) Decisions the user must make: ask_question on the task (blocking if work depends on it) instead of asking only in chat. 5) Finished: request_review ONLY if the user has to look at or decide something concrete (visible result, risk, rollout); pure update information (commit, tests green, internal change) is no review, put it into post_progress; never mark your own work done. 6) End: record_sync. Style: keep every board text short and in bullet points; the headline is the task title; review = one sentence plus at most 4 bullets (new, checked, look at, open); question = 1 or 2 lines plus 2 to 4 options, recommendation first; progress = 1 or 2 sentences. Spawned agents get the task id in their prompt and report with post_progress themselves. The Stop hook checks for board activity."
else
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  emit_context SessionStart "Todolino: this repository is not set up in Todolino yet (no .todolino.json). If the user wants it tracked, run the skill /todolino:setup (set this project up in Todolino). Do not set it up unasked."
fi
exit 0
