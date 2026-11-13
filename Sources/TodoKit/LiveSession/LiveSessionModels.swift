import Fluent
import SQLKit
import Vapor

// Live view per card (ADR 0031): compact events that the working agent reports itself through MCP (current step,
// tool use, notes, questions, progress). No transcript is ever stored; every text passes the secrets filter first
// (`SecretFilter`) and is at most 280 characters. Rows are deleted 3 days after the card is done (`ExpiredCleanup`).

/// One working session on a card (for example "Mac Studio" or a Claude Code window). Unique per (card, name).
final class TaskLiveSession: Model, @unchecked Sendable {
    static let schema = "task_live_sessions"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    /// Account the connection acts for (kept for the audit trail; rights are always checked live).
    @Field(key: "user_id") var userID: UUID
    @Field(key: "name") var name: String
    @OptionalField(key: "model") var model: String?
    /// `person` | `integration` | `run`
    @Field(key: "actor_type") var actorType: String
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "actor_label") var actorLabel: String?
    @OptionalField(key: "current_step") var currentStep: String?
    /// `active` | `ended`
    @Field(key: "status") var status: String
    @Field(key: "started_at") var startedAt: Date
    /// Sign of life: set by every step or event report.
    @Field(key: "last_seen_at") var lastSeenAt: Date
    @OptionalField(key: "ended_at") var endedAt: Date?
    init() {}
}

final class TaskLiveEvent: Model, @unchecked Sendable {
    static let schema = "task_live_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "session_id") var sessionID: UUID
    /// `step` | `tool` | `note` | `question` | `progress`
    @Field(key: "kind") var kind: String
    /// Filtered, at most 280 characters.
    @Field(key: "text") var text: String
    /// Idempotency key chosen by the agent, unique per session.
    @OptionalField(key: "client_uuid") var clientUUID: UUID?
    /// Whole milliseconds, so that the `<ms>:<uuid>` cursor is exact on SQLite and MariaDB.
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

extension TaskLiveEvent: LiveTaskScoped { var liveTaskID: UUID? { taskID } }
extension TaskLiveSession: LiveTaskScoped { var liveTaskID: UUID? { taskID } }

struct CreateTaskLiveSessions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        let text = DatabaseSchema.DataType.sql(raw: "TEXT")
        // Cascades on the card and the account: deleting either never blocks on live data.
        try await db.schema(TaskLiveSession.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("model", .string)
            .field("actor_type", .string, .required)
            .field("actor_id", .uuid, .required)
            .field("actor_label", .string)
            .field("current_step", text)
            .field("status", .string, .required)
            .field("started_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .field("ended_at", .datetime)
            .unique(on: "task_id", "name")
            .create()
        try await db.schema(TaskLiveEvent.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("session_id", .uuid, .required, .references(TaskLiveSession.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("text", text, .required)
            .field("client_uuid", .uuid)
            .field("created_at", .datetime, .required)
            .unique(on: "session_id", "client_uuid")
            .create()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS live_events_task_created ON task_live_events (task_id, created_at)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS live_sessions_user ON task_live_sessions (user_id)").run()
        }
    }
    func revert(on db: any Database) async throws {
        try await db.schema(TaskLiveEvent.schema).delete()
        try await db.schema(TaskLiveSession.schema).delete()
    }
}

func configureLiveSessions(_ app: Application) {
    app.migrations.add(CreateTaskLiveSessions())
}
