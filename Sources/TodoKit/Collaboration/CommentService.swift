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

    /// Optional thread target. A question or review must belong to the same task.
    struct Target: Sendable { var questionID: UUID? = nil; var reviewID: UUID? = nil }

    static func validate(_ target: Target, taskID: UUID, on db: any Database) async throws {
        if target.questionID != nil && target.reviewID != nil { throw Abort(.badRequest, reason: "invalid_thread") }
        if let q = target.questionID {
            guard let row = try await TaskQuestion.find(q, on: db), row.taskID == taskID else { throw Abort(.notFound, reason: "question_not_found") }
        }
        if let r = target.reviewID {
            guard let row = try await TaskReview.find(r, on: db), row.taskID == taskID else { throw Abort(.notFound, reason: "review_not_found") }
        }
    }

    /// `scope` lets a delegated client (OAuth grant) narrow access; it runs on the authorized task.
    static func create(
        taskID: UUID, user: User, body: String, idempotencyKey: String?,
        actor: (type: ActivityActorType, id: UUID)? = nil, target: Target = Target(), agentLabel: String? = nil,
        scope: @escaping @Sendable (TodoTask) throws -> Void = { _ in }, on database: any Database
    ) async throws -> CommentDTO {
        try scope(try await ProjectAccess(user: user, db: database).task(taskID, role: .comment))
        let body = try text(body)
        let label = try agentLabel.map { raw -> String in
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, v.count <= 100 else { throw Abort(.badRequest, reason: "invalid_agent_name") }
            return v
        }
        let hash = try keyHash(idempotencyKey)
        return try await database.transaction { db in
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            try scope(try await ProjectAccess(user: user, db: db).task(taskID, role: .comment))
            let userID = try user.requireID()
            try await validate(target, taskID: taskID, on: db)
            if let hash, let saved = try await CommentIdempotency.query(on: db)
                .filter(\.$taskID == taskID).filter(\.$userID == userID).filter(\.$keyHash == hash).first() {
                guard saved.requestBody == body else { throw Abort(.conflict, reason: "idempotency_conflict") }
                if let original = try await TaskComment.find(saved.commentID, on: db) { return try CommentDTO(original) }
                return CommentDTO(saved)
            }
            let c = TaskComment(taskID: taskID, authorID: userID, body: body)
            c.questionID = target.questionID; c.reviewID = target.reviewID
            // Person = REST/PWA; integration or run = agent.
            let isAgent = (actor?.type ?? .person) != .person
            c.authorKind = isAgent ? "agent" : "person"
            c.authorLabel = isAgent ? label : nil
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

    /// Author edits own comment (REST and MCP). `agentOnly` additionally limits an integration to comments written by agents.
    static func edit(
        taskID: UUID, commentID: UUID, user: User, body raw: String, version: Int,
        actor: (type: ActivityActorType, id: UUID)? = nil, agentOnly: Bool = false,
        scope: @escaping @Sendable (TodoTask) throws -> Void = { _ in }, on database: any Database
    ) async throws -> CommentDTO {
        try scope(try await ProjectAccess(user: user, db: database).task(taskID, role: .comment))
        let body = try text(raw)
        return try await database.transaction { db in
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            try scope(try await ProjectAccess(user: user, db: db).task(taskID, role: .comment))
            let userID = try user.requireID()
            guard let c = try await TaskComment.find(commentID, on: db), c.taskID == taskID else { throw Abort(.notFound) }
            guard c.authorID == userID else { throw Abort(.forbidden, reason: "not_comment_author") }
            if agentOnly, c.authorKind != "agent" { throw Abort(.forbidden, reason: "not_agent_comment") }
            guard c.version == version else { throw Abort(.conflict, reason: "version_conflict") }
            c.body = body; c.version += 1
            try await c.save(on: db)
            try await appendActivity(taskID: taskID, actorType: actor?.type ?? .person, actorID: actor?.id ?? userID, kind: "comment.updated", subjectID: c.id, on: db)
            return try CommentDTO(c)
        }
    }

    /// Author, or a user with manage rights, deletes a comment. `version` must match when given by MCP; REST always passes it.
    static func delete(
        taskID: UUID, commentID: UUID, user: User, version: Int?,
        actor: (type: ActivityActorType, id: UUID)? = nil, on database: any Database
    ) async throws {
        _ = try await ProjectAccess(user: user, db: database).task(taskID, role: .comment)
        try await database.transaction { db in
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            _ = try await ProjectAccess(user: user, db: db).task(taskID, role: .comment)
            let userID = try user.requireID()
            guard let c = try await TaskComment.find(commentID, on: db), c.taskID == taskID else { throw Abort(.notFound) }
            if c.authorID != userID {
                // Moderation of foreign comments requires manage rights on the project.
                do { _ = try await ProjectAccess(user: user, db: db).task(taskID, role: .manage) }
                catch { throw Abort(.forbidden, reason: "not_comment_author") }
            }
            if let version, c.version != version { throw Abort(.conflict, reason: "version_conflict") }
            try await c.delete(on: db)
            try await appendActivity(taskID: taskID, actorType: actor?.type ?? .person, actorID: actor?.id ?? userID, kind: "comment.deleted", subjectID: c.id, on: db)
        }
    }
}
