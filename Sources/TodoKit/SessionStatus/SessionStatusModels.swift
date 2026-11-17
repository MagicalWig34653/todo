import Fluent
import SQLKit
import Vapor

// Light session status without a claimed card (ADR 0034): an agent says "I am working on project X, doing Y" with
// one short sentence. One row per (account, project, session name), overwritten by every report (upsert).
// The text passes the secrets filter before it is stored.

final class SessionStatus: Model, @unchecked Sendable {
    static let schema = "session_statuses"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "session_name") var sessionName: String
    @Field(key: "activity") var activity: String
    /// Whole milliseconds; also the base of the write rate limit and of the orphaned/hidden marking.
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
    init(userID: UUID, projectID: UUID, sessionName: String, activity: String, updatedAt: Date) {
        self.userID = userID; self.projectID = projectID; self.sessionName = sessionName; self.activity = activity; self.updatedAt = updatedAt
    }
}

// The hint row of a status report carries the project id (not a card): MCP `wait_for_events` turns it into a
// project-level `progress` hint for connections that may read the project.
extension SessionStatus: LiveRefScoped { var liveRefID: UUID? { projectID } }

struct CreateSessionStatuses: AsyncMigration {
    func prepare(on db: any Database) async throws {
        let text = DatabaseSchema.DataType.sql(raw: "TEXT")
        try await db.schema(SessionStatus.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("session_name", .string, .required)
            .field("activity", text, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "user_id", "project_id", "session_name")
            .create()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS session_statuses_project_updated ON session_statuses (project_id, updated_at)").run()
        }
    }
    func revert(on db: any Database) async throws { try await db.schema(SessionStatus.schema).delete() }
}

func configureSessionStatuses(_ app: Application) {
    app.migrations.add(CreateSessionStatuses())
}
