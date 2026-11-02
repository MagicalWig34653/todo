import Fluent
import Vapor

/// ADR 0026: confirmation requests for large MCP actions. An agent never runs a class C action (delete a project,
/// transfer ownership, ...) directly; the MCP tool stores the intent here and the account holder decides in the app.
/// The row is also the audit trail ("agent X wanted ..., confirmed by ...").
final class ActionRequest: Model, @unchecked Sendable {
    static let schema = "action_requests"
    static let lifetime: TimeInterval = 7 * 86_400

    @ID(key: .id) var id: UUID?
    /// The account that decides (the one whose connection triggered the request).
    @Field(key: "user_id") var userID: UUID
    /// The OAuth grant (connection) that asked; its project list limits the execution.
    @OptionalField(key: "grant_id") var grantID: UUID?
    /// Name of the connecting client for display, e.g. "Claude Code".
    @OptionalField(key: "agent_label") var agentLabel: String?
    @Field(key: "tool") var tool: String
    @Field(key: "args") var args: [String: String]
    /// Hash of (grant, tool, args): the same call while a request is open returns the same request.
    @Field(key: "fingerprint") var fingerprint: String
    @Field(key: "summary") var summary: String
    @Field(key: "impact") var impact: ActionImpact
    /// `pending` | `confirmed` | `rejected` | `expired` | `executed` | `failed`
    @Field(key: "state") var state: String
    @OptionalField(key: "result") var result: ActionResult?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "executed_at") var executedAt: Date?
    @Field(key: "expires_at") var expiresAt: Date

    init() {}
}

/// What would happen, in numbers the person can judge. Names only; no content.
struct ActionImpact: Codable, Equatable, Sendable {
    /// project | task
    var targetType: String
    var targetID: UUID
    var targetName: String
    var subprojects: Int = 0
    var tasks: Int = 0
    var newOwnerName: String? = nil
    /// Irreversible: the app asks for a second step (type the name or tick "understood").
    var destructive: Bool
}

struct ActionResult: Codable, Equatable, Sendable {
    var ok: Bool
    /// Short machine code of the outcome: `deleted`, `owner_changed`, or the error reason (`forbidden`, `not_found`, ...).
    var code: String
}

struct CreateActionRequests: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ActionRequest.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("grant_id", .uuid)
            .field("agent_label", .string)
            .field("tool", .string, .required)
            .field("args", .json, .required)
            .field("fingerprint", .string, .required)
            .field("summary", .sql(unsafeRaw: "TEXT"), .required)
            .field("impact", .json, .required)
            .field("state", .string, .required)
            .field("result", .json)
            .field("created_at", .datetime)
            .field("decided_at", .datetime)
            .field("executed_at", .datetime)
            .field("expires_at", .datetime, .required)
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(ActionRequest.schema).delete() }
}

/// Hint rows may reference an action request (MCP `wait_for_events`); still no entity data, only the id.
struct AddLiveEventRef: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("live_events").field("ref_id", .uuid).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("live_events").deleteField("ref_id").update()
    }
}

func configureActionRequests(_ app: Application) {
    app.migrations.add(CreateActionRequests())
    app.migrations.add(AddLiveEventRef())
}

// MARK: - DTO

struct ActionRequestDTO: Content {
    let id: UUID
    let tool: String
    let state: String
    let summary: String
    let impact: ActionImpact
    let agentLabel: String?
    let result: ActionResult?
    let createdAt: Date?
    let decidedAt: Date?
    let executedAt: Date?
    let expiresAt: Date

    init(_ r: ActionRequest, now: Date = Date()) throws {
        id = try r.requireID(); tool = r.tool; summary = r.summary; impact = r.impact; agentLabel = r.agentLabel
        // A pending request past its expiry is reported as expired even before the cleanup ran.
        state = r.state == "pending" && r.expiresAt <= now ? "expired" : r.state
        result = r.result; createdAt = r.createdAt; decidedAt = r.decidedAt; executedAt = r.executedAt; expiresAt = r.expiresAt
    }
}
