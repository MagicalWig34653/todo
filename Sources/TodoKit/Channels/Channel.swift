import Fluent
import Vapor

// Channel #brain (ADR 0030, step 2): one account-scoped channel per user (kind `brain`), lazily created on first use.
// Only the owner reads and writes; there is no sharing and no team access. Messages carry text, a voice attachment
// (role `voice`, ADR 0030 step 1) or both. Message content is user data: it is never written to logs.

final class BrainChannel: Model, @unchecked Sendable {
    static let schema = "channels"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    /// Only `brain` exists today.
    @Field(key: "kind") var kind: String
    @Field(key: "created_at") var createdAt: Date
    /// Voice privacy consent (ADR 0030 step 7): stored and shown, not enforced by the server. nil = no consent.
    @OptionalField(key: "consent_at") var consentAt: Date?
    /// "Keep audio": voice audio lives up to 30 days instead of 24 h / 7 days. Only settable with consent; nil = false.
    @OptionalField(key: "keep_audio") var keepAudio: Bool?
    init() {}
    init(ownerID: UUID, kind: String) { self.ownerID = ownerID; self.kind = kind; createdAt = Date() }
}

final class ChannelMessage: Model, @unchecked Sendable {
    static let schema = "channel_messages"
    @ID(key: .id) var id: UUID?
    @Field(key: "channel_id") var channelID: UUID
    /// Repeated from the channel so that every query can filter on the account directly.
    @Field(key: "owner_id") var ownerID: UUID
    /// `text` | `voice_in` | `voice_out` | `status`
    @Field(key: "kind") var kind: String
    /// `person` (app, REST) | `agent` (MCP connection)
    @Field(key: "author") var author: String
    /// Message text or transcript.
    @OptionalField(key: "text") var text: String?
    /// Audio attachment (role `voice`); no foreign key: attachments have their own life cycle and cleanup.
    @OptionalField(key: "attachment_id") var attachmentID: UUID?
    /// Idempotency key chosen by the sender, unique per channel.
    @OptionalField(key: "client_uuid") var clientUUID: UUID?
    /// Rounded to whole milliseconds so that the pagination cursor is exact on SQLite and MariaDB.
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

struct CreateChannels: AsyncMigration {
    func prepare(on db: any Database) async throws {
        let text = DatabaseSchema.DataType.sql(raw: "TEXT")
        try await db.schema(BrainChannel.schema).id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "owner_id", "kind")
            .create()
        try await db.schema(ChannelMessage.schema).id()
            .field("channel_id", .uuid, .required, .references(BrainChannel.schema, "id", onDelete: .cascade))
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("author", .string, .required)
            .field("text", text)
            .field("attachment_id", .uuid)
            .field("client_uuid", .uuid)
            .field("created_at", .datetime, .required)
            .unique(on: "channel_id", "client_uuid")
            .create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ChannelMessage.schema).delete()
        try await db.schema(BrainChannel.schema).delete()
    }
}

/// Voice privacy settings (ADR 0030 step 7). Additive; one column per ALTER (SQLite).
struct AddChannelVoicePrivacy: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(BrainChannel.schema).field("consent_at", .datetime).update()
        try await db.schema(BrainChannel.schema).field("keep_audio", .bool).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(BrainChannel.schema).deleteField("keep_audio").update()
        try await db.schema(BrainChannel.schema).deleteField("consent_at").update()
    }
}

func configureChannels(_ app: Application) {
    app.migrations.add(CreateChannels())
    app.migrations.add(AddChannelVoicePrivacy())
}
