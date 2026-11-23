import Fluent
import Vapor

// ADR 0035: outgoing webhook that wakes an external listener when the person acts. Nothing in these tables carries
// card text; the URL and the signing secret exist only as ciphertext.

/// One webhook per person. `url_ciphertext` is AES-256-GCM (additional data `todolino.webhook.v1:<userID>:url`); the
/// plain URL is never stored, returned or logged. `url_mask` is scheme and host only (`https://host`).
final class WebhookEndpoint: Model, @unchecked Sendable {
    static let schema = "webhook_endpoints"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "url_ciphertext") var urlCiphertext: String
    @Field(key: "key_id") var keyID: String
    @Field(key: "url_mask") var urlMask: String
    @OptionalField(key: "signing_ciphertext") var signingCiphertext: String?
    @OptionalField(key: "signing_key_id") var signingKeyID: String?
    @Field(key: "enabled") var enabled: Bool
    /// Bundles that ended in `failed` since the last success; at `WebhookLimits.disableAfterFailures` the webhook switches itself off.
    @Field(key: "consecutive_failures") var consecutiveFailures: Int
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

/// Projects whose events do not trigger the webhook (exactly these projects, no inheritance to subprojects).
final class WebhookExclusion: Model, @unchecked Sendable {
    static let schema = "webhook_exclusions"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "project_id") var projectID: UUID
    init() {}
    init(userID: UUID, projectID: UUID) { self.userID = userID; self.projectID = projectID }
}

/// One bundle (or test) to send and, afterwards, its log entry. `state`: `pending` | `sent` | `failed`.
/// `kinds_mask` is a bit set over `WebhookKinds` so that bundling is a single atomic `UPDATE` on both engines.
/// `open_marker = 'open'` while the bundle still collects events (at most one such row per person, unique with `user_id`).
final class WebhookDelivery: Model, @unchecked Sendable {
    static let schema = "webhook_deliveries"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "state") var state: String
    /// `person_action` | `test`
    @Field(key: "event") var event: String
    @Field(key: "anzahl") var anzahl: Int
    @Field(key: "kinds_mask") var kindsMask: Int
    @Field(key: "attempts") var attempts: Int
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    @Field(key: "due_at") var dueAt: Date
    @OptionalField(key: "http_status") var httpStatus: Int?
    /// Short machine code of the last problem; never an address, host or response text.
    @OptionalField(key: "error_code") var errorCode: String?
    @OptionalField(key: "open_marker") var openMarker: String?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "finished_at") var finishedAt: Date?
    init() {}
    init(userID: UUID, event: String, anzahl: Int, kindsMask: Int, due: Date, open: Bool, now: Date = Date()) {
        self.id = UUID(); self.userID = userID; state = "pending"; self.event = event; self.anzahl = anzahl; self.kindsMask = kindsMask
        attempts = 0; nextAttemptAt = due; dueAt = due; openMarker = open ? WebhookDelivery.openValue : nil; createdAt = now
    }
    static let openValue = "open"
}

struct CreateWebhookSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(WebhookEndpoint.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("url_ciphertext", .sql(unsafeRaw: "TEXT"), .required)
            .field("key_id", .string, .required)
            .field("url_mask", .sql(unsafeRaw: "TEXT"), .required)
            .field("signing_ciphertext", .sql(unsafeRaw: "TEXT"))
            .field("signing_key_id", .string)
            .field("enabled", .bool, .required)
            .field("consecutive_failures", .int, .required)
            .field("created_at", .datetime, .required).field("updated_at", .datetime, .required)
            .unique(on: "user_id").create()
        try await db.schema(WebhookExclusion.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .unique(on: "user_id", "project_id").create()
        try await db.schema(WebhookDelivery.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("state", .string, .required).field("event", .string, .required)
            .field("anzahl", .int, .required).field("kinds_mask", .int, .required)
            .field("attempts", .int, .required)
            .field("next_attempt_at", .datetime, .required).field("due_at", .datetime, .required)
            .field("http_status", .int).field("error_code", .string)
            // NULL once closed; both SQLite and MariaDB allow many NULLs in a unique index, so only one open row per person exists.
            .field("open_marker", .string)
            .field("created_at", .datetime, .required).field("finished_at", .datetime)
            .unique(on: "user_id", "open_marker").create()
    }
    func revert(on db: any Database) async throws {
        for table in [WebhookDelivery.schema, WebhookExclusion.schema, WebhookEndpoint.schema] { try await db.schema(table).delete() }
    }
}

enum WebhookLimits {
    /// Events of one person within this window become one request.
    static let bundleWindow: TimeInterval = 60
    static let maxAttempts = 6
    /// Pause after attempt n (index n-1): 30 s, 2 min, 10 min, 30 min, 2 h; each with +-10 % jitter.
    static let backoff: [TimeInterval] = [30, 120, 600, 1800, 7200]
    static let disableAfterFailures = 10
    static let timeout: TimeInterval = 10
    static let testInterval = 10
    static let listLimit = 50
    static let retention: TimeInterval = 14 * 86_400
    static let maxURLLength = 2048
    static let maxExclusions = 500
    static let minSecret = 16
    static let maxSecret = 256
}

/// Whitelist of `activity_events.kind` values that may wake the webhook (ADR 0035, item 5). The bit of a kind is stable;
/// new kinds only ever get the next free bit.
enum WebhookKinds {
    static let bits: [String: Int] = [
        "question.answered": 0, "review.accepted": 1, "review.changes_requested": 2, "comment.created": 3,
        "task.created": 4, "task.moved": 5, "task.status_changed": 6,
    ]
    static func mask(_ kind: String) -> Int? { bits[kind].map { 1 << $0 } }
    /// Kinds in the mask, sorted and unique.
    static func kinds(_ mask: Int) -> [String] { bits.filter { mask & (1 << $0.value) != 0 }.map(\.key).sorted() }
}

/// The request body. Fixed keys, values only from the whitelist and a counter; encoded, never assembled by hand.
struct WebhookPayload: Encodable, Equatable, Sendable {
    let event: String
    let anzahl: Int
    let kinds: [String]

    static func person(count: Int, mask: Int) -> WebhookPayload { WebhookPayload(event: "person_action", anzahl: count, kinds: WebhookKinds.kinds(mask)) }
    static let test = WebhookPayload(event: "test", anzahl: 0, kinds: [])

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

func configureWebhook(_ app: Application) {
    app.migrations.add(CreateWebhookSchema())
}
