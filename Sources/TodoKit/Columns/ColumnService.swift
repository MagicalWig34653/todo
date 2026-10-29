import Fluent
import Vapor

/// All column and board-placement writes. Every mutating method takes the sharing-graph lock first (like every other
/// planning write), so column order, task placement and permission checks are serialised across replicas.
struct ColumnService: Sendable {
    static let maxColumnsPerProject = 200
    static let statusColumns: [(key: String, name: String, isDone: Bool)] = [
        ("open", "Offen", false), ("in_progress", "In Arbeit", false), ("done", "Erledigt", true),
    ]

    let user: User
    let db: any Database
    var access: ProjectAccess { ProjectAccess(user: user, db: db) }

    // MARK: Validation

    static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw Abort(.badRequest, reason: "invalid_name") }
        return name
    }

    /// `nil` input = unchanged handled by the caller; empty string clears.
    static func cleanColor(_ raw: String) throws -> String? {
        if raw.isEmpty { return nil }
        guard raw.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "invalid_color")
        }
        return raw.uppercased()
    }

    // MARK: Reads

    func columns(of projectID: UUID) async throws -> [ProjectColumn] {
        try await ProjectColumn.query(on: db).filter(\.$projectID == projectID).sort(\.$position).sort(\.$id).all()
    }

    /// Column of a project the caller may access with `role`; missing or hidden is 404.
    func column(_ id: UUID, role: ProjectRole) async throws -> ProjectColumn {
        guard let c = try await ProjectColumn.find(id, on: db) else { throw Abort(.notFound) }
        _ = try await access.project(c.projectID, role: role)
        return c
    }

    private func tasks(in projectID: UUID, column: UUID?) async throws -> [TodoTask] {
        var q = TodoTask.query(on: db).filter(\.$projectID == projectID)
        q = column.map { q.filter(\.$columnID == $0) } ?? q.filter(\.$columnID == .null)
        return try await q.sort(\.$boardPosition).sort(\.$id).all()
    }

    func board(_ projectID: UUID) async throws -> BoardResponse {
        _ = try await access.project(projectID, role: .read)
        let cols = try await columns(of: projectID)
        let all = try await TodoTask.query(on: db).filter(\.$projectID == projectID).all()
        let planning = Dictionary(uniqueKeysWithValues: try await TaskPlanning.query(on: db)
            .filter(\.$id ~~ all.map { try $0.requireID() }).all().map { (try $0.requireID(), $0) })
        func dto(_ t: TodoTask) throws -> TaskDTO {
            var d = try TaskDTO(t); d.planning = TaskPlanningSummary(planning[d.id]); return d
        }
        if cols.isEmpty {
            let ordered = try all.sorted {
                let a = planning[try $0.requireID()]?.position ?? 0, b = planning[try $1.requireID()]?.position ?? 0
                return a == b ? $0.id!.uuidString < $1.id!.uuidString : a < b
            }
            let virtual = try ["open", "in_progress", "in_review", "done"].enumerated().map { (i, key) in
                BoardColumn(id: nil, key: key, name: ["open": "Offen", "in_progress": "In Arbeit", "in_review": "In Prüfung", "done": "Erledigt"][key]!,
                    color: nil, isDone: key == "done", position: i, version: nil,
                    tasks: try ordered.filter { $0.status == key }.map(dto))
            }
            return BoardResponse(projectID: projectID, mode: "status", columns: virtual, unassigned: [])
        }
        func ordered(_ column: UUID?) -> [TodoTask] {
            all.filter { $0.columnID == column }.sorted {
                $0.boardPosition == $1.boardPosition ? $0.id!.uuidString < $1.id!.uuidString : $0.boardPosition < $1.boardPosition
            }
        }
        let result = try cols.map { c in
            BoardColumn(id: try c.requireID(), key: nil, name: c.name, color: c.color, isDone: c.isDone, position: c.position,
                version: c.version, tasks: try ordered(c.id).map(dto))
        }
        return BoardResponse(projectID: projectID, mode: "columns", columns: result, unassigned: try ordered(nil).map(dto))
    }

    // MARK: Column writes

    private func renumber(_ list: [ProjectColumn]) async throws {
        for (i, c) in list.enumerated() where c.position != i {
            c.position = i
            c.version += 1
            try await c.save(on: db)
        }
    }

    private func insert(_ column: ProjectColumn, into others: [ProjectColumn], at index: Int?) -> [ProjectColumn] {
        var list = others
        list.insert(column, at: min(max(index ?? list.count, 0), list.count))
        return list
    }

    func create(_ projectID: UUID, _ body: CreateColumnRequest) async throws -> ProjectColumn {
        try await lockSharingGraph(on: db)
        _ = try await access.project(projectID, role: .edit)
        let existing = try await columns(of: projectID)
        guard existing.count < Self.maxColumnsPerProject else { throw Abort(.unprocessableEntity, reason: "too_many_columns") }
        if let i = body.index, i < 0 { throw Abort(.badRequest, reason: "invalid_index") }
        let column = ProjectColumn(
            projectID: projectID, name: try Self.cleanName(body.name), color: try body.color.flatMap(Self.cleanColor),
            isDone: body.isDone ?? false, position: existing.count)
        try await column.save(on: db)
        let list = insert(column, into: existing, at: body.index)
        for (i, c) in list.enumerated() where c.position != i {
            c.position = i; c.version += 1; try await c.save(on: db)
        }
        return column
    }

    func update(_ id: UUID, _ body: UpdateColumnRequest) async throws -> ProjectColumn {
        try await lockSharingGraph(on: db)
        let column = try await self.column(id, role: .edit)
        guard column.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
        if let i = body.index, i < 0 { throw Abort(.badRequest, reason: "invalid_index") }
        if let name = body.name { column.name = try Self.cleanName(name) }
        if let color = body.color { column.color = try Self.cleanColor(color) }
        if let done = body.isDone { column.isDone = done }
        var list = try await columns(of: column.projectID)
        if let index = body.index {
            list.removeAll { $0.id == column.id }
            list = insert(column, into: list, at: index)
            for (i, c) in list.enumerated() where c.id != column.id && c.position != i {
                c.position = i; c.version += 1; try await c.save(on: db)
            }
            column.position = list.firstIndex { $0.id == column.id }!
        }
        column.version += 1
        try await column.save(on: db)
        return column
    }

    /// `moveTo`: nil = first remaining column (default), `.some(nil)` = "Ohne Spalte", `.some(id)` = that column.
    func delete(_ id: UUID, moveTo: UUID??, expectedVersion: Int?) async throws {
        try await lockSharingGraph(on: db)
        let column = try await self.column(id, role: .edit)
        if let expectedVersion, column.version != expectedVersion { throw Abort(.conflict, reason: "version_conflict") }
        let remaining = try await columns(of: column.projectID).filter { $0.id != column.id }
        var target: ProjectColumn?
        switch moveTo {
        case .none: target = remaining.first
        case .some(.none): target = nil
        case .some(.some(let t)):
            guard let found = remaining.first(where: { $0.id == t }) else { throw Abort(.notFound) }
            target = found
        }
        for task in try await tasks(in: column.projectID, column: id) {
            try await place(task, in: target, at: nil, bumpVersion: true)
        }
        try await column.delete(on: db)
        try await renumber(remaining)
    }

    /// Creates the default status columns or copies another project's columns into a project that has none.
    func applyTemplate(_ projectID: UUID, source: String) async throws -> [ProjectColumn] {
        try await lockSharingGraph(on: db)
        _ = try await access.project(projectID, role: .edit)
        guard try await columns(of: projectID).isEmpty else { throw Abort(.conflict, reason: "columns_exist") }
        var created: [ProjectColumn] = []
        if source == "status" {
            for (i, s) in Self.statusColumns.enumerated() {
                let c = ProjectColumn(projectID: projectID, name: s.name, color: nil, isDone: s.isDone, position: i)
                try await c.save(on: db); created.append(c)
            }
            // Existing tasks keep their status and land in the matching column.
            for task in try await TodoTask.query(on: db).filter(\.$projectID == projectID).sort(\.$createdAt).sort(\.$id).all() {
                let target = task.status == "done" ? created[2] : task.status == "open" ? created[0] : created[1]
                task.columnID = try target.requireID()
                task.boardPosition = try await tasks(in: projectID, column: target.requireID()).count
                try await task.save(on: db)
            }
        } else {
            guard let sourceID = UUID(uuidString: source) else { throw Abort(.badRequest, reason: "invalid_source") }
            _ = try await access.project(sourceID, role: .read)
            for (i, s) in try await columns(of: sourceID).enumerated() {
                let c = ProjectColumn(projectID: projectID, name: s.name, color: s.color, isDone: s.isDone, position: i)
                try await c.save(on: db); created.append(c)
            }
            guard !created.isEmpty else { throw Abort(.conflict, reason: "source_has_no_columns") }
            if let done = created.first(where: \.isDone) {
                for task in try await TodoTask.query(on: db).filter(\.$projectID == projectID).filter(\.$status == "done").sort(\.$id).all() {
                    task.columnID = try done.requireID()
                    task.boardPosition = try await tasks(in: projectID, column: done.requireID()).count
                    try await task.save(on: db)
                }
            }
        }
        return created
    }

    // MARK: Task placement

    /// Puts `task` into `target` (nil = unassigned) at `index` (nil = end), renumbers the target densely and applies
    /// the done-column status rule. The task's version is bumped when `bumpVersion` and nothing else bumped it.
    private func place(_ task: TodoTask, in target: ProjectColumn?, at index: Int?, bumpVersion: Bool) async throws {
        let taskID = try task.requireID()
        var needsStatus: String?
        if let target {
            if target.isDone && task.status != "done" { needsStatus = "done" }
            else if !target.isDone && task.status == "done" { needsStatus = "open" }
        }
        var bumped = false
        var current = task
        if let status = needsStatus {
            // Same code path as PATCH, so activity, recurrence and sync stay consistent.
            _ = try await PlanningService(user: user, db: db).update(taskID, body: UpdateTaskRequest(
                version: task.version, title: nil, description: nil, status: status, projectID: nil), reconcileColumn: false)
            guard let fresh = try await TodoTask.find(taskID, on: db) else { throw Abort(.notFound) }
            current = fresh; bumped = true
        }
        var others = try await tasks(in: current.projectID, column: target?.id).filter { $0.id != taskID }
        let at = min(max(index ?? others.count, 0), others.count)
        others.insert(current, at: at)
        for (i, t) in others.enumerated() where t.id != taskID && t.boardPosition != i {
            t.boardPosition = i; try await t.save(on: db)
        }
        current.columnID = target?.id
        current.boardPosition = at
        if bumpVersion && !bumped { current.version += 1 }
        try await current.save(on: db)
    }

    func move(_ taskID: UUID, _ body: MoveTaskRequest) async throws -> TaskDTO {
        try await lockSharingGraph(on: db)
        try await lockRow(table: TodoTask.schema, id: taskID, on: db)
        let task = try await access.task(taskID, role: .edit)
        guard task.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
        if let i = body.index, i < 0 { throw Abort(.badRequest, reason: "invalid_index") }
        var target: ProjectColumn?
        if let cid = body.columnID {
            guard let c = try await ProjectColumn.find(cid, on: db), c.projectID == task.projectID else { throw Abort(.notFound) }
            target = c
        }
        try await place(task, in: target, at: body.index, bumpVersion: true)
        guard let fresh = try await TodoTask.find(taskID, on: db) else { throw Abort(.notFound) }
        return try TaskDTO(fresh)
    }

    /// Initial column for a new task (`columnID` of the create request), caller holds the lock.
    func initialPlacement(for task: TodoTask, columnID: UUID) async throws {
        guard let c = try await ProjectColumn.find(columnID, on: db), c.projectID == task.projectID else { throw Abort(.notFound) }
        task.columnID = columnID
        task.boardPosition = try await tasks(in: task.projectID, column: columnID).count
        if c.isDone { task.status = "done" }
    }

    /// Keeps column and status aligned after a status change through any route. Mutates `task` (the caller saves it);
    /// other tasks' positions are unaffected because the task is appended to the end of the target column.
    static func reconcile(_ task: TodoTask, on db: any Database) async throws {
        let columns = try await ProjectColumn.query(on: db).filter(\.$projectID == task.projectID).sort(\.$position).sort(\.$id).all()
        guard !columns.isEmpty else { return }
        let current = columns.first { $0.id == task.columnID }
        let target: ProjectColumn?
        if task.status == "done", current?.isDone != true { target = columns.first(where: \.isDone) }
        else if task.status != "done", current?.isDone == true { target = columns.first { !$0.isDone } }
        else { return }
        guard task.status == "done" ? target != nil : true else { return }
        task.columnID = target?.id
        var q = TodoTask.query(on: db).filter(\.$projectID == task.projectID).filter(\.$id != task.id!)
        if let tid = target?.id { q = q.filter(\.$columnID == tid) } else { q = q.filter(\.$columnID == .null) }
        task.boardPosition = try await q.count()
    }
}
