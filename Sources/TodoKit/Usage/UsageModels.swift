import Fluent
import SQLKit
import Vapor

// Cost efficiency, phase 1 (ADR 0038, contracts/usage.yaml): aggregated token counters only, one row per
// (account, day, session, model). Costs are never stored; they are computed when reading.

final class UsageDaily: Model, @unchecked Sendable {
    static let schema = "usage_daily"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    /// Calendar day of the collector, `YYYY-MM-DD` (sorts and compares as text).
    @Field(key: "day") var day: String
    @Field(key: "session_key") var sessionKey: String
    @Field(key: "model") var model: String
    @Field(key: "provider") var provider: String
    @Field(key: "input_tokens") var inputTokens: Int64
    @Field(key: "output_tokens") var outputTokens: Int64
    @Field(key: "cache_write_tokens") var cacheWriteTokens: Int64
    @Field(key: "cache_write_1h_tokens") var cacheWrite1hTokens: Int64
    @Field(key: "cache_read_tokens") var cacheReadTokens: Int64
    @Field(key: "turns") var turns: Int64
    @Field(key: "max_context_tokens") var maxContextTokens: Int64
    @Field(key: "subagent") var subagent: Bool
    @OptionalField(key: "project_id") var projectID: UUID?
    @OptionalField(key: "commits") var commits: Int64?
    @OptionalField(key: "card_updates") var cardUpdates: Int64?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
}

/// The account's own price entries and thresholds as JSON text; defaults are never stored.
final class UsageSetting: Model, @unchecked Sendable {
    static let schema = "usage_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "prices") var prices: String
    @Field(key: "thresholds") var thresholds: String
    init() {}
}

struct CreateUsage: AsyncMigration {
    func prepare(on db: any Database) async throws {
        // MariaDB: short ASCII columns keep the unique key far below the index length limit, and the binary collation
        // makes keys case sensitive like SQLite does.
        let sqlite = (db as? any SQLDatabase)?.dialect.name == "sqlite"
        func key(_ length: Int) -> DatabaseSchema.DataType {
            .sql(raw: sqlite ? "TEXT" : "VARCHAR(\(length)) CHARACTER SET ascii COLLATE ascii_bin")
        }
        try await db.schema(UsageDaily.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("day", key(10), .required)
            .field("session_key", key(128), .required)
            .field("model", key(80), .required)
            .field("provider", .string, .required)
            .field("input_tokens", .int64, .required)
            .field("output_tokens", .int64, .required)
            .field("cache_write_tokens", .int64, .required)
            .field("cache_write_1h_tokens", .int64, .required)
            .field("cache_read_tokens", .int64, .required)
            .field("turns", .int64, .required)
            .field("max_context_tokens", .int64, .required)
            .field("subagent", .bool, .required)
            .field("project_id", .uuid, .references("projects", "id", onDelete: .setNull))
            .field("commits", .int64)
            .field("card_updates", .int64)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "day", "session_key", "model", name: "uq_usage_daily_key")
            .create()
        try await db.schema(UsageSetting.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("prices", .sql(raw: "TEXT"), .required)
            .field("thresholds", .sql(raw: "TEXT"), .required)
            .unique(on: "user_id")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(UsageSetting.schema).delete()
        try await db.schema(UsageDaily.schema).delete()
    }
}

func configureUsage(_ app: Application) {
    app.migrations.add(CreateUsage())
}
