import Vapor

/// MCP prompts (`prompts/list`, `prompts/get`). Claude Code shows them as `/mcp__<server name>__<prompt name>`.
/// They only carry instructions for the agent; all data access still goes through the scoped tools.
enum MCPPrompts {
    struct Definition {
        let name: String
        let title: String
        let description: String
        let arguments: [(name: String, description: String)]
    }

    static let definitions: [Definition] = [
        Definition(name: "setup_project", title: "Set up this repository in Todolino",
                   description: "Analyse the current repository and create or link its Todolino project: columns, agent brief, features, tasks, criteria, questions and progress, idempotently. Writes the .todolino.json marker and a short CLAUDE.md section.",
                   arguments: [("name", "Optional project name (default: derived from the repository)."),
                               ("description", "Optional one-sentence project description."),
                               ("parent", "Optional name or id of an existing parent project.")]),
        Definition(name: "sync_project", title: "Reconcile this repository with Todolino",
                   description: "Compare the repository (plan files, git log) with the Todolino board and bring the board up to date; then record the sync.",
                   arguments: [("projectID", "Optional project id (default: from .todolino.json or find_project_by_repository).")]),
        Definition(name: "session_start", title: "Todolino session briefing",
                   description: "Short briefing at the start of a session: sync state, open questions, reviews, what is running, blocked and ready, and what to do next.",
                   arguments: [("projectID", "Optional project id (default: from .todolino.json or find_project_by_repository).")]),
    ]

    static var list: JSONValue {
        .array(definitions.map { d in
            .object(["name": .string(d.name), "title": .string(d.title), "description": .string(d.description),
                     "arguments": .array(d.arguments.map { .object(["name": .string($0.name), "description": .string($0.description), "required": .bool(false)]) })])
        })
    }

    /// Returns the `prompts/get` result, or nil for an unknown prompt or invalid arguments.
    static func get(_ name: String, arguments: JSONValue, origin: String) -> JSONValue? {
        guard let definition = definitions.first(where: { $0.name == name }) else { return nil }
        var values: [String: String] = [:]
        if case .object(let fields) = arguments {
            for (key, value) in fields {
                guard definition.arguments.contains(where: { $0.name == key }), let s = value.string, s.count <= 500,
                      !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
                values[key] = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if !arguments.isNull { return nil }
        let text: String
        switch name {
        case "setup_project": text = setupText(values, origin: origin)
        case "sync_project": text = syncText(values)
        default: text = sessionText(values)
        }
        return .object(["description": .string(definition.description),
                        "messages": .array([.object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string(text)])])])])
    }

    private static func quoted(_ s: String?) -> String { s.flatMap { $0.isEmpty ? nil : "\"\($0)\"" } ?? "(not given)" }

    static let markerBegin = "<!-- todolino:begin -->"
    static let markerEnd = "<!-- todolino:end -->"

    /// Section the agent writes into the repository's CLAUDE.md or AGENTS.md (kept in sync with docs/CLAUDE-CODE-EINRICHTUNG.md).
    static let repoSection = """
    \(markerBegin)
    ## Todolino

    This project is tracked in Todolino (project id in `.todolino.json`). Todolino must stay current:
    - Session start: run `/mcp__todolino__session_start` (or call `get_sync_status` and `get_command_center`).
    - While working: `claim_task`, `post_progress` after each meaningful step, `ask_question` instead of guessing, `request_review` when done.
    - Session end: update statuses and call `record_sync`. A task is not done until Todolino reflects it.
    - If the board looks stale (`get_sync_status`), run `/mcp__todolino__sync_project` first.
    \(markerEnd)
    """

    static func setupText(_ v: [String: String], origin: String) -> String {
        """
        Set up the repository in the current working directory in Todolino (server \(origin)). Work step by step, keep it idempotent, and never create a second project for a repository that already has one.

        Inputs: project name \(quoted(v["name"])); description \(quoted(v["description"])); parent project \(quoted(v["parent"])).

        1. Call `get_manual` once and read the section "Project onboarding and keeping Todolino current".
        2. Identify the repository: `git remote get-url origin` (drop credentials if any); without a remote use a free key such as `local/<directory name>`. Check for an existing `.todolino.json` in the repository root.
        3. Call `find_project_by_repository {repository}`. If it finds exactly one project (or `.todolino.json` names one you can read with `get_project_structure`), DO NOT create a project: continue with the steps of the prompt `sync_project` instead. If `outsideGrant` > 0, stop and tell the user to reconnect Todolino (/mcp) and include that project. If several match, ask the user which one.
        4. Analyse the repository read-only: README, AGENTS.md / CLAUDE.md, docs/, plan and todo files (ARBEITSPLAN, TODO, ROADMAP, STATUS, CHANGELOG), lists of open issues kept in files, and `git log --oneline -50`. Do not read or copy secrets (.env, keys, tokens) into Todolino.
        5. Derive a plan: features with subtasks, standalone tasks, acceptance criteria, finished work (status done), blocked work with a reason, open decisions (as questions). Give every item a stable `externalKey` derived from its source (for example `docs/ARBEITSPLAN.md#phase-2-login`). Prefer few meaningful features over hundreds of tiny tasks; keep titles under 100 characters. Ask the user once, briefly, only if the project name or parent is truly ambiguous; otherwise proceed.
        6. Create the project: `create_project {name, description, parentID?, repository}` (the repository binding is set in the same call).
        7. Import the plan: `import_plan {projectID, applyWorkflowColumns: true, items}`. For more than 50 items run it once with `dryRun: true` first. Running it again must report everything `unchanged`.
        8. If `get_project_structure` shows an empty brief (version 0), write one with `set_agent_brief {projectID, text, version: 0}` from the project's own rules (headings: Goals, Constraints, Definition of done, Agent rules). Include the rule "Todolino must be current: post progress while working and call record_sync at the end of every session". Never overwrite a brief written by a person.
        9. Open decisions found in the documents: `ask_question {taskID, prompt, options, blocking, idempotencyKey}` on the matching task (use `list_plan_keys` to find task ids). Current work: `post_progress` on the relevant features.
        10. Write the marker file `.todolino.json` in the repository root: {"schema": 1, "server": "\(origin)", "projectID": "<id>", "repository": "<normalised repository key>"}. It contains no secrets and may be committed.
        11. Add or update this section in CLAUDE.md (or AGENTS.md if that is the file the project uses; create CLAUDE.md if neither exists). Replace everything between the markers if they already exist, otherwise append:

        \(repoSection)

        12. Call `record_sync {projectID, summary, repoRef}` with a short summary and `repoRef` like `main@<short commit>`.
        13. Report to the user in a few lines: project name and id, number of features/tasks/criteria/questions created, what you did not import and why, and that they can open \(origin) to see the board.
        """
    }

    static func syncText(_ v: [String: String]) -> String {
        """
        Reconcile the repository in the current working directory with its Todolino project. Project id: \(quoted(v["projectID"])) (if not given, read `.todolino.json`, else call `find_project_by_repository` with the git remote). If no project is bound, run the steps of `setup_project` instead.

        1. `get_sync_status {projectID}` for the last sync time and `repoRef`; `get_project_structure {projectID}` for the brief (it overrides your defaults).
        2. Collect what changed in the repository since the last sync: `git log --oneline <lastRepoRef>..HEAD` (or the last 50 commits if the ref is unknown), changes to plan, todo and docs files, new TODO lists.
        3. Read the board: `get_command_center {projectID}` and `list_plan_keys {projectID}`. Use `get_task_context` for tasks you are unsure about.
        4. Update the board from the repository with `import_plan` (same `externalKey` scheme as before; new work gets new keys). It only creates, updates texts, adds criteria and moves open to done. It never deletes, reopens or unticks. Mark work that the repository shows as finished with `status: "done"` only when you verified it.
        5. Things import does not do, you do with the tools: `post_progress` for work in flight, `set_task_structure` for blocked reasons, `ask_question` for open decisions (use idempotency keys), `request_review` for finished work that needs a person's decision. Answered questions and reviews with requested changes on the board change what you must do next: read them (`list_open_questions {includeAnswered: true}`, `list_pending_reviews`) and act on them.
        6. The board is the authority for in_progress, in_review, claims and answers; the repository is the authority for what is implemented. If the two disagree and you cannot resolve it, ask a question instead of overwriting.
        7. Finish with `record_sync {projectID, summary, repoRef}` (`repoRef` like `main@<short commit>`). Tell the user in a few lines what changed on the board.
        """
    }

    static func sessionText(_ v: [String: String]) -> String {
        """
        Give a short Todolino briefing for the repository in the current working directory. Project id: \(quoted(v["projectID"])) (if not given, read `.todolino.json`, else call `find_project_by_repository` with the git remote). If no project is bound, say so and offer `setup_project`.

        1. `get_sync_status {projectID}`. If the state is `stale` or `never`, say how old it is and run the steps of `sync_project` before anything else.
        2. `get_project_structure {projectID}` (read the agent brief; it overrides your defaults) and `get_command_center {projectID}`.
        3. `list_open_questions {projectID, includeAnswered: true}` and `list_pending_reviews {projectID}`: new answers you must act on, reviews with requested changes, questions still waiting.
        4. Brief the user in at most 10 lines: what is running (and by whom), what waits for an answer or review, what is blocked, the next ready tasks, and your proposal for what to do now.
        5. Remember the routine for this session: `claim_task` before working, `post_progress` after each meaningful step, `ask_question` instead of guessing, `request_review` when done, and at the end update statuses and call `record_sync {projectID, summary, repoRef}`. Todolino is part of the definition of done.
        """
    }
}
