---
name: setup
description: Set up the current repository in Todolino ("Richte das Projekt in Todolino ein"): analyse README, plans and git log, create or link the Todolino project, import features, tasks and criteria idempotently, write .todolino.json and a short CLAUDE.md section. Use when the user asks to set this project up in Todolino.
argument-hint: "[project name]"
disable-model-invocation: false
---

# Set up this repository in Todolino

Work step by step, idempotently. Optional project name from the user: $ARGUMENTS

1. Call `get_manual` and read "Project onboarding and keeping Todolino current".
2. Identify the repository: `git remote get-url origin` (drop credentials) or a free key like `local/<directory>`. Check for an existing `.todolino.json`.
3. `find_project_by_repository {repository}`. Exactly one match (or a readable project in `.todolino.json`): do NOT create a project, continue with the skill `todolino:sync`. `outsideGrant > 0`: stop and tell the user to reconnect Todolino via `/mcp` and include that project. Several matches: ask the user.
4. Analyse the repository read-only: README, AGENTS.md / CLAUDE.md, docs/, plan and todo files (ARBEITSPLAN, TODO, ROADMAP, STATUS, CHANGELOG), file-based issue lists, `git log --oneline -50`. Never copy secrets (.env, keys, tokens).
5. Derive a plan: features with subtasks, standalone tasks, acceptance criteria, finished work (done), blocked work with reason, open decisions (as questions). Give every item a stable `externalKey` from its source (for example `docs/ARBEITSPLAN.md#phase-2-login`). Prefer few meaningful features; titles under 100 characters. Ask the user only if name or parent is truly ambiguous.
6. `create_project {name, description, parentID?, repository}`.
7. `import_plan {projectID, applyWorkflowColumns: true, items}` (first with `dryRun: true` above 50 items). A second run must report everything `unchanged`.
8. Empty agent brief (version 0 in `get_project_structure`): `set_agent_brief` from the project's own rules (Goals, Constraints, Definition of done, Agent rules), including "Todolino must be current: post progress while working and call record_sync at the end of every session". Never overwrite a brief a person wrote.
9. Open decisions: `ask_question` with idempotency keys (task ids via `list_plan_keys`). Work in flight: `post_progress`.
10. Write `.todolino.json` in the repository root: `{"schema": 1, "server": "<MCP URL>", "projectID": "<id>", "repository": "<normalised key>"}`. No secrets; may be committed.
11. Add or replace the section between `<!-- todolino:begin -->` and `<!-- todolino:end -->` in CLAUDE.md (or AGENTS.md if that is what the project uses; create CLAUDE.md if neither exists), using the text of `${CLAUDE_PLUGIN_ROOT}/templates/claude-md-section.md`.
12. `record_sync {projectID, summary, repoRef}` with `repoRef` like `main@<short commit>`.
13. Report in a few lines: project name and id, counts created, what was not imported and why.
