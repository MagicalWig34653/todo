import Fluent
import SQLKit
import Vapor

// Voice jobs (ADR 0030, step 3): one job per `voice_in` message of channel #brain that a Mac runner with the capability
// "sprache" can answer. Not an agent job (ADR 0008): no repository slot, no review. States:
// queued -> claimed -> done | failed, and expired (10 minutes after creation, from queued or claimed).
// Audio, transcripts and reply texts are user data and never appear in logs; only ids, sizes and error codes do.

final class VoiceJob: Model, @unchecked Sendable {
    static let schema = "voice_jobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    /// The `voice_in` channel message that caused the job (unique).
    @Field(key: "message_id") var messageID: UUID
    /// The recording (role `voice`, no task). No foreign key: attachments have their own life cycle.
    @Field(key: "attachment_id") var attachmentID: UUID
    @Field(key: "required_capability") var requiredCapability: String
    /// `queued` | `claimed` | `done` | `failed` | `expired`
    @Field(key: "state") var state: String
    /// Bumped on every claim; the runner repeats it on every call and a stale value is refused (fencing).
    @Field(key: "generation") var generation: Int
    @OptionalField(key: "device_id") var deviceID: UUID?
    @OptionalField(key: "lease_until") var leaseUntil: Date?
    /// Reply audio uploaded by the runner before the result (role `voice`, no task).
    @OptionalField(key: "reply_attachment_id") var replyAttachmentID: UUID?
    @OptionalField(key: "error_code") var errorCode: String?
    /// Digest of the accepted result, so that a retried result call is answered instead of refused.
    @OptionalField(key: "result_hash") var resultHash: String?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "ended_at") var endedAt: Date?
    init() {}

    var isEnded: Bool { ["done", "failed", "expired"].contains(state) }
}

extension RunnerDevice {
    /// Reported by the runner on its voice heartbeat; stored as a comma separated string.
    var reportedCapabilities: [String] { VoiceCapabilities.parse(capabilitiesRaw) }
    /// Switched off by the owner (PWA); wins over what the runner reports.
    var disabledCapabilityList: [String] { VoiceCapabilities.parse(disabledCapabilitiesRaw) }
    var effectiveCapabilities: [String] {
        let off = Set(disabledCapabilityList)
        return reportedCapabilities.filter { !off.contains($0) }
    }
}

enum VoiceCapabilities {
    static let voice = "sprache"
    static let maxCount = 10
    static let maxLength = 20

    static func parse(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map(String.init)
    }
    static func join(_ list: [String]) -> String? { list.isEmpty ? nil : list.joined(separator: ",") }

    /// Lower-case identifiers only; duplicates are dropped, order is kept.
    static func validated(_ list: [String]) throws -> [String] {
        guard list.count <= maxCount else { throw Abort(.badRequest, reason: "invalid_capabilities") }
        var seen = Set<String>(), out: [String] = []
        for item in list {
            guard (1...maxLength).contains(item.count), let first = item.unicodeScalars.first,
                  ("a"..."z").contains(first),
                  item.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" })
            else { throw Abort(.badRequest, reason: "invalid_capabilities") }
            if seen.insert(item).inserted { out.append(item) }
        }
        return out
    }
}

struct AddVoiceJobs: AsyncMigration {
    func prepare(on db: any Database) async throws {
        // Additive only. One ALTER per column: SQLite cannot add several columns in one statement. The columns are
        // nullable (comma separated strings, at most 10 x 20 characters, so they fit VARCHAR(255) on MariaDB).
        try await db.schema(RunnerDevice.schema).field("capabilities", .string).update()
        try await db.schema(RunnerDevice.schema).field("disabled_capabilities", .string).update()
        try await db.schema(RunnerDevice.schema).field("last_seen_at", .datetime).update()
        try await db.schema(VoiceJob.schema).id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("message_id", .uuid, .required, .references(ChannelMessage.schema, "id", onDelete: .cascade))
            .field("attachment_id", .uuid, .required)
            .field("required_capability", .string, .required)
            .field("state", .string, .required)
            .field("generation", .int, .required)
            .field("device_id", .uuid)
            .field("lease_until", .datetime)
            .field("reply_attachment_id", .uuid)
            .field("error_code", .string)
            .field("result_hash", .string)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("ended_at", .datetime)
            .unique(on: "message_id")
            .create()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("CREATE INDEX voice_job_owner_state ON voice_jobs (owner_id, state)").run()
        }
    }
    func revert(on db: any Database) async throws {
        try await db.schema(VoiceJob.schema).delete()
        try await db.schema(RunnerDevice.schema).deleteField("last_seen_at").update()
        try await db.schema(RunnerDevice.schema).deleteField("disabled_capabilities").update()
        try await db.schema(RunnerDevice.schema).deleteField("capabilities").update()
    }
}

/// Additive: when an attachment was created (nullable, legacy rows stay nil).
struct AddAttachmentCreatedAt: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Attachment.schema).field("created_at", .datetime).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(Attachment.schema).deleteField("created_at").update()
    }
}

func configureVoice(_ app: Application) {
    app.migrations.add(AddVoiceJobs())
    app.migrations.add(AddAttachmentCreatedAt())
    app.lifecycle.use(VoiceExpiryWorker(app: app))
}
