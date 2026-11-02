---
name: todolino
description: Use when working in a repository that has a .todolino.json file, when the user mentions Todolino, tasks on the board, progress, questions or reviews for agents, or at the start and end of a work session in such a repository. Explains how to use the Todolino MCP tools and keep the board current.
---

# Todolino

Todolino is the user's task and project board. The MCP server `todolino` (tools such as `get_manual`, `get_command_center`, `post_progress`, `record_sync`) is provided by this plugin. Its tools appear as `mcp__plugin_todolino_todolino__<tool>`.

1. Call `get_manual` once per session and follow it; it is the authoritative description of the tools and the workflow. The section "Project onboarding and keeping Todolino current" defines the routine below.
2. Find the project: read `.todolino.json` in the repository root (`projectID`), otherwise `find_project_by_repository` with the git remote. Never create a second project for a repository that already has one.
3. Mandatory rules for every session in a bound repository. Use the board while you work; calling only `record_sync` at the end is a violation.
   - Start: `get_sync_status`, `get_project_structure` (the agent brief overrides your defaults), `get_command_center`, `list_open_questions` with `includeAnswered`, `list_pending_reviews`. Handle answered questions, requested changes and tasks you already claimed first. If the sync state is `stale` or `never`, reconcile first (skill `todolino:sync`).
   - Before any work: look for the matching task (`list_tasks`, command center, `list_plan_keys`); none: `create_task` (no duplicates). Then `claim_task`.
   - After every finished sub-step and every commit: `post_progress` (what is done, what is next). The Stop hook reminds if a session changed files without any board call.
   - Decisions the user must make: `ask_question` on the task (`blocking: true` if work depends on it) instead of asking only in chat. Read the answer later with `list_open_questions`.
   - Finished and the user has something to look at or decide (a visible result to try, a risk, a rollout or merge decision): `request_review`, and say in one bullet what to look at. Finished but nothing for the user to check (internal change, tests green, commit done): NO review, only `post_progress` (percent 100, commit hash and numbers there). Never mark your own work done; open the question "can this be closed?" with `ask_question` only if it is unclear.
   - Chat: tasks, questions and reviews each have a chat. At session start and after each step read new messages from people (`list_comments` with `authorKind: "person"` and `since`, plus `questionID`/`reviewID` for those cards, or `wait_for_events` hint `comment`) and answer with `add_comment`.
   - Writing style for everything people read on the board (reviews, questions, progress, comments, task descriptions): short and in bullet points. The headline is the task title, not the text. `request_review`: one sentence of result, then at most 4 bullets (new, checked with numbers, what to look at, open). `ask_question`: the situation in one or two lines, 2 to 4 concrete options, your recommendation first. `post_progress`: one or two sentences. Lists of findings go into the task description or subtasks, not into progress notes. No file lists, hashes or repeated titles.
   - Spawned agents: the main session creates and names the task, puts its ID in the agent prompt, the agent reports with `post_progress` itself, the main session requests the review.
   - After a blocking `ask_question`: at most a few rounds of `wait_for_events` (pass the returned token as `since`), then `get_question`; if still open, end normally.
   - End: bring statuses up to date and call `record_sync {projectID, summary, repoRef}`.
4. Not yet set up? Offer the skill `todolino:setup`; do not set a repository up without the user asking.
5. If the Todolino tools are missing or return an authorisation error, tell the user to run `/mcp` and authenticate "todolino"; do not work around it.
