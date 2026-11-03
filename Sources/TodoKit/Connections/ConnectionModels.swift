import Fluent
import Vapor

/// ADR 0028: an MCP connection (OAuth grant) asked for a project outside its grant. One row per connection and project;
/// repeats only raise `count`. Rows exist only for projects the connection's owner can read, and never carry project content.
final class ConnectionAccessRequest: Model, @unchecked Sendable {
    static let schema = "connection_access_requests"
    @ID(key: .id) var id: UUID?
    @Field(key: "grant_id") var grantID: UUID
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "user_id") var userID: UUID
    /// `open` | `granted` | `ignored`
    @Field(key: "state") var state: String
    @Field(key: "count") var count: Int
    @Field(key: "first_at") var firstAt: Date
    @Field(key: "last_at") var lastAt: Date
    init() {}
    init(grantID: UUID, projectID: UUID, userID: UUID, now: Date) {
        self.grantID = grantID; self.projectID = projectID; self.userID = userID
        state = "open"; count = 1; firstAt = now; lastAt = now
    }
}

struct AddOAuthGrantNameAndUsage: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("oauth_grants").field("name", .string).update()
        try await db.schema("oauth_grants").field("last_used_at", .datetime).update()
        // Default name = client name, so no connection is ever unnamed.
        let clients = Dictionary(uniqueKeysWithValues: try await OAuthClient.query(on: db).all().compactMap { c in c.id.map { ($0, c.name) } })
        for grant in try await OAuthGrant.query(on: db).all() where grant.name == nil {
            grant.name = ConnectionNames.defaultName(clients[grant.clientID]); try await grant.save(on: db)
        }
    }
    func revert(on db: any Database) async throws {
        try await db.schema("oauth_grants").deleteField("name").update()
        try await db.schema("oauth_grants").deleteField("last_used_at").update()
    }
}

struct CreateConnectionAccessRequests: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ConnectionAccessRequest.schema).id()
            .field("grant_id", .uuid, .required, .references("oauth_grants", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("state", .string, .required).field("count", .int, .required)
            .field("first_at", .datetime, .required).field("last_at", .datetime, .required)
            .unique(on: "grant_id", "project_id").create()
    }
    func revert(on db: any Database) async throws { try await db.schema(ConnectionAccessRequest.schema).delete() }
}

func configureConnections(_ app: Application) {
    app.migrations.add(AddOAuthGrantNameAndUsage())
    app.migrations.add(CreateConnectionAccessRequests())
}
