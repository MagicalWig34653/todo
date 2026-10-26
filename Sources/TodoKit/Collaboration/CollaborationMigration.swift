import Fluent
import FluentSQL

struct CreateCollaborationSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskComment.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references("users", "id"))
            .field("body", .sql(raw: "TEXT"), .required).field("version", .int, .required).create()
        try await db.schema(AcceptanceCriterion.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("text", .sql(raw: "TEXT"), .required).field("completed", .bool, .required)
            .field("version", .int, .required).create()
        try await db.schema(ActivityEvent.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("sequence", .int, .required).field("actor_type", .string, .required)
            .field("actor_id", .uuid, .required).field("kind", .string, .required)
            .field("subject_id", .uuid).field("created_at", .datetime)
            .unique(on: "task_id", "sequence").create()
        try await db.schema(CommentIdempotency.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("key_hash", .string, .required).field("request_body", .sql(raw: "TEXT"), .required)
            .field("comment_id", .uuid, .required)
            .unique(on: "task_id", "user_id", "key_hash").create()
    }
    func revert(on db: any Database) async throws {
        for table in [CommentIdempotency.schema, ActivityEvent.schema, AcceptanceCriterion.schema, TaskComment.schema] {
            try await db.schema(table).delete()
        }
    }
}
