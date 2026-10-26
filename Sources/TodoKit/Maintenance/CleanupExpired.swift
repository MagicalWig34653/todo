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

    struct Report: Sendable, Equatable {
        var sessions = 0, challenges = 0, invitations = 0, recoveries = 0
        var rateLimits = 0, oauthSecrets = 0, pairings = 0
        var total: Int { sessions + challenges + invitations + recoveries + rateLimits + oauthSecrets + pairings }
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
        return r
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
    }
    let help = "Delete expired sessions, challenges, invitations, recovery grants, rate-limit rows, OAuth tokens and pairing codes."
    func run(using context: CommandContext, signature: Signature) async throws {
        var cleanup = ExpiredCleanup()
        if let g = signature.grace { guard g >= 0 else { throw Abort(.badRequest, reason: "invalid_grace") }; cleanup.grace = TimeInterval(g) }
        if let b = signature.batch { guard (1...10_000).contains(b) else { throw Abort(.badRequest, reason: "invalid_batch_size") }; cleanup.batchSize = b }
        let r = try await cleanup.run(on: context.application.db)
        context.console.print("Removed \(r.total) expired rows (sessions \(r.sessions), challenges \(r.challenges), invitations \(r.invitations), recovery \(r.recoveries), rate limits \(r.rateLimits), OAuth tokens \(r.oauthSecrets), pairings \(r.pairings)).")
    }
}

func configureMaintenance(_ app: Application) {
    app.asyncCommands.use(CleanupExpiredCommand(), as: "cleanup-expired")
}
