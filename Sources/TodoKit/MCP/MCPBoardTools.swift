import Fluent
import Vapor

/// Batch 6 (docs/MCP-PARITAET.md): board columns and personal project state. Same domain code as REST
/// (`ColumnService`, `PlanningService`, `ProjectStateService`); `delete_column` is a class C confirmation (batch 1).
extension PlanningService {
    /// Manual order of one board column (status): `taskIDs` must be exactly the visible tasks of that status.
    /// Shared by `PUT /v1/board/reorder` and the MCP tool `reorder_tasks`. Runs on the caller's transaction.
    func reorderBoard(projectID: UUID, status: String, taskIDs: [UUID]) async throws {
        guard TaskStatus.all.contains(status), Set(taskIDs).count == taskIDs.count else { throw Abort(.badRequest) }
        try await lock(); _ = try await access.project(projectID, role: .edit)
        let tasks = try await visibleTasks().filter { $0.projectID == projectID && $0.status == status }
        guard Set(try tasks.map { try $0.requireID() }) == Set(taskIDs) else { throw Abort(.conflict, reason: "board_changed") }
        for (position, id) in taskIDs.enumerated() {
            let p = try await TaskPlanning.find(id, on: db) ?? TaskPlanning(taskID: id)
            p.position = position; try await p.save(on: db)
        }
    }
}

extension MCPController {
    static let boardTools: [Tool] = [
        Tool(name: "update_column", scope: "tasks:write",
             description: "Change a board column: name, color, done flag and/or position. Pass the column's current version (list_columns). Changing the done flag does not move tasks. To remove a column use delete_column.",
             properties: ["id": Schema.uuid("Column id."), "version": versionField,
                          "name": Schema.string("New name, 1 to 100 characters.", maxLength: 100),
                          "color": Schema.string("Color as #RRGGBB; an empty string removes the color.", maxLength: 7),
                          "isDone": Schema.boolean("Whether tasks in this column count as done."),
                          "index": Schema.integer("New zero-based position among the project's columns.", min: 0, max: 1000)],
             required: ["id", "version"]),
        Tool(name: "apply_column_template", scope: "tasks:write",
             description: "Give a project without columns a column set: source 'status' (Offen / In Arbeit / Erledigt), 'agent_workflow' (Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt) or the id of another project in this connection's grant whose columns are copied. Existing tasks are placed by status. Fails with columns_exist when the project already has columns.",
             properties: ["projectID": Schema.uuid("Project without columns."),
                          "source": Schema.string("'status', 'agent_workflow' or a project id.", maxLength: 40)],
             required: ["projectID", "source"]),
        Tool(name: "reorder_tasks", scope: "tasks:write",
             description: "Set the manual order of the tasks of one status in a project (classic board without columns). taskIDs must list every task of that status exactly once, otherwise board_changed (re-read the board and retry). For project columns use move_task_to_column.",
             properties: ["projectID": Schema.uuid("Project id."),
                          "status": Schema.string("Task status whose order is set.", values: ["open", "in_progress", "in_review", "done"]),
                          "taskIDs": Schema.stringArray("All task ids of that status in the new order (up to 1000).", maxItems: 1000)],
             required: ["projectID", "status", "taskIDs"]),
        Tool(name: "list_favorites", scope: "projects:read",
             description: "Your favorite projects in order, limited to projects in this connection's grant: [{projectID, position}]."),
        Tool(name: "set_project_favorite", scope: "projects:write",
             description: "Add a project to your favorites (at index, default the end) or move it there, or remove it with favorite=false. Personal setting, shared with nobody. Returns the visible favorites.",
             properties: ["projectID": Schema.uuid("Project id (must be in this connection's grant)."),
                          "favorite": Schema.boolean("true adds or moves, false removes."),
                          "index": Schema.integer("Zero-based position in the favorites (only with favorite=true; default the end).", min: 0, max: 10000)],
             required: ["projectID", "favorite"]),
        Tool(name: "get_project_prefs", scope: "projects:read",
             description: "Your personal display settings for one project: view, sort, grouping, showCompleted, mode (classic or management, with modeSource), favorite state and the revision needed by update_project_prefs.",
             properties: ["projectID": Schema.uuid("Project id (must be in this connection's grant).")],
             required: ["projectID"]),
        Tool(name: "update_project_prefs", scope: "projects:write",
             description: "Change your personal display settings for one project. Pass the revision from get_project_prefs (0 if never written); a stale value fails with revision_conflict. At least one setting is required.",
             properties: ["projectID": Schema.uuid("Project id."),
                          "revision": Schema.integer("Current revision of the settings.", min: 0),
                          "view": Schema.string("Display of tasks.", values: ProjectUserState.views.sorted()),
                          "sort": Schema.string("Task sort order.", values: ProjectUserState.sorts.sorted()),
                          "grouping": Schema.string("Task grouping.", values: ProjectUserState.groupings.sorted()),
                          "showCompleted": Schema.boolean("Whether completed tasks are shown."),
                          "mode": Schema.string("Project mode.", values: ProjectUserState.modes.sorted())],
             required: ["projectID", "revision"]),
    ]

    func callBoardTools(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        switch name {
        case "update_column":
            let id = try uuid(a["id"])
            guard let version = try intArgument(a["version"], reason: "invalid_version"), version >= 1 else { throw Abort(.badRequest, reason: "invalid_version") }
            func text(_ key: String) throws -> String? {
                if a[key].isNull { return nil }
                guard let s = a[key].string else { throw Abort(.badRequest, reason: "invalid_\(key)") }
                return s
            }
            let newName = try text("name"), color = try text("color")
            let isDone: Bool?
            if a["isDone"].isNull { isDone = nil } else { guard case .bool(let b) = a["isDone"] else { throw Abort(.badRequest, reason: "invalid_isDone") }; isDone = b }
            let index = try intArgument(a["index"], reason: "invalid_index")
            if let index, index < 0 { throw Abort(.badRequest, reason: "invalid_index") }
            guard newName != nil || color != nil || isDone != nil || index != nil else { throw Abort(.badRequest, reason: "invalid_arguments") }
            let doneFlag = isDone
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                try await self.grantedColumn(id, user: user, grant: grant, db: tx)
                let column = try await ColumnService(user: user, db: tx).update(id,
                    UpdateColumnRequest(version: version, name: newName, color: color, isDone: doneFlag, index: index))
                return try .encoded(ColumnDTO(column))
            }
        case "apply_column_template":
            let projectID = try uuid(a["projectID"])
            guard let source = a["source"].string else { throw Abort(.badRequest, reason: "invalid_source") }
            if source != "status" && source != "agent_workflow" {
                guard let sourceID = UUID(uuidString: source) else { throw Abort(.badRequest, reason: "invalid_source") }
                guard grant.projects.contains(sourceID) else { throw Abort(.notFound) }
            }
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                _ = try await self.project(projectID, user: user, grant: grant, db: tx, role: .edit)
                let columns = try await ColumnService(user: user, db: tx).applyTemplate(projectID, source: source)
                return try .encoded(columns.map(ColumnDTO.init))
            }
        case "reorder_tasks":
            let projectID = try uuid(a["projectID"])
            guard let status = a["status"].string, TaskStatus.all.contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
            guard case .array(let raw) = a["taskIDs"], raw.count <= 1000 else { throw Abort(.badRequest, reason: "invalid_taskIDs") }
            let ids = try raw.map { v -> UUID in
                guard let s = v.string, let id = UUID(uuidString: s) else { throw Abort(.badRequest, reason: "invalid_taskIDs") }
                return id
            }
            guard Set(ids).count == ids.count else { throw Abort(.badRequest, reason: "invalid_taskIDs") }
            try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                _ = try await self.project(projectID, user: user, grant: grant, db: tx, role: .edit)
                try await PlanningService(user: user, db: tx).reorderBoard(projectID: projectID, status: status, taskIDs: ids)
            }
            return .object(["ok": .bool(true), "count": .number(Double(ids.count))])
        case "list_favorites":
            return try favoritesJSON(try await ProjectStateService(user: user, db: db).favorites(), grant: grant)
        case "set_project_favorite":
            let projectID = try uuid(a["projectID"])
            guard case .bool(let favorite) = a["favorite"] else { throw Abort(.badRequest, reason: "invalid_favorite") }
            let index = try intArgument(a["index"], reason: "invalid_index")
            if let index, index < 0 || !favorite { throw Abort(.badRequest, reason: "invalid_index") }
            guard grant.projects.contains(projectID) else { throw Abort(.notFound) }
            let items = try await db.transaction { tx -> [FavoriteDTO] in
                let service = ProjectStateService(user: user, db: tx)
                if favorite { return try await service.setFavorite(projectID, index: index) }
                try await service.removeFavorite(projectID)
                return try await service.favorites()
            }
            return try favoritesJSON(items, grant: grant)
        case "get_project_prefs":
            let projectID = try uuid(a["projectID"])
            _ = try await project(projectID, user: user, grant: grant, db: db)
            return try .encoded(try await ProjectStateService(user: user, db: db).prefs(projectID))
        case "update_project_prefs":
            let projectID = try uuid(a["projectID"])
            guard grant.projects.contains(projectID) else { throw Abort(.notFound) }
            // Same strict decoder as PATCH /v1/me/project-prefs/{id} (exact keys, enum values, revision).
            guard case .object(var fields) = a else { throw Abort(.badRequest, reason: "invalid_arguments") }
            fields["projectID"] = nil
            let change: ProjectPrefsChange
            do { change = try JSONValue.object(fields).decode(ProjectPrefsChange.self) }
            catch is DecodingError { throw Abort(.badRequest, reason: "invalid_project_prefs") }
            let dto = try await db.transaction { tx in try await ProjectStateService(user: user, db: tx).updatePrefs(projectID, change) }
            return try .encoded(dto)
        default: throw Abort(.badRequest)
        }
    }

    private func favoritesJSON(_ items: [FavoriteDTO], grant: OAuthGrant) throws -> JSONValue {
        let allowed = Set(grant.projects)
        return try .encoded(items.filter { allowed.contains($0.projectID) })
    }
}
