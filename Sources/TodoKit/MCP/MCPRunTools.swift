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
                          "version": Schema.integer("Optional current task version; a stale value fails with version_conflict.", min: 0)],
             required: ["taskID"]),
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
            _ = try await ProjectAccess(user: user, db: db).startAgent(in: task.projectID)
            if let version, version != task.version { throw Abort(.conflict, reason: "version_conflict") }
            // Existing bindings only: of this user's live devices, for this project.
            var candidates: [ProjectRunnerBinding] = []
            for binding in try await ProjectRunnerBinding.query(on: db).filter(\.$projectID == task.projectID).sort(\.$id).all() {
                if let deviceID, binding.deviceID != deviceID { continue }
                guard let device = try await RunnerDevice.find(binding.deviceID, on: db), device.ownerID == user.id,
                      device.revokedAt == nil, device.tokenHash != nil else { continue }
                candidates.append(binding)
            }
            guard !candidates.isEmpty else { throw Abort(.conflict, reason: "no_binding") }
            guard candidates.count == 1, let binding = candidates.first else { throw Abort(.conflict, reason: "device_required") }
            let job = try await AgentService.release(ReleaseJobRequest(id: UUID(), taskID: task.requireID(), bindingID: binding.requireID(),
                previousJobID: nil, taskRevision: task.version, mode: mode, scope: scope), user: user, on: db)
            return try .encoded(job)
        case "stop_agent_job":
            let jobID = try uuid(a["jobID"])
            guard let job = try await AgentJob.find(jobID, on: db), allowed.contains(job.projectID) else { throw Abort(.notFound) }
            return try .encoded(try await AgentService.humanTransition(jobID: jobID, decision: "stop", user: user, on: db))
        default: throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }
}
