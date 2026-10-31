import Fluent
import SQLKit
import Vapor

/// Table with one row per periodic job; the row is the lease (ADR 0019). No `GET_LOCK` (it is bound to one pooled
/// connection and silently lost with it): acquiring is a single atomic `UPDATE` on the row, so only one replica
/// wins, and an expired lease (crashed holder) is taken over automatically. Times use the database clock.
struct CreateMaintenanceLeases: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("maintenance_leases").id()
            .field("name", .string, .required)
            .field("holder", .string, .required)
            .field("expires_at", .int64, .required)
            .field("last_run_at", .int64, .required)
            .field("last_status", .string, .required)
            .field("last_message", .string, .required)
            .unique(on: "name").create()
    }
    func revert(on db: any Database) async throws { try await db.schema("maintenance_leases").delete() }
}

struct MaintenanceStatus: Content, Equatable {
    var enabled: Bool
    /// ISO-8601; nil if the job never ran.
    var lastRunAt: String?
    /// ok | error | never
    var lastStatus: String
}

/// Periodic `cleanup-expired` inside the API process. Every replica runs a scheduler, the lease row decides who
/// works; failures are logged and recorded on the row and never affect serving or `/health/ready`.
final class CleanupScheduler: LifecycleHandler, @unchecked Sendable {
    static let jobName = "cleanup-expired"

    enum Outcome: Equatable {
        case skipped
        case ran(ExpiredCleanup.Report)
        case failed(String)
    }

    let app: Application
    let interval: TimeInterval
    let leaseDuration: TimeInterval
    let retention: TimeInterval?
    let holder = UUID().uuidString
    /// Pause after a failed run before another attempt (instead of waiting a full interval).
    let retryAfterFailure: TimeInterval = 300
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(app: Application, interval: TimeInterval, retention: TimeInterval?, leaseDuration: TimeInterval = 1800) {
        self.app = app; self.interval = interval; self.retention = retention; self.leaseDuration = leaseDuration
    }

    // MARK: Lifecycle

    /// True for `serve` (explicit or default); false for one-off commands like `migrate` or `cleanup-expired`.
    static func isServing(arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first else { return true }
        return first == "serve" || first.hasPrefix("-")
    }

    func didBoot(_ application: Application) throws {
        guard Self.isServing(arguments: application.environment.arguments) else { return }
        start()
    }

    func shutdown(_ application: Application) {
        lock.lock(); let t = task; task = nil; lock.unlock()
        t?.cancel()
    }

    func start(initialDelay: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let period = min(interval, 300)
        let delay = initialDelay ?? Double.random(in: 20...60)
        task = Task.detached { [self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                _ = await runIfDue()
                let jitter = Double.random(in: 0.9...1.1)
                try? await Task.sleep(nanoseconds: UInt64(period * jitter * 1_000_000_000))
            }
        }
    }

    // MARK: One tick

    func runIfDue() async -> Outcome {
        let db = app.db
        guard let sql = db as? any SQLDatabase else { return .skipped }
        do {
            guard try await acquire(sql) else { return .skipped }
        } catch {
            app.logger.warning("cleanup scheduler: lease check failed: \(String(reflecting: error))")
            return .failed("lease")
        }
        do {
            var cleanup = ExpiredCleanup()
            cleanup.syncRetention = retention
            let report = try await cleanup.run(on: db)
            try await finish(sql, status: "ok", message: Self.summary(report), failed: false)
            app.logger.info("cleanup scheduler: \(Self.summary(report))")
            return .ran(report)
        } catch {
            let text = String(reflecting: error)
            app.logger.error("cleanup scheduler: run failed: \(text)")
            try? await finish(sql, status: "error", message: String(text.prefix(200)), failed: true)
            return .failed(text)
        }
    }

    static func summary(_ r: ExpiredCleanup.Report) -> String {
        "removed \(r.total) rows (expired \(r.total - r.syncTotal), sync log \(r.syncTotal))"
    }

    private func databaseNow(_ sql: any SQLDatabase) async throws -> Int64 {
        let query = sql.dialect.name == "sqlite" ? "SELECT CAST(strftime('%s', 'now') AS INTEGER) AS t" : "SELECT UNIX_TIMESTAMP() AS t"
        guard let row = try await sql.raw(SQLQueryString(query)).first() else { throw Abort(.internalServerError) }
        return try row.decode(column: "t", as: Int64.self)
    }

    /// Atomic take-over: only one `UPDATE` can match while the lease is free and the last run is old enough.
    private func acquire(_ sql: any SQLDatabase) async throws -> Bool {
        // Only the very first run ever needs the insert; checking first avoids concurrent duplicate-key locking.
        if try await sql.raw("SELECT 1 AS x FROM maintenance_leases WHERE name = \(bind: Self.jobName)").first() == nil {
            let verb = sql.dialect.name == "sqlite" ? "INSERT OR IGNORE" : "INSERT IGNORE"
            try await sql.raw("""
                \(unsafeRaw: verb) INTO maintenance_leases (id, name, holder, expires_at, last_run_at, last_status, last_message)
                VALUES (\(bind: UUID()), \(bind: Self.jobName), '', 0, 0, 'never', '')
                """).run()
        }
        let now = try await databaseNow(sql)
        let due = now - Int64(interval)
        let until = now + Int64(leaseDuration)
        try await sql.raw("""
            UPDATE maintenance_leases SET holder = \(bind: holder), expires_at = \(bind: until)
            WHERE name = \(bind: Self.jobName) AND expires_at < \(bind: now) AND last_run_at <= \(bind: due)
            """).run()
        let row = try await sql.raw("SELECT holder FROM maintenance_leases WHERE name = \(bind: Self.jobName)").first()
        return try row?.decode(column: "holder", as: String.self) == holder
    }

    private func finish(_ sql: any SQLDatabase, status: String, message: String, failed: Bool) async throws {
        let now = try await databaseNow(sql)
        // After a failure the next attempt is due after `retryAfterFailure`, not after a full interval.
        let lastRun = failed ? now - max(0, Int64(interval) - Int64(retryAfterFailure)) : now
        try await sql.raw("""
            UPDATE maintenance_leases SET holder = '', expires_at = 0, last_run_at = \(bind: lastRun), last_status = \(bind: status),
            last_message = \(bind: message) WHERE name = \(bind: Self.jobName) AND holder = \(bind: holder)
            """).run()
    }

    // MARK: Status (best effort, for /health/ready)

    static func status(of app: Application) async -> MaintenanceStatus? {
        guard app.storage[SchedulerKey.self] != nil else { return nil }
        guard let sql = app.db as? any SQLDatabase,
              let row = try? await sql.raw("SELECT last_run_at, last_status FROM maintenance_leases WHERE name = \(bind: jobName)").first(),
              let at = try? row.decode(column: "last_run_at", as: Int64.self),
              let status = try? row.decode(column: "last_status", as: String.self)
        else { return MaintenanceStatus(enabled: true, lastRunAt: nil, lastStatus: "never") }
        return MaintenanceStatus(enabled: true,
            lastRunAt: at > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(at))) : nil,
            lastStatus: status)
    }

    struct SchedulerKey: StorageKey { typealias Value = CleanupScheduler }
}

func configureMaintenanceScheduler(_ app: Application) {
    let s = app.settings
    guard s.cleanupIntervalMinutes > 0 else {
        app.logger.info("cleanup scheduler disabled (CLEANUP_INTERVAL_MINUTES=0)")
        return
    }
    let scheduler = CleanupScheduler(
        app: app, interval: TimeInterval(s.cleanupIntervalMinutes) * 60,
        retention: s.syncRetentionDays > 0 ? TimeInterval(s.syncRetentionDays) * 86_400 : nil)
    app.storage[CleanupScheduler.SchedulerKey.self] = scheduler
    app.lifecycle.use(scheduler)
}
