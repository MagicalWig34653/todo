import Fluent
import FluentSQL

struct CreateOAuthSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("oauth_clients").id().field("name", .string, .required)
            .field("redirects", .json, .required).create()
        try await db.schema("oauth_grants").id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("client_id", .uuid, .required, .references("oauth_clients", "id", onDelete: .cascade))
            .field("resource", .string, .required).field("scopes", .json, .required)
            .field("projects", .json, .required).field("revoked", .bool, .required).create()
        try await db.schema("oauth_secrets").id().field("hash", .string, .required).unique(on: "hash")
            .field("kind", .string, .required)
            .field("grant_id", .uuid, .references("oauth_grants", "id", onDelete: .cascade))
            .field("payload", .sql(.text), .required).field("expires_at", .datetime, .required)
            .field("consumed", .bool, .required).create()
    }
    func revert(on db: any Database) async throws {
        for table in ["oauth_secrets", "oauth_grants", "oauth_clients"] { try await db.schema(table).delete() }
    }
}
