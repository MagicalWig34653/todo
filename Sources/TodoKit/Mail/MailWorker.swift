import Fluent
import SQLKit
import Vapor

/// Background worker of the mail outbox. Every replica runs one; a lease row in `maintenance_leases` (same table
/// and take-over rules as the push worker and the cleanup scheduler, ADR 0019/0021) lets exactly one of them work
/// per interval. Delivery is at-least-once: a crash between the SMTP acceptance and the status update repeats the
/// mail. Nothing here runs in the request path.
final class MailWorker: LifecycleHandler, @unchecked Sendable {
    static let jobName = "mail-worker"

    struct Report: Equatable, Sendable {
        var sent = 0, skipped = 0, failed = 0, retried = 0, expired = 0, purged = 0
    }
    enum Outcome: Equatable, Sendable {
        case skipped
        case ran(Report)
        case failed(String)
    }

    let app: Application
    let interval: TimeInterval
    let leaseDuration: TimeInterval
    let holder = UUID().uuidString
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(app: Application, interval: TimeInterval = 10, leaseDuration: TimeInterval = 120) {
        self.app = app; self.interval = interval; self.leaseDuration = leaseDuration
    }

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
        let delay = initialDelay ?? Double.random(in: 3...10)
        let period = max(1, interval / 2)
        task = Task.detached { [self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                _ = await runIfDue()
                try? await Task.sleep(nanoseconds: UInt64(period * Double.random(in: 0.9...1.1) * 1_000_000_000))
            }
        }
    }

    func runIfDue() async -> Outcome {
        // Mail may be switched on and off at runtime; while it is off the outbox stays untouched.
        guard app.settings.mail.enabled, let sql = app.db as? any SQLDatabase else { return .skipped }
        do { guard try await acquire(sql) else { return .skipped } }
        catch {
            app.logger.warning("mail worker: lease check failed")
            return .failed("lease")
        }
        do {
            let report = try await tick()
            try await finish(sql, status: "ok", message: "sent \(report.sent), retried \(report.retried), failed \(report.failed)")
            return .ran(report)
        } catch {
            app.logger.error("mail worker: run failed (\(type(of: error)))")
            try? await finish(sql, status: "error", message: String(describing: type(of: error)))
            return .failed(String(describing: type(of: error)))
        }
    }

    // MARK: One run

    func tick(now: Date = Date()) async throws -> Report {
        var report = Report()
        let db = app.db
        let due = try await MailOutbox.query(on: db).filter(\.$state == "pending").filter(\.$nextAttemptAt <= now)
            .sort(\.$nextAttemptAt).sort(\.$id).limit(20).all()
        for row in due {
            var next: (state: String, error: String?, retryAfter: TimeInterval?)
            if row.expiresAt <= now {
                next = ("expired", "expired", nil)
            } else {
                do { next = try await deliver(row) } catch let e as MailSendError {
                    if e.isPermanent || row.attempts + 1 >= MailService.maxAttempts {
                        next = ("failed", e.description, nil)
                    } else {
                        next = ("pending", e.description, MailService.backoff(attempt: row.attempts + 1))
                    }
                } catch {
                    next = row.attempts + 1 >= MailService.maxAttempts ? ("failed", "internal_error", nil)
                        : ("pending", "internal_error", MailService.backoff(attempt: row.attempts + 1))
                }
            }
            row.attempts += 1; row.state = next.state; row.lastError = next.error
            if let after = next.retryAfter { row.nextAttemptAt = now.addingTimeInterval(after * Double.random(in: 0.9...1.1)) }
            if next.state != "pending" {
                // Secrets (recovery code, confirmation token) must not outlive the delivery.
                row.payload = "{}"
                if next.state == "sent" { row.sentAt = now }
            }
            try await row.save(on: db)
            switch next.state {
            case "sent": report.sent += 1
            case "pending": report.retried += 1
            case "failed":
                report.failed += 1
                app.logger.error("mail worker: delivery failed kind=\(row.kind) reason=\(next.error ?? "unknown")")
            case "expired": report.expired += 1
            default: report.skipped += 1
            }
        }
        report.purged = try await purge(now: now)
        return report
    }

    /// Returns the final state of a row, or throws `MailSendError` for a failed attempt.
    private func deliver(_ row: MailOutbox) async throws -> (state: String, error: String?, retryAfter: TimeInterval?) {
        guard app.settings.mail.enabled, let transport = app.mailTransport else { return ("skipped", "mail_disabled", nil) }
        let db = app.db
        guard let data = row.payload.data(using: .utf8), let payload = try? JSONDecoder().decode(MailPayload.self, from: data),
              let userID = row.userID else { return ("failed", "invalid_payload", nil) }
        let origin = app.settings.relyingPartyOrigin.hasSuffix("/") ? String(app.settings.relyingPartyOrigin.dropLast()) : app.settings.relyingPartyOrigin
        let until = Date(timeIntervalSince1970: TimeInterval(payload.until ?? Int(row.expiresAt.timeIntervalSince1970)))
        let mail: RenderedMail
        switch row.kind {
        case MailKind.verifyEmail:
            // Superseded by a newer request, already confirmed or withdrawn: do not send an obsolete link.
            guard let token = payload.token,
                  try await EmailVerification.query(on: db).filter(\.$userID == userID).filter(\.$tokenHash == AuthSupport.hash(token))
                    .filter(\.$email == row.recipient).count() > 0 else { return ("skipped", "superseded", nil) }
            mail = MailTemplates.verifyEmail(link: "\(origin)/confirm-email#token=\(token)", expiresAt: until)
        case MailKind.recoveryCode:
            guard let code = payload.code else { return ("failed", "invalid_payload", nil) }
            guard try await UserEmail.query(on: db).filter(\.$userID == userID).filter(\.$email == row.recipient).count() > 0,
                  try await RecoveryGrant.query(on: db).filter(\.$userID == userID).filter(\.$codeHash == AuthSupport.hash(code)).filter(\.$sessionHash == nil).count() > 0
            else { return ("skipped", "no_longer_relevant", nil) }
            mail = MailTemplates.recoveryCode(link: "\(origin)/recover#code=\(code)", code: code, expiresAt: until)
        case MailKind.test:
            guard try await UserEmail.query(on: db).filter(\.$userID == userID).filter(\.$email == row.recipient).count() > 0 else {
                return ("skipped", "address_changed", nil)
            }
            mail = MailTemplates.test()
        default:
            return ("failed", "unknown_kind", nil)
        }
        try await transport.send(MailMessage(to: row.recipient, subject: mail.subject, text: mail.text, html: mail.html))
        return ("sent", nil, nil)
    }

    /// Finished rows are kept for three days (they carry the dedupe keys); stale confirmations are removed.
    private func purge(now: Date) async throws -> Int {
        let db = app.db
        let cutoff = now.addingTimeInterval(-3 * 86_400)
        let old = try await MailOutbox.query(on: db).filter(\.$state != "pending").filter(\.$createdAt < cutoff).count()
        if old > 0 { try await MailOutbox.query(on: db).filter(\.$state != "pending").filter(\.$createdAt < cutoff).delete() }
        try await EmailVerification.query(on: db).filter(\.$expiresAt < cutoff).delete()
        return old
    }

    // MARK: Lease (same pattern as PushWorker / CleanupScheduler)

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

    private func finish(_ sql: any SQLDatabase, status: String, message: String) async throws {
        let now = try await databaseNow(sql)
        try await sql.raw("""
            UPDATE maintenance_leases SET holder = '', expires_at = 0, last_run_at = \(bind: now), last_status = \(bind: status),
            last_message = \(bind: message) WHERE name = \(bind: Self.jobName) AND holder = \(bind: holder)
            """).run()
    }
}

// MARK: - Wiring

func configureMailWorker(_ app: Application) throws {
    let cfg = app.settings.mail
    // The worker always exists: mail can be enabled later in the PWA and then needs no restart.
    if cfg.enabled {
        try app.reconfigureMail()
        app.logger.info("mail enabled (SMTP \(cfg.host):\(cfg.port) \(cfg.security.rawValue), from \(cfg.from))")
    } else {
        app.logger.info("mail disabled (enable it in the PWA settings or with MAIL_ENABLED=true)")
    }
    app.lifecycle.use(MailWorker(app: app))
}
