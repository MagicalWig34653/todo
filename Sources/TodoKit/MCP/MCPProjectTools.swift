import Fluent
import Vapor

/// Stapel 1 of docs/MCP-PARITAET.md: CRUD parity. `create_task`/`update_task` run on the shared planning services
/// (activity, sync, recurrence, link clean-up), plus project moves, sibling order and criteria edits.
extension MCPController {
    static let projectTools: [Tool] = [
        Tool(name: "move_project", scope: "projects:write",
             description: "Move a project in the project tree: below another project (parentID) or to the top level (parentID null). Needs manage rights on the project and on the target; both must be in this connection's grant. A move below the project itself or one of its sub-projects fails with project_cycle. Pass the project's current version.",
             properties: ["projectID": Schema.uuid("Project to move."), "version": versionField,
                          "parentID": Schema.nullable("string", "New parent project id, or null for the top level.")],
             required: ["projectID", "version", "parentID"]),
        Tool(name: "set_project_position", scope: "projects:write",
             description: "Set the position of a project among its siblings in your own project list (personal order, the tree itself does not change). afterProjectID is the sibling it should follow; null puts it first.",
             properties: ["projectID": Schema.uuid("Project to place."),
                          "afterProjectID": Schema.nullable("string", "Sibling project id the project should follow, or null for the first position.")],
             required: ["projectID", "afterProjectID"]),
        Tool(name: "update_criterion", scope: "tasks:write",
             description: "Change the text of an acceptance criterion (ids are in get_task_context). To tick or untick use set_criterion; to remove use delete_criterion.",
             properties: ["criterionID": Schema.uuid("Criterion id."), "text": Schema.string("New text, 1 to 2000 characters.", maxLength: 2000),
                          "version": Schema.integer("Optional current criterion version; a stale value fails with version_conflict.", min: 1)],
             required: ["criterionID", "text"]),
        Tool(name: "delete_criterion", scope: "tasks:write",
             description: "Delete an acceptance criterion (irreversible)." + confirmationNote,
             properties: ["criterionID": Schema.uuid("Criterion id."),
                          "version": Schema.integer("Optional current criterion version; a stale version fails with version_conflict when the user confirms.", min: 1)],
             required: ["criterionID"]),
    ]

    /// Optional priority and due date of `create_task`. A date-only value means the start of that day (UTC).
    static func parseDueDate(_ raw: String) throws -> Date {
        let full = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateOnly = ISO8601DateFormatter(); dateOnly.formatOptions = [.withFullDate]
        if let d = full.date(from: raw) ?? fractional.date(from: raw) ?? dateOnly.date(from: raw) { return d }
        throw Abort(.badRequest, reason: "invalid_due_date")
    }

    func callCreateTask(_ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        guard let projectRaw = a["projectID"].string, let projectID = UUID(uuidString: projectRaw) else { throw Abort(.badRequest, reason: "invalid_id") }
        guard let title = a["title"].string else { throw Abort(.badRequest, reason: "invalid_title") }
        let description: String?
        if a["description"].isNull { description = nil } else {
            guard let d = a["description"].string else { throw Abort(.badRequest, reason: "invalid_description") }; description = d
        }
        let columnID = try optionalUUID(a, "columnID")
        let due = try optionalString(a, "dueDate").map(Self.parseDueDate)
        let priority = try intArgument(a["priority"], reason: "invalid_priority")
        if let priority, !(0...3).contains(priority) { throw Abort(.badRequest, reason: "invalid_priority") }
        guard grant.projects.contains(projectID) else { throw Abort(.notFound) }
        let body = CreateTaskRequest(projectID: projectID, title: title, description: description, columnID: columnID)
        let dto = try await db.transaction { tx -> TaskDTO in
            try await lockSharingGraph(on: tx)
            _ = try await self.project(projectID, user: user, grant: grant, db: tx, role: .edit)
            let task = try await PlanningOperations.createTask(user: user, db: tx, body: body)
            if due != nil || priority != nil {
                _ = try await PlanningService(user: user, db: tx).put(task.requireID(),
                    data: PlanningData(dueAt: due, plannedAt: nil, priority: priority ?? 0, recurrence: nil, reminders: []))
            }
            return try TaskDTO(task)
        }
        return try .encoded(dto)
    }

    func callUpdateTask(_ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        let id = try uuid(a["id"])
        guard let version = try intArgument(a["version"], reason: "invalid_version") else { throw Abort(.badRequest, reason: "invalid_version") }
        func text(_ key: String) throws -> String? {
            if a[key].isNull { return nil }
            guard let s = a[key].string else { throw Abort(.badRequest, reason: "invalid_\(key)") }; return s
        }
        let body = UpdateTaskRequest(version: version, title: try text("title"), description: try text("description"),
                                     status: try text("status"), projectID: try optionalUUID(a, "projectID"))
        let dto = try await db.transaction { tx -> TaskDTO in
            try await lockSharingGraph(on: tx)
            let current = try await ProjectAccess(user: user, db: tx).task(id, role: .edit)
            _ = try await self.project(current.projectID, user: user, grant: grant, db: tx, role: .edit)
            if let target = body.projectID { _ = try await self.project(target, user: user, grant: grant, db: tx, role: .edit) }
            // REST path (PATCH /v1/tasks/{id}): activity, column reconcile, link clean-up on a move, recurrence on completion.
            return try await PlanningService(user: user, db: tx).update(id, body: body)
        }
        return try .encoded(dto)
    }

    func callProjectTools(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        switch name {
        case "move_project":
            let projectID = try uuid(a["projectID"])
            guard let version = try intArgument(a["version"], reason: "invalid_version") else { throw Abort(.badRequest, reason: "invalid_version") }
            let parent = try optionalUUID(a, "parentID")
            guard grant.projects.contains(projectID) else { throw Abort(.notFound) }
            if let parent, !grant.projects.contains(parent) { throw Abort(.notFound) }
            let body = UpdateProjectRequest(version: version, name: nil, parentID: nil, moveToRoot: parent == nil ? true : nil)
            let request = parent == nil ? body : UpdateProjectRequest(version: version, name: nil, parentID: .some(parent), moveToRoot: nil)
            let dto = try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                return try await PlanningOperations.updateProject(user: user, db: tx, id: projectID, body: request)
            }
            return .object(["id": .string(dto.id.uuidString), "name": .string(dto.name), "version": .number(Double(dto.version)),
                "parentID": dto.parentID.flatMap { grant.projects.contains($0) ? .string($0.uuidString) : nil } ?? .null])
        case "set_project_position":
            let projectID = try uuid(a["projectID"])
            let after = try optionalUUID(a, "afterProjectID")
            guard grant.projects.contains(projectID) else { throw Abort(.notFound) }
            if let after, !grant.projects.contains(after) { throw Abort(.notFound) }
            let dto = try await db.transaction { tx -> ProjectDTO in
                try await lockSharingGraph(on: tx)
                _ = try await ProjectAccess(user: user, db: tx).project(projectID)
                let all = try await ProjectAccess(user: user, db: tx).listDTOs(states: try await ProjectUserState.states(of: user, on: tx))
                guard let me = all.first(where: { $0.id == projectID }) else { throw Abort(.notFound) }
                // Same base order as GET /v1/projects: stored position, creation time, id.
                let siblings = all.filter { $0.parentID == me.parentID && $0.id != projectID }.sorted { x, y in
                    let px = x.position ?? Int.max, py = y.position ?? Int.max
                    if px != py { return px < py }
                    if x.createdAt != y.createdAt { return (x.createdAt ?? .distantPast) < (y.createdAt ?? .distantPast) }
                    return x.id.uuidString < y.id.uuidString
                }
                var index = 0
                if let after {
                    guard let i = siblings.firstIndex(where: { $0.id == after }) else { throw Abort(.badRequest, reason: "invalid_after_project") }
                    index = i + 1
                }
                return try await ProjectStateService(user: user, db: tx).position(projectID, ProjectPositionRequest(index: index))
            }
            return .object(["id": .string(dto.id.uuidString), "version": .number(Double(dto.version)),
                "position": dto.position.map { .number(Double($0)) } ?? .null])
        case "update_criterion":
            let id = try uuid(a["criterionID"])
            guard let raw = a["text"].string else { throw Abort(.badRequest, reason: "invalid_text") }
            let version = try intArgument(a["version"], reason: "invalid_version")
            guard let existing = try await AcceptanceCriterion.find(id, on: db) else { throw Abort(.notFound) }
            let value = try WorkflowService.text(raw, max: 2000, reason: "invalid_text")
            let grantID = try grant.requireID()
            let label = try await OAuthClient.find(grant.clientID, on: db)?.name
            let service = WorkflowService(user: user, db: db, allowedProjects: Set(grant.projects))
            let actor = WorkflowActor.integration(grantID: grantID, label: label)
            return try .encoded(try await service.mutate(existing.taskID, role: .edit) { _, tx in
                guard let c = try await AcceptanceCriterion.find(id, on: tx) else { throw Abort(.notFound) }
                if let version, c.version != version { throw Abort(.conflict, reason: "version_conflict") }
                if c.text != value {
                    c.text = value; c.version += 1
                    try await c.save(on: tx)
                    try await appendActivity(taskID: c.taskID, actorType: actor.type, actorID: actor.id, kind: "criterion.updated", subjectID: c.id, on: tx)
                }
                return try CriterionDTO(c)
            })
        case "delete_criterion":
            var args = ["criterionID": try uuid(a["criterionID"]).uuidString]
            if let v = try intArgument(a["version"], reason: "invalid_version") { args["version"] = String(v) }
            return try await requestConfirmation("delete_criterion", args, user: user, grant: grant, db: db)
        default: throw Abort(.badRequest)
        }
    }

    /// Class C: stores a confirmation request and ends the call with `confirmation_required`.
    func requestConfirmation(_ tool: String, _ args: [String: String], user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        let label = try await OAuthClient.find(grant.clientID, on: db)?.name
        let request = try await ActionRequestService.create(tool: tool, args: args, user: user, grant: grant, label: label, on: db)
        throw ConfirmationRequired(requestID: try request.requireID())
    }

    func callDeleteColumn(_ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        var args = ["id": try uuid(a["id"]).uuidString]
        if let v = try intArgument(a["version"], reason: "invalid_arguments") { args["version"] = String(v) }
        if !a["moveTo"].isNull {
            guard let raw = a["moveTo"].string else { throw Abort(.badRequest, reason: "invalid_move_to") }
            guard raw == "none" || UUID(uuidString: raw) != nil else { throw Abort(.badRequest, reason: "invalid_move_to") }
            args["moveTo"] = raw
        }
        return try await requestConfirmation("delete_column", args, user: user, grant: grant, db: db)
    }
}

// MARK: Confirmable actions (ADR 0026)

extension ConfirmableActions {
    private static func uuidArg(_ args: [String: String], _ key: String) throws -> UUID {
        guard let raw = args[key], let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return id
    }

    static let deleteColumn = ConfirmableAction(
        tool: "delete_column",
        describe: { args, user, db in
            let id = try uuidArg(args, "id")
            let service = ColumnService(user: user, db: db)
            let column = try await service.column(id, role: .edit)
            if let raw = args["version"], let v = Int(raw), v != column.version { throw Abort(.conflict, reason: "version_conflict") }
            let remaining = try await service.columns(of: column.projectID).filter { $0.id != id }
            var target = "der ersten verbleibenden Spalte"
            switch args["moveTo"] {
            case nil: if remaining.isEmpty { target = "„Ohne Spalte“" }
            case "none": target = "„Ohne Spalte“"
            case let raw?:
                guard let t = UUID(uuidString: raw), let found = remaining.first(where: { $0.id == t }) else { throw Abort(.notFound) }
                target = "„\(found.name)“"
            }
            let count = try await TodoTask.query(on: db).filter(\.$columnID == id).count()
            let project = try await Project.find(column.projectID, on: db)
            let text = "Spalte „\(column.name)“ im Projekt „\(project?.name ?? "?")“ löschen; \(count) \(count == 1 ? "Aufgabe zieht" : "Aufgaben ziehen") nach \(target) um"
            return .init(summary: text, impact: ActionImpact(targetType: "column", targetID: id, targetName: column.name, tasks: count, destructive: true),
                         projectIDs: [column.projectID])
        },
        execute: { args, user, db in
            let id = try uuidArg(args, "id")
            var moveTo: UUID??
            switch args["moveTo"] {
            case nil: break
            case "none": moveTo = .some(nil)
            case let raw?: moveTo = .some(UUID(uuidString: raw))
            }
            try await ColumnService(user: user, db: db).delete(id, moveTo: moveTo, expectedVersion: args["version"].flatMap(Int.init))
            return "deleted"
        })

    static let deleteCriterion = ConfirmableAction(
        tool: "delete_criterion",
        describe: { args, user, db in
            let id = try uuidArg(args, "criterionID")
            guard let c = try await AcceptanceCriterion.find(id, on: db) else { throw Abort(.notFound) }
            let task = try await ProjectAccess(user: user, db: db).task(c.taskID, role: .edit)
            if let raw = args["version"], let v = Int(raw), v != c.version { throw Abort(.conflict, reason: "version_conflict") }
            let short = c.text.count > 80 ? String(c.text.prefix(80)) + "…" : c.text
            return .init(summary: "Kriterium „\(short)“ der Aufgabe „\(task.title)“ löschen",
                         impact: ActionImpact(targetType: "criterion", targetID: id, targetName: short, destructive: true), projectIDs: [task.projectID])
        },
        execute: { args, user, db in
            let id = try uuidArg(args, "criterionID")
            guard let c = try await AcceptanceCriterion.find(id, on: db) else { throw Abort(.notFound) }
            try await lockRow(table: TodoTask.schema, id: c.taskID, on: db)
            _ = try await ProjectAccess(user: user, db: db).task(c.taskID, role: .edit)
            guard let fresh = try await AcceptanceCriterion.find(id, on: db) else { throw Abort(.notFound) }
            if let raw = args["version"], let v = Int(raw), v != fresh.version { throw Abort(.conflict, reason: "version_conflict") }
            try await fresh.delete(on: db)
            try await appendActivity(taskID: fresh.taskID, actorType: .person, actorID: user.requireID(), kind: "criterion.deleted", subjectID: id, on: db)
            return "deleted"
        })
}
