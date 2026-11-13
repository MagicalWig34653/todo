<!-- manual-version: 1.26.0 -->
# Todolino agent manual

This manual is written for coding agents (Claude Code and others) that work for a person through the Todolino MCP server. It is served by the MCP tool `get_manual`, the MCP resource `todo://manual` and `GET /v1/manual`. Fetch it once at the start of a session and re-read the section you need when unsure. The manual is versioned (see the first line); `get_manual` returns the version and a structured `conventions` object.

## Start here

1. Call `get_manual` (you are reading its result).
2. Find the project you work for: `find_project_by_repository {repository}` with the git remote of your working directory (or a `.todolino.json` in the repository root, or `list_projects`). If the repository has no project yet, see "Project onboarding and keeping Todolino current". Then call `get_project_structure {projectID}`. It returns the project's **agent brief**: the goals, constraints and definition of done that the user wrote for agents of this project. The brief overrides your defaults. It also returns the board columns and whether the standard workflow columns exist.
**Current project.** One login covers all projects of the person, so account-wide reads would show tasks of other projects. Your current project is the one bound to the repository (`projectID` in `.todolino.json`). Pass it as `projectID` to `get_command_center`, `list_open_questions` and `list_pending_reviews`: the answer then names it as `currentProject {id, name}` and is limited to it and its sub-projects. Never claim, edit, mention or offer tasks of other projects. Without `projectID` the answer covers all projects and carries a `hint`; `scope: "account"` (with `projectID`) keeps all projects but marks entries of other projects with `foreignProject: true` - ignore those.
3. Call `get_command_center {projectID}` to see what is running, what waits for an answer or a review, and what is ready to start.
4. Work through the workflow below. All communication with the user goes through the board: progress notes, questions, review requests and screenshots. Do not ask the user in free chat when the board can carry the question.

The user decides; you propose and execute. If a decision is needed that the brief does not answer, ask a question (blocking) instead of guessing.

## Concepts

- **Project**: a node in a freely nested tree. Every project has its own board columns, a description and an agent brief. You can only see projects the user granted to your connection.
- **Task**: one card on the board. Status: `open`, `in_progress`, `in_review`, `done`. Optimistic concurrency: every task has a `version`; writes that pass a stale version fail with `version_conflict`.
- **Feature**: a task with `kind=feature` or with at least one subtask. A subtask is a task whose parent is a feature of the same project (depth at most 2). Features show their percent progress on the overview.
- **Board column**: a named column of one project. Columns are recognised by name; the standard workflow uses Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt.
- **Message (comment)**: one entry in the chat of a card. Every task, question and review has its own chat; people and agents write into it (`authorKind` is `person` or `agent`). Not tracked as a decision.
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
4a. **Read what people wrote**: new messages and replies come as chat messages. After a question, a review or a long step call `list_comments {taskID, authorKind: "person", since}` (or `wait_for_events`, hint `kind: "comment"`) and answer with `add_comment`. Pass `questionID` or `reviewID` to read or write in the chat of that question or review; without it you write into the task's own chat.
5. **Ask when you need a decision**: `ask_question {taskID, prompt, options?, blocking: true}`. The card moves to "Frage offen". Continue with other tasks while it is open. Poll `get_question {questionID}` (or `list_open_questions {taskID, includeAnswered: true}`) until `state` is `answered`, then read `answer`. Never answer your own question. After a blocking question you may call `wait_for_events {since?, timeoutSeconds}` for at most a few rounds (it returns hints only: `changed`, `token`, `hints[{kind, taskID, projectID}]`; pass the returned `token` as `since` next time), then `get_question`; if still open, end the turn normally instead of looping.
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
- `list_open_questions {projectID, scope?, taskID?}` answers `{currentProject, hint?, items}`: open questions of the current project and its sub-projects (`scope: "account"`: all granted projects, foreign entries have `foreignProject: true`; no `projectID`: all projects plus `hint`); pass `includeAnswered: true` to also see answers. Answers are compact by default (`compact: false` for every field); narrow with `status` (`open|answered|all`), `limit` and `fields`.
- Humans answer in the app. `answer_question` exists for a person who steers you through the chat ("answer yes"); it refuses questions asked by your own connection (`cannot_answer_own_question`).
- Questions asked by a local runner job use the same list; they are answered by the project owner.

## Progress and features

- Percent is computed: done task = 100; with subtasks = done subtasks / all subtasks; else completed criteria / all criteria; else the percent of your latest progress note; else 0. The response always names the `source`.
- `post_progress` notes appear in the overview card and in the update feed. Keep them short and factual ("Login screen done, token refresh next", at most 4000 characters).
- `get_task_context` returns `progress`, `progressNotes`, `criteria` and `subtasks`.

## Reviews

- `request_review {taskID, summary, reviewerID?}` is for something the person has to look at or decide: a visible result to try, a risk, a rollout or merge decision. Pure update information (commit hash, tests green, internal change, numbers) is NOT a review: put it into `post_progress` and keep the task where it is. Write the summary as one sentence of result plus at most four bullets: what is new, how it was checked (with numbers), what to look at, what is open. No commit hashes or file lists as the main content. Optionally name the person who must review (`reviewerID`, a user id from the brief or the task context).
- `list_pending_reviews {projectID, scope?}` answers `{currentProject, hint?, items}` with the pending reviews of the current project (same `scope`/`foreignProject`/`hint` rules as `list_open_questions`).
- A person accepts (task becomes `done`) or requests changes (task returns to `in_progress`). `decide_review` exists for a person steering you via chat; it refuses reviews requested by your own connection (`cannot_decide_own_review`).
- One pending review per task: requesting again updates the summary.

## Build screenshots

- `add_attachment {taskID, filename, mediaType, dataBase64, buildID, label?, platform?}` uploads up to 5 MiB in one call. `mediaType` is `image/png`, `image/jpeg`, `image/webp` or `application/pdf`; `filename` has no path separators.
- Larger files: `begin_attachment {taskID, filename, mediaType, size, checksum (SHA-256 hex), buildID, ...}` returns an `uploadURL` and a one-time `token`; send the bytes with `PUT <uploadURL>` and `Authorization: Bearer <token>`, then call `complete_attachment {attachmentID}`. The size limit of the instance applies (default 10 MiB).
- `list_builds {taskID}` returns the build artifacts of a task. The overview groups screenshots by `buildID`.
- Do not attach secrets, tokens or personal data in screenshots.

## Command center

`get_command_center {projectID, scope?}` returns lanes with cards (plus `currentProject`, `hint` and `foreignProject` on cards as described in "Start here"), a summary and the latest updates. `summary.overdue` counts all visible unfinished tasks with `planning.dueAt < generatedAt`, including subtasks and backlog, before card filters or pagination. It respects project scope and the OAuth grant. Each card has `dueDate` (its own planning dueAt) and `nextDue` (earliest dueAt of its unfinished task or unfinished subtasks); completed tasks do not contribute to nextDue. These timestamps remain in compact responses. `list_tasks {projectID, overdue: true}` and `GET /v1/tasks?overdue=true` return only visible unfinished overdue tasks with planning data; false or omission leaves the list unfiltered. **Orphaned claims.** A claim (`claim_task`) is orphaned when the task is `in_progress` and the newest sign of life is older than 24 hours. Signs of life are progress notes, comments, activity of the task (status changes, questions, reviews), runner events such as checkpoints, and at least `claimedAt`. `summary.orphanedClaims` counts tasks (parents and subtasks individually, all readable ones, before card filters), so the number of cards with `orphaned: true` can be smaller; cards carry `orphaned` and `lastSignOfLifeAt`. Take over an orphaned task with `claim_task {takeOver: true}` or ask the person; the server never releases on its own. A card contains the task, project, progress, current agent, open question count and preview, pending review, last progress text, build screenshots (up to 3) and the next due date. Lanes, in order: `running` (Läuft), `question` (Frage offen), `review` (Review fällig), `ready` (Bereit), `blocked` (Blockiert), `done` (Erledigt kürzlich). A task lands in the first matching lane: done, open question, review, blocked, running, ready. The answer is compact by default (subtasks and builds only as counts, short texts, 10 cards per lane, 5 updates); pass `compact: false` for the full detail and `fields` to keep only some card fields. Use `view: "list"` with `lane`, `kind`, `hasQuestion`, `sort` (`attention|updated|due|progress|title`), `limit` and `offset` for a flat list.

## Daily brief

`get_daily_brief {projectID?, since?, format?}` (REST `GET /v1/daily-brief`) is the short morning read: what needs the person, what is stuck, what runs, what got done. Use it for a status line or a standup summary instead of reading the whole command center. Without `projectID` it covers all readable projects of the connection (with `projectID`: that project and its sub-projects); nothing outside the OAuth grant appears.

- `format=full` (default): `{generatedAt, since, scope, projectID, format, line, summary, sections}`. `sections` come in priority order: `waiting` (open questions, pending reviews, confirmation requests of the account), `decisions` (journal decisions since `since` that the person has not reviewed yet, newest first, kind `decision`; `summary.decisionsToReview`), `orphaned` (claims without a sign of life for over 24 hours), `stale` (bound projects with a stale or missing sync), `running` (in progress with a claim, not orphaned), `done` (done since `since`). Each section has `key`, `title`, `count` (always exact), `truncated` and up to 5 `items` `{id, title, projectID, kind}` (waiting: oldest first, done: newest first). `summary` has the exact counters.
- `format=line`: `{generatedAt, since, scope, projectID, format, line}` with one German line of at most 200 characters, for example `3 warten auf dich, 2 verwaist, 1 Projekt veraltet · 5 erledigt, 4 laufen`, or `Alles ruhig: nichts wartet auf dich.` on a quiet day.
- `since`: ISO 8601 date-time or a date (`YYYY-MM-DD`, UTC midnight); default is the start of yesterday in UTC (the account has no time zone setting). A date in the future fails with `invalid_since`; an unknown `format` with `invalid_format`. A done task counts when its last change is at or after `since`.
- Confirmation requests belong to the account, not to a project: they are counted only without `projectID` and without an OAuth grant limit (so over MCP they are not part of it; use `get_action_request`/the app).
- The person can switch on a daily push of the line (`update_notification_prefs {categories: {daily_brief: true}, dailyBriefHour}`, default off, hour 0 to 23 in UTC, default 8). The push carries only the counts line, never titles.

## Decision journal

When you decide something yourself that the person would normally have decided (especially overnight, without asking), journal it. The person then reviews decisions and criteria in the morning instead of code.

- `record_decision {taskID, decision, rationale, criterion, rollbackRef?, agentName?}` (REST `POST /v1/tasks/{id}/decisions`, scope `tasks:write`). `criterion` is the checkable thing the person can judge it by; `rollbackRef` is the commit hash or branch that undoes or contains it (up to 200 characters of letters, digits and `._/-@+`, otherwise `invalid_rollback_ref`). Only reversible, non-destructive, local decisions; anything else is an `ask_question`.
- `list_decisions {projectID?, taskID?, since?, state?, query?, limit?}` (REST `GET /v1/decisions`, `GET /v1/tasks/{id}/decisions`, scope `tasks:read`): newest first, `state` is `open`, `ok`, `rolled_back` or `all`. Before deciding something similar, search precedents: `state=rolled_back` plus `query`; the `reviewNote` is the person's reason.
- `review_decision {decisionID, verdict, note?}` (REST `POST /v1/decisions/{id}/review`, scope `tasks:write`): `verdict` `ok` or `rollback`; `rollback` needs a `note` (`note_required`). It only marks the decision; undoing the change in git is separate work. A connection cannot review its own decisions (`cannot_review_own_decision`).
- The morning view is the `decisions` section of `get_daily_brief`.

## Channel #brain (voice and text with the person)

Each account has exactly one channel `brain` (created on first use): the person talks to the brain there, by text or by voice message from the app, and you answer there. It belongs to the account alone: nobody else can read or write it, there is no sharing and no project or task link.

- `list_channel_messages {limit?, cursor?, since?}` (REST `GET /v1/channels/brain/messages`, scope `channels:read`): newest first, `{items, nextCursor}`; pass `nextCursor` as `cursor` for older messages, `since` (ISO 8601) for newer ones. A message is `{id, kind, author, text, attachmentID, clientUUID, createdAt}`. `kind`: `text`, `voice_in` (spoken by the person; `text` is the transcript once there is one, `attachmentID` the audio), `voice_out` (your spoken answer) or `status` (system note, for example that the Mac is offline). `author`: `person` or `agent`.
- `post_channel_message {kind?, text?, attachmentID?, clientUUID?}` (REST for the person: same path with POST, scope `channels:write` for connections): you may write `text` (default) and `status` (text required, up to 4000 characters) and `voice_out` (`attachmentID` of a finished audio attachment with role `voice` that belongs to this account; `text` optional). You cannot write `voice_in`; that is the person's own voice. Errors: `invalid_kind`, `invalid_text`, `attachment_required`, `attachment_not_allowed`, `invalid_attachment` (not a finished voice attachment), `not_found` (attachment missing or not yours), `client_uuid_conflict`.
- Idempotency: send a `clientUUID` of your own; a retry with the same UUID and the same content returns the original message (HTTP 200 instead of 201 over REST), the same UUID with different content fails with `client_uuid_conflict`. The key is per account.
- Voice jobs (server side, no tool): a `voice_in` message makes the server create a voice job for a Mac runner that reports the capability `sprache`; the runner transcribes (the transcript fills `text` of the `voice_in` message) and answers with a `voice_out` (audio) or `text` message, all written by the server, not by you. Without such a runner the server itself writes a `status` message "Brain gerade nur per Text erreichbar." and there is no job; a job that nobody finishes within 10 minutes ends with the `status` message "Die Sprachnachricht ist abgelaufen.". So a `voice_in` without `text` yet is not an unanswered request for you: it is waiting for the runner. Read `status` messages as system notes, not as the person's words.
- Voice and transcripts are private user data: quote them only as far as needed, never copy them into project comments or logs unasked. The person's rights apply as in the app; a spoken request is not a confirmation for class C actions.

## Project onboarding and keeping Todolino current

Todolino is only useful if it is current. Treat the board as part of the repository's definition of done.

**Prompts.** The server offers three prompts (in Claude Code: `/mcp__<server name>__setup_project`, `sync_project`, `session_start`). Each returns step-by-step instructions that use the tools below. If the user says "set this project up in Todolino", follow `setup_project`.

**Repository binding.** A project can be bound to a repository identifier: a normalised git remote (`host/owner/repo`, lower case, credentials dropped) or a free key such as `local/my-project`. The binding stores when the board was last reconciled with the repository (`last_synced_at`), who did it and a repository hint (`repoRef`, for example `main@a1b2c3d`).

- `find_project_by_repository {repository}`: always call it before creating anything. One match = use it. Zero matches and `outsideGrant: 0` = the repository is new. `outsideGrant > 0` = a project exists for this account but this connection does not include it: do not create a duplicate, ask the user to reconnect (`/mcp` in Claude Code) and include the project.
- `create_project {name, description?, parentID?, repository?, staleAfterDays?}`: creates the project and binds it; the connection's grant is extended automatically. Needs the scope `projects:write`.
- `update_project {projectID, version, name?, description?, color?}`: rename a project or change its description/colour (only passed fields change; empty or null description clears it). Needs `version` from `list_projects`/`get_project_structure` (stale -> `version_conflict`), manage rights and the scope `projects:write`.
- `bind_repository {projectID, repository?, staleAfterDays?}`: add a repository binding to an existing project or change the staleness threshold (default 3 days). A project can have up to 10 bindings (for example several checkouts or repositories), each with its own sync history that is never reset. Without `repository` the call only works when there is exactly one binding.
- `record_sync {projectID, repository?, summary, repoRef?}`: "the board matches the repository now". `get_sync_status {projectID, repository?}` and `get_stale_projects` read the state: `fresh` (synced within the threshold), `stale` (older) or `never`. The command center shows the state per project in `projects[].sync` and counts stale bound projects in `summary.staleProjects`.
- `list_repository_bindings {projectID}`: all bindings of the project, oldest first, each with its own state. `unbind_repository {projectID, repository}`: removes one binding with its sync history (not recoverable; binding again starts a new history). The answer carries an `effect` text. It leaves no activity entry, because projects have no activity log.
- Several bindings: always pass the `repository` from `.todolino.json` to `record_sync` and `get_sync_status`. Without it, `record_sync` fails with `repository_required` (the error lists the keys). `get_sync_status` without `repository` returns the flat fields of the stalest binding plus `bindings` (all of them); `get_stale_projects` adds `staleBindings`. A project counts as stale as soon as one binding is not fresh.

**Importing a plan.** `import_plan {projectID, items, applyWorkflowColumns?, dryRun?}` creates or updates features, subtasks, tasks, acceptance criteria and blocked reasons in one transaction, matched by your `externalKey` (unique per project, for example `docs/ARBEITSPLAN.md#login`). It reports `created`, `updated` and `unchanged` per item, so running it twice changes nothing the second time. It never deletes, never reopens a task and never unticks a criterion; it advances `open` to `done` only. Up to 300 items per call; items may have `children` (one level, the parent becomes a feature). New open tasks land in "Bereit" (or "Backlog" with `backlog: true`). `list_plan_keys {projectID}` maps keys to task ids afterwards. `set_agent_brief {projectID, text, version}` writes the agent brief when it is still empty (version 0); never overwrite a brief a person wrote.

**Mandatory routine for every session in a bound repository.**

1. Start: `session_start` (or `get_sync_status`, `get_command_center`, `list_open_questions {includeAnswered: true}`, `list_pending_reviews`). If the state is `stale` or `never`, run `sync_project` first.
2. Work: `claim_task`, then `post_progress` after each meaningful step. Ask with `ask_question` instead of guessing. Finished work goes to `request_review`.
3. End: bring statuses up to date (`import_plan` for new or finished plan items, `post_progress` for work in flight), then call `record_sync {projectID, summary, repoRef}`.

**Definition of done "Todolino aktuell".** A piece of work is done only when (a) the matching task has a final progress note or is in review, (b) new work found during the session exists as a task, (c) open decisions are questions on the board, not only in chat, and (d) `record_sync` was called after the last change. Do not claim a task is finished while the board says otherwise.

**Conflicts.** The board is the authority for `in_progress`, `in_review`, claims, questions and answers; the repository is the authority for what is implemented. When they disagree and you cannot tell which is right, ask a question instead of overwriting.

**What is written to the repository.** `setup_project` writes `.todolino.json` ({"schema": 1, "server", "projectID", "repository"}; no secrets, may be committed) and a short Todolino section between `<!-- todolino:begin -->` and `<!-- todolino:end -->` in CLAUDE.md or AGENTS.md. Update the section between the markers; never duplicate it.

## Using the board while you work

Calling only `record_sync` at the end of a session is not "using Todolino". The board is how the person follows your work, answers your decisions and reviews results, so use it during the work.

1. **Start.** `session_start` (or `get_sync_status`, `get_command_center`, `list_open_questions {includeAnswered: true}`, `list_pending_reviews`). Handle answered questions, requested changes and tasks you already claimed before anything new.
2. **Before work.** Find the task that matches the order (`list_tasks`, the command center, `list_plan_keys`). None exists: `create_task` (title, short description; never a duplicate), then `claim_task`. One task per order; split larger orders into subtasks.
3. **During work.** `post_progress` after every finished sub-step and every commit (what is done, what is next, commit hash). Short, factual, no secrets.
4. **Decisions.** A choice only the person can make (scope, naming, trade-off, risk) is an `ask_question` on the task, with options and your recommendation; use `blocking: true` when you cannot continue without it. Do not ask only in chat; chat is gone with the session, the question is not. Continue with unaffected work and read the answer later.
5. **Finished.** `request_review` only if the person has something concrete to look at or decide, with a short summary (see Reviews) and, where relevant, screenshots. Finished without anything for the person to check (internal change, tests green): only `post_progress` (percent 100, commit and numbers there), no review. Close the task yourself with `update_task {id, version, status: "done"}` when the work is proven finished (merged, tests green, criteria met) and there is nothing for the person to look at or decide; post the proof first in a short `post_progress` (commit, test numbers). Anything the person must see or decide, or a risky or rollout step: `request_review` instead, never `done`.
6. **End.** Bring statuses up to date, `post_progress` for work in flight, then `record_sync {projectID, summary, repoRef}`.

**Writing style for everything the person reads on the board** (reviews, questions, progress, comments, task descriptions): short and in bullet points. The headline is the task title, not the text. Questions: the situation in one or two lines, then 2 to 4 concrete options with your recommendation first. Progress: one or two sentences. Lists of findings belong into the task description or into subtasks, not into progress notes. Ask the person questions on the board (`ask_question`), not in chat, and keep working on what does not depend on the answer.

With the Claude Code plugin, hooks support this: the SessionStart text repeats the rules, the PostToolUse hook after `git commit` asks for `post_progress`, and the Stop hook reminds once per session when files were changed or commits made without any `post_progress`, `request_review` or `ask_question` call. Hooks send nothing to the server; the calls are yours.

**Checklist for a main session that starts agents.**

- [ ] The order has a task on the board (found or created, claimed by the main session or handed over deliberately).
- [ ] Every spawned agent gets its own task or subtask ID, the project ID and the rules "claim_task, post_progress after each sub-step, ask_question instead of chat questions, no request_review unless the person must look or decide; close the card with `update_task status=done` only when proven finished" in its prompt.
- [ ] Agents work in separate worktrees with clear file ownership; the prompt names the files.
- [ ] While agents run, check `get_command_center` / `list_open_questions` and answer or forward questions.
- [ ] When an agent returns: verify the result (tests, diff), then the main session calls `request_review` with the summary.
- [ ] Decisions the person must take are `ask_question`s on the task, not chat messages only.
- [ ] End of session: statuses current, `record_sync` called.

**Loading the tools (Claude Code).** Tool schemas are deferred: calling a Todolino tool directly fails with `invalid_arguments` until it is loaded. A plugin cannot preload schemas; the SessionStart hook prints a ready line instead. Run it once per session with ToolSearch: `select:mcp__plugin_todolino_todolino__post_progress,mcp__plugin_todolino_todolino__claim_task,mcp__plugin_todolino_todolino__create_task,mcp__plugin_todolino_todolino__ask_question,mcp__plugin_todolino_todolino__request_review,mcp__plugin_todolino_todolino__list_tasks,mcp__plugin_todolino_todolino__get_command_center,mcp__plugin_todolino_todolino__record_sync,mcp__plugin_todolino_todolino__get_sync_status`. Load other tools by name the same way.

**Codex jobs and other sandboxed workers.** Codex jobs (companion, Codex sandbox) cannot call Todolino tools, so their work would stay invisible. The Claude session that started the job is the wrapper: it reads the job result and reports with `post_progress` (or `add_comment`) on the job's behalf, with `agentName` like `codex@<topic>`, and turns open questions of the job into `ask_question`. The Claude Code Stop hook counts board calls of the main session and of its subagents, so the wrapper's report counts as board activity.

## Large actions need confirmation

Irreversible or far-reaching actions (class C) never run directly: `delete_project {projectID, version?}`, `delete_task {taskID, version?}` and `transfer_project_owner {projectID, ownerType, ownerID, version}`. The call stores a confirmation request and answers with an error `confirmation_required` and an `actionRequestID` (JSON: `{error, actionRequestID, state: "pending", message}`). The user sees the request in Todolino ("Für dich" > "Braucht dich", with a summary such as "Projekt X mit 14 Aufgaben und 3 Unterprojekten löschen") and confirms or rejects it. Only after the confirmation the server runs the action, with the user's current rights and the limits of your connection (rights are checked again then).

- Do NOT call the tool again; the same call while the request is open returns the same `actionRequestID`. Requests expire after 7 days.
- Wait for the result with `wait_for_events` (hint `kind: "action_request"` with `actionRequestID`, no content) and read it with `get_action_request {id}`: `state` is `pending`, `rejected`, `expired`, `executed` or `failed`; `result` is `{ok, code}` (`deleted`, `owner_changed`, or the reason such as `forbidden`, `not_found`, `version_conflict`, `connection_revoked`).
- `list_action_requests {state?}` lists the requests of your connection.
- Delete a project only when the user clearly asked for it. Post a progress note or ask a question explaining why before you request it. All sub-projects must be in your grant, otherwise the call fails with `not_found`.
- After `rejected` do not ask again unless the user tells you to.

## Tool reference

All tool arguments are JSON objects; unknown fields are rejected. Ids are UUID strings. Scopes are OAuth scopes of your connection; `tools/list` shows only the tools you may call. Errors are returned as tool results with `isError: true` and a short reason string (see "Errors and retries").

| Tool | Scope | Purpose |
| --- | --- | --- |
| `get_manual` | (none) | This manual; optional `section`. |
| `list_projects` | projects:read | Projects you may use. |
| `get_project_structure` | projects:read | Brief, columns, workflow template status, counts. |
| `get_command_center` | tasks:read | Kanban/list overview, summary, updates, build groups. |
| `record_decision` | tasks:write | Journal a decision you took yourself: decision, rationale, criterion, rollbackRef (commit/branch). |
| `list_decisions` | tasks:read | Journal entries, newest first; `state=rolled_back` + `query` finds precedents. |
| `review_decision` | tasks:write | Mark a decision ok or rollback (note required); not your own decisions. |
| `list_channel_messages` | channels:read | Read the account's #brain channel (voice and text messages), newest first, with cursor. |
| `post_channel_message` | channels:write | Write to #brain as the agent: text, status or voice_out (audio attachment); idempotent by `clientUUID`. |
| `get_daily_brief` | tasks:read | Daily brief: what waits for the person, orphaned claims, stale projects, running, done since a date; `format=line` gives one short line. |
| `list_tasks` | tasks:read | Tasks of a project with planning; optional `overdue: true` for unfinished overdue tasks, `orphaned: true` for in-progress tasks with a claim that shows no sign of life for over 24 hours. |
| `get_task` | tasks:read | One task. |
| `get_task_context` | tasks:read | Task plus subtasks, criteria, comments, questions, review, builds, progress. |
| `create_task` | tasks:write | New task in a project; optional `columnID`, `dueDate`, `priority`. Runs the same rules as the app (activity, recurrence, clean-up on project change). |
| `update_task` | tasks:write | Edit title, description, status, project (needs `version`). |
| `set_task_structure` | tasks:write | Set `kind` feature/task, `parentTaskID`, `blockedReason`. |
| `claim_task` | tasks:write | Start work: status `in_progress`, owner label, column "In Arbeit". |
| `release_task` | tasks:write | Give a task back to "Bereit". |
| `post_progress` | tasks:write | Progress note with optional percent. |
| `add_criterion` | tasks:write | Add an acceptance criterion. |
| `set_criterion` | tasks:write | Tick or untick a criterion. |
| `ask_question` | tasks:write | Ask a structured, optionally blocking question. |
| `list_open_questions` | tasks:read | Questions of the current project (`projectID`), `scope=account` for all; answer `{currentProject, hint?, items}`. |
| `get_question` | tasks:read | One question with its answer. |
| `wait_for_events` | tasks:read | Wait up to 25 s for board changes; returns hints only (no content). Use a few rounds after a blocking question or a confirmation request, then `get_question` / `get_action_request`. |
| `answer_question` | tasks:write | Answer a question on behalf of the user (not your own). |
| `request_review` | tasks:write | Ask for review; task becomes `in_review`. |
| `list_pending_reviews` | tasks:read | Pending reviews of the current project (`projectID`), `scope=account` for all; answer `{currentProject, hint?, items}`. |
| `decide_review` | tasks:write | Accept or request changes on behalf of the user (not your own request). |
| `list_comments` | tasks:read | Chat messages of a task; filters `questionID`, `reviewID`, `thread: "task"`, `authorKind`, `since`. Uploads by people appear as entries with `kind: "attachment"` and `attachments: [{id, filename, mediaType, size}]`; files without a chat entry add one trailing `attachments_note`. |
| `add_comment` | comments:write | Write a message into the chat of a task, question (`questionID`) or review (`reviewID`); optional `agentName`. |
| `list_columns` | projects:read | Board with tasks per column. |
| `move_task_to_column` | tasks:write | Move a card. |
| `create_column` | tasks:write | Add a column. |
| `rename_column` | tasks:write | Rename a column. |
| `delete_column` | tasks:write | Class C: asks the person to confirm deleting a column (its tasks move). |
| `apply_agent_workflow_columns` | tasks:write | Create the standard six columns on a project without columns. |
| `add_attachment` | attachments:write | Upload a screenshot (base64) with build metadata. |
| `begin_attachment` | attachments:write | Start a large upload; returns uploadURL and token. |
| `complete_attachment` | attachments:write | Finish a large upload. |
| `list_builds` | attachments:read | Build artifacts of a task. |
| `list_attachments` | attachments:read | Attachment metadata of a task. |
| `get_attachment` | attachments:read | One attachment's metadata. |
| `find_project_by_repository` | projects:read | Find the project bound to a repository. |
| `create_project` | projects:write | Create a project (optionally nested, optionally bound to a repository). |
| `update_project` | projects:write | Change name, description, colour of a project (needs `version`). |
| `delete_project` | projects:write | Request deletion of a project (needs the user's confirmation; answers `confirmation_required`). |
| `delete_task` | tasks:write | Request deletion of a task (needs confirmation). |
| `transfer_project_owner` | projects:write | Request an ownership transfer (needs confirmation). |
| `list_action_requests` | (none) | Confirmation requests of this connection. |
| `get_action_request` | (none) | State and result of one confirmation request. |
| `bind_repository` | tasks:write | Add a repository binding (up to 10) / set the staleness threshold. |
| `list_repository_bindings` | projects:read | All repository bindings of a project with their sync state. |
| `unbind_repository` | tasks:write | Remove one repository binding and its sync history (not recoverable). |
| `record_sync` | tasks:write | Record that the board was reconciled with a repository now (`repository` needed with several bindings). |
| `get_sync_status` | projects:read | Sync state of one project (fresh, stale, never); optional `repository`, `bindings` list. |
| `get_stale_projects` | projects:read | Projects whose data is stale or never synced. |
| `import_plan` | tasks:write | Idempotent bulk upsert of features, tasks, subtasks, criteria by external key. |
| `list_plan_keys` | tasks:read | External keys of a project mapped to tasks. |
| `set_agent_brief` | tasks:write | Write the agent brief of a project (manage rights, version check). |
| `get_progress` | agents:read | Local runner jobs of a task (project owner only). |
| `move_project` | projects:write | Move a project under another parent (`parentID`, null = top level); needs manage rights at source and target. |
| `set_project_position` | projects:write | Place a project among its siblings (`afterProjectID`, null = first). |
| `update_criterion` | tasks:write | Change the text of an acceptance criterion. |
| `delete_criterion` | tasks:write | Class C: asks the person to confirm deleting a criterion. |
| `get_task_planning` | tasks:read | Due date and time, priority, recurrence and reminders of a task. |
| `update_task_planning` | tasks:write | Set due date/time, priority, recurrence, reminders (same rules as the app). |
| `list_planned_tasks` | tasks:read | Today, upcoming or up next (`view`), optionally for one project. |
| `set_dependencies` | tasks:write | Replace what blocks a task (`blockedBy`); cycles are refused. |
| `list_dependencies` | tasks:read | What blocks a task and what it blocks. |
| `remove_dependency` | tasks:write | Remove one dependency. |
| `list_milestones` | tasks:read | Milestones of a project. |
| `create_milestone` | tasks:write | New milestone with optional due date. |
| `assign_milestone` | tasks:write | Put a task into a milestone. |
| `unassign_milestone` | tasks:write | Take a task out of a milestone. |
| `delete_milestone` | tasks:write | Class C: asks the person to confirm deleting a milestone. |
| `search_tasks` | tasks:read | Search tasks in the projects of this connection. |
| `list_labels` | labels:read | Your own labels. |
| `create_label` | labels:write | New label (name, optional color). |
| `update_label` | labels:write | Rename or recolor a label. |
| `set_task_labels` | labels:write | Replace the labels of a task. |
| `delete_label` | labels:write | Class C: asks the person to confirm deleting a label. |
| `list_filters` | filters:read | Your saved filters. |
| `create_filter` | filters:write | New saved filter. |
| `update_filter` | filters:write | Change name or query of a filter. |
| `run_filter` | filters:read | Run a saved filter; results only from the projects of this connection. |
| `delete_filter` | filters:write | Class C: asks the person to confirm deleting a filter. |
| `list_project_grants` | sharing:read | Shares of a project (needs manage). |
| `get_project_visibility` | sharing:read | Effective role and inheritance of a project, optionally for another person. |
| `set_project_grant` | sharing:write | Share a project with a person or team. Class B for known principals up to role edit; strangers, role manage or sub-projects outside the connection ask the person to confirm. |
| `revoke_project_grant` | sharing:write | Class C: asks the person to confirm removing a share. |
| `list_teams` | teams:read | Your teams. |
| `list_team_members` | teams:read | Members of a team. |
| `create_team` | teams:write | New team (grants no access by itself). |
| `invite_team_member` | teams:write | Invite a person to a team; inviting as team admin asks the person to confirm. |
| `update_comment` | comments:write | Edit one of your own agent messages on a task. |
| `delete_comment` | comments:write | Class C: asks the person to confirm deleting a task comment. |
| `list_project_comments` | projects:read | Comments on a project. |
| `add_project_comment` | comments:write | Comment on a project. |
| `update_project_comment` | comments:write | Edit one of your own project comments. |
| `delete_project_comment` | comments:write | Class C: asks the person to confirm deleting a project comment. |
| `list_activity` | tasks:read | Activity feed, only from the projects of this connection. |
| `read_attachment` | attachments:read | Attachment metadata, build info and an inline preview only for tiny images (up to 45000 bytes); bigger ones return `previewOmitted: preview_unavailable` and a hint. |
| `get_attachment_download` | attachments:read | Signed URL (5 minutes, one attachment, GET) to download a file. Run `scripts/fetch-attachment.sh <url> [dir]` of the plugin and `Read` the printed path to look at a screenshot. Never post the URL on the board. |
| `register_build` | attachments:write | Turn a finished attachment into a build screenshot (idempotent). |
| `begin_task_upload` | attachments:write | Start an upload with a chosen role (reference, progress, result). |
| `complete_task_upload` | attachments:write | Finish your own upload. |
| `delete_attachment` | attachments:write | Class C: asks the person to confirm deleting an attachment. |
| `update_column` | tasks:write | Change a board column: name, color, done flag, position. |
| `apply_column_template` | tasks:write | Class B: give a project without columns a column set (status, agent workflow or another project's). |
| `reorder_tasks` | tasks:write | Set the manual order of the tasks of one status (classic board). |
| `list_favorites` | projects:read | Your favorite projects in order. |
| `set_project_favorite` | projects:write | Add, move or remove a favorite project (personal setting). |
| `get_project_prefs` | projects:read | Your display settings for a project plus the revision. |
| `update_project_prefs` | projects:write | Change your display settings for a project (pass the revision). |
| `get_settings` | account:read | Your appearance settings plus the revision. |
| `update_settings` | account:write | Change your appearance settings (pass the revision). |
| `get_notification_prefs` | account:read | Your push notification preferences. |
| `update_notification_prefs` | account:write | Change your push notification preferences. |
| `get_system_status` | account:read | Latest situation report of the Mac watcher: traffic lights for Claude quota, Codex and disk, per source with `reportedAt` and the server time `now` (older than 30 minutes = stale). |
| `get_connection` | (none) | Describe this connection: client, name (chosen by the person), scopes, grant projects, expiry. No tokens. |
| `list_users` | admin:read | Administrators only: accounts, read-only. |
| `list_invitations` | admin:read | Administrators only: invitations without codes. |
| `list_reviews` | tasks:read | Reviews including decided ones, filter by project and status. |
| `list_progress_notes` | tasks:read | Progress notes of a task, newest first. |
| `list_agent_jobs` | runs:read | Local agent jobs in your granted projects. |
| `list_runner_devices` | runs:read | Your Mac runner devices, without tokens; with `capabilities` (reported, for example `sprache`), `disabledCapabilities` (switched off by the person) and `lastSeenAt`. |
| `start_agent_job` | runs:write | Class B: queue a job through an existing repository binding (`no_binding`, `device_required`). |
| `stop_agent_job` | runs:write | Cancel a job. |

Prompts: `setup_project`, `sync_project`, `session_start` (see "Project onboarding and keeping Todolino current").

Resources: `todo://manual` (this manual, Markdown), `todo://conventions` (JSON), and the template `todo://projects/{projectID}/structure`.

**Changed in 1.7.0:** chat per card. `list_comments` and `add_comment` take `questionID`/`reviewID` (the question or review must belong to the task); messages carry `authorKind`, `authorLabel`, `createdAt`, `questionID`, `reviewID`. No new scopes. Read new messages from people at the start of a session and after finishing a step.

**Scopes added in 1.6.0:** `labels:read`/`labels:write` and `filters:read`/`filters:write`. An existing connection does not get new scopes by itself: the person has to connect again and approve them. Labels and filters are private to the person; search and filter results only contain projects of this connection.

**Changed in 1.26.0:** voice jobs and runner capabilities (ADR 0030, step 3). `list_runner_devices` (and `GET /v1/agents/devices`) gain `capabilities`, `disabledCapabilities`, `lastSeenAt`; a `voice_in` message in #brain now creates a server-side voice job or an automatic `status` message (see the channel section); voice attachments may have no task (`taskID` absent, `contracts/attachments.yaml` 1.2.0). The runner API `/v1/runner/voice/*` is for the Mac runner with its device token and has no MCP tool. All additive.

**Changed in 1.25.0:** channel #brain. New tools `list_channel_messages` and `post_channel_message`, REST `GET`/`POST /v1/channels/brain/messages` (`contracts/voice.yaml` 1.0.0), new scopes `channels:read` and `channels:write`. An existing connection does not get new scopes by itself (no forced re-consent): it simply does not see the two tools until the person connects again and approves them. All else additive.

**Changed in 1.24.0:** decision journal. New tools `record_decision`, `list_decisions`, `review_decision` (existing scopes `tasks:read`/`tasks:write`), REST `/v1/tasks/{id}/decisions`, `/v1/decisions`, `/v1/decisions/{id}/review`; `get_daily_brief` gets the section `decisions` and `summary.decisionsToReview`, the `line` mentions open decisions (`N Entscheidungen zu prüfen`). All additive; a running client sees the new tools after `/mcp` reconnect.

**Changed in 1.23.0:** situation lights. New tool `get_system_status` (account:read, no new scope) and REST `GET /v1/system-status`; the watcher on the Mac reports with `PUT /v1/system-status[?source=name]` (runner device token or session, body = the watcher's status JSON; known fields `claude_ampel`, `platte_ampel` = gruen|gelb|rot, `claude_frei_fuer_brain`, `claude_nutzbare_konten`, `codex`, `platte_frei_gb`, `zeit` are validated, other fields are kept). The PWA shows the lights in the command center and refreshes live. All additive.

**Changed in 1.22.0:** when a task is set to `done` (`update_task`, REST, column move), its open non-runner reviews are withdrawn automatically (`state` `withdrawn`, `decisionNote` "Karte auf erledigt gesetzt", activity `review.withdrawn`); they no longer stay `pending`. Additive, no API change.

**Changed in 1.21.0:** agents may close their own proven-finished tasks (`update_task status=done`, after a `post_progress` with the proof). `request_review` stays for visible results, risk, rollout or decisions. No API change (the server always allowed it).

**Changed in 1.20.0:** note only. New MCP tools that arrive with a plugin or server update (for example `update_project`, `wait_for_events`) appear in a running session only after a `/mcp` reconnect (or a restart of the session). If a tool named here is missing, ask the person to reconnect.

**Changed in 1.19.0:** daily brief. New tool `get_daily_brief` (tasks:read, no new scope) and REST `GET /v1/daily-brief`; push category `daily_brief` (default off) and `dailyBriefHour` in the notification preferences (`get_notification_prefs`, `update_notification_prefs`, REST `/v1/me/push-prefs`). All additive.

**Changed in 1.18.0:** orphaned claims. `get_command_center` answers `summary.orphanedClaims` and each card has `orphaned` and `lastSignOfLifeAt`; `get_command_center {orphaned: true}` and `list_tasks {projectID, orphaned: true}` (REST `?orphaned=true`) keep only in-progress tasks whose claim has had no sign of life for more than 24 hours. Flag only: nothing is released automatically. `get_task_context.workflow` carries the same two fields. All additive; calls without the new parameter behave as before.

**Changed in 1.17.0:** several repository bindings per project. New tools `list_repository_bindings` (projects:read) and `unbind_repository` (tasks:write); optional `repository` on `record_sync` and `get_sync_status`; `get_sync_status` and `projects[].sync` add `bindings`, `get_stale_projects` adds `staleBindings`. `bind_repository` with a `repository` now adds a binding instead of replacing the old one and no longer resets its history. No new scopes. With one binding everything behaves as before; with several, pass `repository` (plugin 1.7.0 does it from `.todolino.json`).

**Changed in 1.16.0:** current project. `get_command_center`, `list_open_questions` and `list_pending_reviews` take `projectID` (the repository's project) and optional `scope` (`project` default, `account`). Answers carry `currentProject {id, name}`, a `hint` when no project was given or `scope=account`, and `foreignProject` on entries (only when `projectID` is set). `list_open_questions` and `list_pending_reviews` now answer an object `{currentProject, hint?, items}` instead of a bare array. Without `projectID` everything else is unchanged.

**Changed in 1.14.0:** connections get names (`get_connection.name`) and appear in the project share dialog. A call outside the grant still answers `not_found`; the person sees a notice in the app and can grant access there (ask them to do so).

**Changed in 1.13.0:** attachments for agents. `get_attachment_download` returns a 5-minute signed link, `claude-plugin/scripts/fetch-attachment.sh` saves it locally so you can Read the file. `read_attachment` previews only small images (`preview_unavailable` otherwise). `list_comments` returns `attachments` and chat entries of kind `attachment`.

**Changed in 1.12.0:** compact answers. `get_command_center` and `list_open_questions` answer compactly by default (`compact:false` returns the full shape; `status` and `fields` filter questions). Plugin notes: core tool select line, Codex wrapper reporting.

**Connections (unreleased, manual version not bumped):** your connection has a name the person chooses and can change (`get_connection.name`); it appears in the share dialog next to people and teams and in the activity feed. A project or task outside your grant still answers `not_found`, nothing more. If you need it, ask the person to grant access in the app: they see a notice "<connection name> wollte auf <project> zugreifen" in "Für dich" (only if they can read that project) and allow it with one click. Do not retry in a loop; repeated requests are only counted.

**Changed in 1.11.0:** stack 7. New scopes `runs:read`, `runs:write` (reconnect to get them). `list_reviews`, `list_progress_notes`, agent job and runner device tools.

**Changed in 1.10.0:** stack 8. New scopes `account:read`, `account:write`, `admin:read` (reconnect to get them). Settings, notification preferences, `get_connection`, read-only admin lists. No notification inbox tools: the feed is derived.

**Changed in 1.9.0:** stack 6. Board tools: `update_column`, `apply_column_template`, `reorder_tasks`, favorites and per-project display settings. Existing scopes only. Deleting a column stays a confirmation request (`delete_column`).

**Changed in 1.8.0:** stacks 4 and 5. New scopes `sharing:read`/`sharing:write` and `teams:read`/`teams:write` (an existing connection must be reconnected to get them). `update_comment` only edits agent messages, not texts of people (`not_agent_comment`). Sharing never widens this connection: a share that reaches sub-projects outside the connection becomes a confirmation request.

**Class C tools** (deleting or irreversible actions: `delete_comment`, `delete_project_comment`, `delete_attachment`, `revoke_project_grant`, `delete_project`, `delete_task`, `delete_column`, `delete_criterion`, `delete_milestone`, `delete_label`, `delete_filter`, `transfer_project_owner`) never act directly. They answer `confirmation_required` with an action request ID; the person confirms in the app. Do not repeat the call; read the result with `get_action_request` or wait with `wait_for_events`.

## Errors and retries

- `repository_already_bound`: another project of the same owner already has this repository; use `find_project_by_repository`.
- `repository_required`: the project has several bindings; pass `repository` (the error lists the keys).
- `too_many_bindings`: a project has at most 10 repository bindings; `unbind_repository` one first.
- `not_bound`: `record_sync` needs a repository binding (call `bind_repository`), or the named `repository` is not bound to this project.
- `insufficient_scope`: your connection lacks the OAuth scope. Tell the user which scope the tool needs.
- `confirmation_required`: not a failure; the action waits for the user (see "Large actions need confirmation"). Do not repeat the call.
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
