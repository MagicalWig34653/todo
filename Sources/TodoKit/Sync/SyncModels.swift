import Fluent
import SQLKit
import Vapor

/// One entry of the replica-safe change log. `seq` is allocated under the sharing-graph lock, so it is gap-free
/// and strictly in commit order: a client that has seen `seq = n` has seen every committed change up to `n`.
final class SyncChange: Model, @unchecked Sendable {
    static let schema = "sync_changes"
    @ID(key: .id) var id: UUID?
    @Field(key: "seq") var seq: Int
    @Field(key: "entity_type") var entityType: String // project | task
    @Field(key: "entity_id") var entityID: UUID
    @Field(key: "kind") var kind: String // upsert | delete
    @OptionalField(key: "project_id") var projectID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(seq: Int, entityType: String, entityID: UUID, kind: String, projectID: UUID?) {
        self.seq = seq; self.entityType = entityType; self.entityID = entityID; self.kind = kind; self.projectID = projectID
    }
}

/// Who was allowed to read an object at the moment it was deleted. Tombstones cannot be authorized afterwards
/// (the project row is gone), so the audience is frozen into the log.
final class SyncTombstoneAudience: Model, @unchecked Sendable {
    static let schema = "sync_tombstone_audience"
    @ID(key: .id) var id: UUID?
    @Field(key: "seq") var seq: Int
    @Field(key: "user_id") var userID: UUID
    init() {}
    init(seq: Int, userID: UUID) { self.seq = seq; self.userID = userID }
}

/// Stored result of an applied client mutation, keyed by (account, client mutation ID).
final class SyncMutation: Model, @unchecked Sendable {
    static let schema = "sync_mutations"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "mutation_id") var mutationID: UUID
    @Field(key: "request_hash") var requestHash: String
    @Field(key: "status") var status: Int
    @Field(key: "response") var response: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(userID: UUID, mutationID: UUID, requestHash: String, status: Int, response: String) {
        self.userID = userID; self.mutationID = mutationID; self.requestHash = requestHash
        self.status = status; self.response = response
    }
}

let syncCounterID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

struct CreateSyncSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(SyncChange.schema).id()
            .field("seq", .int64, .required)
            .field("entity_type", .string, .required)
            .field("entity_id", .uuid, .required)
            .field("kind", .string, .required)
            .field("project_id", .uuid)
            .field("created_at", .datetime)
            .unique(on: "seq").create()
        try await db.schema(SyncTombstoneAudience.schema).id()
            .field("seq", .int64, .required)
            .field("user_id", .uuid, .required)
            .unique(on: "seq", "user_id").create()
        try await db.schema(SyncMutation.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("mutation_id", .uuid, .required)
            .field("request_hash", .string, .required)
            .field("status", .int, .required)
            .field("response", .sql(unsafeRaw: "TEXT"), .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "mutation_id").create()
        try await db.schema("sync_counter").id().field("value", .int64, .required).create()
        // Backfill: pre-existing projects and tasks become upserts so a cursor of 0 yields the full state.
        var seq = 0
        for project in try await Project.query(on: db).sort(\.$createdAt).sort(\.$id).all() {
            seq += 1
            try await SyncChange(seq: seq, entityType: "project", entityID: project.requireID(), kind: "upsert",
                projectID: project.requireID()).save(on: db)
        }
        for task in try await TodoTask.query(on: db).sort(\.$createdAt).sort(\.$id).all() {
            seq += 1
            try await SyncChange(seq: seq, entityType: "task", entityID: task.requireID(), kind: "upsert",
                projectID: task.projectID).save(on: db)
        }
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("INSERT INTO sync_counter (id, value) VALUES (\(bind: syncCounterID), \(bind: seq))").run()
    }

    func revert(on db: any Database) async throws {
        for table in ["sync_counter", SyncMutation.schema, SyncTombstoneAudience.schema, SyncChange.schema] {
            try await db.schema(table).delete()
        }
    }
}
