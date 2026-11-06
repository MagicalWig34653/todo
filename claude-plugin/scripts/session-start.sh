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
  repo=$(marker_field "$marker" repository)
  case "$repo" in *[!A-Za-z0-9._/:@-]*) repo="" ;; esac
  repohint=""
  [ -n "$repo" ] && repohint=" REPOSITORY: this checkout is bound as ${repo} (from .todolino.json); a project can have several repository bindings, so ALWAYS pass repository=${repo} to get_sync_status and record_sync."
  emit_context SessionStart "Todolino: this repository is bound to the Todolino project ${pid:-unknown} (see .todolino.json). TOOL SCHEMAS ARE DEFERRED: direct calls fail with invalid_arguments until loaded. Load the core tools ONCE now with ToolSearch, query: select:mcp__plugin_todolino_todolino__post_progress,mcp__plugin_todolino_todolino__claim_task,mcp__plugin_todolino_todolino__create_task,mcp__plugin_todolino_todolino__ask_question,mcp__plugin_todolino_todolino__request_review,mcp__plugin_todolino_todolino__list_tasks,mcp__plugin_todolino_todolino__get_command_center,mcp__plugin_todolino_todolino__record_sync,mcp__plugin_todolino_todolino__get_sync_status (other tools: ToolSearch with their name). MANDATORY, use the board while you work, not only at the end. CURRENT PROJECT: ${pid:-unknown} is the ONLY project you work on.${repohint} The login covers all projects of the user, so ALWAYS pass projectID=${pid:-unknown} to get_command_center, list_open_questions and list_pending_reviews (the answer names currentProject; entries with foreignProject=true or from other projects are never to be worked on, claimed, mentioned or offered). 1) Now: call get_sync_status (with repository if given above; stale or never: run the skill todolino:sync first), get_command_center {projectID}, list_open_questions {projectID, includeAnswered: true}, list_pending_reviews {projectID}; answered questions, requested changes and tasks already claimed by you come first. 1b) Chat: every task, question and review has a chat. Read new messages from people (list_comments with authorKind person and since, also with questionID or reviewID; or wait_for_events, hint kind comment) at session start and after each finished step, and reply with add_comment (same questionID or reviewID). 2) Before any work: find the matching task (list_tasks or get_command_center) or create it with create_task (no duplicates), then claim_task. 3) After every finished sub-step or commit: post_progress. 4) Decisions the user must make: ask_question on the task (blocking if work depends on it) instead of asking only in chat. 5) Finished: request_review ONLY if the user has to look at or decide something concrete (visible result, risk, rollout); pure update information (commit, tests green, internal change) is no review, put it into post_progress; never mark your own work done. 6) End: record_sync (with repository if given above). Style: keep every board text short and in bullet points; the headline is the task title; review = one sentence plus at most 4 bullets (new, checked, look at, open); question = 1 or 2 lines plus 2 to 4 options, recommendation first; progress = 1 or 2 sentences. Spawned agents get the task id in their prompt and report with post_progress themselves. The Stop hook checks for board activity."
else
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  emit_context SessionStart "Todolino: this repository is not set up in Todolino yet (no .todolino.json). If the user wants it tracked, run the skill /todolino:setup (set this project up in Todolino). Do not set it up unasked."
fi
exit 0
