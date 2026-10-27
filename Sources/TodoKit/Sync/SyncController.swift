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
}

struct SyncChangesResponse: Content {
    let changes: [SyncChangeDTO]
    let cursor: String
    let hasMore: Bool
}

struct SyncMutationRequest: Content {
    let mutationID: UUID
    /// project.create | project.update | project.delete | task.create | task.update | task.delete
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
}

struct SyncMutationResponse: Content {
    let mutationID: UUID
    let type: String
    let id: UUID
    let deleted: Bool
    let project: ProjectDTO?
    let task: TaskDTO?
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
                } else {
                    let task = try await access.task(row.entityID)
                    result.append(SyncChangeDTO(seq: row.seq, entityType: "task", entityID: row.entityID,
                        kind: "upsert", project: nil, task: try TaskDTO(task)))
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

    private func cursorNow(_ db: any Database) async throws -> String {
        guard let sql = db as? any SQLDatabase,
              let row = try await sql.raw("SELECT value FROM sync_counter WHERE id = \(bind: syncCounterID)").first()
        else { throw Abort(.internalServerError) }
        return Self.cursor(try row.decode(column: "value", as: Int.self))
    }

    /// Dispatches to the same operations as the REST routes, so permission checks cannot differ between paths.
    private func apply(_ m: SyncMutationRequest, user: User, on db: any Database) async throws -> (HTTPStatus, SyncMutationResponse) {
        func result(_ status: HTTPStatus, project: ProjectDTO? = nil, task: TaskDTO? = nil, deleted: Bool = false) async throws
            -> (HTTPStatus, SyncMutationResponse) {
            (status, SyncMutationResponse(mutationID: m.mutationID, type: m.type, id: m.id, deleted: deleted,
                project: project, task: task, cursor: try await cursorNow(db)))
        }
        func requireVersion() throws -> Int {
            guard let version = m.version else { throw Abort(.badRequest, reason: "version_required") }
            return version
        }
        func requireFreshID() async throws {
            let projectExists = try await Project.find(m.id, on: db) != nil
            let taskExists = try await TodoTask.find(m.id, on: db) != nil
            if projectExists || taskExists {
                throw Abort(.conflict, reason: "id_exists")
            }
            if try await SyncRecorder.wasDeleted(m.id, on: db) { throw Abort(.conflict, reason: "id_deleted") }
        }
        switch m.type {
        case "project.create":
            guard let name = m.name else { throw Abort(.badRequest, reason: "invalid_name") }
            try await requireFreshID()
            let project = try await PlanningOperations.createProject(
                user: user, db: db, id: m.id, body: CreateProjectRequest(name: name, parentID: m.parentID))
            return try await result(.created, project: ProjectAccess(user: user, db: db).dto(project))
        case "project.update":
            let dto = try await PlanningOperations.updateProject(user: user, db: db, id: m.id,
                body: UpdateProjectRequest(version: try requireVersion(), name: m.name, parentID: m.parentID.map { Optional($0) },
                    moveToRoot: m.moveToRoot))
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
        default:
            throw Abort(.badRequest, reason: "unknown_mutation_type")
        }
    }
}
