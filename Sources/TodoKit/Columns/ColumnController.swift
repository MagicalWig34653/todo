import Fluent
import Vapor

struct ColumnController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("projects", ":id", "columns", use: list)
        v1.post("projects", ":id", "columns", use: create)
        v1.post("projects", ":id", "columns", "template", use: template)
        v1.get("projects", ":id", "board", use: board)
        v1.patch("projects", ":id", "columns", ":columnID", use: update)
        v1.delete("projects", ":id", "columns", ":columnID", use: remove)
        v1.put("tasks", ":id", "column", use: move)
    }

    private func param(_ req: Request, _ name: String = "id") throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    @Sendable func list(_ req: Request) async throws -> [ColumnDTO] {
        let s = ColumnService(user: try await req.requireUser(), db: req.db)
        let project = try param(req)
        _ = try await s.access.project(project)
        return try await s.columns(of: project).map(ColumnDTO.init)
    }

    @Sendable func board(_ req: Request) async throws -> BoardResponse {
        try await ColumnService(user: try await req.requireUser(), db: req.db).board(try param(req))
    }

    @Sendable func create(_ req: Request) async throws -> Response {
        let user = try await req.requireUser(), project = try param(req)
        let body = try req.content.decode(CreateColumnRequest.self)
        let dto = try await req.db.transaction { db in try ColumnDTO(try await ColumnService(user: user, db: db).create(project, body)) }
        return try await dto.encodeResponse(status: .created, for: req)
    }

    @Sendable func template(_ req: Request) async throws -> Response {
        let user = try await req.requireUser(), project = try param(req)
        let body = try req.content.decode(ColumnTemplateRequest.self)
        let dtos = try await req.db.transaction { db in
            try await ColumnService(user: user, db: db).applyTemplate(project, source: body.source).map(ColumnDTO.init)
        }
        return try await dtos.encodeResponse(status: .created, for: req)
    }

    @Sendable func update(_ req: Request) async throws -> ColumnDTO {
        let user = try await req.requireUser(), project = try param(req), id = try param(req, "columnID")
        let body = try req.content.decode(UpdateColumnRequest.self)
        return try await req.db.transaction { db in
            let s = ColumnService(user: user, db: db)
            try await s.assertColumn(id, in: project)
            return try ColumnDTO(try await s.update(id, body))
        }
    }

    /// `?moveTo=<columnID>` | `?moveTo=none` ("Ohne Spalte") | omitted (first remaining column); `?version=n` optional.
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser(), project = try param(req), id = try param(req, "columnID")
        var moveTo: UUID??
        if let raw = req.query[String.self, at: "moveTo"] {
            if raw == "none" { moveTo = .some(nil) }
            else if let u = UUID(uuidString: raw) { moveTo = .some(u) }
            else { throw Abort(.badRequest, reason: "invalid_move_to") }
        }
        let version = req.query[Int.self, at: "version"]
        let target = moveTo
        try await req.db.transaction { db in
            let s = ColumnService(user: user, db: db)
            try await s.assertColumn(id, in: project)
            try await s.delete(id, moveTo: target, expectedVersion: version)
        }
        return .noContent
    }

    @Sendable func move(_ req: Request) async throws -> TaskDTO {
        let user = try await req.requireUser(), id = try param(req)
        let body = try req.content.decode(MoveTaskRequest.self)
        return try await req.db.transaction { db in try await ColumnService(user: user, db: db).move(id, body) }
    }
}

extension ColumnService {
    /// Path consistency: the column exists, is visible and belongs to `project`.
    func assertColumn(_ id: UUID, in project: UUID) async throws {
        guard let c = try await ProjectColumn.find(id, on: db), c.projectID == project else { throw Abort(.notFound) }
        _ = try await access.project(project, role: .read)
    }
}
