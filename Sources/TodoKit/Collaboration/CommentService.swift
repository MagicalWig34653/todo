import Crypto
import Fluent
import Vapor

/// Shared comment business rules for REST and MCP. Rights are rechecked after the task row lock.
enum CommentService {
    static func text(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 10_000 else { throw Abort(.badRequest, reason: "invalid_text") }
        return value
    }

    /// Returns the hashed key, or nil if no key was sent.
    static func keyHash(_ key: String?) throws -> String? {
        guard let key else { return nil }
        guard !key.isEmpty, key.utf8.count <= 200, key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw Abort(.badRequest, reason: "invalid_idempotency_key")
        }
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `scope` lets a delegated client (OAuth grant) narrow access; it runs on the authorized task.
    static func create(
        taskID: UUID, user: User, body: String, idempotencyKey: String?,
        actor: (type: ActivityActorType, id: UUID)? = nil,
        scope: @escaping @Sendable (TodoTask) throws -> Void = { _ in }, on database: any Database
    ) async throws -> CommentDTO {
        try scope(try await ProjectAccess(user: user, db: database).task(taskID, role: .comment))
        let body = try text(body)
        let hash = try keyHash(idempotencyKey)
        return try await database.transaction { db in
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            try scope(try await ProjectAccess(user: user, db: db).task(taskID, role: .comment))
            let userID = try user.requireID()
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
            try await appendActivity(taskID: taskID, actorType: actor?.type ?? .person, actorID: actor?.id ?? userID, kind: "comment.created", subjectID: c.id, on: db)
            return try CommentDTO(c)
        }
    }
}
