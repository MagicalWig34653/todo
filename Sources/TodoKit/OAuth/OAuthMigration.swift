import Fluent
import FluentSQL
import Foundation

/// Unused dynamically registered clients are purged by age (ADR-less security hardening); existing rows start their clock now.
struct AddOAuthClientCreatedAt: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("oauth_clients").field("created_at", .datetime).update()
        try await OAuthClient.query(on: db).set(\.$createdAt, to: Date()).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("oauth_clients").deleteField("created_at").update()
    }
}

/// ADR 0036 (card BEF08998): reuse window of rotated refresh tokens and the cause of a revocation. Additive and nullable:
/// tokens rotated before get no window, connections revoked before keep an unknown cause and are never taken over. Runs
/// before `AddOAuthGrantNameAndUsage`, which reads whole grant rows.
struct AddOAuthReuseAndRevocation: AsyncMigration {
    private static let columns: [(String, FieldKey, DatabaseSchema.DataType)] = [
        ("oauth_secrets", "consumed_at", .datetime), ("oauth_secrets", "rotated_from", .uuid),
        ("oauth_grants", "revoked_reason", .string), ("oauth_grants", "revoked_at", .datetime)]
    func prepare(on db: any Database) async throws {
        for (table, field, type) in Self.columns { try await db.schema(table).field(field, type).update() }
    }
    func revert(on db: any Database) async throws {
        // SQLite cannot drop an indexed column; the index belongs to `AddOAuthRotatedFromIndex`.
        try await AddOAuthRotatedFromIndex.drop(on: db)
        for (table, field, _) in Self.columns { try await db.schema(table).deleteField(field).update() }
    }
}

/// ADR 0036: which connections a connection took over after a new sign-in. Additive and nullable; same ordering rule as
/// `AddOAuthReuseAndRevocation`.
struct AddOAuthGrantLineage: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("oauth_grants").field("predecessors", .json).update()
        try await db.schema("oauth_grants").field("taken_over_at", .datetime).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("oauth_grants").deleteField("predecessors").update()
        try await db.schema("oauth_grants").deleteField("taken_over_at").update()
    }
}

/// Security review 26.11.2026 (ADR 0036): siblings are looked up by `rotated_from` inside the token transaction. Without an
/// index MariaDB scans and locks the whole table there, so rotations of unrelated connections deadlock (ERROR 1213/1020).
/// Separate migration and idempotent (`IF NOT EXISTS`), so databases that already ran `AddOAuthReuseAndRevocation` (dc842e3)
/// get it as well as fresh ones and ones from before ADR 0036 (cf4237e).
struct AddOAuthRotatedFromIndex: AsyncMigration {
    static let name = "oauth_secrets_rotated_from"
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS \(ident: Self.name) ON \(ident: OAuthSecret.schema) (\(ident: "rotated_from"))").run()
    }
    func revert(on db: any Database) async throws { try await Self.drop(on: db) }
    static func drop(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        if sql.dialect.name == "sqlite" {
            try await sql.raw("DROP INDEX IF EXISTS \(ident: name)").run()
        } else {
            try await sql.raw("DROP INDEX IF EXISTS \(ident: name) ON \(ident: OAuthSecret.schema)").run()
        }
    }
}

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
            .field("payload", .sql(raw: "TEXT"), .required).field("expires_at", .datetime, .required)
            .field("consumed", .bool, .required).create()
    }
    func revert(on db: any Database) async throws {
        for table in ["oauth_secrets", "oauth_grants", "oauth_clients"] { try await db.schema(table).delete() }
    }
}
