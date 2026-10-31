---
name: sync
description: Reconcile the current repository with its Todolino project (plan files, git log versus board) and record the sync. Use at session start when Todolino is stale or never synced, and whenever the user asks to bring Todolino up to date.
---

# Reconcile this repository with Todolino

1. Project: `.todolino.json` (`projectID`), else `find_project_by_repository` with the git remote. Not bound: use the skill `todolino:setup`.
2. `get_sync_status` (last sync, `repoRef`) and `get_project_structure` (brief overrides your defaults).
3. What changed since the last sync: `git log --oneline <lastRepoRef>..HEAD` (or the last 50 commits), changes to plan, todo and docs files.
4. Read the board: `get_command_center {projectID}`, `list_plan_keys {projectID}`, `get_task_context` where unsure.
5. Update with `import_plan` (same `externalKey` scheme; new work gets new keys). It never deletes, reopens or unticks. Mark `status: "done"` only what you verified.
6. Do the rest with tools: `post_progress` for work in flight, `set_task_structure` for blocked reasons, `ask_question` for open decisions, `request_review` for finished work. Read answers (`list_open_questions` with `includeAnswered`) and reviews with requested changes and act on them.
7. The board is authoritative for in_progress, in_review, claims and answers; the repository for what is implemented. Unresolvable conflicts become questions, not overwrites.
8. `record_sync {projectID, summary, repoRef}`; tell the user briefly what changed.
