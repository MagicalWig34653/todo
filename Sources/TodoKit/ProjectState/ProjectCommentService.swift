import Fluent
import SQLKit
import Vapor

struct ProjectCommentDTO: Content {
    let id: UUID
    let projectID: UUID
    let authorID: UUID
    var authorName: String?
    let body: String
    let version: Int
    let createdAt: Date?
    init(_ c: ProjectComment) throws {
        id = try c.requireID(); projectID = c.projectID; authorID = c.authorID; body = c.body
        version = c.version; createdAt = c.createdAt
    }
}

/// Appends a project-level event. Caller holds the project row lock inside a transaction and checked ProjectAccess.
func appendProjectActivity(projectID: UUID, actorType: ActivityActorType, actorID: UUID, kind: String,
                           subjectID: UUID?, on db: any Database) async throws {
    let last: Int
    if let sql = db as? any SQLDatabase, sql.dialect.name != "sqlite" {
        last = try await sql.raw("SELECT \(ident: "sequence") FROM \(ident: ProjectActivityEvent.schema) WHERE \(ident: "project_id") = \(bind: projectID) ORDER BY \(ident: "sequence") DESC LIMIT 1 FOR UPDATE")
            .first(decodingColumn: "sequence", as: Int.self) ?? 0
    } else {
        last = try await ProjectActivityEvent.query(on: db).filter(\.$projectID == projectID)
            .sort(\.$sequence, .descending).first()?.sequence ?? 0
    }
    let event = ProjectActivityEvent()
    event.projectID = projectID; event.sequence = last + 1
    event.actorType = actorType; event.actorID = actorID; event.kind = kind; event.subjectID = subjectID
    try await event.save(on: db)
}

/// Project comments: same rules as task comments (read to list, comment to create, author edits, author or manage
/// deletes, optimistic `version`, optional `Idempotency-Key`), rights always through `ProjectAccess`.
struct ProjectCommentService: Sendable {
    let user: User
    let db: any Database
    var access: ProjectAccess { ProjectAccess(user: user, db: db) }

    private func named(_ comments: [ProjectCommentDTO]) async throws -> [ProjectCommentDTO] {
        let names = try await displayNames(comments.map(\.authorID), on: db)
        return comments.map { var c = $0; c.authorName = names[c.authorID]; return c }
    }

    func list(_ projectID: UUID) async throws -> [ProjectCommentDTO] {
        _ = try await access.project(projectID, role: .read)
        let rows = try await ProjectComment.query(on: db).filter(\.$projectID == projectID)
            .sort(\.$createdAt).sort(\.$id).all()
        return try await named(rows.map(ProjectCommentDTO.init))
    }

    func create(_ projectID: UUID, body raw: String, idempotencyKey: String?) async throws -> ProjectCommentDTO {
        _ = try await access.project(projectID, role: .comment)
        let body = try CommentService.text(raw)
        let hash = try CommentService.keyHash(idempotencyKey)
        let userID = try user.requireID()
        let dto = try await db.transaction { db -> ProjectCommentDTO in
            try await lockRow(table: Project.schema, id: projectID, on: db)
            _ = try await ProjectAccess(user: user, db: db).project(projectID, role: .comment)
            if let hash, let saved = try await ProjectCommentIdempotency.query(on: db)
                .filter(\.$projectID == projectID).filter(\.$userID == userID).filter(\.$keyHash == hash).first() {
                guard saved.requestBody == body else { throw Abort(.conflict, reason: "idempotency_conflict") }
                // Replay returns the original comment as stored (or its recorded content if edited/deleted since).
                if let comment = try await ProjectComment.find(saved.commentID, on: db) { return try ProjectCommentDTO(comment) }
                return ProjectCommentDTO(replayed: saved)
            }
            let comment = ProjectComment(projectID: projectID, authorID: userID, body: body)
            try await comment.save(on: db)
            if let hash {
                let saved = ProjectCommentIdempotency()
                saved.projectID = projectID; saved.userID = userID; saved.keyHash = hash
                saved.requestBody = body; saved.commentID = try comment.requireID(); saved.createdAt = Date()
                try await saved.save(on: db)
            }
            try await appendProjectActivity(projectID: projectID, actorType: .person, actorID: userID,
                kind: "comment.created", subjectID: comment.id, on: db)
            return try ProjectCommentDTO(comment)
        }
        return try await named([dto])[0]
    }

    func edit(_ projectID: UUID, commentID: UUID, body raw: String, version: Int) async throws -> ProjectCommentDTO {
        _ = try await access.project(projectID, role: .comment)
        let body = try CommentService.text(raw)
        let userID = try user.requireID()
        let dto = try await db.transaction { db -> ProjectCommentDTO in
            try await lockRow(table: Project.schema, id: projectID, on: db)
            _ = try await ProjectAccess(user: user, db: db).project(projectID, role: .comment)
            guard let c = try await ProjectComment.find(commentID, on: db), c.projectID == projectID else { throw Abort(.notFound) }
            guard c.authorID == userID else { throw Abort(.forbidden, reason: "not_comment_author") }
            guard c.version == version else { throw Abort(.conflict, reason: "version_conflict") }
            c.body = body; c.version += 1
            try await c.save(on: db)
            try await appendProjectActivity(projectID: projectID, actorType: .person, actorID: userID,
                kind: "comment.updated", subjectID: c.id, on: db)
            return try ProjectCommentDTO(c)
        }
        return try await named([dto])[0]
    }

    func delete(_ projectID: UUID, commentID: UUID, version: Int) async throws {
        _ = try await access.project(projectID, role: .comment)
        let userID = try user.requireID()
        try await db.transaction { db in
            try await lockRow(table: Project.schema, id: projectID, on: db)
            let access = ProjectAccess(user: user, db: db)
            _ = try await access.project(projectID, role: .comment)
            guard let c = try await ProjectComment.find(commentID, on: db), c.projectID == projectID else { throw Abort(.notFound) }
            if c.authorID != userID {
                // Moderating a foreign comment requires manage rights.
                do { _ = try await access.project(projectID, role: .manage) }
                catch { throw Abort(.forbidden, reason: "not_comment_author") }
            }
            guard c.version == version else { throw Abort(.conflict, reason: "version_conflict") }
            try await c.delete(on: db)
            try await appendProjectActivity(projectID: projectID, actorType: .person, actorID: userID,
                kind: "comment.deleted", subjectID: c.id, on: db)
        }
    }
}

extension ProjectCommentDTO {
    init(replayed record: ProjectCommentIdempotency) {
        id = record.commentID; projectID = record.projectID; authorID = record.userID; body = record.requestBody
        version = 1; createdAt = record.createdAt
    }
}
