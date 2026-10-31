<!-- manual-version: 1.1.0 -->
# Todolino agent manual

This manual is written for coding agents (Claude Code and others) that work for a person through the Todolino MCP server. It is served by the MCP tool `get_manual`, the MCP resource `todo://manual` and `GET /v1/manual`. Fetch it once at the start of a session and re-read the section you need when unsure. The manual is versioned (see the first line); `get_manual` returns the version and a structured `conventions` object.

## Start here

1. Call `get_manual` (you are reading its result).
2. Find the project you work for: `find_project_by_repository {repository}` with the git remote of your working directory (or a `.todolino.json` in the repository root, or `list_projects`). If the repository has no project yet, see "Project onboarding and keeping Todolino current". Then call `get_project_structure {projectID}`. It returns the project's **agent brief**: the goals, constraints and definition of done that the user wrote for agents of this project. The brief overrides your defaults. It also returns the board columns and whether the standard workflow columns exist.
3. Call `get_command_center {projectID}` to see what is running, what waits for an answer or a review, and what is ready to start.
4. Work through the workflow below. All communication with the user goes through the board: progress notes, questions, review requests and screenshots. Do not ask the user in free chat when the board can carry the question.

The user decides; you propose and execute. If a decision is needed that the brief does not answer, ask a question (blocking) instead of guessing.

## Concepts

- **Project**: a node in a freely nested tree. Every project has its own board columns, a description and an agent brief. You can only see projects the user granted to your connection.
- **Task**: one card on the board. Status: `open`, `in_progress`, `in_review`, `done`. Optimistic concurrency: every task has a `version`; writes that pass a stale version fail with `version_conflict`.
- **Feature**: a task with `kind=feature` or with at least one subtask. A subtask is a task whose parent is a feature of the same project (depth at most 2). Features show their percent progress on the overview.
- **Board column**: a named column of one project. Columns are recognised by name; the standard workflow uses Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt.
- **Comment**: free discussion on a task. Not tracked as a decision.
- **Question**: a structured question on a task (prompt, optional answer options, blocking flag). It stays open until a person answers. Open questions of the whole project appear on the overview.
- **Progress note**: a short status text with an optional percent that you post while working.
- **Checkpoint**: the resume point of a local runner job (`nextStep`). Local runners store them automatically; MCP agents use progress notes.
- **Review request**: you ask a person to check finished work. The task moves to `in_review` until the person accepts or requests changes.
- **Build artifact**: a screenshot (PNG, JPEG, WebP) or PDF attached to a task together with a build id, label and platform.
- **Agent job**: a run started by the user's local Mac runner. Questions and reviews of runner jobs appear in the same lists as yours.
- **Command center** (German UI: Steuerzentrale / Überblick): the aggregated kanban view of lanes `running`, `question`, `review`, `ready`, `blocked`, `done`.

## Recommended workflow

1. **Read the board**: `get_command_center {projectID}` and, for one task, `get_task_context {taskID}` (task, subtasks, criteria, comments, questions, review, builds, progress).
2. **Claim**: `claim_task {taskID, agentName}`. This sets the task to `in_progress`, records who works on it and moves the card to "In Arbeit". A second agent gets `already_claimed` unless it passes `takeOver: true`; never take over a task that another agent is actively working on without a reason.
3. **Plan**: for a larger piece of work create the feature with `create_task`, mark it `set_task_structure {taskID, kind: "feature"}` and create subtasks with `create_task` plus `set_task_structure {taskID, parentTaskID}`. Optionally add acceptance criteria with `add_criterion`. Progress is then computed for you.
4. **Work and report**: `post_progress {taskID, note, percent?}` after each meaningful step (not for every command). Tick criteria with `set_criterion {criterionID, completed}`. Mark blocked work with `set_task_structure {taskID, blockedReason}`; clear it with `blockedReason: null`.
5. **Ask when you need a decision**: `ask_question {taskID, prompt, options?, blocking: true}`. The card moves to "Frage offen". Continue with other tasks while it is open. Poll `get_question {questionID}` (or `list_open_questions {taskID, includeAnswered: true}`) until `state` is `answered`, then read `answer`. Never answer your own question.
6. **Show the result**: attach screenshots of the finished build with `add_attachment` (or `begin_attachment` + `complete_attachment` for large files). Always pass the same `buildID` for screenshots of one build and a `platform` (for example `ios`, `macos`, `web`).
7. **Request review**: `request_review {taskID, summary}`. The task moves to `in_review` and "Review". Do not set `done` yourself.
8. **Handle the review**: poll `get_task_context {taskID}`; `review.state` is `accepted` (the task is done), or `changes_requested` with `decisionNote`. On changes, the task is back in `in_progress`: read the note, continue at step 4.
9. **Release** a task you cannot finish with `release_task {taskID}` and say why in a progress note.

Do not create duplicate tasks for the same work; search the existing tasks first (`list_tasks`).

## Board columns

The standard "agent workflow" template has these columns in this order. Names are matched case-insensitively; the aliases are accepted as well.

| Column | Role | Aliases | Meaning |
| --- | --- | --- | --- |
| Backlog | backlog | backlog | Not scheduled. Hidden from the overview lanes (counted only). |
| Bereit | ready | ready, to do, todo, offen, open | Ready to be claimed. |
| In Arbeit | working | in progress, doing, läuft, wip | An agent or person is working on it. |
| Frage offen | question | questions, open question, rückfrage | Waiting for an answer to a question. |
| Review | review | in review, in prüfung, prüfung | Waiting for a person to review. |
| Erledigt | done | (any column marked done) | Finished. |

Create the columns with `apply_agent_workflow_columns {projectID}` when `get_project_structure` reports `template.complete = false` and the project has no own columns yet (the call fails with `columns_exist` otherwise; ask the user before adding columns to an existing board). The workflow tools move the card automatically when the matching column exists. The state itself (status, open question, pending review) lives on the task, never only in the column, so a board with other column names still works; the cards then simply stay in their column.

## Questions

- `ask_question` creates a question with `prompt` (up to 4000 characters), optional `options` (up to 20 short strings; if given, the answer must be one of them), `blocking` (default true: you cannot continue without the answer) and an `idempotencyKey` for safe retries.
- Write questions so that a person can decide in seconds: state the situation in one or two sentences, offer concrete options and name your recommendation first.
- States: `open`, `answered`, `withdrawn` (the runner job ended). Only one answer is accepted; a second different answer fails with `question_already_answered`.
- `list_open_questions {projectID?}` lists open questions of all granted projects (or one project, or one task); pass `includeAnswered: true` to also see answers.
- Humans answer in the app. `answer_question` exists for a person who steers you through the chat ("answer yes"); it refuses questions asked by your own connection (`cannot_answer_own_question`).
- Questions asked by a local runner job use the same list; they are answered by the project owner.

## Progress and features

- Percent is computed: done task = 100; with subtasks = done subtasks / all subtasks; else completed criteria / all criteria; else the percent of your latest progress note; else 0. The response always names the `source`.
- `post_progress` notes appear in the overview card and in the update feed. Keep them short and factual ("Login screen done, token refresh next", at most 4000 characters).
- `get_task_context` returns `progress`, `progressNotes`, `criteria` and `subtasks`.

## Reviews

- `request_review {taskID, summary, reviewerID?}`: the summary says what changed, how it was verified and what the reviewer should look at. Optionally name the person who must review (`reviewerID`, a user id from the brief or the task context).
- `list_pending_reviews {projectID?}` lists all pending reviews of the granted projects.
- A person accepts (task becomes `done`) or requests changes (task returns to `in_progress`). `decide_review` exists for a person steering you via chat; it refuses reviews requested by your own connection (`cannot_decide_own_review`).
- One pending review per task: requesting again updates the summary.

## Build screenshots

- `add_attachment {taskID, filename, mediaType, dataBase64, buildID, label?, platform?}` uploads up to 5 MiB in one call. `mediaType` is `image/png`, `image/jpeg`, `image/webp` or `application/pdf`; `filename` has no path separators.
- Larger files: `begin_attachment {taskID, filename, mediaType, size, checksum (SHA-256 hex), buildID, ...}` returns an `uploadURL` and a one-time `token`; send the bytes with `PUT <uploadURL>` and `Authorization: Bearer <token>`, then call `complete_attachment {attachmentID}`. The size limit of the instance applies (default 10 MiB).
- `list_builds {taskID}` returns the build artifacts of a task. The overview groups screenshots by `buildID`.
- Do not attach secrets, tokens or personal data in screenshots.

## Command center

`get_command_center` returns lanes with cards, a summary and the latest updates. A card contains the task, project, progress, current agent, open question count and preview, pending review, last progress text, build screenshots (up to 3) and the next due date. Lanes, in order: `running` (Läuft), `question` (Frage offen), `review` (Review fällig), `ready` (Bereit), `blocked` (Blockiert), `done` (Erledigt kürzlich). A task lands in the first matching lane: done, open question, review, blocked, running, ready. Use `view: "list"` with `lane`, `kind`, `hasQuestion`, `sort` (`attention|updated|due|progress|title`), `limit` and `offset` for a flat list.

## Project onboarding and keeping Todolino current

Todolino is only useful if it is current. Treat the board as part of the repository's definition of done.

**Prompts.** The server offers three prompts (in Claude Code: `/mcp__<server name>__setup_project`, `sync_project`, `session_start`). Each returns step-by-step instructions that use the tools below. If the user says "set this project up in Todolino", follow `setup_project`.

**Repository binding.** A project can be bound to a repository identifier: a normalised git remote (`host/owner/repo`, lower case, credentials dropped) or a free key such as `local/my-project`. The binding stores when the board was last reconciled with the repository (`last_synced_at`), who did it and a repository hint (`repoRef`, for example `main@a1b2c3d`).

- `find_project_by_repository {repository}`: always call it before creating anything. One match = use it. Zero matches and `outsideGrant: 0` = the repository is new. `outsideGrant > 0` = a project exists for this account but this connection does not include it: do not create a duplicate, ask the user to reconnect (`/mcp` in Claude Code) and include the project.
- `create_project {name, description?, parentID?, repository?, staleAfterDays?}`: creates the project and binds it; the connection's grant is extended automatically. Needs the scope `projects:write`.
- `bind_repository {projectID, repository?, staleAfterDays?}`: bind an existing project or change the staleness threshold (default 3 days).
- `record_sync {projectID, summary, repoRef?}`: "the board matches the repository now". `get_sync_status {projectID}` and `get_stale_projects` read the state: `fresh` (synced within the threshold), `stale` (older) or `never`. The command center shows the state per project in `projects[].sync` and counts stale bound projects in `summary.staleProjects`.

**Importing a plan.** `import_plan {projectID, items, applyWorkflowColumns?, dryRun?}` creates or updates features, subtasks, tasks, acceptance criteria and blocked reasons in one transaction, matched by your `externalKey` (unique per project, for example `docs/ARBEITSPLAN.md#login`). It reports `created`, `updated` and `unchanged` per item, so running it twice changes nothing the second time. It never deletes, never reopens a task and never unticks a criterion; it advances `open` to `done` only. Up to 300 items per call; items may have `children` (one level, the parent becomes a feature). New open tasks land in "Bereit" (or "Backlog" with `backlog: true`). `list_plan_keys {projectID}` maps keys to task ids afterwards. `set_agent_brief {projectID, text, version}` writes the agent brief when it is still empty (version 0); never overwrite a brief a person wrote.

**Mandatory routine for every session in a bound repository.**

1. Start: `session_start` (or `get_sync_status`, `get_command_center`, `list_open_questions {includeAnswered: true}`, `list_pending_reviews`). If the state is `stale` or `never`, run `sync_project` first.
2. Work: `claim_task`, then `post_progress` after each meaningful step. Ask with `ask_question` instead of guessing. Finished work goes to `request_review`.
3. End: bring statuses up to date (`import_plan` for new or finished plan items, `post_progress` for work in flight), then call `record_sync {projectID, summary, repoRef}`.

**Definition of done "Todolino aktuell".** A piece of work is done only when (a) the matching task has a final progress note or is in review, (b) new work found during the session exists as a task, (c) open decisions are questions on the board, not only in chat, and (d) `record_sync` was called after the last change. Do not claim a task is finished while the board says otherwise.

**Conflicts.** The board is the authority for `in_progress`, `in_review`, claims, questions and answers; the repository is the authority for what is implemented. When they disagree and you cannot tell which is right, ask a question instead of overwriting.

**What is written to the repository.** `setup_project` writes `.todolino.json` ({"schema": 1, "server", "projectID", "repository"}; no secrets, may be committed) and a short Todolino section between `<!-- todolino:begin -->` and `<!-- todolino:end -->` in CLAUDE.md or AGENTS.md. Update the section between the markers; never duplicate it.

## Tool reference

All tool arguments are JSON objects; unknown fields are rejected. Ids are UUID strings. Scopes are OAuth scopes of your connection; `tools/list` shows only the tools you may call. Errors are returned as tool results with `isError: true` and a short reason string (see "Errors and retries").

| Tool | Scope | Purpose |
| --- | --- | --- |
| `get_manual` | (none) | This manual; optional `section`. |
| `list_projects` | projects:read | Projects you may use. |
| `get_project_structure` | projects:read | Brief, columns, workflow template status, counts. |
| `get_command_center` | tasks:read | Kanban/list overview, summary, updates, build groups. |
| `list_tasks` | tasks:read | All tasks of a project. |
| `get_task` | tasks:read | One task. |
| `get_task_context` | tasks:read | Task plus subtasks, criteria, comments, questions, review, builds, progress. |
| `create_task` | tasks:write | New task in a project. |
| `update_task` | tasks:write | Edit title, description, status, project (needs `version`). |
| `set_task_structure` | tasks:write | Set `kind` feature/task, `parentTaskID`, `blockedReason`. |
| `claim_task` | tasks:write | Start work: status `in_progress`, owner label, column "In Arbeit". |
| `release_task` | tasks:write | Give a task back to "Bereit". |
| `post_progress` | tasks:write | Progress note with optional percent. |
| `add_criterion` | tasks:write | Add an acceptance criterion. |
| `set_criterion` | tasks:write | Tick or untick a criterion. |
| `ask_question` | tasks:write | Ask a structured, optionally blocking question. |
| `list_open_questions` | tasks:read | Questions across projects, one project or one task. |
| `get_question` | tasks:read | One question with its answer. |
| `answer_question` | tasks:write | Answer a question on behalf of the user (not your own). |
| `request_review` | tasks:write | Ask for review; task becomes `in_review`. |
| `list_pending_reviews` | tasks:read | Pending reviews. |
| `decide_review` | tasks:write | Accept or request changes on behalf of the user (not your own request). |
| `list_comments` | tasks:read | Comments of a task. |
| `add_comment` | comments:write | Post a comment. |
| `list_columns` | projects:read | Board with tasks per column. |
| `move_task_to_column` | tasks:write | Move a card. |
| `create_column` | tasks:write | Add a column. |
| `rename_column` | tasks:write | Rename a column. |
| `delete_column` | tasks:write | Delete a column (tasks move). |
| `apply_agent_workflow_columns` | tasks:write | Create the standard six columns on a project without columns. |
| `add_attachment` | attachments:write | Upload a screenshot (base64) with build metadata. |
| `begin_attachment` | attachments:write | Start a large upload; returns uploadURL and token. |
| `complete_attachment` | attachments:write | Finish a large upload. |
| `list_builds` | attachments:read | Build artifacts of a task. |
| `list_attachments` | attachments:read | Attachment metadata of a task. |
| `get_attachment` | attachments:read | One attachment's metadata. |
| `find_project_by_repository` | projects:read | Find the project bound to a repository. |
| `create_project` | projects:write | Create a project (optionally nested, optionally bound to a repository). |
| `bind_repository` | tasks:write | Bind a project to a repository / set the staleness threshold. |
| `record_sync` | tasks:write | Record that the board was reconciled with the repository now. |
| `get_sync_status` | projects:read | Sync state of one project (fresh, stale, never). |
| `get_stale_projects` | projects:read | Projects whose data is stale or never synced. |
| `import_plan` | tasks:write | Idempotent bulk upsert of features, tasks, subtasks, criteria by external key. |
| `list_plan_keys` | tasks:read | External keys of a project mapped to tasks. |
| `set_agent_brief` | tasks:write | Write the agent brief of a project (manage rights, version check). |
| `get_progress` | agents:read | Local runner jobs of a task (project owner only). |

Prompts: `setup_project`, `sync_project`, `session_start` (see "Project onboarding and keeping Todolino current").

Resources: `todo://manual` (this manual, Markdown), `todo://conventions` (JSON), and the template `todo://projects/{projectID}/structure`.

## Errors and retries

- `repository_already_bound`: another project of the same owner already has this repository; use `find_project_by_repository`.
- `not_bound`: `record_sync` needs a repository binding; call `bind_repository`.
- `insufficient_scope`: your connection lacks the OAuth scope. Tell the user which scope the tool needs.
- `not_found`: the object does not exist or is outside your grant (both look the same).
- `forbidden`: the user's current role does not allow it (reading needs read, writing needs edit, brief editing needs manage).
- `version_conflict`: someone changed the object; re-read it and apply your change again.
- `already_claimed`: another agent works on the task. Pick another task or ask the user.
- `question_already_answered`, `review_already_pending`, `no_pending_review`, `cannot_answer_own_question`, `cannot_decide_own_review`: workflow guards; do not retry blindly.
- `columns_exist`: the project already has columns; do not apply the template.
- `invalid_arguments` and `invalid_*`: fix the arguments; the reason names the field.
- Network errors: retry writes only with an `idempotencyKey` (`add_comment`, `ask_question`) or after re-reading the object.

## Examples

Claim and report:

```json
{"name": "claim_task", "arguments": {"taskID": "6f1c9a3e-0000-4000-8000-000000000001", "agentName": "claude-code@build-mac"}}
{"name": "post_progress", "arguments": {"taskID": "6f1c9a3e-0000-4000-8000-000000000001", "note": "Login view implemented, writing tests", "percent": 40}}
```

Ask a decision question:

```json
{"name": "ask_question", "arguments": {"taskID": "6f1c9a3e-0000-4000-8000-000000000001",
  "prompt": "Passkeys only, or keep password login as a fallback? I recommend passkeys only.",
  "options": ["Passkeys only", "Passkeys and password"], "blocking": true, "idempotencyKey": "login-method-1"}}
```

Attach a screenshot and request review:

```json
{"name": "add_attachment", "arguments": {"taskID": "6f1c9a3e-0000-4000-8000-000000000001", "filename": "login.png",
  "mediaType": "image/png", "dataBase64": "iVBORw0KGgo...", "buildID": "web-2026-10-30.3", "label": "Login screen", "platform": "web"}}
{"name": "request_review", "arguments": {"taskID": "6f1c9a3e-0000-4000-8000-000000000001",
  "summary": "Login with passkey implemented. Verified with the e2e test; screenshot attached."}}
```
