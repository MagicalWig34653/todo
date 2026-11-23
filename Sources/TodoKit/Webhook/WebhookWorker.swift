import Fluent
import SQLKit
import Vapor

/// Background worker of the outgoing webhook (ADR 0035). Same pattern as `PushWorker`: every replica runs one; a lease row in
/// `maintenance_leases` lets exactly one of them work per interval. Per run: send due rows (bundles, retries), purge the log.
/// Nothing here runs in the request path (the "send test" request calls `WebhookDeliverer` itself).
final class WebhookWorker: LifecycleHandler, @unchecked Sendable {
    static let jobName = "webhook-worker"

    struct Report: Equatable, Sendable {
        var sent = 0, retried = 0, failed = 0, skipped = 0, purged = 0
    }
    enum Outcome: Equatable, Sendable {
        case skipped
        case ran(Report)
        case failed(String)
    }

    let app: Application
    /// Minimum seconds between two runs across all replicas. Small, because the bundle window is only 60 s.
    let interval: TimeInterval
    let leaseDuration: TimeInterval
    let holder = UUID().uuidString
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(app: Application, interval: TimeInterval = 10, leaseDuration: TimeInterval = 120) {
        self.app = app; self.interval = interval; self.leaseDuration = leaseDuration
    }

    // MARK: Lifecycle

    func didBoot(_ application: Application) throws {
        guard CleanupScheduler.isServing(arguments: application.environment.arguments) else { return }
        start()
    }

    func shutdown(_ application: Application) {
        lock.lock(); let t = task; task = nil; lock.unlock()
        t?.cancel()
    }

    func start(initialDelay: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let delay = initialDelay ?? Double.random(in: 3...8)
        let period = max(1, interval / 2)
        task = Task.detached { [self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                _ = await runIfDue()
                try? await Task.sleep(nanoseconds: UInt64(period * Double.random(in: 0.9...1.1) * 1_000_000_000))
            }
        }
    }

    // MARK: One run

    func runIfDue() async -> Outcome {
        guard let sql = app.db as? any SQLDatabase else { return .skipped }
        do { guard try await acquire(sql) else { return .skipped } }
        catch {
            app.logger.warning("webhook worker: lease check failed")
            return .failed("lease")
        }
        do {
            let report = try await tick(keepLease: { [self] in await renew(sql) })
            try await finish(sql, status: "ok", message: "sent \(report.sent), retried \(report.retried), failed \(report.failed)")
            return .ran(report)
        } catch {
            // Only the type: error texts of the database or transport layers could carry identifiers.
            app.logger.error("webhook worker: run failed (\(type(of: error)))")
            try? await finish(sql, status: "error", message: String(describing: type(of: error)))
            return .failed(String(describing: type(of: error)))
        }
    }

    func tick(now: Date = Date(), keepLease: (@Sendable () async -> Bool)? = nil) async throws -> Report {
        var report = Report()
        let db = app.db
        let due = try await WebhookDelivery.query(on: db).filter(\.$state == "pending").filter(\.$nextAttemptAt <= now)
            .sort(\.$dueAt).sort(\.$id).limit(50).all()
        let deliverer = WebhookDeliverer(app: app)
        // The target host of a row is the host of the mask of its webhook (`https://host`, no secret part), so no decryption is needed here.
        let masks = Dictionary(try await WebhookEndpoint.query(on: db).filter(\.$userID ~~ Set(due.map(\.userID))).all().map { ($0.userID, $0.urlMask.lowercased()) },
                               uniquingKeysWith: { first, _ in first })
        var waiting = due.map { (row: $0, host: masks[$0.userID] ?? "user:\($0.userID.uuidString)") }
        var busyHosts = Set<String>()
        var stopped = false
        // A tarpit target must not hold up the others: up to `maxConcurrentDeliveries` at once, but never two for one host
        // (rows of one host, also of different people, go one after the other). Everything is started and collected from this
        // task, so the report and the sets need no locking.
        await withTaskGroup(of: (host: String, outcome: Result<WebhookDeliverer.Verdict?, any Error>).self) { group in
            var active = 0
            while true {
                while !stopped, active < WebhookLimits.maxConcurrentDeliveries,
                      let index = waiting.firstIndex(where: { !busyHosts.contains($0.host) }) {
                    // Renewed before every start: a run of many slow targets keeps its lease, a lost lease stops the run.
                    if let keepLease, !(await keepLease()) { stopped = true; break }
                    let entry = waiting.remove(at: index)
                    busyHosts.insert(entry.host); active += 1
                    group.addTask { [self] in
                        do { return (entry.host, .success(try await deliver(entry.row, with: deliverer, now: now))) }
                        catch { return (entry.host, .failure(error)) }
                    }
                }
                guard active > 0, let finished = await group.next() else { break }
                active -= 1; busyHosts.remove(finished.host)
                switch finished.outcome {
                case .success(.sent?): report.sent += 1
                case .success(.retry?): report.retried += 1
                case .success(.failed?): report.failed += 1
                case .success(nil): report.skipped += 1
                case .failure(let error):
                    app.logger.error("webhook worker: delivery step failed (\(type(of: error)))")
                    report.skipped += 1
                }
            }
        }
        report.purged = try await purge(now: now)
        return report
    }

    /// Closes the bundle (no event can join it any more), re-reads it, sends it once and records the result.
    /// Nil when the row vanished or is not pending any more.
    private func deliver(_ candidate: WebhookDelivery, with deliverer: WebhookDeliverer, now: Date) async throws -> WebhookDeliverer.Verdict? {
        let db = app.db
        let id = try candidate.requireID()
        let endpoint = try await WebhookEndpoint.query(on: db).filter(\.$userID == candidate.userID).first()
        if candidate.openMarker != nil {
            // Same lock as the trigger: after this transaction a concurrent event starts a new bundle instead of joining this one.
            try await db.transaction { tx in
                if let endpointID = endpoint?.id { try await lockRow(table: WebhookEndpoint.schema, id: endpointID, on: tx) }
                try await WebhookDelivery.query(on: tx).filter(\.$id == id).filter(\.$openMarker == WebhookDelivery.openValue)
                    .set(\.$openMarker, to: nil).update()
            }
        }
        guard let row = try await WebhookDelivery.find(id, on: db), row.state == "pending" else { return nil }
        guard let endpoint, endpoint.enabled else {
            let verdict = WebhookDeliverer.Verdict.failed(code: "webhook_disabled", status: nil)
            row.attempts += 1; row.state = "failed"; row.errorCode = "webhook_disabled"; row.finishedAt = now
            try await row.save(on: db)
            return verdict
        }
        let payload = row.event == "test" ? WebhookPayload.test : WebhookPayload.person(count: row.anzahl, mask: row.kindsMask)
        let verdict = await deliverer.attempt(endpoint: endpoint, payload: payload)
        try await deliverer.record(verdict, on: row, now: now)
        if case .failed(let code, _) = verdict { app.logger.error("webhook worker: bundle failed code=\(code)") }
        return verdict
    }

    /// The log is kept for 14 days.
    private func purge(now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-WebhookLimits.retention)
        let old = try await WebhookDelivery.query(on: app.db).filter(\.$createdAt < cutoff).count()
        if old > 0 { try await WebhookDelivery.query(on: app.db).filter(\.$createdAt < cutoff).delete() }
        return old
    }

    // MARK: Lease (same pattern as PushWorker and CleanupScheduler)

    private func databaseNow(_ sql: any SQLDatabase) async throws -> Int64 {
        let query = sql.dialect.name == "sqlite" ? "SELECT CAST(strftime('%s', 'now') AS INTEGER) AS t" : "SELECT UNIX_TIMESTAMP() AS t"
        guard let row = try await sql.raw(SQLQueryString(query)).first() else { throw Abort(.internalServerError) }
        return try row.decode(column: "t", as: Int64.self)
    }

    private func acquire(_ sql: any SQLDatabase) async throws -> Bool {
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

    /// False once another replica took the lease over; the run then stops before it touches another row.
    private func renew(_ sql: any SQLDatabase) async -> Bool {
        do {
            let until = try await databaseNow(sql) + Int64(leaseDuration)
            try await sql.raw("UPDATE maintenance_leases SET expires_at = \(bind: until) WHERE name = \(bind: Self.jobName) AND holder = \(bind: holder)").run()
            let row = try await sql.raw("SELECT holder FROM maintenance_leases WHERE name = \(bind: Self.jobName)").first()
            return try row?.decode(column: "holder", as: String.self) == holder
        } catch { return false }
    }

    private func finish(_ sql: any SQLDatabase, status: String, message: String) async throws {
        let now = try await databaseNow(sql)
        try await sql.raw("""
            UPDATE maintenance_leases SET holder = '', expires_at = 0, last_run_at = \(bind: now), last_status = \(bind: status),
            last_message = \(bind: message) WHERE name = \(bind: Self.jobName) AND holder = \(bind: holder)
            """).run()
    }
}

func configureWebhookWorker(_ app: Application) {
    app.lifecycle.use(WebhookWorker(app: app))
}
