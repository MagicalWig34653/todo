import Foundation
import Fluent
import SQLKit

struct CreateSharingSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Team.schema).id()
            .field("name", .string, .required)
            .field("founder_id", .uuid, .required, .references("users", "id"))
            .create()
        try await db.schema(TeamMembership.schema).id()
            .field("team_id", .uuid, .required, .references(Team.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("is_admin", .bool, .required).field("accepted", .bool, .required)
            .unique(on: "team_id", "user_id").create()
        try await db.schema(ProjectGrant.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("principal_type", .string, .required).field("principal_id", .uuid, .required)
            .field("role", .string, .required)
            .unique(on: "project_id", "principal_type", "principal_id").create()
        try await db.schema(ProjectSharing.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("owner_type", .string, .required).field("owner_id", .uuid, .required)
            .field("inherits", .bool, .required).unique(on: "project_id").create()
        try await db.schema("sharing_lock").id().field("revision", .int, .required).create()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("INSERT INTO sharing_lock (id, revision) VALUES (\(bind: sharingLockID), 0)").run()
        }
    }
    func revert(on db: any Database) async throws {
        for table in ["sharing_lock", ProjectSharing.schema, ProjectGrant.schema, TeamMembership.schema, Team.schema] {
            try await db.schema(table).delete()
        }
    }
}

private let sharingLockID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

/// Acquire before any reads in a write transaction. UPDATE also obtains SQLite's writer lock.
/// MariaDB serializes graph/ACL changes across replicas, preventing write-skew cycles.
func lockSharingGraph(on db: any Database) async throws {
    guard let sql = db as? any SQLDatabase else { throw SharingDatabaseError.unsupported }
    try await sql.raw("UPDATE sharing_lock SET revision = revision + 1 WHERE id = \(bind: sharingLockID)").run()
}
private enum SharingDatabaseError: Error { case unsupported }
