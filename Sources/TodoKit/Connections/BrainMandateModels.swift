import Fluent
import SQLKit
import Vapor

/// ADR 0032: the power of attorney a person gives one of their MCP connections (OAuth grants) to decide reviews and
/// answer questions as an agent. One row per connection (`user_id` + `grant_id` unique, addendum 23.11.2026); granting the same
/// connection again overwrites its row. Active = `revoked_at` is null.
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

/// ADR 0032 addendum: one mandate per connection instead of one per person. `unique(user_id)` becomes
/// `unique(user_id, grant_id)`; existing rows are kept.
///
/// MariaDB: the new index is added first because the foreign key on `user_id` needs an index that starts with it, then the
/// old one is dropped. SQLite cannot drop a table constraint, so the table is rebuilt and the rows are copied.
struct BrainMandateGrantUnique: AsyncMigration {
    private static let columns = "id, user_id, grant_id, projects, created_at, updated_at, revoked_at"

    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        if sql.dialect.name == "sqlite" {
            try await rebuild(sql: sql, db: db) { $0.unique(on: "user_id", "grant_id") }
        } else {
            try await db.schema(BrainMandate.schema).unique(on: "user_id", "grant_id").update()
            try await sql.raw("ALTER TABLE \(ident: BrainMandate.schema) DROP INDEX \(ident: "uq:brain_mandates.user_id")").run()
        }
    }

    /// Back to one mandate per person. Fails when a person already holds several (they would have to be revoked first).
    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        if sql.dialect.name == "sqlite" {
            try await rebuild(sql: sql, db: db) { $0.unique(on: "user_id") }
        } else {
            try await db.schema(BrainMandate.schema).unique(on: "user_id").update()
            try await sql.raw("ALTER TABLE \(ident: BrainMandate.schema) DROP INDEX \(ident: "uq:brain_mandates.user_id+grant_id")").run()
        }
    }

    private func rebuild(sql: any SQLDatabase, db: any Database, constraint: (SchemaBuilder) -> SchemaBuilder) async throws {
        let old = "brain_mandates_old"
        try await sql.raw("ALTER TABLE \(ident: BrainMandate.schema) RENAME TO \(ident: old)").run()
        try await constraint(db.schema(BrainMandate.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("grant_id", .uuid, .required, .references("oauth_grants", "id", onDelete: .cascade))
            .field("projects", .json, .required)
            .field("created_at", .datetime, .required).field("updated_at", .datetime, .required)
            .field("revoked_at", .datetime)).create()
        try await sql.raw("INSERT INTO \(ident: BrainMandate.schema) (\(unsafeRaw: Self.columns)) SELECT \(unsafeRaw: Self.columns) FROM \(ident: old)").run()
        try await sql.raw("DROP TABLE \(ident: old)").run()
    }
}
