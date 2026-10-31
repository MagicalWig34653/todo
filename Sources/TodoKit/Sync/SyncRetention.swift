import Fluent
import SQLKit
import Vapor

/// Counter row (in `sync_counter`) that stores the retention floor: the highest `seq` of a purged
/// `delete`/`revoke` entry. A client whose cursor is below it may have missed tombstones and must resync from `c0`.
let syncFloorID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

/// Bounded growth of the change log (ADR 0019). Safe to run on several replicas at once: every step is idempotent,
/// works in small batches and the floor only ever moves forward.
///
/// What is removed (only rows older than the cutoff):
/// - tombstones (`delete`/`revoke`) and their frozen audiences; the floor is raised first, in the same transaction;
/// - upserts that are superseded by a later upsert of the same entity, or whose entity was deleted;
/// - stored mutation results (`sync_mutations`), which only serve idempotent replays.
/// The newest upsert of every living entity is kept, so `c0` still yields the complete visible state.
struct SyncRetention: Sendable {
    var batchSize = 500

    struct Report: Sendable, Equatable {
        var tombstones = 0, superseded = 0, mutations = 0
        var total: Int { tombstones + superseded + mutations }
    }

    static func floor(on db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase,
              let row = try await sql.raw("SELECT value FROM sync_counter WHERE id = \(bind: syncFloorID)").first()
        else { return 0 }
        return try row.decode(column: "value", as: Int.self)
    }

    private static func ensureFloorRow(_ sql: any SQLDatabase) async throws {
        let verb = sql.dialect.name == "sqlite" ? "INSERT OR IGNORE" : "INSERT IGNORE"
        try await sql.raw("\(unsafeRaw: verb) INTO sync_counter (id, value) VALUES (\(bind: syncFloorID), 0)").run()
    }

    private func ids(_ sql: any SQLDatabase, _ query: SQLQueryString) async throws -> [(id: UUID, seq: Int)] {
        try await sql.raw(query).all().map { (try $0.decode(column: "id", as: UUID.self), try $0.decode(column: "seq", as: Int.self)) }
    }

    @discardableResult func run(on db: any Database, olderThan cutoff: Date) async throws -> Report {
        guard let sql = db as? any SQLDatabase else { return Report() }
        try await Self.ensureFloorRow(sql)
        var r = Report()
        r.tombstones = try await purgeTombstones(db, sql, cutoff)
        r.superseded = try await purgeSuperseded(db, sql, cutoff)
        r.mutations = try await purgeMutations(db, sql, cutoff)
        return r
    }

    private func purgeTombstones(_ db: any Database, _ sql: any SQLDatabase, _ cutoff: Date) async throws -> Int {
        var total = 0
        while true {
            let rows = try await ids(sql, """
                SELECT id, seq FROM sync_changes WHERE kind IN ('delete', 'revoke') AND created_at < \(bind: cutoff)
                ORDER BY seq LIMIT \(literal: batchSize)
                """)
            if rows.isEmpty { return total }
            let maxSeq = rows.map(\.seq).max()!
            try await db.transaction { tx in
                guard let txSQL = tx as? any SQLDatabase else { return }
                try await lockRow(table: "sync_counter", id: syncFloorID, on: tx)
                // Floor first, in the same transaction as the deletion: a reader that no longer finds a tombstone
                // reads the floor afterwards and therefore sees it raised.
                let current = try await Self.floor(on: tx)
                if maxSeq > current {
                    try await txSQL.raw("UPDATE sync_counter SET value = \(bind: maxSeq) WHERE id = \(bind: syncFloorID)").run()
                }
                for (id, seq) in rows {
                    try await txSQL.raw("DELETE FROM sync_tombstone_audience WHERE seq = \(bind: seq)").run()
                    try await txSQL.raw("DELETE FROM sync_changes WHERE id = \(bind: id) AND seq = \(bind: seq)").run()
                }
            }
            total += rows.count
            if rows.count < batchSize { return total }
        }
    }

    private func purgeSuperseded(_ db: any Database, _ sql: any SQLDatabase, _ cutoff: Date) async throws -> Int {
        var total = 0
        while true {
            let rows = try await ids(sql, """
                SELECT c.id AS id, c.seq AS seq FROM sync_changes c
                WHERE c.kind = 'upsert' AND c.created_at < \(bind: cutoff)
                AND (EXISTS (SELECT 1 FROM sync_changes n WHERE n.entity_id = c.entity_id AND n.kind = 'upsert' AND n.seq > c.seq)
                  OR EXISTS (SELECT 1 FROM sync_changes d WHERE d.entity_id = c.entity_id AND d.kind = 'delete' AND d.seq > c.seq))
                ORDER BY c.seq LIMIT \(literal: batchSize)
                """)
            if rows.isEmpty { return total }
            for (id, seq) in rows {
                try await sql.raw("DELETE FROM sync_changes WHERE id = \(bind: id) AND seq = \(bind: seq)").run()
            }
            total += rows.count
            if rows.count < batchSize { return total }
        }
    }

    private func purgeMutations(_ db: any Database, _ sql: any SQLDatabase, _ cutoff: Date) async throws -> Int {
        var total = 0
        while true {
            let rows = try await sql.raw("SELECT id FROM sync_mutations WHERE created_at < \(bind: cutoff) ORDER BY id LIMIT \(literal: batchSize)")
                .all().map { try $0.decode(column: "id", as: UUID.self) }
            if rows.isEmpty { return total }
            for id in rows { try await sql.raw("DELETE FROM sync_mutations WHERE id = \(bind: id)").run() }
            total += rows.count
            if rows.count < batchSize { return total }
        }
    }
}

/// Indexes for the purge queries, the lease table for the scheduler and the retention floor row.
/// Registered after `CreateSyncSchema`.
struct AddSyncRetentionSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX sync_changes_entity_seq_idx ON sync_changes (entity_id, seq)").run()
        try await sql.raw("CREATE INDEX sync_changes_created_idx ON sync_changes (created_at)").run()
        try await sql.raw("CREATE INDEX sync_mutations_created_idx ON sync_mutations (created_at)").run()
        let verb = sql.dialect.name == "sqlite" ? "INSERT OR IGNORE" : "INSERT IGNORE"
        try await sql.raw("\(unsafeRaw: verb) INTO sync_counter (id, value) VALUES (\(bind: syncFloorID), 0)").run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM sync_counter WHERE id = \(bind: syncFloorID)").run()
        if sql.dialect.name == "sqlite" {
            for index in ["sync_changes_entity_seq_idx", "sync_changes_created_idx", "sync_mutations_created_idx"] {
                try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index)").run()
            }
        } else {
            try await sql.raw("DROP INDEX sync_changes_entity_seq_idx ON sync_changes").run()
            try await sql.raw("DROP INDEX sync_changes_created_idx ON sync_changes").run()
            try await sql.raw("DROP INDEX sync_mutations_created_idx ON sync_mutations").run()
        }
    }
}
