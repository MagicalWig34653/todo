import Fluent
import FluentSQL

struct CreateDiscoverySchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(DiscoveryLabel.schema).id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required).field("version", .int, .required).create()
        try await db.schema(DiscoveryTaskLabel.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("label_id", .uuid, .required, .references(DiscoveryLabel.schema, "id", onDelete: .cascade))
            .unique(on: "task_id", "label_id").create()
        try await db.schema(DiscoverySavedFilter.schema).id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required).field("criteria", .sql(.text), .required)
            .field("version", .int, .required).create()
    }

    func revert(on db: any Database) async throws {
        for table in [DiscoverySavedFilter.schema, DiscoveryTaskLabel.schema, DiscoveryLabel.schema] {
            try await db.schema(table).delete()
        }
    }
}
