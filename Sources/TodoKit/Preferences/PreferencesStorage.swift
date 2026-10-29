import Fluent
import Vapor

/// One row per account holding the validated preferences document as JSON text.
final class UserPreferences: Model, @unchecked Sendable {
    static let schema = "user_preferences"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    /// Schema version of `document` (see `PreferencesDocument.currentVersion`); older rows are migrated on read.
    @Field(key: "version") var version: Int
    @Field(key: "document") var document: String
    /// Incremented on every write; lets clients notice that another device changed the document.
    @Field(key: "revision") var revision: Int
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

struct CreateUserPreferences: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(UserPreferences.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .unique(on: "user_id")
            .field("version", .int, .required)
            .field("document", .sql(raw: "TEXT"), .required)
            .field("revision", .int, .required)
            .field("updated_at", .datetime, .required).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(UserPreferences.schema).delete()
    }
}

func configurePreferences(_ app: Application) {
    app.migrations.add(CreateUserPreferences())
}

func registerPreferences(_ app: Application) throws {
    try app.register(collection: PreferencesController())
}
