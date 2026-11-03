import Fluent
import Vapor

/// Uploads by people show up in the chat of the task, question or review they belong to, so agents that read
/// `list_comments` learn that a file exists. The file itself is never inlined.
enum AttachmentChat {
    /// Records one chat entry per completed attachment (idempotent). Called after a person completed an upload.
    static func record(_ a: Attachment, user: User, target: CommentService.Target, on database: any Database) async throws {
        let attachmentID = try a.requireID()
        try await database.transaction { db in
            try await lockRow(table: TodoTask.schema, id: a.taskID, on: db)
            try await CommentService.validate(target, taskID: a.taskID, on: db)
            if try await TaskComment.query(on: db).filter(\.$attachmentID == attachmentID).first() != nil { return }
            let userID = try user.requireID()
            let c = TaskComment(taskID: a.taskID, authorID: userID, body: a.filename)
            c.questionID = target.questionID; c.reviewID = target.reviewID
            c.authorKind = "person"; c.attachmentID = attachmentID
            try await c.save(on: db)
            try await appendActivity(taskID: a.taskID, actorType: .person, actorID: userID, kind: "comment.created", subjectID: c.id, on: db)
        }
    }

    /// Fills `attachments` (id, filename, mediaType, size) of entries that announce an upload.
    /// Deleted or not yet complete attachments are dropped from the list; the entry itself stays.
    static func decorate(_ comments: [CommentDTO], on db: any Database) async throws -> [CommentDTO] {
        let ids = Set(comments.compactMap(\.attachmentID))
        guard !ids.isEmpty else { return comments }
        let rows = try await Attachment.query(on: db).filter(\.$id ~~ Array(ids)).filter(\.$status == "complete").all()
        var byID: [UUID: AttachmentRef] = [:]
        for row in rows { byID[try row.requireID()] = try ref(row) }
        return comments.map { dto in
            var c = dto
            if let id = dto.attachmentID { c.attachments = byID[id].map { [$0] } ?? [] }
            return c
        }
    }

    static func ref(_ a: Attachment) throws -> AttachmentRef {
        AttachmentRef(id: try a.requireID(), filename: a.filename, mediaType: a.mediaType, size: a.size)
    }

    /// Complete attachments of the task that no chat entry announces (uploaded by an agent, via an older client
    /// or before chat entries existed). `nil` if there are none.
    static func unannounced(taskID: UUID, on db: any Database) async throws -> CommentDTO? {
        let announced = Set(try await TaskComment.query(on: db).filter(\.$taskID == taskID).filter(\.$attachmentID != .null).all().compactMap(\.attachmentID))
        let rows = try await Attachment.query(on: db).filter(\.$taskID == taskID).filter(\.$status == "complete").sort(\.$id).all()
            .filter { !announced.contains($0.id!) }
        guard !rows.isEmpty else { return nil }
        let refs = try rows.map(ref)
        var note = try CommentDTO(note: "\(refs.count) attachment(s) without a chat message: \(refs.map(\.filename).joined(separator: ", ")). To look at one call get_attachment_download, then fetch-attachment.sh, then Read the file.",
                                  taskID: taskID)
        note.attachments = refs
        return note
    }
}

extension CommentDTO {
    /// Synthetic hint entry (never stored): all-zero ids, `kind` = `attachments_note`.
    init(note: String, taskID: UUID) throws {
        let nilID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let c = TaskComment(taskID: taskID, authorID: nilID, body: note)
        c.id = nilID; c.authorKind = "agent"; c.authorLabel = "todolino"
        try self.init(c)
        kind = "attachments_note"
    }
}
