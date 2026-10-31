import Fluent
import Vapor

// MARK: - Models (ADR 0024)

/// The confirmed e-mail address of an account (at most one; unique across accounts). A separate table keeps the
/// `users` table untouched: only addresses whose owner clicked the confirmation link are ever stored here.
final class UserEmail: Model, @unchecked Sendable {
    static let schema = "user_emails"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "email") var email: String
    @Field(key: "verified_at") var verifiedAt: Date
    init() {}
}

/// A not yet confirmed address (double opt-in). One row per account (a new request replaces the previous one);
/// only the SHA-256 of the single-use token is stored.
final class EmailVerification: Model, @unchecked Sendable {
    static let schema = "email_verifications"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "email") var email: String
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

/// Durable mail queue. The unique `dedupe_key` makes every trigger produce at most one mail. `payload` holds the
/// template parameters (for example a recovery code) only until the row is finished: it is blanked on every
/// terminal state, so secrets do not outlive the delivery.
final class MailOutbox: Model, @unchecked Sendable {
    static let schema = "mail_outbox"
    @ID(key: .id) var id: UUID?
    @OptionalField(key: "user_id") var userID: UUID?
    @Field(key: "recipient") var recipient: String
    /// `verify_email` | `recovery_code` | `test`
    @Field(key: "kind") var kind: String
    @Field(key: "payload") var payload: String
    @Field(key: "dedupe_key") var dedupeKey: String
    /// `pending` | `sent` | `failed` | `skipped` | `expired`
    @Field(key: "state") var state: String
    @Field(key: "attempts") var attempts: Int
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    /// Not sent any more after this time (a recovery code mail is useless once the code has expired).
    @Field(key: "expires_at") var expiresAt: Date
    /// Short machine reason of the last problem; never contains server text or addresses.
    @OptionalField(key: "last_error") var lastError: String?
    @OptionalField(key: "sent_at") var sentAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

struct CreateMailSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(UserEmail.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("email", .string, .required).field("verified_at", .datetime, .required)
            .unique(on: "user_id").unique(on: "email").create()
        try await db.schema(EmailVerification.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("email", .string, .required).field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required).field("created_at", .datetime)
            .unique(on: "user_id").unique(on: "token_hash").create()
        try await db.schema(MailOutbox.schema).id()
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("recipient", .string, .required).field("kind", .string, .required)
            .field("payload", .sql(raw: "TEXT"), .required).field("dedupe_key", .string, .required)
            .field("state", .string, .required).field("attempts", .int, .required)
            .field("next_attempt_at", .datetime, .required).field("expires_at", .datetime, .required)
            .field("last_error", .string).field("sent_at", .datetime).field("created_at", .datetime)
            .unique(on: "dedupe_key").create()
    }
    func revert(on db: any Database) async throws {
        for table in [MailOutbox.schema, EmailVerification.schema, UserEmail.schema] { try await db.schema(table).delete() }
    }
}

func configureMail(_ app: Application) {
    app.migrations.add(CreateMailSchema())
}

// MARK: - DTOs

struct EmailStatusDTO: Content, Equatable {
    /// Confirmed address (only the owner sees it).
    var email: String?
    var verifiedAt: Date?
    /// Address waiting for confirmation.
    var pending: String?
    var pendingExpiresAt: Date?
    /// Server side: `MAIL_ENABLED=true`.
    var mailEnabled: Bool
    var lastMail: LastMailDTO?
}

struct LastMailDTO: Content, Equatable {
    var kind: String
    /// `pending` | `sent` | `failed` | `skipped` | `expired`
    var state: String
    var error: String?
    var at: Date?
}

struct SetEmailRequest: Content { var email: String }
struct ConfirmEmailRequest: Content { var token: String }
struct EmailRequestedDTO: Content, Equatable {
    var status: String
    var expiresAt: Date
}
struct EmailTestDTO: Content, Equatable { var status: String }

/// Informational block in `/health/ready`; never influences readiness.
struct MailStatus: Content, Equatable { var enabled: Bool }
