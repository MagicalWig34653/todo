import Fluent
import Vapor

/// A confirmable action: what it would do (`describe`, which also checks the user's current rights) and how it runs
/// (`execute`, the same domain code as REST). Class C actions of MCP tools are registered here.
struct ConfirmableAction: Sendable {
    struct Description: Sendable {
        let summary: String
        let impact: ActionImpact
        /// Every project the action touches; all of them must be in the connection's grant.
        let projectIDs: Set<UUID>
    }
    let tool: String
    let describe: @Sendable (_ args: [String: String], _ user: User, _ db: any Database) async throws -> Description
    /// Runs the action inside the caller's transaction (sharing graph locked); returns the result code.
    let execute: @Sendable (_ args: [String: String], _ user: User, _ db: any Database) async throws -> String
}

/// MCP error: the call was turned into a request, nothing happened yet.
struct ConfirmationRequired: Error {
    let requestID: UUID
}

enum ConfirmableActions {
    static let all: [String: ConfirmableAction] = Dictionary(uniqueKeysWithValues: [deleteProject, deleteTask, transferOwner, deleteColumn, deleteCriterion].map { ($0.tool, $0) })

    private static func id(_ args: [String: String], _ key: String) throws -> UUID {
        guard let raw = args[key], let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return id
    }
    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// Project plus all descendants.
    private static func subtree(of root: UUID, on db: any Database) async throws -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for p in try await Project.query(on: db).all() {
            if let parent = p.parentID, let pid = p.id { children[parent, default: []].append(pid) }
        }
        var result: Set<UUID> = [root]
        var queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where result.insert(child).inserted { queue.append(child) }
        }
        return result
    }

    static let deleteProject = ConfirmableAction(
        tool: "delete_project",
        describe: { args, user, db in
            let projectID = try id(args, "projectID")
            let access = ProjectAccess(user: user, db: db)
            let project = try await access.project(projectID)
            try await access.requireDeletion(project)
            if let raw = args["version"], let v = Int(raw), v != project.version { throw Abort(.conflict, reason: "version_conflict") }
            let ids = try await subtree(of: projectID, on: db)
            let tasks = try await TodoTask.query(on: db).filter(\.$projectID ~~ Array(ids)).count()
            let subs = ids.count - 1
            var text = "Projekt „\(project.name)“ mit \(plural(tasks, "Aufgabe", "Aufgaben"))"
            if subs > 0 { text += " und \(plural(subs, "Unterprojekt", "Unterprojekten"))" }
            text += " unwiderruflich löschen"
            return .init(summary: text, impact: ActionImpact(targetType: "project", targetID: projectID, targetName: project.name,
                subprojects: subs, tasks: tasks, destructive: true), projectIDs: ids)
        },
        execute: { args, user, db in
            let version = args["version"].flatMap(Int.init)
            try await PlanningOperations.deleteProject(user: user, db: db, id: try id(args, "projectID"), expectedVersion: version)
            return "deleted"
        })

    static let deleteTask = ConfirmableAction(
        tool: "delete_task",
        describe: { args, user, db in
            let taskID = try id(args, "taskID")
            let access = ProjectAccess(user: user, db: db)
            let task = try await access.task(taskID, role: .edit)
            let project = try await access.project(task.projectID)
            guard try await SharingAccess(user: user, db: db).visibility(project).canDelete else { throw Abort(.forbidden) }
            if let raw = args["version"], let v = Int(raw), v != task.version { throw Abort(.conflict, reason: "version_conflict") }
            let subtasks = try await TaskWorkflow.query(on: db).filter(\.$parentTaskID == taskID).count()
            var text = "Aufgabe „\(task.title)“ im Projekt „\(project.name)“"
            if subtasks > 0 { text += " mit \(plural(subtasks, "Teilaufgabe", "Teilaufgaben"))" }
            text += " unwiderruflich löschen"
            return .init(summary: text, impact: ActionImpact(targetType: "task", targetID: taskID, targetName: task.title,
                tasks: 1 + subtasks, destructive: true), projectIDs: [task.projectID])
        },
        execute: { args, user, db in
            try await PlanningOperations.deleteTask(user: user, db: db, id: try id(args, "taskID"), expectedVersion: args["version"].flatMap(Int.init))
            return "deleted"
        })

    static let transferOwner = ConfirmableAction(
        tool: "transfer_project_owner",
        describe: { args, user, db in
            let projectID = try id(args, "projectID")
            let ownerID = try id(args, "ownerID")
            guard let ownerType = args["ownerType"], ["person", "team"].contains(ownerType) else { throw Abort(.badRequest, reason: "invalid_principal") }
            let access = SharingAccess(user: user, db: db)
            let project = try await ProjectAccess(user: user, db: db).project(projectID)
            guard try await access.visibility(project).canTransferOwnership else { throw Abort(.forbidden) }
            if let raw = args["version"], let v = Int(raw), v != project.version { throw Abort(.conflict, reason: "version_conflict") }
            try await access.validatePrincipal(type: ownerType, id: ownerID)
            if ownerType == "team" { _ = try await access.requireTeam(ownerID, admin: true) }
            let name = ownerType == "team" ? try await Team.find(ownerID, on: db)?.name : try await User.find(ownerID, on: db)?.displayName
            return .init(summary: "Eigentum am Projekt „\(project.name)“ an \(ownerType == "team" ? "das Team" : "") „\(name ?? "?")“ übertragen",
                impact: ActionImpact(targetType: "project", targetID: projectID, targetName: project.name, newOwnerName: name, destructive: true),
                projectIDs: [projectID])
        },
        execute: { args, user, db in
            // Same steps as PUT /v1/projects/{id}/owner.
            let projectID = try id(args, "projectID"), ownerID = try id(args, "ownerID")
            let ownerType = args["ownerType"] ?? ""
            let access = SharingAccess(user: user, db: db)
            let before = try await SyncRecorder.visibility(on: db)
            let project = try await ProjectAccess(user: user, db: db).project(projectID)
            guard try await access.visibility(project).canTransferOwnership else { throw Abort(.forbidden) }
            if let raw = args["version"], let v = Int(raw), v != project.version { throw Abort(.conflict, reason: "version_conflict") }
            try await access.validatePrincipal(type: ownerType, id: ownerID)
            if ownerType == "team" { _ = try await access.requireTeam(ownerID, admin: true) }
            let policy = try await ProjectSharing.query(on: db).filter(\.$projectID == projectID).first() ?? ProjectSharing(project: project)
            policy.ownerType = ownerType; policy.ownerID = ownerID
            try await policy.save(on: db)
            try await AgentService.revokeRunnerAccess(projectID: projectID, on: db)
            project.version += 1
            try await project.save(on: db)
            try await SyncRecorder.recordVisibilityChanges(from: before, on: db)
            return "owner_changed"
        })
}

struct ActionRequestService: Sendable {
    let user: User
    let db: any Database

    static func fingerprint(grantID: UUID?, tool: String, args: [String: String]) -> String {
        let canonical = args.keys.sorted().map { "\($0)=\(args[$0] ?? "")" }.joined(separator: "&")
        return AuthSupport.hash("\(grantID?.uuidString ?? "-")|\(tool)|\(canonical)")
    }

    /// MCP path: validates, then stores (or returns the already open) request. Nothing is executed.
    static func create(tool: String, args: [String: String], user: User, grant: OAuthGrant, label: String?, on db: any Database) async throws -> ActionRequest {
        guard let action = ConfirmableActions.all[tool] else { throw Abort(.badRequest, reason: "unknown_action") }
        let grantID = try grant.requireID(), userID = try user.requireID()
        return try await db.transaction { tx in
            // Serialises concurrent identical calls of one connection (same pattern as create_project).
            try await lockRow(table: OAuthGrant.schema, id: grantID, on: tx)
            let description = try await action.describe(args, user, tx)
            guard description.projectIDs.isSubset(of: Set(grant.projects)) else { throw Abort(.notFound) }
            let print = fingerprint(grantID: grantID, tool: tool, args: args)
            let now = Date()
            if let open = try await ActionRequest.query(on: tx).filter(\.$fingerprint == print).filter(\.$state == "pending")
                .filter(\.$expiresAt > now).first() { return open }
            let r = ActionRequest()
            r.userID = userID; r.grantID = grantID; r.agentLabel = label; r.tool = tool; r.args = args; r.fingerprint = print
            r.summary = description.summary; r.impact = description.impact; r.state = "pending"
            r.expiresAt = now.addingTimeInterval(ActionRequest.lifetime)
            try await r.save(on: tx)
            return r
        }
    }

    private func owned(_ id: UUID) async throws -> ActionRequest {
        guard let r = try await ActionRequest.find(id, on: db), r.userID == (try user.requireID()) else { throw Abort(.notFound) }
        return r
    }

    func list(state: String?) async throws -> [ActionRequest] {
        let uid = try user.requireID()
        var q = ActionRequest.query(on: db).filter(\.$userID == uid)
        let now = Date()
        switch state {
        case nil, "all": break
        case "pending": q = q.filter(\.$state == "pending").filter(\.$expiresAt > now)
        case let s?:
            guard ["confirmed", "rejected", "expired", "executed", "failed"].contains(s) else { throw Abort(.badRequest, reason: "invalid_state") }
            q = q.filter(\.$state == s)
        }
        return try await q.sort(\.$createdAt, .descending).sort(\.$id).limit(100).all()
    }

    func get(_ id: UUID) async throws -> ActionRequest { try await owned(id) }

    func reject(_ id: UUID) async throws -> ActionRequest {
        try await db.transaction { tx in
            try await lockRow(table: ActionRequest.schema, id: id, on: tx)
            let r = try await ActionRequestService(user: user, db: tx).owned(id)
            switch r.state {
            case "rejected": return r
            case "pending":
                guard r.expiresAt > Date() else { r.state = "expired"; try await r.save(on: tx); throw Abort(.gone, reason: "request_expired") }
                r.state = "rejected"; r.decidedAt = Date(); try await r.save(on: tx)
                return r
            case "expired": throw Abort(.gone, reason: "request_expired")
            default: throw Abort(.conflict, reason: "already_decided")
            }
        }
    }

    /// Confirm and run. A second confirmation returns the stored outcome without running anything again.
    func confirm(_ id: UUID) async throws -> ActionRequest {
        struct Failed: Error { let code: String }
        do {
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                try await lockRow(table: ActionRequest.schema, id: id, on: tx)
                let r = try await ActionRequestService(user: user, db: tx).owned(id)
                switch r.state {
                case "executed", "failed": return r
                case "rejected": throw Abort(.conflict, reason: "already_decided")
                case "expired": throw Abort(.gone, reason: "request_expired")
                default: break
                }
                guard r.expiresAt > Date() else { r.state = "expired"; try await r.save(on: tx); throw Abort(.gone, reason: "request_expired") }
                guard let action = ConfirmableActions.all[r.tool] else { throw Failed(code: "unknown_action") }
                // The connection's limits apply at execution time too.
                guard let grantID = r.grantID, let grant = try await OAuthGrant.find(grantID, on: tx), !grant.revoked else { throw Failed(code: "connection_revoked") }
                do {
                    // describe re-checks the account's current rights; execute is the REST code path.
                    let description = try await action.describe(r.args, user, tx)
                    guard description.projectIDs.isSubset(of: Set(grant.projects)) else { throw Failed(code: "not_found") }
                    let code = try await action.execute(r.args, user, tx)
                    r.state = "executed"; r.result = ActionResult(ok: true, code: code)
                } catch let e as Failed { throw e }
                catch { throw Failed(code: Self.code(error)) }
                r.decidedAt = Date(); r.executedAt = Date()
                try await r.save(on: tx)
                return r
            }
        } catch let failure as Failed {
            // The action's own writes rolled back; record the failure in a fresh transaction.
            return try await db.transaction { tx in
                try await lockRow(table: ActionRequest.schema, id: id, on: tx)
                let r = try await ActionRequestService(user: user, db: tx).owned(id)
                guard r.state == "pending" || r.state == "confirmed" else { return r }
                r.state = "failed"; r.result = ActionResult(ok: false, code: failure.code)
                r.decidedAt = r.decidedAt ?? Date(); r.executedAt = Date()
                try await r.save(on: tx)
                return r
            }
        }
    }

    static func code(_ error: any Error) -> String {
        guard let abort = error as? any AbortError else { return "failed" }
        return abort.status == .notFound ? "not_found" : abort.reason
    }

    /// Pending requests of the account, newest first (the feed's confirmation cards).
    static func pending(of userID: UUID, limit: Int = 20, on db: any Database) async throws -> (items: [ActionRequest], total: Int) {
        let now = Date()
        func base() -> QueryBuilder<ActionRequest> {
            ActionRequest.query(on: db).filter(\.$userID == userID).filter(\.$state == "pending").filter(\.$expiresAt > now)
        }
        let total = try await base().count()
        return (try await base().sort(\.$createdAt, .descending).sort(\.$id).limit(limit).all(), total)
    }
}

struct ActionRequestController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped("v1", "action-requests")
        g.get(use: list)
        g.get(":id", use: get)
        g.post(":id", "confirm", use: confirm)
        g.post(":id", "reject", use: reject)
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }
    private func service(_ req: Request) async throws -> ActionRequestService { ActionRequestService(user: try await req.requireUser(), db: req.db) }

    @Sendable func list(_ req: Request) async throws -> [ActionRequestDTO] {
        try await service(req).list(state: req.query[String.self, at: "state"]).map { try ActionRequestDTO($0) }
    }
    @Sendable func get(_ req: Request) async throws -> ActionRequestDTO { try ActionRequestDTO(try await service(req).get(id(req))) }
    @Sendable func confirm(_ req: Request) async throws -> ActionRequestDTO { try ActionRequestDTO(try await service(req).confirm(id(req))) }
    @Sendable func reject(_ req: Request) async throws -> ActionRequestDTO { try ActionRequestDTO(try await service(req).reject(id(req))) }
}
