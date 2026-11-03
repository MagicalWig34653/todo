import Fluent
import Vapor

final class TaskComment: Model, @unchecked Sendable {
    static let schema = "comments"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "author_id") var authorID: UUID
    @Field(key: "body") var body: String
    @Field(key: "version") var version: Int
    /// Optional thread: a message about a question or a review of the task (chat per card). Both nil = task thread.
    @OptionalField(key: "question_id") var questionID: UUID?
    @OptionalField(key: "review_id") var reviewID: UUID?
    /// `person` (nil on old rows) or `agent` (written through MCP or by the runner).
    @OptionalField(key: "author_kind") var authorKind: String?
    @OptionalField(key: "author_label") var authorLabel: String?
    /// Set on the chat entry that announces a completed upload (nil on normal messages).
    @OptionalField(key: "attachment_id") var attachmentID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(taskID: UUID, authorID: UUID, body: String) {
        self.taskID = taskID; self.authorID = authorID; self.body = body; version = 1
    }
}

final class AcceptanceCriterion: Model, @unchecked Sendable {
    static let schema = "acceptance_criteria"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "text") var text: String
    @Field(key: "completed") var completed: Bool
    @Field(key: "version") var version: Int
    init() {}
    init(taskID: UUID, text: String) {
        self.taskID = taskID; self.text = text; completed = false; version = 1
    }
}

public enum ActivityActorType: String, Content, Sendable { case person = "Person", integration = "Integration", run = "Run" }

final class ActivityEvent: Model, @unchecked Sendable {
    static let schema = "activity_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "sequence") var sequence: Int
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @Field(key: "kind") var kind: String
    @OptionalField(key: "subject_id") var subjectID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

final class CommentIdempotency: Model, @unchecked Sendable {
    static let schema = "comment_idempotency"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "key_hash") var keyHash: String
    @Field(key: "request_body") var requestBody: String
    // Retain the original response even when the comment is edited or deleted.
    @Field(key: "comment_id") var commentID: UUID
    init() {}
}

struct CommentDTO: Content {
    let id: UUID
    let taskID: UUID
    let authorID: UUID
    var authorName: String?
    let body: String
    let version: Int
    var questionID: UUID?
    var reviewID: UUID?
    /// `person` or `agent`.
    var authorKind: String = "person"
    var authorLabel: String?
    var createdAt: Date?
    /// Additive. `attachment` = chat entry for an upload, `attachments_note` = synthetic hint (list_comments only).
    var kind: String?
    var attachmentID: UUID?
    var attachments: [AttachmentRef]?
    init(_ c: TaskComment) throws {
        id = try c.requireID(); taskID = c.taskID; authorID = c.authorID; body = c.body; version = c.version
        questionID = c.questionID; reviewID = c.reviewID; authorKind = c.authorKind ?? "person"
        authorLabel = c.authorLabel; createdAt = c.createdAt
        attachmentID = c.attachmentID; kind = c.attachmentID == nil ? nil : "attachment"
    }
    init(_ record: CommentIdempotency) {
        id = record.commentID; taskID = record.taskID; authorID = record.userID; body = record.requestBody; version = 1
    }
}
struct AttachmentRef: Content {
    let id: UUID
    let filename: String
    let mediaType: String
    let size: Int
}
struct CriterionDTO: Content {
    let id: UUID
    let taskID: UUID
    let text: String
    let completed: Bool
    let version: Int
    init(_ c: AcceptanceCriterion) throws {
        id = try c.requireID(); taskID = c.taskID; text = c.text; completed = c.completed; version = c.version
    }
}
struct ActivityDTO: Content {
    let id: UUID
    let sequence: Int
    let actorType: ActivityActorType
    let actorID: UUID
    var actorName: String?
    let kind: String
    let subjectID: UUID?
    let createdAt: Date?
    init(_ e: ActivityEvent) throws {
        id = try e.requireID(); sequence = e.sequence; actorType = e.actorType; actorID = e.actorID
        kind = e.kind; subjectID = e.subjectID; createdAt = e.createdAt
    }
}
