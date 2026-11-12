import Fluent
import Vapor

extension MCPController {
    static let taskIDField = Schema.uuid("Task id.")
    static let agentNameField = Schema.string("Optional name of this agent shown on the board (for example 'claude-code@build-mac', up to 100 characters).", maxLength: 100)
    static let optionalProject = Schema.uuid("Optional project id. Omit for all granted projects.")
    static let currentProjectID = Schema.uuid("The CURRENT project (projectID from .todolino.json). Strongly recommended: the answer then names it as currentProject and is limited to it (and its sub-projects). Without it the answer covers all projects of the account and carries a hint.")
    static let accountScope = Schema.string("With projectID: project (default) filters to the current project; account keeps all projects but marks entries of other projects with foreignProject=true (never work on those).", values: ["project", "account"])

    /// Command-center and workflow tools (ADR 0014).
    static let workflowTools: [Tool] = [
        Tool(name: "get_manual", scope: "",
             description: "FIRST CALL of every session. Returns the versioned usage manual for agents (concepts, recommended workflow, board column conventions, question/review/progress/screenshot rules, tool reference, examples) plus machine-readable conventions. Pass a section id to fetch only one part.",
             properties: ["section": Schema.string("Optional section id such as 'recommended-workflow' or 'board-columns'; omit for the whole manual.")]),
        Tool(name: "get_project_structure", scope: "projects:read",
             description: "Per-project agent briefing: description, the user-written agent brief (goals, constraints, definition of done, agent rules), board columns with their workflow roles, whether the standard agent workflow columns exist, task counts and the always-valid rules. Call it before starting work in a project; the brief overrides your defaults.",
             properties: ["projectID": Schema.uuid("Project id.")], required: ["projectID"]),
        Tool(name: "get_command_center", scope: "tasks:read",
             description: "The overview ('Steuerzentrale') as kanban lanes (running, question, review, ready, blocked, done) with cards (task, project, progress percent, agent, open questions, pending review, latest note, build screenshots, due date), summary counters (overdue counts all visible unfinished tasks with planning.dueAt before server time, including subtasks/backlog), card dueDate (own planning.dueAt) and nextDue (earliest unfinished own/subtask dueAt), the latest updates and build groups. Pass projectID (current project): the answer names currentProject and is limited to it; without it all account projects are shown with a hint, with scope=account foreign entries carry foreignProject=true. Use it to see what is open, what waits for a person and what you can start. view=list returns the same cards flat with filters and sorting.",
             properties: [
                "projectID": currentProjectID, "scope": accountScope,
                "includeSubprojects": Schema.boolean("With projectID: include nested sub-projects (default true)."),
                "view": Schema.string("kanban (default, lanes) or list (flat cards).", values: ["kanban", "list"]),
                "lane": Schema.string("Comma-separated lane keys to keep: running,question,review,ready,blocked,done."),
                "kind": Schema.string("Only tasks of this kind.", values: ["task", "feature"]),
                "hasQuestion": Schema.boolean("Only cards with (true) or without (false) open questions."),
                "orphaned": Schema.boolean("Only cards with (true) or without (false) an orphaned claim: in progress, claimed, no sign of life for over 24 hours (summary.orphanedClaims counts them)."),
                "includeSubtasks": Schema.boolean("List view: also list subtasks as their own cards."),
                "sort": Schema.string("attention (default), updated, due, progress or title.", values: ["attention", "updated", "due", "progress", "title"]),
                "doneWithinDays": Schema.integer("How long finished tasks stay in the done lane (default 7).", min: 1, max: 365),
                "laneLimit": Schema.integer("Kanban: maximum cards per lane (default 50); lane.count has the total.", min: 1, max: 200),
                "updatesLimit": Schema.integer("Number of latest updates (default 5 compact, 20 with compact=false, 0 = none).", min: 0, max: 50),
                "compact": Schema.boolean("Default true: small answer (subtasks and builds as counts only, short texts, laneLimit 10, 5 updates, list limit 20, no build groups). false returns the full detail."),
                "fields": Schema.string("Comma-separated card fields to keep (task is always kept), e.g. 'lane,openQuestionCount,latestUpdate'."),
                "limit": Schema.integer("List view: page size (default 50).", min: 1, max: 200),
                "offset": Schema.integer("List view: number of cards to skip.", min: 0)]),
        Tool(name: "get_daily_brief", scope: "tasks:read",
             description: "Daily brief ('Tagesbericht'): what waits for the person (open questions, pending reviews, confirmation requests), orphaned claims, stale projects, what runs and what got done since a date, as short sections with counts and up to 5 items each (id, title, projectID; truncated=true when the list was shortened, counts are always exact). format=line returns only one German line of at most 200 characters, ideal for a status line. Without projectID all readable projects of this connection are covered; sub-projects are included. Default since: start of yesterday (UTC).",
             properties: ["projectID": Schema.uuid("Optional: only this project and its sub-projects."),
                          "since": Schema.string("ISO 8601 date-time or date (YYYY-MM-DD, UTC); tasks done since then count as done. Default: start of yesterday UTC.", maxLength: 40),
                          "format": Schema.string("full (default, sections) or line (one short line).", values: ["full", "line"])]),
        Tool(name: "get_task_context", scope: "tasks:read",
             description: "Everything about one task in one call: task, workflow state (kind, parent, blocked reason, claimed by), progress rollup, progress notes, acceptance criteria, subtasks, comments, questions with answers, the latest review (state, decision note) and build screenshots. Use it to resume work and to read review feedback or answers.",
             properties: ["taskID": taskIDField], required: ["taskID"]),
        Tool(name: "claim_task", scope: "tasks:write",
             description: "Start working on a task: sets status in_progress, records you as the worker and moves the card to the 'In Arbeit' column if the project has one. Fails with already_claimed if another agent claimed it (pass takeOver=true only with a good reason). Idempotent for the same agent.",
             properties: ["taskID": taskIDField, "agentName": agentNameField,
                          "takeOver": Schema.boolean("Take the task over from another agent (default false).")],
             required: ["taskID"]),
        Tool(name: "release_task", scope: "tasks:write",
             description: "Give a claimed task back: clears the worker, sets status open and moves the card to 'Bereit'. Explain why in a progress note. Fails with claimed_by_other unless force=true.",
             properties: ["taskID": taskIDField, "force": Schema.boolean("Release a claim held by another agent (default false).")],
             required: ["taskID"]),
        Tool(name: "post_progress", scope: "tasks:write",
             description: "Post a short, factual progress note on a task (what is done, what is next), optionally with a percent. The note appears on the overview card and in the update feed. The percent is used for the progress bar when the task has neither subtasks nor criteria.",
             properties: ["taskID": taskIDField,
                          "note": Schema.string("Progress text, 1 to 4000 characters.", maxLength: 4000),
                          "percent": Schema.integer("Optional overall completion estimate 0 to 100.", min: 0, max: 100),
                          "agentName": agentNameField],
             required: ["taskID", "note"]),
        Tool(name: "record_decision", scope: "tasks:write",
             description: "Journal a decision you took on your own (especially overnight or without asking): what you decided, why, the criterion it is measured by and where to roll it back (commit hash or branch). The person reviews these in the morning (get_daily_brief section decisions) instead of reading code. Only decisions that are reversible, non-destructive and local; otherwise ask_question.",
             properties: ["taskID": taskIDField,
                          "decision": Schema.string("What was decided, 1 to 2000 characters.", maxLength: 2000),
                          "rationale": Schema.string("Why, 1 to 2000 characters.", maxLength: 2000),
                          "criterion": Schema.string("Checkable criterion the person can judge it by, 1 to 2000 characters.", maxLength: 2000),
                          "rollbackRef": Schema.string("Commit hash or branch that undoes or contains the decision (up to 200 characters, no spaces). Omit if nothing changed in code.", maxLength: 200),
                          "agentName": agentNameField],
             required: ["taskID", "decision", "rationale", "criterion"]),
        Tool(name: "list_decisions", scope: "tasks:read",
             description: "List journal decisions (newest first) of the readable scope: id, task, decision, rationale, criterion, rollbackRef, state (open, ok, rolled_back), reviewNote. Use state=rolled_back with query to find precedents (decisions the person took back, with the reason) before you decide something similar.",
             properties: ["projectID": Schema.uuid("Optional: only this project and its sub-projects."),
                          "taskID": Schema.uuid("Optional: only this task."),
                          "since": Schema.string("ISO 8601 date-time or date (YYYY-MM-DD, UTC).", maxLength: 40),
                          "state": Schema.string("open, ok, rolled_back or all (default).", values: ["open", "ok", "rolled_back", "all"]),
                          "query": Schema.string("Case-insensitive text search in decision, rationale, criterion and review note.", maxLength: 200),
                          "limit": Schema.integer("Maximum entries (default 50).", min: 1, max: 200)]),
        Tool(name: "review_decision", scope: "tasks:write",
             description: "Mark a journal decision on behalf of the user steering you: verdict ok, or rollback with a reason (note required; it stays retrievable as precedent). It only marks the decision; undoing the change (git) is separate. Refused for decisions recorded by this same connection (cannot_review_own_decision).",
             properties: ["decisionID": Schema.uuid("Decision id (from list_decisions)."),
                          "verdict": Schema.string("ok or rollback.", values: ["ok", "rollback"]),
                          "note": Schema.string("Reason, required for rollback (up to 4000 characters).", maxLength: 4000)],
             required: ["decisionID", "verdict"]),
        Tool(name: "set_task_structure", scope: "tasks:write",
             description: "Structure a task: mark it a feature (kind=feature), attach it to a parent feature as a subtask (parentTaskID, same project, depth at most 2; null detaches) or set/clear a blocked reason (null or empty clears). Only the fields you pass change. Features show percent progress rolled up from their subtasks.",
             properties: ["taskID": taskIDField,
                          "kind": Schema.string("task or feature.", values: ["task", "feature"]),
                          "parentTaskID": Schema.nullable("string", "Parent feature id in the same project, or null to detach."),
                          "blockedReason": Schema.nullable("string", "Why the task is blocked (up to 1000 characters), or null to unblock.")],
             required: ["taskID"]),
        Tool(name: "add_criterion", scope: "tasks:write",
             description: "Add an acceptance criterion (a checkable definition-of-done item) to a task. Completed criteria drive the task's progress percent when it has no subtasks.",
             properties: ["taskID": taskIDField, "text": Schema.string("Criterion text, 1 to 2000 characters.", maxLength: 2000)],
             required: ["taskID", "text"]),
        Tool(name: "set_criterion", scope: "tasks:write",
             description: "Tick or untick an acceptance criterion (ids are in get_task_context).",
             properties: ["criterionID": Schema.uuid("Criterion id."), "completed": Schema.boolean("New completed state.")],
             required: ["criterionID", "completed"]),
        Tool(name: "ask_question", scope: "tasks:write",
             description: "Ask the user a structured question on a task instead of guessing. The question appears in the overview ('Frage offen') and the card moves to the 'Frage offen' column. Give 2 to 4 concrete options and put your recommendation first. Continue with other work; poll get_question for the answer. Use idempotencyKey so a retry does not create a duplicate.",
             properties: ["taskID": taskIDField,
                          "prompt": Schema.string("The question, 1 to 4000 characters. State the situation briefly.", maxLength: 4000),
                          "options": Schema.stringArray("Optional answer options (up to 20, each up to 500 characters). If present the answer must be one of them.", maxItems: 20),
                          "blocking": Schema.boolean("True (default) if you cannot continue this task without the answer."),
                          "agentName": agentNameField,
                          "idempotencyKey": Schema.string("Optional retry key; the same key with the same prompt returns the existing question.", maxLength: 200)],
             required: ["taskID", "prompt"]),
        Tool(name: "list_open_questions", scope: "tasks:read",
             description: "List open questions (pass projectID = current project; the answer is {currentProject, hint?, items}, items of other projects carry foreignProject=true with scope=account), newest first, each with options, who asked and the task/project it belongs to. includeAnswered=true also returns answered ones with their answer. Includes questions asked by local runner jobs.",
             properties: ["projectID": currentProjectID, "scope": accountScope,
                          "taskID": Schema.uuid("Optional: only questions of this task."),
                          "includeAnswered": Schema.boolean("Also return answered questions (default false)."),
                          "status": Schema.string("open (default), answered or all; overrides includeAnswered.", values: ["open", "answered", "all"]),
                          "compact": Schema.boolean("Default true: leaves out internal ids and versions. false returns every field."),
                          "fields": Schema.string("Comma-separated question fields to keep (id is always kept), e.g. 'id,taskID,prompt,options'."),
                          "limit": Schema.integer("Maximum number of questions (default 50 compact, 100 with compact=false).", min: 1, max: 200)]),
        Tool(name: "get_question", scope: "tasks:read",
             description: "Read one question: state open|answered|withdrawn, the answer, who answered and when. Poll this to find out whether your question was answered.",
             properties: ["questionID": Schema.uuid("Question id.")], required: ["questionID"]),
        Tool(name: "answer_question", scope: "tasks:write",
             description: "Answer a question on behalf of the user who is steering you in conversation. Refused for questions asked by this same connection (cannot_answer_own_question): the person decides, not the asking agent. Normally people answer in the app.",
             properties: ["questionID": Schema.uuid("Question id."), "answer": Schema.string("The answer text; must equal one of the options if the question has options.", maxLength: 4000)],
             required: ["questionID", "answer"]),
        Tool(name: "request_review", scope: "tasks:write",
             description: "Ask a person to review finished work: sets the task to in_review, moves it to the 'Review' column and shows it as 'Review fällig' on the overview. Summarise what changed, how you verified it and what to look at. Attach build screenshots first. Only for a visible result, risk, rollout or decision; proven-finished work with nothing to check is closed with update_task status=done after a post_progress with the proof.",
             properties: ["taskID": taskIDField,
                          "summary": Schema.string("Review summary, 1 to 4000 characters.", maxLength: 4000),
                          "reviewerID": Schema.uuid("Optional user id of the person who must review (must be able to read the project)."),
                          "agentName": agentNameField],
             required: ["taskID", "summary"]),
        Tool(name: "list_pending_reviews", scope: "tasks:read",
             description: "List pending review requests (pass projectID = current project; the answer is {currentProject, hint?, items}, other projects only with scope=account and foreignProject=true): task, project, summary, who requested, optional named reviewer. Includes reviews of local runner jobs.",
             properties: ["projectID": currentProjectID, "scope": accountScope]),
        Tool(name: "decide_review", scope: "tasks:write",
             description: "Accept or request changes on a pending review on behalf of the user steering you. accept marks the task done; request_changes returns it to in_progress with your note. Refused for reviews requested by this same connection (cannot_decide_own_review).",
             properties: ["taskID": taskIDField,
                          "decision": Schema.string("accept or request_changes.", values: ["accept", "request_changes"]),
                          "note": Schema.string("Optional note, required in practice for request_changes (up to 4000 characters).", maxLength: 4000)],
             required: ["taskID", "decision"]),
        Tool(name: "apply_agent_workflow_columns", scope: "tasks:write",
             description: "Create the standard agent workflow columns (Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt) on a project that has no own columns; existing tasks are placed by status. Fails with columns_exist otherwise. Ask the user before changing a project's board.",
             properties: ["projectID": Schema.uuid("Project id.")], required: ["projectID"]),
        Tool(name: "add_attachment", scope: "attachments:write",
             description: "Upload a build screenshot (or PDF) to a task in one call and register it as a build artifact. Use the same buildID for all screenshots of one build and set the platform. Up to 5 MiB of raw data; use begin_attachment/complete_attachment for larger files. PNG, JPEG, WebP or PDF only; no secrets in screenshots.",
             properties: ["taskID": taskIDField,
                          "filename": Schema.string("File name without path separators, up to 200 characters.", maxLength: 200),
                          "mediaType": Schema.string("MIME type of the file.", values: ["image/png", "image/jpeg", "image/webp", "application/pdf"]),
                          "dataBase64": Schema.string("File content, standard base64."),
                          "buildID": Schema.string("Identifier of the build the screenshot belongs to, 1 to 100 characters (for example a version or commit).", maxLength: 100),
                          "label": Schema.string("Optional caption such as 'Login screen', up to 200 characters.", maxLength: 200),
                          "platform": Schema.string("Optional platform such as ios, macos, watchos, web, android; up to 50 characters.", maxLength: 50)],
             required: ["taskID", "filename", "mediaType", "dataBase64", "buildID"]),
        Tool(name: "begin_attachment", scope: "attachments:write",
             description: "Start a large upload (up to the instance limit, default 10 MiB). Returns attachmentID, an absolute uploadURL and a one-time token: send the bytes with PUT to uploadURL with 'Authorization: Bearer <token>' and the matching Content-Type, then call complete_attachment. The file is only visible after completion.",
             properties: ["taskID": taskIDField,
                          "filename": Schema.string("File name without path separators.", maxLength: 200),
                          "mediaType": Schema.string("MIME type of the file.", values: ["image/png", "image/jpeg", "image/webp", "application/pdf"]),
                          "size": Schema.integer("Exact size in bytes.", min: 1),
                          "checksum": Schema.string("SHA-256 of the file as 64 lowercase hex characters."),
                          "buildID": Schema.string("Identifier of the build, 1 to 100 characters.", maxLength: 100),
                          "label": Schema.string("Optional caption.", maxLength: 200),
                          "platform": Schema.string("Optional platform such as ios, macos, web.", maxLength: 50)],
             required: ["taskID", "filename", "mediaType", "size", "checksum", "buildID"]),
        Tool(name: "complete_attachment", scope: "attachments:write",
             description: "Finish a large upload started with begin_attachment after the PUT succeeded. Verifies size, type and checksum and makes the screenshot visible on the board.",
             properties: ["attachmentID": Schema.uuid("attachmentID returned by begin_attachment.")], required: ["attachmentID"]),
        Tool(name: "list_builds", scope: "attachments:read",
             description: "List the build artifacts (screenshots with buildID, label, platform, previewURL) of a task, newest first.",
             properties: ["taskID": taskIDField], required: ["taskID"]),
    ]

    // MARK: Argument helpers

    func optionalString(_ a: JSONValue, _ key: String) throws -> String? {
        if a[key].isNull { return nil }
        guard let s = a[key].string else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return s
    }
    func requiredString(_ a: JSONValue, _ key: String) throws -> String {
        guard let s = a[key].string else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return s
    }
    func optionalBool(_ a: JSONValue, _ key: String) throws -> Bool? {
        if a[key].isNull { return nil }
        guard case .bool(let b) = a[key] else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return b
    }
    func requiredBool(_ a: JSONValue, _ key: String) throws -> Bool {
        guard let b = try optionalBool(a, key) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return b
    }
    func optionalUUID(_ a: JSONValue, _ key: String) throws -> UUID? {
        if a[key].isNull { return nil }
        guard let s = a[key].string, let id = UUID(uuidString: s) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return id
    }

    func workflowService(user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) -> WorkflowService {
        WorkflowService(user: user, db: db, allowedProjects: Set(grant.projects), attachments: { CommandCenterAttachments.service(settings: settings) })
    }

    func actor(grant: OAuthGrant, db: any Database) async throws -> WorkflowActor {
        let client = try await OAuthClient.find(grant.clientID, on: db)
        return .integration(grantID: try grant.requireID(), label: client?.name)
    }

    /// Dispatch for the tools of `workflowTools`.
    func callWorkflow(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) async throws -> JSONValue {
        if name == "get_manual" {
            return try .encoded(try AgentManual.response(section: try optionalString(a, "section")))
        }
        let service = workflowService(user: user, grant: grant, db: db, settings: settings)
        let actor = try await self.actor(grant: grant, db: db)
        switch name {
        case "get_project_structure":
            return try .encoded(try await service.structure(uuid(a["projectID"])))
        case "get_command_center":
            let compact = try optionalBool(a, "compact") ?? true
            let fields = try MCPCompact.fields(optionalString(a, "fields"), allowed: MCPCompact.cardFields)
            var raw: [String: String] = [:]
            for key in ["includeSubprojects", "view", "lane", "kind", "hasQuestion", "orphaned", "includeSubtasks", "sort", "doneWithinDays",
                        "laneLimit", "updatesLimit", "limit", "offset"] where !a[key].isNull {
                switch a[key] {
                case .string(let s): raw[key] = s
                case .bool(let b): raw[key] = b ? "true" : "false"
                case .number: raw[key] = String(try intArgument(a[key], reason: "invalid_\(key)") ?? 0)
                default: throw Abort(.badRequest, reason: "invalid_\(key)")
                }
            }
            if compact {
                if raw["laneLimit"] == nil { raw["laneLimit"] = String(MCPCompact.compactLaneLimit) }
                if raw["updatesLimit"] == nil { raw["updatesLimit"] = String(MCPCompact.compactUpdatesLimit) }
                if raw["limit"] == nil { raw["limit"] = String(MCPCompact.compactListLimit) }
            }
            let context = try await MCPProjectContext.resolve(projectID: optionalUUID(a, "projectID"), scope: optionalString(a, "scope"),
                user: user, db: db, allowed: Set(grant.projects))
            let filter = context.filterProjectID
            let query = try CommandCenterQuery(scope: filter == nil ? "account" : "project", projectID: filter?.uuidString, raw: raw)
            let response = try await CommandCenterService(user: user, db: db, allowedProjects: Set(grant.projects)).build(query)
            let marked = context.markCards(try .encoded(response))
            return context.decorate(MCPCompact.commandCenter(marked, compact: compact, fields: fields))
        case "get_daily_brief":
            let brief = DailyBriefService(user: user, db: db, allowedProjects: Set(grant.projects))
            return try .encoded(try await brief.build(projectID: optionalUUID(a, "projectID"),
                since: DailyBriefService.parseSince(optionalString(a, "since")), format: DailyBriefService.parseFormat(optionalString(a, "format"))))
        case "get_task_context":
            return try .encoded(try await service.context(uuid(a["taskID"])))
        case "claim_task":
            return try .encoded(try await service.claim(uuid(a["taskID"]), agentName: optionalString(a, "agentName"),
                takeOver: optionalBool(a, "takeOver") ?? false, actor: actor))
        case "release_task":
            return try .encoded(try await service.release(uuid(a["taskID"]), force: optionalBool(a, "force") ?? false, actor: actor))
        case "post_progress":
            return try .encoded(try await service.postProgress(uuid(a["taskID"]), note: requiredString(a, "note"),
                percent: intArgument(a["percent"], reason: "invalid_percent"), label: optionalString(a, "agentName"), actor: actor))
        case "record_decision":
            let body = RecordDecisionRequest(decision: try requiredString(a, "decision"), rationale: try requiredString(a, "rationale"),
                criterion: try requiredString(a, "criterion"), rollbackRef: try optionalString(a, "rollbackRef"), agentName: try optionalString(a, "agentName"))
            return try .encoded(try await service.recordDecision(uuid(a["taskID"]), body, actor: actor))
        case "list_decisions":
            let state = try optionalString(a, "state") ?? "all"
            let limit = try intArgument(a["limit"], reason: "invalid_limit") ?? 50
            let since = try DailyBriefService.parseSince(optionalString(a, "since"))
            let list = try await service.decisions(projectID: optionalUUID(a, "projectID"), taskID: optionalUUID(a, "taskID"),
                since: since, state: state, query: optionalString(a, "query"), limit: limit)
            return try .encoded(list)
        case "review_decision":
            let verdict = DecisionVerdictRequest(verdict: try requiredString(a, "verdict"), note: try optionalString(a, "note"))
            return try .encoded(try await service.reviewDecision(uuid(a["decisionID"]), verdict, actor: actor))
        case "set_task_structure":
            guard case .object(let fields) = a else { throw Abort(.badRequest, reason: "invalid_arguments") }
            var parent: UUID??
            if fields["parentTaskID"] != nil { parent = .some(try optionalUUID(a, "parentTaskID")) }
            var blocked: String??
            if fields["blockedReason"] != nil { blocked = .some(try optionalString(a, "blockedReason")) }
            let body = StructureRequest(kind: try optionalString(a, "kind"), parentTaskID: parent, blockedReason: blocked)
            return try .encoded(try await service.setStructure(uuid(a["taskID"]), body, actor: actor))
        case "add_criterion":
            return try .encoded(try await service.addCriterion(uuid(a["taskID"]), text: requiredString(a, "text"), actor: actor))
        case "set_criterion":
            return try .encoded(try await service.setCriterion(uuid(a["criterionID"]), completed: requiredBool(a, "completed"), actor: actor))
        case "ask_question":
            var options: [String]?
            if !a["options"].isNull {
                guard case .array(let items) = a["options"] else { throw Abort(.badRequest, reason: "invalid_option") }
                options = try items.map { guard let s = $0.string else { throw Abort(.badRequest, reason: "invalid_option") }; return s }
            }
            let body = AskQuestionRequest(prompt: try requiredString(a, "prompt"), options: options, blocking: try optionalBool(a, "blocking"),
                agentName: try optionalString(a, "agentName"), idempotencyKey: try optionalString(a, "idempotencyKey"))
            return try .encoded(try await service.ask(uuid(a["taskID"]), body, actor: actor))
        case "list_open_questions":
            let all = try optionalBool(a, "includeAnswered") ?? false
            let compact = try optionalBool(a, "compact") ?? true
            let fields = try MCPCompact.fields(optionalString(a, "fields"), allowed: MCPCompact.questionFields)
            let state = try optionalString(a, "status") ?? (all ? "all" : "open")
            guard ["open", "answered", "all"].contains(state) else { throw Abort(.badRequest, reason: "invalid_status") }
            let context = try await MCPProjectContext.resolve(projectID: optionalUUID(a, "projectID"), scope: optionalString(a, "scope"),
                user: user, db: db, allowed: Set(grant.projects))
            let rows = try await service.questions(projectID: context.filterProjectID, taskID: optionalUUID(a, "taskID"),
                state: state, limit: intArgument(a["limit"], reason: "invalid_limit") ?? (compact ? 50 : 100))
            return context.wrap(items: MCPCompact.questions(context.markRows(try .encoded(rows)), compact: compact, fields: fields))
        case "get_question":
            return try .encoded(try await service.question(uuid(a["questionID"])))
        case "answer_question":
            return try .encoded(try await service.answer(uuid(a["questionID"]), value: requiredString(a, "answer"), actor: actor))
        case "request_review":
            let body = RequestReviewRequest(summary: try requiredString(a, "summary"), reviewerID: try optionalUUID(a, "reviewerID"),
                agentName: try optionalString(a, "agentName"))
            return try .encoded(try await service.requestReview(uuid(a["taskID"]), body, actor: actor))
        case "list_pending_reviews":
            let context = try await MCPProjectContext.resolve(projectID: optionalUUID(a, "projectID"), scope: optionalString(a, "scope"),
                user: user, db: db, allowed: Set(grant.projects))
            return context.wrap(items: context.markRows(try .encoded(try await service.reviews(projectID: context.filterProjectID, state: "pending"))))
        case "decide_review":
            return try .encoded(try await service.decideReview(uuid(a["taskID"]), decision: requiredString(a, "decision"),
                note: optionalString(a, "note"), actor: actor))
        case "apply_agent_workflow_columns":
            let projectID = try uuid(a["projectID"])
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                _ = try await self.project(projectID, user: user, grant: grant, db: tx, role: .edit)
                let created = try await ColumnService(user: user, db: tx).applyTemplate(projectID, source: "agent_workflow")
                return try .encoded(try created.map(ColumnDTO.init))
            }
        case "add_attachment":
            return try .encoded(try await service.addInline(taskID: uuid(a["taskID"]), filename: requiredString(a, "filename"),
                mediaType: requiredString(a, "mediaType"), base64: requiredString(a, "dataBase64"), buildID: requiredString(a, "buildID"),
                label: optionalString(a, "label"), platform: optionalString(a, "platform"), actor: actor))
        case "begin_attachment":
            guard let size = try intArgument(a["size"], reason: "invalid_size") else { throw Abort(.badRequest, reason: "invalid_size") }
            let (capability, artifact) = try await service.beginBuild(taskID: uuid(a["taskID"]), filename: requiredString(a, "filename"),
                mediaType: requiredString(a, "mediaType"), size: size, checksum: requiredString(a, "checksum"),
                buildID: requiredString(a, "buildID"), label: optionalString(a, "label"), platform: optionalString(a, "platform"), actor: actor)
            return .object(["attachmentID": .string(capability.attachmentID.uuidString),
                "uploadURL": .string(settings.oauthIssuer + capability.uploadURL), "method": .string("PUT"),
                "token": .string(capability.token), "expiresAt": try .encoded(capability.expiresAt),
                "buildID": .string(artifact.buildID)])
        case "complete_attachment":
            return try .encoded(try await service.completeBuild(attachmentID: uuid(a["attachmentID"]), actor: actor))
        case "list_builds":
            return try .encoded(try await service.builds(taskID: uuid(a["taskID"])))
        default: return try await callSync(name, a, user: user, grant: grant, db: db, settings: settings, actor: actor)
        }
    }

    // MARK: Resources

    static let manualURI = "todo://manual"
    static let conventionsURI = "todo://conventions"

    static let resources: JSONValue = .array([
        .object(["uri": .string(manualURI), "name": .string("Todo agent manual"), "mimeType": .string("text/markdown"),
                 "description": .string("Versioned usage manual for agents: concepts, workflow, conventions, tool reference.")]),
        .object(["uri": .string(conventionsURI), "name": .string("Todo conventions"), "mimeType": .string("application/json"),
                 "description": .string("Machine-readable conventions: lanes, column template, states, limits, tools.")]),
    ])

    static let resourceTemplates: JSONValue = .array([
        .object(["uriTemplate": .string("todo://projects/{projectID}/structure"), "name": .string("Project structure and agent brief"),
                 "mimeType": .string("application/json"),
                 "description": .string("Agent brief, board columns and counts of one project (needs projects:read).")]),
    ])

    func readResource(uri: String, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) async throws -> JSONValue {
        func contents(_ mime: String, _ text: String) -> JSONValue {
            .object(["contents": .array([.object(["uri": .string(uri), "mimeType": .string(mime), "text": .string(text)])])])
        }
        if uri == Self.manualURI { return contents("text/markdown", AgentManual.markdown) }
        if uri == Self.conventionsURI {
            return contents("application/json", String(decoding: try JSONEncoder().encode(AgentManual.conventions), as: UTF8.self))
        }
        let prefix = "todo://projects/", suffix = "/structure"
        if uri.hasPrefix(prefix), uri.hasSuffix(suffix), let id = UUID(uuidString: String(uri.dropFirst(prefix.count).dropLast(suffix.count))) {
            guard grant.scopes.contains("projects:read") else { throw Abort(.forbidden, reason: "insufficient_scope") }
            let dto = try await workflowService(user: user, grant: grant, db: db, settings: settings).structure(id)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return contents("application/json", String(decoding: try encoder.encode(dto), as: UTF8.self))
        }
        throw Abort(.notFound, reason: "resource_not_found")
    }
}
