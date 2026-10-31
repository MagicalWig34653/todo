---
name: todolino
description: Use when working in a repository that has a .todolino.json file, when the user mentions Todolino, tasks on the board, progress, questions or reviews for agents, or at the start and end of a work session in such a repository. Explains how to use the Todolino MCP tools and keep the board current.
---

# Todolino

Todolino is the user's task and project board. The MCP server `todolino` (tools such as `get_manual`, `get_command_center`, `post_progress`, `record_sync`) is provided by this plugin. Its tools appear as `mcp__plugin_todolino_todolino__<tool>`.

1. Call `get_manual` once per session and follow it; it is the authoritative description of the tools and the workflow. The section "Project onboarding and keeping Todolino current" defines the routine below.
2. Find the project: read `.todolino.json` in the repository root (`projectID`), otherwise `find_project_by_repository` with the git remote. Never create a second project for a repository that already has one.
3. Routine for every session in a bound repository:
   - Start: `get_sync_status`, `get_project_structure` (the agent brief overrides your defaults), `get_command_center`, `list_open_questions` with `includeAnswered`, `list_pending_reviews`. If the sync state is `stale` or `never`, reconcile first (skill `todolino:sync`).
   - Work: `claim_task`, `post_progress` after each meaningful step, `ask_question` instead of guessing, `request_review` for finished work. Never mark your own work done.
   - End: bring statuses up to date and call `record_sync {projectID, summary, repoRef}`.
4. Not yet set up? Offer the skill `todolino:setup`; do not set a repository up without the user asking.
5. If the Todolino tools are missing or return an authorisation error, tell the user to run `/mcp` and authenticate "todolino"; do not work around it.
