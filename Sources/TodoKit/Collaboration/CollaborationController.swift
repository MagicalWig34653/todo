import Crypto
import Fluent
import Vapor

private struct CommentInput: Content { let body: String; let version: Int? }
private struct CriterionInput: Content { let text: String?; let completed: Bool?; let version: Int? }
private struct VersionInput: Content { let version: Int }
struct ActivityPage: Content { let items: [ActivityDTO]; let nextCursor: String? }

struct CollaborationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let tasks = routes.grouped("v1", "tasks", ":taskID")
        tasks.get("comments", use: comments)
        tasks.get("comments", ":resourceID", use: comment)
        tasks.post("comments", use: createComment)
        tasks.patch("comments", ":resourceID", use: editComment)
        tasks.delete("comments", ":resourceID", use: deleteComment)
        tasks.get("activity", use: activity)
        tasks.get("acceptance-criteria", use: criteria)
        tasks.get("acceptance-criteria", ":resourceID", use: criterion)
        tasks.post("acceptance-criteria", use: createCriterion)
        tasks.patch("acceptance-criteria", ":resourceID", use: editCriterion)
        tasks.delete("acceptance-criteria", ":resourceID", use: deleteCriterion)
    }

    private func parameter(_ req: Request, _ name: String) throws -> UUID {
        guard let value = req.parameters.get(name, as: UUID.self) else { throw Abort(.badRequest) }
        return value
    }
    private func text(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 10_000 else { throw Abort(.badRequest, reason: "invalid_text") }
        return value
    }
    private func checkVersion(_ actual: Int, _ expected: Int?) throws {
        guard let expected else { throw Abort(.badRequest, reason: "version_required") }
        guard actual == expected else { throw Abort(.conflict, reason: "version_conflict") }
    }
    private func authorized(_ req: Request) async throws -> UUID {
        let user = try await req.requireUser()
        let taskID = try parameter(req, "taskID")
        _ = try await ProjectAccess(user: user, db: req.db).task(taskID)
        return taskID
    }
    // Access is rechecked after acquiring the lock, including during long-running transactions.
    private func mutate<T: Sendable>(_ req: Request, _ operation: @escaping @Sendable (any Database, UUID, UUID) async throws -> T) async throws -> T {
        let user = try await req.requireUser()
        let taskID = try await authorized(req)
        return try await req.db.transaction { db in
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            _ = try await ProjectAccess(user: user, db: db).task(taskID)
            return try await operation(db, taskID, user.requireID())
        }
    }
    private func loadComment(_ req: Request, taskID: UUID, on db: any Database) async throws -> TaskComment {
        guard let c = try await TaskComment.find(parameter(req, "resourceID"), on: db), c.taskID == taskID else { throw Abort(.notFound) }
        return c
    }
    private func loadCriterion(_ req: Request, taskID: UUID, on db: any Database) async throws -> AcceptanceCriterion {
        guard let c = try await AcceptanceCriterion.find(parameter(req, "resourceID"), on: db), c.taskID == taskID else { throw Abort(.notFound) }
        return c
    }
    @Sendable func comments(_ req: Request) async throws -> [CommentDTO] {
        let taskID = try await authorized(req)
        return try await TaskComment.query(on: req.db).filter(\.$taskID == taskID).sort(\.$id).all().map(CommentDTO.init)
    }
    @Sendable func comment(_ req: Request) async throws -> CommentDTO {
        let taskID = try await authorized(req)
        return try await CommentDTO(loadComment(req, taskID: taskID, on: req.db))
    }
    @Sendable func createComment(_ req: Request) async throws -> Response {
        _ = try await authorized(req)
        let input = try req.content.decode(CommentInput.self)
        let body = try text(input.body)
        let keys = req.headers["Idempotency-Key"]
        guard keys.count <= 1 else { throw Abort(.badRequest, reason: "invalid_idempotency_key") }
        let key = keys.first
        if let key {
            guard !key.isEmpty, key.utf8.count <= 200, key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
                throw Abort(.badRequest, reason: "invalid_idempotency_key")
            }
        }
        let hash = key.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        let dto = try await mutate(req) { db, taskID, userID in
            if let hash, let saved = try await CommentIdempotency.query(on: db)
                .filter(\.$taskID == taskID).filter(\.$userID == userID).filter(\.$keyHash == hash).first() {
                guard saved.requestBody == body else { throw Abort(.conflict, reason: "idempotency_conflict") }
                return CommentDTO(saved)
            }
            let c = TaskComment(taskID: taskID, authorID: userID, body: body)
            try await c.save(on: db)
            if let hash {
                let saved = CommentIdempotency()
                saved.taskID = taskID; saved.userID = userID; saved.keyHash = hash
                saved.requestBody = body; saved.commentID = try c.requireID()
                try await saved.save(on: db)
            }
            try await appendActivity(taskID: taskID, actorType: .person, actorID: userID, kind: "comment.created", subjectID: c.id, on: db)
            return try CommentDTO(c)
        }
        return try await dto.encodeResponse(status: .created, for: req)
    }
    @Sendable func editComment(_ req: Request) async throws -> CommentDTO {
        _ = try await authorized(req)
        let input = try req.content.decode(CommentInput.self)
        return try await mutate(req) { db, taskID, userID in
            let c = try await loadComment(req, taskID: taskID, on: db)
            try checkVersion(c.version, input.version)
            c.body = try text(input.body); c.version += 1
            try await c.save(on: db)
            try await appendActivity(taskID: taskID, actorType: .person, actorID: userID, kind: "comment.updated", subjectID: c.id, on: db)
            return try CommentDTO(c)
        }
    }
    @Sendable func deleteComment(_ req: Request) async throws -> HTTPStatus {
        _ = try await authorized(req)
        let input = try req.content.decode(VersionInput.self)
        return try await mutate(req) { db, taskID, userID in
            let c = try await loadComment(req, taskID: taskID, on: db)
            try checkVersion(c.version, input.version)
            try await c.delete(on: db)
            try await appendActivity(taskID: taskID, actorType: .person, actorID: userID, kind: "comment.deleted", subjectID: c.id, on: db)
            return .noContent
        }
    }
    @Sendable func criteria(_ req: Request) async throws -> [CriterionDTO] {
        let taskID = try await authorized(req)
        return try await AcceptanceCriterion.query(on: req.db).filter(\.$taskID == taskID).sort(\.$id).all().map(CriterionDTO.init)
    }
    @Sendable func criterion(_ req: Request) async throws -> CriterionDTO {
        let taskID = try await authorized(req)
        return try await CriterionDTO(loadCriterion(req, taskID: taskID, on: req.db))
    }
    @Sendable func createCriterion(_ req: Request) async throws -> Response {
        _ = try await authorized(req)
        let input = try req.content.decode(CriterionInput.self)
        guard let raw = input.text else { throw Abort(.badRequest, reason: "text_required") }
        let value = try text(raw)
        let dto = try await mutate(req) { db, taskID, userID in
            let c = AcceptanceCriterion(taskID: taskID, text: value)
            c.completed = input.completed ?? false
            try await c.save(on: db)
            try await appendActivity(taskID: taskID, actorType: .person, actorID: userID, kind: "criterion.created", subjectID: c.id, on: db)
            return try CriterionDTO(c)
        }
        return try await dto.encodeResponse(status: .created, for: req)
    }
    @Sendable func editCriterion(_ req: Request) async throws -> CriterionDTO {
        _ = try await authorized(req)
        let input = try req.content.decode(CriterionInput.self)
        return try await mutate(req) { db, taskID, userID in
            let c = try await loadCriterion(req, taskID: taskID, on: db)
            try checkVersion(c.version, input.version)
            guard input.text != nil || input.completed != nil else { throw Abort(.badRequest) }
            if let raw = input.text { c.text = try text(raw) }
            if let completed = input.completed { c.completed = completed }
            c.version += 1
            try await c.save(on: db)
            try await appendActivity(taskID: taskID, actorType: .person, actorID: userID, kind: "criterion.updated", subjectID: c.id, on: db)
            return try CriterionDTO(c)
        }
    }
    @Sendable func deleteCriterion(_ req: Request) async throws -> HTTPStatus {
        _ = try await authorized(req)
        let input = try req.content.decode(VersionInput.self)
        return try await mutate(req) { db, taskID, userID in
            let c = try await loadCriterion(req, taskID: taskID, on: db)
            try checkVersion(c.version, input.version)
            try await c.delete(on: db)
            try await appendActivity(taskID: taskID, actorType: .person, actorID: userID, kind: "criterion.deleted", subjectID: c.id, on: db)
            return .noContent
        }
    }
    @Sendable func activity(_ req: Request) async throws -> ActivityPage {
        let taskID = try await authorized(req)
        var after = 0
        if let cursor = req.query[String.self, at: "cursor"] {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, UUID(uuidString: String(parts[0])) == taskID,
                  let sequence = Int(parts[1]), sequence >= 0 else { throw Abort(.badRequest, reason: "invalid_cursor") }
            after = sequence
        }
        let rawLimit = req.query[String.self, at: "limit"] ?? "50"
        guard let limit = Int(rawLimit), (1...100).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        let rows = try await ActivityEvent.query(on: req.db).filter(\.$taskID == taskID)
            .filter(\.$sequence > after).sort(\.$sequence).limit(limit + 1).all()
        let page = Array(rows.prefix(limit))
        return try ActivityPage(items: page.map(ActivityDTO.init), nextCursor: rows.count > limit ? "\(taskID):\(page.last!.sequence)" : nil)
    }
}
