import Fluent
import SQLKit
import Vapor

struct SyncChangeDTO: Content {
    let seq: Int
    let entityType: String
    let entityID: UUID
    let kind: String
    let project: ProjectDTO?
    let task: TaskDTO?
    /// Set for `entityType == "column"` upserts (project board columns).
    var column: ColumnDTO? = nil
    /// Set for `entityType == "task"` upserts: the task's planning data (ADR 0020). Always present for tasks,
    /// with defaults (priority 0, no dates, no reminders) when nothing is planned.
    var planning: SyncPlanningDTO? = nil
    /// Set for `entityType == "label"` upserts (account-private labels).
    var label: SyncLabelDTO? = nil
}

/// Planning data of a task as carried by the feed and by `task.planning` results.
struct SyncPlanningDTO: Content {
    let dueAt: Date?
    let plannedAt: Date?
    let priority: Int
    let recurrence: RecurrenceRule?
    let reminders: [Date]
    init(_ p: TaskPlanning?) {
        dueAt = p?.dueAt; plannedAt = p?.plannedAt; priority = p?.priority ?? 0
        recurrence = p?.recurrence; reminders = p?.reminders ?? []
    }
}

/// A label with its full task membership. Labels are private to the owning account; `taskIDs` lists only tasks
/// the account can currently read.
struct SyncLabelDTO: Content {
    let id: UUID
    let name: String
    let version: Int
    let taskIDs: [UUID]

    static func make(_ label: DiscoveryLabel, user: User, on db: any Database) async throws -> SyncLabelDTO {
        let access = ProjectAccess(user: user, db: db)
        var ids: [UUID] = []
        let links = try await DiscoveryTaskLabel.query(on: db).filter(\.$labelID == label.requireID()).all()
        for link in links.sorted(by: { $0.taskID.uuidString < $1.taskID.uuidString }) {
            do { _ = try await access.task(link.taskID); ids.append(link.taskID) }
            catch let error as any AbortError where error.status == .notFound || error.status == .forbidden { continue }
        }
        return SyncLabelDTO(id: try label.requireID(), name: label.name, version: label.version, taskIDs: ids)
    }
}

struct SyncChangesResponse: Content {
    let changes: [SyncChangeDTO]
    let cursor: String
    let hasMore: Bool
}

struct SyncMutationRequest: Content {
    let mutationID: UUID
    /// project.create | project.update | project.delete | project.position | task.create | task.update | task.delete |
    /// task.move_column | column.create | column.update | column.delete | task.planning | label.create | label.rename |
    /// label.delete | task.label_add | task.label_remove
    let type: String
    /// Entity ID: chosen by the client for creates, the target for updates and deletes.
    let id: UUID
    let version: Int?
    let name: String?
    let parentID: UUID?
    let moveToRoot: Bool?
    let projectID: UUID?
    let title: String?
    let description: String?
    let status: String?
    /// project.create/update: `#RRGGBB` (empty clears; project `description` reuses the field above, empty clears).
    /// column.create/update: column colour.
    var color: String? = nil
    /// column.create/update.
    var isDone: Bool? = nil
    /// Insert position for column.create/update, task.move_column and project.position.
    var index: Int? = nil
    /// column.delete: `"none"` ("Ohne Spalte") or a column UUID; omitted = first remaining column.
    var moveTo: String? = nil
    /// task.move_column: target column of the task's project; omitted/null = "Ohne Spalte".
    var columnID: UUID? = nil
    /// task.planning: full replacement of the task's planning data (omitted optional fields clear; `priority`
    /// omitted = 0, `reminders` omitted = none). Requires `version`.
    var dueAt: Date? = nil
    var plannedAt: Date? = nil
    var priority: Int? = nil
    var recurrence: RecurrenceRule? = nil
    var reminders: [Date]? = nil
    /// task.label_add / task.label_remove: the label (the task is `id`).
    var labelID: UUID? = nil
}

struct SyncMutationResponse: Content {
    let mutationID: UUID
    let type: String
    let id: UUID
    let deleted: Bool
    let project: ProjectDTO?
    let task: TaskDTO?
    /// Set for column.create/update.
    var column: ColumnDTO? = nil
    /// Set for task.planning.
    var planning: SyncPlanningDTO? = nil
    /// Set for label.create/rename and task.label_add/remove (the label after the change).
    var label: SyncLabelDTO? = nil
    let cursor: String
}

struct SyncController: RouteCollection {
    static let defaultLimit = 100
    static let maxLimit = 500

    func boot(routes: any RoutesBuilder) throws {
        let sync = routes.grouped("v1", "sync")
        sync.get("changes", use: changes)
        sync.post("mutations", use: mutate)
    }

    // MARK: Feed

    private func parseCursor(_ raw: String?) throws -> Int {
        guard let raw else { return 0 }
        guard raw.hasPrefix("c"), let value = Int(raw.dropFirst()), value >= 0 else {
            throw Abort(.badRequest, reason: "invalid_cursor")
        }
        return value
    }

    static func cursor(_ seq: Int) -> String { "c\(seq)" }

    @Sendable func changes(_ req: Request) async throws -> SyncChangesResponse {
        let user = try await req.requireUser()
        let userID = try user.requireID()
        let cursor = try parseCursor(req.query[String.self, at: "cursor"])
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.defaultLimit, 1), Self.maxLimit)
        guard let sql = req.db as? any SQLDatabase,
              let head = try await sql.raw("SELECT value FROM sync_counter WHERE id = \(bind: syncCounterID)").first()
        else { throw Abort(.internalServerError) }
        // A cursor ahead of the log (restored backup, forged value) cannot be continued; the client restarts at 0.
        guard cursor <= (try head.decode(column: "value", as: Int.self)) else { throw Abort(.conflict, reason: "cursor_ahead") }

        var rows = try await SyncChange.query(on: req.db).filter(\.$seq > cursor).sort(\.$seq).limit(limit + 1).all()
        // Retention (ADR 0019): tombstones below the floor may have been purged, so a cursor below it cannot be
        // continued. Checked after reading the rows: the floor is raised in the same transaction as the purge, so a
        // reader that missed a purged tombstone always sees the raised floor here. `c0` (full state) is never stale.
        if cursor > 0, cursor < (try await SyncRetention.floor(on: req.db)) { throw Abort(.gone, reason: "cursor_expired") }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        let last = rows.last?.seq ?? cursor

        // An entity changed several times within the page is delivered once, with its latest state.
        var lastUpsert: [UUID: Int] = [:]
        for row in rows where row.kind == "upsert" { lastUpsert[row.entityID] = row.seq }

        let access = ProjectAccess(user: user, db: req.db)
        var result: [SyncChangeDTO] = []
        for row in rows {
            if row.kind == "delete" || row.kind == "revoke" {
                let allowed = try await SyncTombstoneAudience.query(on: req.db)
                    .filter(\.$seq == row.seq).filter(\.$userID == userID).count() > 0
                if allowed {
                    // A later regrant/move may have restored access. Never remove currently readable data
                    // because of a historical revocation, including when the regrant is on another page.
                    if row.kind == "revoke" {
                        do {
                            if row.entityType == "project" { _ = try await access.project(row.entityID) }
                            else if row.entityType == "label" { continue }
                            else if row.entityType == "column" {
                                guard let c = try await ProjectColumn.find(row.entityID, on: req.db) else { throw Abort(.notFound) }
                                _ = try await access.project(c.projectID)
                            }
                            else { _ = try await access.task(row.entityID) }
                            continue
                        } catch let error as any AbortError where error.status == .notFound || error.status == .forbidden {
                            // Still inaccessible: deliver the frozen revocation audience's tombstone.
                        }
                    }
                    result.append(SyncChangeDTO(seq: row.seq, entityType: row.entityType, entityID: row.entityID,
                        kind: "delete", project: nil, task: nil))
                }
                continue
            }
            guard lastUpsert[row.entityID] == row.seq else { continue }
            // Same authorization as the REST reads; anything unreadable (or gone) is silently omitted.
            do {
                if row.entityType == "project" {
                    let project = try await access.project(row.entityID)
                    result.append(SyncChangeDTO(seq: row.seq, entityType: "project", entityID: row.entityID,
                        kind: "upsert", project: try await access.dto(project), task: nil))
                } else if row.entityType == "label" {
                    guard let label = try await DiscoveryLabel.find(row.entityID, on: req.db), label.ownerID == userID else { continue }
                    result.append(SyncChangeDTO(seq: row.seq, entityType: "label", entityID: row.entityID,
                        kind: "upsert", project: nil, task: nil, label: try await SyncLabelDTO.make(label, user: user, on: req.db)))
                } else if row.entityType == "column" {
                    guard let column = try await ProjectColumn.find(row.entityID, on: req.db) else { continue }
                    _ = try await access.project(column.projectID)
                    result.append(SyncChangeDTO(seq: row.seq, entityType: "column", entityID: row.entityID,
                        kind: "upsert", project: nil, task: nil, column: try ColumnDTO(column)))
                } else {
                    let task = try await access.task(row.entityID)
                    result.append(SyncChangeDTO(seq: row.seq, entityType: "task", entityID: row.entityID,
                        kind: "upsert", project: nil, task: try TaskDTO(task),
                        planning: SyncPlanningDTO(try await TaskPlanning.find(row.entityID, on: req.db))))
                }
            } catch let error as any AbortError where error.status == .notFound || error.status == .forbidden {
                continue
            }
        }
        return SyncChangesResponse(changes: result, cursor: Self.cursor(last), hasMore: hasMore)
    }

    // MARK: Mutations

    private func requestHash(_ body: SyncMutationRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AuthSupport.hash(String(decoding: try encoder.encode(body), as: UTF8.self))
    }

    private func jsonResponse(_ status: HTTPStatus, _ json: String, replay: Bool) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        if replay { headers.add(name: "Idempotent-Replay", value: "true") }
        return Response(status: status, headers: headers, body: .init(string: json))
    }

    @Sendable func mutate(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let body = try req.content.decode(SyncMutationRequest.self)
        let hash = try requestHash(body)
        let userID = try user.requireID()
        let outcome: (status: HTTPStatus, json: String, replay: Bool) = try await req.db.transaction { db in
            // Lock before the first read (MariaDB snapshot isolation); this also serialises duplicate deliveries
            // of the same mutation arriving on different replicas.
            try await lockSharingGraph(on: db)
            if let stored = try await SyncMutation.query(on: db).filter(\.$userID == userID)
                .filter(\.$mutationID == body.mutationID).first() {
                guard stored.requestHash == hash else { throw Abort(.conflict, reason: "mutation_id_reused") }
                return (HTTPStatus(statusCode: stored.status), stored.response, true)
            }
            let (status, response) = try await apply(body, user: user, on: db)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let json = String(decoding: try encoder.encode(response), as: UTF8.self)
            try await SyncMutation(userID: userID, mutationID: body.mutationID, requestHash: hash,
                status: Int(status.code), response: json).save(on: db)
            return (status, json, false)
        }
        return jsonResponse(outcome.status, outcome.json, replay: outcome.replay)
    }

    private func labelName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw Abort(.badRequest, reason: "invalid_name") }
        return value
    }

    private func cursorNow(_ db: any Database) async throws -> String {
        guard let sql = db as? any SQLDatabase,
              let row = try await sql.raw("SELECT value FROM sync_counter WHERE id = \(bind: syncCounterID)").first()
        else { throw Abort(.internalServerError) }
        return Self.cursor(try row.decode(column: "value", as: Int.self))
    }

    /// Dispatches to the same operations as the REST routes, so permission checks cannot differ between paths.
    private func apply(_ m: SyncMutationRequest, user: User, on db: any Database) async throws -> (HTTPStatus, SyncMutationResponse) {
        func result(_ status: HTTPStatus, project: ProjectDTO? = nil, task: TaskDTO? = nil, column: ColumnDTO? = nil,
                    planning: SyncPlanningDTO? = nil, label: SyncLabelDTO? = nil, deleted: Bool = false) async throws -> (HTTPStatus, SyncMutationResponse) {
            (status, SyncMutationResponse(mutationID: m.mutationID, type: m.type, id: m.id, deleted: deleted,
                project: project, task: task, column: column, planning: planning, label: label, cursor: try await cursorNow(db)))
        }
        func requireVersion() throws -> Int {
            guard let version = m.version else { throw Abort(.badRequest, reason: "version_required") }
            return version
        }
        func requireFreshID() async throws {
            let projectExists = try await Project.find(m.id, on: db) != nil
            let taskExists = try await TodoTask.find(m.id, on: db) != nil
            let columnExists = try await ProjectColumn.find(m.id, on: db) != nil
            let labelExists = try await DiscoveryLabel.find(m.id, on: db) != nil
            if projectExists || taskExists || columnExists || labelExists {
                throw Abort(.conflict, reason: "id_exists")
            }
            if try await SyncRecorder.wasDeleted(m.id, on: db) { throw Abort(.conflict, reason: "id_deleted") }
        }
        switch m.type {
        case "project.create":
            guard let name = m.name else { throw Abort(.badRequest, reason: "invalid_name") }
            try await requireFreshID()
            let project = try await PlanningOperations.createProject(
                user: user, db: db, id: m.id,
                body: CreateProjectRequest(name: name, parentID: m.parentID, description: m.description, color: m.color))
            return try await result(.created, project: ProjectAccess(user: user, db: db).dto(project))
        case "project.update":
            let dto = try await PlanningOperations.updateProject(user: user, db: db, id: m.id,
                body: UpdateProjectRequest(version: try requireVersion(), name: m.name, parentID: m.parentID.map { Optional($0) },
                    moveToRoot: m.moveToRoot, description: m.description, color: m.color))
            return try await result(.ok, project: dto)
        case "project.position":
            // Without parentID/moveToRoot the viewer's current parent is kept (pure personal reorder).
            guard let index = m.index else { throw Abort(.badRequest, reason: "invalid_index") }
            let dto = try await ProjectStateService(user: user, db: db).position(m.id, ProjectPositionRequest(
                index: index, version: m.version, parentSpecified: m.moveToRoot == true || m.parentID != nil,
                parentID: m.moveToRoot == true ? nil : m.parentID))
            return try await result(.ok, project: dto)
        case "project.delete":
            try await PlanningOperations.deleteProject(user: user, db: db, id: m.id, expectedVersion: m.version)
            return try await result(.ok, deleted: true)
        case "task.create":
            guard let projectID = m.projectID, let title = m.title else { throw Abort(.badRequest, reason: "invalid_title") }
            try await requireFreshID()
            let task = try await PlanningOperations.createTask(
                user: user, db: db, id: m.id, body: CreateTaskRequest(projectID: projectID, title: title, description: m.description))
            return try await result(.created, task: TaskDTO(task))
        case "task.update":
            let dto = try await PlanningService(user: user, db: db).update(m.id,
                body: UpdateTaskRequest(version: try requireVersion(), title: m.title, description: m.description,
                    status: m.status, projectID: m.projectID))
            return try await result(.ok, task: dto)
        case "task.delete":
            try await PlanningOperations.deleteTask(user: user, db: db, id: m.id, expectedVersion: m.version)
            return try await result(.ok, deleted: true)
        case "task.move_column":
            let dto = try await ColumnService(user: user, db: db).move(m.id,
                MoveTaskRequest(version: try requireVersion(), columnID: m.columnID, index: m.index))
            return try await result(.ok, task: dto)
        case "column.create":
            guard let projectID = m.projectID, let name = m.name else { throw Abort(.badRequest, reason: "invalid_name") }
            try await requireFreshID()
            let column = try await ColumnService(user: user, db: db).create(projectID,
                CreateColumnRequest(name: name, color: m.color, isDone: m.isDone, index: m.index), id: m.id)
            return try await result(.created, column: ColumnDTO(column))
        case "column.update":
            let column = try await ColumnService(user: user, db: db).update(m.id,
                UpdateColumnRequest(version: try requireVersion(), name: m.name, color: m.color, isDone: m.isDone, index: m.index))
            return try await result(.ok, column: ColumnDTO(column))
        case "column.delete":
            var moveTo: UUID??
            if let raw = m.moveTo {
                if raw == "none" { moveTo = .some(nil) }
                else if let id = UUID(uuidString: raw) { moveTo = .some(id) }
                else { throw Abort(.badRequest, reason: "invalid_move_to") }
            }
            try await ColumnService(user: user, db: db).delete(m.id, moveTo: moveTo, expectedVersion: m.version)
            return try await result(.ok, deleted: true)
        case "task.planning":
            let data = PlanningData(dueAt: m.dueAt, plannedAt: m.plannedAt, priority: m.priority ?? 0,
                recurrence: m.recurrence, reminders: m.reminders ?? [])
            let dto = try await PlanningService(user: user, db: db).put(m.id, data: data, expectedVersion: try requireVersion())
            return try await result(.ok, task: dto.task, planning: SyncPlanningDTO(try await TaskPlanning.find(m.id, on: db)))
        case "label.create":
            guard let raw = m.name else { throw Abort(.badRequest, reason: "invalid_name") }
            let name = try labelName(raw)
            try await requireFreshID()
            let label = DiscoveryLabel(ownerID: try user.requireID(), name: name)
            label.id = m.id
            try await label.save(on: db)
            return try await result(.created, label: SyncLabelDTO.make(label, user: user, on: db))
        case "label.rename":
            guard let raw = m.name else { throw Abort(.badRequest, reason: "invalid_name") }
            try await lockRow(table: DiscoveryLabel.schema, id: m.id, on: db)
            let label = try await DiscoveryService(user: user, db: db).label(m.id)
            guard label.version == (try requireVersion()) else { throw Abort(.conflict, reason: "version_conflict") }
            label.name = try labelName(raw)
            label.version += 1
            try await label.save(on: db)
            return try await result(.ok, label: SyncLabelDTO.make(label, user: user, on: db))
        case "label.delete":
            try await lockRow(table: DiscoveryLabel.schema, id: m.id, on: db)
            let label = try await DiscoveryService(user: user, db: db).label(m.id)
            if let version = m.version, version != label.version { throw Abort(.conflict, reason: "version_conflict") }
            try await label.delete(on: db)
            return try await result(.ok, deleted: true)
        case "task.label_add", "task.label_remove":
            guard let labelID = m.labelID else { throw Abort(.badRequest, reason: "invalid_label") }
            // Same rules as PUT/DELETE /v1/tasks/{id}/labels/{labelID}: own label, readable task, idempotent.
            try await lockRow(table: DiscoveryLabel.schema, id: labelID, on: db)
            let service = DiscoveryService(user: user, db: db)
            let label = try await service.label(labelID)
            _ = try await service.task(m.id)
            let existing = try await DiscoveryTaskLabel.query(on: db)
                .filter(\.$taskID == m.id).filter(\.$labelID == labelID).first()
            if m.type == "task.label_add", existing == nil { try await DiscoveryTaskLabel(taskID: m.id, labelID: labelID).save(on: db) }
            else if m.type == "task.label_remove", let existing { try await existing.delete(on: db) }
            return try await result(.ok, label: SyncLabelDTO.make(label, user: user, on: db))
        default:
            throw Abort(.badRequest, reason: "unknown_mutation_type")
        }
    }
}
