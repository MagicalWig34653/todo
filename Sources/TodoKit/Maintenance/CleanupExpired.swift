import Fluent
import SQLKit
import Vapor

/// Removes expired short-lived rows. Safe to run on several replicas or schedulers at once:
/// every delete is idempotent, ids are processed in sorted order in small autocommit batches
/// (consistent lock order, no long transactions), and nothing depends on in-process state.
/// Counts are what this run selected; two overlapping runs may both count the same row.
struct ExpiredCleanup: Sendable {
    /// Rows stay this long after expiry (replay detection of consumed OAuth tokens, diagnostics).
    var grace: TimeInterval = 86_400
    var batchSize = 500
    /// Age after which change-log tombstones, superseded upserts and stored mutation results are purged (ADR 0019).
    /// nil keeps the sync log untouched.
    var syncRetention: TimeInterval?
    /// Dynamically registered OAuth clients without any grant are removed after this age (default 7 days, env OAUTH_UNUSED_CLIENT_DAYS; nil keeps them).
    var unusedClientRetention: TimeInterval? = ExpiredCleanup.defaultClientRetention()

    static func defaultClientRetention() -> TimeInterval? {
        guard let raw = Environment.get("OAUTH_UNUSED_CLIENT_DAYS") else { return 7 * 86_400 }
        guard let days = Int(raw), days > 0 else { return nil }
        return TimeInterval(days) * 86_400
    }

    struct Report: Sendable, Equatable {
        var sessions = 0, challenges = 0, invitations = 0, recoveries = 0
        var rateLimits = 0, oauthSecrets = 0, pairings = 0, oauthClients = 0
        var syncTombstones = 0, syncSuperseded = 0, syncMutations = 0
        /// Confirmation requests deleted (ADR 0026).
        var actionRequests = 0
        /// Connection access notices deleted (ADR 0028).
        var accessNotices = 0
        var syncTotal: Int { syncTombstones + syncSuperseded + syncMutations }
        var total: Int { sessions + challenges + invitations + recoveries + rateLimits + oauthSecrets + pairings + oauthClients + actionRequests + accessNotices + syncTotal }
    }

    private func purge<M: Model>(_ type: M.Type, on db: any Database, _ condition: (QueryBuilder<M>) -> QueryBuilder<M>) async throws -> Int
    where M.IDValue == UUID {
        var total = 0
        while true {
            let ids = try await condition(M.query(on: db)).sort(\M._$id).limit(batchSize).all().compactMap(\.id)
            if ids.isEmpty { return total }
            try await M.query(on: db).filter(\M._$id ~~ ids).delete()
            total += ids.count
            if ids.count < batchSize { return total }
        }
    }

    @discardableResult func run(on db: any Database, now: Date = Date()) async throws -> Report {
        let cutoff = now.addingTimeInterval(-grace)
        var r = Report()
        r.sessions = try await purge(UserSession.self, on: db) { $0.filter(\.$expiresAt < cutoff) }
        r.challenges = try await purge(AuthChallenge.self, on: db) { $0.filter(\.$expiresAt < cutoff) }
        r.invitations = try await purge(Invitation.self, on: db) { $0.filter(\.$expiresAt < cutoff) }
        // A recovery grant is only removable once its code and any started recovery session are over.
        r.recoveries = try await purge(RecoveryGrant.self, on: db) {
            $0.filter(\.$expiresAt < cutoff).group(.or) { $0.filter(\.$sessionExpiresAt == nil).filter(\.$sessionExpiresAt < cutoff) }
        }
        r.oauthSecrets = try await purge(OAuthSecret.self, on: db) { $0.filter(\.$expiresAt < cutoff) }
        r.pairings = try await purge(RunnerPairing.self, on: db) { $0.filter(\.$expiresAt < cutoff) }
        r.rateLimits = try await purgeRateLimits(on: db)
        // Open requests past their expiry become `expired`; decided and expired rows (the audit trail) go after 30 days.
        try await ActionRequest.query(on: db).filter(\.$state == "pending").filter(\.$expiresAt < now).set(\.$state, to: "expired").update()
        r.actionRequests = try await purge(ActionRequest.self, on: db) { $0.filter(\.$state != "pending").filter(\.$expiresAt < now.addingTimeInterval(-30 * 86_400)) }
        // Notices: decided ones after 7 days, open ones that were not repeated for 30 days.
        r.accessNotices = try await purge(ConnectionAccessRequest.self, on: db) { $0.filter(\.$state != "open").filter(\.$lastAt < now.addingTimeInterval(-7 * 86_400)) }
        r.accessNotices += try await purge(ConnectionAccessRequest.self, on: db) { $0.filter(\.$lastAt < now.addingTimeInterval(-30 * 86_400)) }
        if let age = unusedClientRetention { r.oauthClients = try await purgeUnusedClients(on: db, olderThan: now.addingTimeInterval(-age)) }
        if let retention = syncRetention {
            let sync = try await SyncRetention(batchSize: batchSize).run(on: db, olderThan: now.addingTimeInterval(-retention))
            r.syncTombstones = sync.tombstones; r.syncSuperseded = sync.superseded; r.syncMutations = sync.mutations
        }
        return r
    }

    /// Clients nobody ever authorized (no grant row, revoked or not) and older than the cutoff.
    private func purgeUnusedClients(on db: any Database, olderThan cutoff: Date) async throws -> Int {
        var total = 0
        var last: UUID?
        while true {
            var q = OAuthClient.query(on: db).filter(\.$createdAt < cutoff).sort(\.$id).limit(batchSize)
            if let last { q = q.filter(\.$id > last) }
            let ids = try await q.all().compactMap(\.id)
            if ids.isEmpty { return total }
            last = ids.last
            let used = Set(try await OAuthGrant.query(on: db).filter(\.$clientID ~~ ids).all().map(\.clientID))
            let unused = ids.filter { !used.contains($0) }
            if !unused.isEmpty {
                try await OAuthClient.query(on: db).filter(\.$id ~~ unused).delete()
                total += unused.count
            }
            if ids.count < batchSize { return total }
        }
    }

    /// Rate-limit windows are measured with the database clock; a row is useless once its window ended.
    private func purgeRateLimits(on db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        let now: Int64
        if sql.dialect.name == "sqlite" {
            now = try await sql.raw("SELECT CAST(strftime('%s', 'now') AS INTEGER) AS t").first()!.decode(column: "t", as: Int64.self)
        } else {
            now = try await sql.raw("SELECT UNIX_TIMESTAMP() AS t").first()!.decode(column: "t", as: Int64.self)
        }
        var total = 0
        while true {
            let ids = try await sql.raw("SELECT id FROM identity_rate_limits WHERE expires_at < \(bind: now) ORDER BY id LIMIT \(literal: batchSize)")
                .all().map { try $0.decode(column: "id", as: String.self) }
            if ids.isEmpty { return total }
            for id in ids {
                try await sql.raw("DELETE FROM identity_rate_limits WHERE id = \(bind: id) AND expires_at < \(bind: now)").run()
            }
            total += ids.count
            if ids.count < batchSize { return total }
        }
    }
}

struct CleanupExpiredCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "grace-seconds", help: "Keep rows this long after expiry (default 86400).")
        var grace: Int?
        @Option(name: "batch-size", help: "Rows per delete batch (default 500).")
        var batch: Int?
        @Option(name: "sync-retention-days", help: "Purge sync log entries older than this (default SYNC_RETENTION_DAYS, 90; 0 keeps them).")
        var syncRetentionDays: Int?
    }
    let help = "Delete expired sessions, challenges, invitations, recovery grants, rate-limit rows, OAuth tokens and pairing codes."
    func run(using context: CommandContext, signature: Signature) async throws {
        var cleanup = ExpiredCleanup()
        if let g = signature.grace { guard g >= 0 else { throw Abort(.badRequest, reason: "invalid_grace") }; cleanup.grace = TimeInterval(g) }
        if let b = signature.batch { guard (1...10_000).contains(b) else { throw Abort(.badRequest, reason: "invalid_batch_size") }; cleanup.batchSize = b }
        let days = signature.syncRetentionDays ?? context.application.settings.syncRetentionDays
        guard days >= 0 else { throw Abort(.badRequest, reason: "invalid_sync_retention") }
        if days > 0 { cleanup.syncRetention = TimeInterval(days) * 86_400 }
        let r = try await cleanup.run(on: context.application.db)
        context.console.print("Removed \(r.total) expired rows (sessions \(r.sessions), challenges \(r.challenges), invitations \(r.invitations), recovery \(r.recoveries), rate limits \(r.rateLimits), OAuth tokens \(r.oauthSecrets), pairings \(r.pairings), unused OAuth clients \(r.oauthClients), sync log \(r.syncTotal)).")
    }
}

func configureMaintenance(_ app: Application) {
    app.asyncCommands.use(CleanupExpiredCommand(), as: "cleanup-expired")
    app.asyncCommands.use(DeleteAccountCommand(), as: "delete-account")
    app.migrations.add(CreateMaintenanceLeases())
}
