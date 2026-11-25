import Fluent
import Vapor

/// Batch 7 (docs/MCP-PARITAET.md): review history, progress notes, local runner jobs and devices.
/// Same domain code as REST (`WorkflowService.reviews`, `AgentController.jobPage/devices`, `AgentService.release/humanTransition`).
/// Runner execution is an owner capability (`ProjectAccess.startAgent`) and needs its own scopes `runs:read`/`runs:write`.
/// Pairing and new bindings stay in the PWA.
extension MCPController {
    static let reviewStates = ["pending", "accepted", "changes_requested", "withdrawn", "all"]

    static let runTools: [Tool] = [
        Tool(name: "list_reviews", scope: "tasks:read",
             description: "List review requests with their history (newest first), including decided ones: state, summary, who requested and decided, decision note, task and project. Only projects in this connection's grant. status defaults to all.",
             properties: ["projectID": Schema.uuid("Optional project id (includes its sub-projects in the grant)."),
                          "status": Schema.string("pending, accepted, changes_requested, withdrawn or all (default).", values: reviewStates),
                          "limit": Schema.integer("Maximum number of reviews, 1 to 200 (default 50).", min: 1, max: 200)]),
        Tool(name: "list_progress_notes", scope: "tasks:read",
             description: "List the progress notes of a task, newest first: author, text, percent, time.",
             properties: ["taskID": Schema.uuid("Task id."),
                          "limit": Schema.integer("Maximum number of notes, 1 to 100 (default 50).", min: 1, max: 100)],
             required: ["taskID"]),
        Tool(name: "list_agent_jobs", scope: "runs:read",
             description: "List local runner jobs (Claude Code on a paired Mac) of projects you own and that are in this connection's grant, newest first: state, mode, progress, task title, project name. Needs owner rights.",
             properties: ["projectID": Schema.uuid("Optional project id."),
                          "status": Schema.string("Optional job state filter.", values: AgentJobPage.states.sorted()),
                          "limit": Schema.integer("Maximum number of jobs, 1 to 100 (default 50).", min: 1, max: 100)]),
        Tool(name: "start_agent_job", scope: "runs:write",
             description: "Release a task to a local runner through an EXISTING project binding: creates a queued job that the Mac runner picks up. Owner rights required. Without deviceID the project must have exactly one usable binding. Pairing devices and creating bindings is only possible in the PWA.",
             properties: ["taskID": Schema.uuid("Task id (its project must be in this connection's grant)."),
                          "deviceID": Schema.uuid("Runner device id (see list_runner_devices); required when several devices are bound to the project."),
                          "mode": Schema.string("clarify (only ask questions) or implement (default).", values: ["clarify", "implement"]),
                          "scope": Schema.string("Optional work scope for the runner, up to 4000 characters (default: the task title).", maxLength: 4000),
                          "version": Schema.integer("Optional current task version; a stale value fails with version_conflict.", min: 0),
                          "releaseID": Schema.uuid("Optional idempotency key (UUID). The same call with the same releaseID returns the existing job instead of a second one; different data under the same releaseID fails with release_id_conflict."),
                          "origin": Schema.string("manual (default) or scheduler. scheduler is the guard (watcher on the Mac): it only works if the person allowed automatic starts in the account settings and on this card (one-time permission set in the app, never by an agent), the card is not done and not blocked; otherwise auto_start_disabled_for_account, auto_start_not_enabled, task_done or task_blocked. A start more than 5 minutes after plannedAt is audited as catch-up.", values: ["manual", "scheduler"])],
             required: ["taskID"]),
        Tool(name: "start_pipeline_execution", scope: "runs:write",
             description: "Start the pipeline of one card on a paired Mac through an EXISTING project binding: the server queues one runner job per step (planner, developer, validation, tester, review, as the project switched them on) and waits for the person at the plan approval. Owner rights required, same rules as start_agent_job. Refused: execution_active, execution_id_conflict (same executionID, other data), nothing_to_run. Follow the state with get_task_pipeline (execution); stop it with stop_agent_job on execution.jobID. Continuing a paused execution is a person's decision in the app.",
             properties: ["taskID": Schema.uuid("Task id (its project must be in this connection's grant)."),
                          "bindingID": Schema.uuid("Runner binding of the task's project (see list_runner_devices)."),
                          "executionID": Schema.uuid("Optional idempotency key (UUID); the same call returns the existing execution.")],
             required: ["taskID", "bindingID"]),
        Tool(name: "stop_agent_job", scope: "runs:write",
             description: "Stop a queued, claimed, running or waiting local runner job (state becomes cancelled; the runner confirms termination later). Owner rights required.",
             properties: ["jobID": Schema.uuid("Agent job id (see list_agent_jobs).")],
             required: ["jobID"]),
        Tool(name: "list_runner_devices", scope: "runs:read",
             description: "List your paired and revoked runner devices with label, paired flag, revokedAt, active run count and the bindings to projects in this connection's grant. No tokens or pairing codes.")
    ]

    func callRunTools(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) async throws -> JSONValue {
        let allowed = Set(grant.projects)
        switch name {
        case "list_reviews":
            let status = try optionalString(a, "status") ?? "all"
            guard Self.reviewStates.contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
            let limit = try intArgument(a["limit"], reason: "invalid_limit") ?? 50
            guard (1...200).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
            return try .encoded(try await workflowService(user: user, grant: grant, db: db, settings: settings)
                .reviews(projectID: optionalUUID(a, "projectID"), state: status, limit: limit))
        case "list_progress_notes":
            let limit = try intArgument(a["limit"], reason: "invalid_limit") ?? 50
            guard (1...100).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
            let task = try await task(uuid(a["taskID"]), user: user, grant: grant, db: db)
            let notes = try await TaskProgressNote.query(on: db).filter(\.$taskID == task.requireID())
                .sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit).all()
            return try .encoded(try notes.map(ProgressNoteDTO.init))
        case "list_agent_jobs":
            let projectID = try optionalUUID(a, "projectID")
            let status = try optionalString(a, "status")
            if let status, !AgentJobPage.states.contains(status) { throw Abort(.badRequest, reason: "invalid_status") }
            let limit = try intArgument(a["limit"], reason: "invalid_limit") ?? AgentJobPage.defaultLimit
            guard (1...AgentJobPage.maxLimit).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
            return try .encoded(try await AgentController.jobPage(user: user, db: db, projectID: projectID, allowed: allowed,
                taskID: nil, state: status, limit: limit, cursor: nil))
        case "list_runner_devices":
            return try .encoded(try await AgentController.devices(user: user, db: db, allowed: allowed))
        case "start_agent_job":
            let task = try await task(uuid(a["taskID"]), user: user, grant: grant, db: db)
            let mode = try optionalString(a, "mode") ?? "implement"
            guard ["clarify", "implement"].contains(mode) else { throw Abort(.badRequest, reason: "invalid_mode") }
            let deviceID = try optionalUUID(a, "deviceID")
            let version = try intArgument(a["version"], reason: "invalid_version")
            if let version { guard version >= 0 else { throw Abort(.badRequest, reason: "invalid_version") } }
            let scope = try optionalString(a, "scope") ?? task.title
            let releaseID: UUID
            if a["releaseID"].isNull { releaseID = UUID() }
            else { guard let raw = a["releaseID"].string, let parsed = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_release_id") }; releaseID = parsed }
            let origin = try optionalString(a, "origin") ?? "manual"
            guard let releaseOrigin = ReleaseOrigin(rawValue: origin) else { throw Abort(.badRequest, reason: "invalid_origin") }
            _ = try await ProjectAccess(user: user, db: db).startAgent(in: task.projectID)
            if let version, version != task.version { throw Abort(.conflict, reason: "version_conflict") }
            // Existing bindings only: of this user's live devices, for this project.
            let binding = try await AutoStartService.usableBinding(projectID: task.projectID, deviceID: deviceID, user: user, on: db)
            let job = try await AgentService.release(ReleaseJobRequest(id: releaseID, taskID: task.requireID(), bindingID: binding.requireID(),
                previousJobID: nil, taskRevision: task.version, mode: mode, scope: scope), user: user, origin: releaseOrigin,
                integrationGrant: releaseOrigin == .scheduler ? try grant.requireID() : nil, on: db)
            return try .encoded(job)
        case "start_pipeline_execution":
            let task = try await task(uuid(a["taskID"]), user: user, grant: grant, db: db)
            let executionID: UUID
            if a["executionID"].isNull { executionID = UUID() }
            else { guard let raw = a["executionID"].string, let parsed = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_execution_id") }; executionID = parsed }
            return try .encoded(try await WorkflowService(user: user, db: db, allowedProjects: allowed).startExecution(task.requireID(),
                StartExecutionRequest(id: executionID, bindingID: uuid(a["bindingID"])), actor: await actor(grant: grant, db: db)))
        case "stop_agent_job":
            let jobID = try uuid(a["jobID"])
            guard let job = try await AgentJob.find(jobID, on: db), allowed.contains(job.projectID) else { throw Abort(.notFound) }
            return try .encoded(try await AgentService.humanTransition(jobID: jobID, decision: "stop", user: user, on: db))
        default: throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }
}
