import Fluent
import Vapor

/// ADR 0032: the power of attorney a person gives one of their MCP connections (OAuth grants) to decide reviews and
/// answer questions as an agent. One row per person (`user_id` unique); granting again overwrites it. Active = `revoked_at` is null.
final class BrainMandate: Model, @unchecked Sendable {
    static let schema = "brain_mandates"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "grant_id") var grantID: UUID
    /// Exactly these projects; no inheritance to subprojects.
    @Field(key: "projects") var projects: [UUID]
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    init() {}
    init(userID: UUID, grantID: UUID, projects: [UUID], now: Date = Date()) {
        self.userID = userID; self.grantID = grantID; self.projects = projects; createdAt = now; updatedAt = now
    }
}

/// One row per decision taken under a mandate. Deliberately no foreign keys to task, grant or mandate, so the log
/// survives deletions; only the owner (`user_id`) cascades.
final class BrainDecisionAudit: Model, @unchecked Sendable {
    static let schema = "brain_decision_audits"
    @ID(key: .id) var id: UUID?
    @Field(key: "mandate_id") var mandateID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "grant_id") var grantID: UUID
    /// `review.accepted` | `review.changes_requested` | `question.answered`
    @Field(key: "kind") var kind: String
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "project_id") var projectID: UUID
    /// Review or question id.
    @Field(key: "subject_id") var subjectID: UUID
    @Field(key: "quote") var quote: String
    /// Review note or the given answer.
    @OptionalField(key: "note") var note: String?
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

struct CreateBrainMandates: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(BrainMandate.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("grant_id", .uuid, .required, .references("oauth_grants", "id", onDelete: .cascade))
            .field("projects", .json, .required)
            .field("created_at", .datetime, .required).field("updated_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .unique(on: "user_id").create()
        try await db.schema(BrainDecisionAudit.schema).id()
            .field("mandate_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("grant_id", .uuid, .required)
            .field("kind", .string, .required)
            .field("task_id", .uuid, .required).field("project_id", .uuid, .required).field("subject_id", .uuid, .required)
            .field("quote", .sql(raw: "TEXT"), .required).field("note", .sql(raw: "TEXT"))
            .field("created_at", .datetime, .required).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(BrainDecisionAudit.schema).delete()
        try await db.schema(BrainMandate.schema).delete()
    }
}
