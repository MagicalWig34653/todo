import Fluent
import Vapor

extension MCPController {
    static let repositoryField = Schema.string("Repository identifier: a git remote URL (https, ssh or scp-like; credentials are dropped) or a free key such as 'local/my-project'. It is normalised to 'host/owner/repo' in lower case.", maxLength: 300)
    static let staleDaysField = Schema.integer("After how many days without record_sync the project counts as stale (default 3).", min: 1, max: 365)

    private static func planItemSchema(children: Bool) -> JSONValue {
        var props: [String: JSONValue] = [
            "externalKey": Schema.string("Stable key you choose, unique inside the project (for example 'plan/phase-2/login'). Re-importing the same key updates instead of duplicating.", maxLength: 200),
            "title": Schema.string("Task or feature title, 1 to 200 characters.", maxLength: 200),
            "description": Schema.string("Optional description (Markdown, up to 10000 characters). Replaces the old text when it differs."),
            "status": Schema.string("open (default) or done. Import only moves open to done; it never reopens a task.", values: ["open", "done"]),
            "blockedReason": Schema.string("Why the task is blocked (up to 1000 characters). Never cleared by import.", maxLength: 1000),
            "criteria": Schema.stringArray("Acceptance criteria. Missing ones are added by exact text; existing ones are never removed or unticked.", maxItems: 50),
            "backlog": Schema.boolean("New open tasks go to 'Backlog' instead of 'Bereit' (not yet scheduled)."),
        ]
        if children {
            props["children"] = .object(["type": .string("array"), "maxItems": .number(300),
                "description": .string("Subtasks of this feature (one level only). An item with children becomes a feature."),
                "items": planItemSchema(children: false)])
        }
        return .object(["type": .string("object"), "properties": .object(props), "required": .strings(["externalKey", "title"]),
                        "additionalProperties": .bool(false)])
    }

    /// Project onboarding and sync tools (ADR 0018).
    static let syncTools: [Tool] = [
        Tool(name: "find_project_by_repository", scope: "projects:read",
             description: "Find the Todolino project that is bound to a repository (git remote URL or free key). Call it FIRST when you start work in a repository: if a project is found, use it and never create a second one. The result lists matches, how many matching projects exist outside this connection's grant (then ask the user to reconnect and include them) and a hint for the next step.",
             properties: ["repository": repositoryField], required: ["repository"]),
        Tool(name: "create_project", scope: "projects:write",
             description: "Create a new project (optionally nested under a parent project you may manage) and optionally bind it to a repository in the same step. The new project is added to this connection's grant automatically. Search first (find_project_by_repository, list_projects) to avoid duplicates; a repository that is already bound fails with repository_already_bound.",
             properties: ["name": Schema.string("Project name, 1 to 200 characters.", maxLength: 200),
                          "description": Schema.string("Optional description (up to 10000 characters)."),
                          "parentID": Schema.uuid("Optional parent project id (must be in this connection's grant and manageable by the user)."),
                          "repository": repositoryField, "staleAfterDays": staleDaysField],
             required: ["name"]),
        Tool(name: "bind_repository", scope: "tasks:write",
             description: "Bind an existing project to a repository identifier, or change the staleness threshold of an existing binding (omit repository then). One repository maps to one project per owner (repository_already_bound otherwise). Changing the repository of a bound project resets its sync history. Needs edit rights.",
             properties: ["projectID": Schema.uuid("Project id."), "repository": repositoryField, "staleAfterDays": staleDaysField],
             required: ["projectID"]),
        Tool(name: "record_sync", scope: "tasks:write",
             description: "Record that the project's board was reconciled with the repository just now. Call it at the end of every working session after progress, statuses and questions are up to date; this timestamp is what the command center shows as fresh or stale. Fails with not_bound if the project has no repository binding (call bind_repository).",
             properties: ["projectID": Schema.uuid("Project id."),
                          "summary": Schema.string("What was reconciled or done in this session, 1 to 4000 characters.", maxLength: 4000),
                          "repoRef": Schema.string("Repository state hint, for example 'main@a1b2c3d' (up to 200 characters).", maxLength: 200),
                          "agentName": agentNameField],
             required: ["projectID", "summary"]),
        Tool(name: "get_sync_status", scope: "projects:read",
             description: "Read the sync state of one project: bound or not, repository, state fresh|stale|never, last sync time and author, days since, threshold, last repository hint and summary. Use it at session start to decide whether a reconciliation (sync_project) is due.",
             properties: ["projectID": Schema.uuid("Project id.")], required: ["projectID"]),
        Tool(name: "get_stale_projects", scope: "projects:read",
             description: "List bound projects whose data is stale or was never synced, most outdated first. Optionally narrow to one project and its sub-projects, or include projects without any repository binding.",
             properties: ["projectID": Schema.uuid("Optional: only this project and its sub-projects."),
                          "includeUnbound": Schema.boolean("Also list projects without a repository binding (default false).")]),
        Tool(name: "import_plan", scope: "tasks:write",
             description: "Idempotent bulk upsert of a plan: features with subtasks, tasks, acceptance criteria and blocked reasons, matched by externalKey (so running it twice creates nothing new). Reports created/updated/unchanged per item. Never deletes, reopens or unticks anything. All-or-nothing in one transaction (up to 300 items); dryRun previews without writing. Use it for onboarding a repository's plan and for reconciling later.",
             properties: ["projectID": Schema.uuid("Project id (edit rights needed)."),
                          "items": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(300),
                              "description": .string("Top-level features and tasks, each optionally with children (subtasks, one level)."),
                              "items": planItemSchema(children: true)]),
                          "applyWorkflowColumns": Schema.boolean("Create the standard agent workflow columns if the project has no columns yet (default false)."),
                          "dryRun": Schema.boolean("Compute and return the result without writing anything (default false).")],
             required: ["projectID", "items"]),
        Tool(name: "list_plan_keys", scope: "tasks:read",
             description: "List the external keys of a project with the task they map to (task id, title, status, parent). Use it to find the board tasks of an earlier import before posting progress or reconciling.",
             properties: ["projectID": Schema.uuid("Project id.")], required: ["projectID"]),
        Tool(name: "set_agent_brief", scope: "tasks:write",
             description: "Write the project's agent brief (goals, constraints, definition of done, agent rules; Markdown with headings Goals, Constraints, Definition of done, Agent rules). Needs manage rights and the current brief version (0 if never written; see get_project_structure). Only write a brief when it is empty or the user asked you to; never overwrite a brief a person wrote.",
             properties: ["projectID": Schema.uuid("Project id."),
                          "text": Schema.string("Brief text, up to 20000 characters. Empty text clears the brief."),
                          "version": Schema.integer("Current brief version as returned by get_project_structure (0 = never written).", min: 0)],
             required: ["projectID", "text", "version"]),
    ]

    func syncService(user: User, grant: OAuthGrant, db: any Database) -> ProjectSyncService {
        ProjectSyncService(user: user, db: db, allowedProjects: Set(grant.projects))
    }

    /// Dispatch for the tools of `syncTools`.
    func callSync(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings,
                  actor: WorkflowActor) async throws -> JSONValue {
        let sync = syncService(user: user, grant: grant, db: db)
        switch name {
        case "find_project_by_repository":
            return try .encoded(try await sync.find(repository: requiredString(a, "repository")))
        case "create_project":
            let body = CreateProjectRequest(name: try requiredString(a, "name"), parentID: try optionalUUID(a, "parentID"),
                                            description: try optionalString(a, "description"), color: nil)
            let repository = try optionalString(a, "repository")
            let days = try intArgument(a["staleAfterDays"], reason: "invalid_stale_after_days")
            if repository != nil { _ = try RepositoryKey.normalize(repository!) }
            let grantID = try grant.requireID()
            let (project, binding) = try await db.transaction { tx -> (Project, ProjectSyncDTO?) in
                try await lockSharingGraph(on: tx)
                try await lockRow(table: OAuthGrant.schema, id: grantID, on: tx)
                // Re-read under the lock: a concurrent create_project must not lose its entry.
                guard let current = try await OAuthGrant.find(grantID, on: tx), !current.revoked else { throw Abort(.unauthorized) }
                if let parent = body.parentID, !current.projects.contains(parent) { throw Abort(.notFound) }
                let project = try await PlanningOperations.createProject(user: user, db: tx, body: body)
                current.projects.append(try project.requireID())
                try await current.save(on: tx)
                let binding = try await repository.asyncMap { try await ProjectSyncService.bindNew(project, repository: $0, staleAfterDays: days, on: tx) }
                return (project, binding)
            }
            return .object(["project": try .encoded(ProjectDTO(project)),
                "sync": try binding.map { try .encoded($0) } ?? .null,
                "grantExtended": .bool(true),
                "next": .string("Add the standard columns and the plan with import_plan (applyWorkflowColumns true), write the agent brief with set_agent_brief, then record_sync.")])
        case "bind_repository":
            return try .encoded(try await sync.bind(uuid(a["projectID"]), repository: optionalString(a, "repository"),
                staleAfterDays: intArgument(a["staleAfterDays"], reason: "invalid_stale_after_days")))
        case "record_sync":
            return try .encoded(try await sync.recordSync(uuid(a["projectID"]), summary: requiredString(a, "summary"),
                repoRef: optionalString(a, "repoRef"), actor: actor, agentName: optionalString(a, "agentName")))
        case "get_sync_status":
            return try .encoded(try await sync.status(uuid(a["projectID"])))
        case "get_stale_projects":
            return try .encoded(try await sync.stale(projectID: optionalUUID(a, "projectID"),
                includeUnbound: optionalBool(a, "includeUnbound") ?? false))
        case "import_plan":
            let request = try a.decode(ImportPlanRequest.self)
            return try .encoded(try await sync.importPlan(uuid(a["projectID"]), request, actor: actor))
        case "list_plan_keys":
            return .array(try await sync.planKeys(uuid(a["projectID"])))
        case "set_agent_brief":
            guard let version = try intArgument(a["version"], reason: "invalid_version") else { throw Abort(.badRequest, reason: "invalid_version") }
            let service = workflowService(user: user, grant: grant, db: db, settings: settings)
            return try .encoded(try await service.putBrief(uuid(a["projectID"]), AgentBriefRequest(text: requiredString(a, "text"), version: version)))
        default: throw Abort(.badRequest)
        }
    }
}

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
