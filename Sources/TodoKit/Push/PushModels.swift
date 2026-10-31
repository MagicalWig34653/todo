import Fluent
import Vapor

// MARK: - Models (ADR 0021)

/// A registered APNs device token. The token itself is a credential for sending to the device: it is never logged
/// and never returned by the API (`PushDeviceDTO` has no token field). `token_hash` makes registration idempotent.
final class PushDevice: Model, @unchecked Sendable {
    static let schema = "push_devices"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    /// `ios` | `macos`
    @Field(key: "platform") var platform: String
    @Field(key: "token") var token: String
    @Field(key: "token_hash") var tokenHash: String
    /// `sandbox` | `production`
    @Field(key: "environment") var environment: String
    /// apns-topic (bundle ID) the token was issued for.
    @Field(key: "bundle_id") var bundleID: String
    @OptionalField(key: "app_version") var appVersion: String?
    @OptionalField(key: "locale") var locale: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "last_seen_at") var lastSeenAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    init() {}
}

/// Per-account push settings (one row, created on first write). Missing categories fall back to the defaults.
final class PushPrefs: Model, @unchecked Sendable {
    static let schema = "push_prefs"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "categories") var categories: [String: Bool]
    /// Include task titles and short texts in the notification (default off, see ADR 0021).
    @Field(key: "show_content") var showContent: Bool
    @Field(key: "badge") var badge: Bool
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
}

/// Durable work queue; the unique `(user_id, dedupe_key)` makes every trigger fire at most once per account.
/// `payload` holds only identifiers (`PushEvent`), never task text: content is resolved when sending, after the
/// rights check.
final class PushOutbox: Model, @unchecked Sendable {
    static let schema = "push_outbox"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "category") var category: String
    @Field(key: "payload") var payload: String
    @Field(key: "dedupe_key") var dedupeKey: String
    @Field(key: "due_at") var dueAt: Date
    /// `pending` | `sent` | `skipped` | `failed`
    @Field(key: "state") var state: String
    @Field(key: "attempts") var attempts: Int
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    /// Short machine reason of the last problem; never contains tokens.
    @OptionalField(key: "last_error") var lastError: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

struct PushEvent: Codable, Equatable, Sendable {
    /// `reminder` | `question` | `review` | `comment`
    var kind: String
    var taskID: UUID
    var projectID: UUID
    var subjectID: UUID?
    /// Reminder time (unix seconds) for `reminder` events.
    var at: Int?
}

enum PushCategory: String, CaseIterable, Sendable {
    case reminders, agentQuestions = "agent_questions", agentReviews = "agent_reviews", assignments, comments
    static let defaults: [String: Bool] = [
        "reminders": true, "agent_questions": true, "agent_reviews": true, "assignments": false, "comments": false,
    ]
}

struct CreatePushSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(PushDevice.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("platform", .string, .required).field("token", .string, .required).field("token_hash", .string, .required)
            .field("environment", .string, .required).field("bundle_id", .string, .required)
            .field("app_version", .string).field("locale", .string)
            .field("created_at", .datetime).field("last_seen_at", .datetime, .required).field("revoked_at", .datetime)
            .unique(on: "token_hash").create()
        try await db.schema(PushPrefs.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("categories", .json, .required).field("show_content", .bool, .required).field("badge", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id").create()
        try await db.schema(PushOutbox.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("category", .string, .required).field("payload", .sql(raw: "TEXT"), .required)
            .field("dedupe_key", .string, .required).field("due_at", .datetime, .required)
            .field("state", .string, .required).field("attempts", .int, .required)
            .field("next_attempt_at", .datetime, .required).field("last_error", .string)
            .field("created_at", .datetime)
            .unique(on: "user_id", "dedupe_key").create()
    }
    func revert(on db: any Database) async throws {
        for table in [PushOutbox.schema, PushPrefs.schema, PushDevice.schema] { try await db.schema(table).delete() }
    }
}

func configurePush(_ app: Application) {
    app.migrations.add(CreatePushSchema())
    app.asyncCommands.use(PushTestCommand(), as: "push-test")
}

// MARK: - DTOs

struct PushDeviceDTO: Content, Equatable {
    let id: UUID
    let platform: String
    let environment: String
    let bundleId: String
    let appVersion: String?
    let locale: String?
    let createdAt: Date?
    let lastSeenAt: Date
    init(_ d: PushDevice) throws {
        id = try d.requireID(); platform = d.platform; environment = d.environment; bundleId = d.bundleID
        appVersion = d.appVersion; locale = d.locale; createdAt = d.createdAt; lastSeenAt = d.lastSeenAt
    }
}

struct RegisterPushDeviceRequest: Content {
    var token: String
    var platform: String
    var environment: String?
    var bundleId: String
    var appVersion: String?
    var locale: String?
}

struct PushPrefsDTO: Content, Equatable {
    var categories: [String: Bool]
    var showContent: Bool
    var badge: Bool
}

struct UpdatePushPrefsRequest: Content {
    var categories: [String: Bool]?
    var showContent: Bool?
    var badge: Bool?
}

/// Informational block in `/health/ready`; never influences readiness.
struct PushStatus: Content, Equatable {
    var enabled: Bool
    var environment: String
}
