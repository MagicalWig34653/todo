import Fluent
import SQLKit
import Vapor

/// Background worker of the push outbox. Every replica runs one; a lease row in `maintenance_leases` (same table
/// and take-over rules as the cleanup scheduler, ADR 0019) lets exactly one of them work per interval. Per run:
/// 1. find new triggers (due reminders, open questions, pending reviews, comments) and enqueue them, deduplicated
///    by `(user_id, dedupe_key)`;
/// 2. send due outbox rows with retry/backoff;
/// 3. purge old finished rows.
/// Nothing here runs in the request path.
final class PushWorker: LifecycleHandler, @unchecked Sendable {
    static let jobName = "push-worker"

    struct Report: Equatable, Sendable {
        var enqueued = 0, sent = 0, skipped = 0, failed = 0, retried = 0, revokedDevices = 0, purged = 0
    }
    enum Outcome: Equatable, Sendable {
        case skipped
        case ran(Report)
        case failed(String)
    }

    let app: Application
    let sender: APNsSender
    /// Minimum seconds between two runs across all replicas.
    let interval: TimeInterval
    let leaseDuration: TimeInterval
    /// Triggers older than this are not announced any more (limits the burst after downtime or first activation).
    let lookback: TimeInterval
    let holder = UUID().uuidString
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(app: Application, sender: APNsSender, interval: TimeInterval = 15, leaseDuration: TimeInterval = 120,
         lookback: TimeInterval = 6 * 3600) {
        self.app = app; self.sender = sender; self.interval = interval; self.leaseDuration = leaseDuration; self.lookback = lookback
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
        let delay = initialDelay ?? Double.random(in: 5...15)
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
            app.logger.warning("push worker: lease check failed")
            return .failed("lease")
        }
        do {
            let report = try await tick()
            try await finish(sql, status: "ok", message: "enqueued \(report.enqueued), sent \(report.sent)")
            return .ran(report)
        } catch {
            // Error text of database/transport layers may contain identifiers; log only the type.
            app.logger.error("push worker: run failed (\(type(of: error)))")
            try? await finish(sql, status: "error", message: String(describing: type(of: error)))
            return .failed(String(describing: type(of: error)))
        }
    }

    func tick(now: Date = Date()) async throws -> Report {
        var report = Report()
        let db = app.db
        let candidates = try await Candidate.load(on: db)
        if !candidates.isEmpty {
            report.enqueued += try await PushTriggers(db: db, candidates: candidates, since: now.addingTimeInterval(-lookback), now: now).run()
        }
        let delivery = PushDelivery(db: db, sender: sender)
        let due = try await PushOutbox.query(on: db).filter(\.$state == "pending").filter(\.$nextAttemptAt <= now)
            .sort(\.$dueAt).sort(\.$id).limit(50).all()
        for row in due {
            let result: PushDelivery.Result
            do { result = try await delivery.deliver(row) } catch {
                result = .init(state: row.attempts + 1 < PushDelivery.maxAttempts ? "pending" : "failed", error: "internal_error",
                               retryAfter: PushDelivery.backoff(attempt: row.attempts + 1))
            }
            row.attempts += 1; row.state = result.state; row.lastError = result.error
            if let after = result.retryAfter { row.nextAttemptAt = now.addingTimeInterval(after * Double.random(in: 0.9...1.1)) }
            try await row.save(on: db)
            report.revokedDevices += result.revoked
            switch result.state {
            case "sent": report.sent += 1
            case "pending": report.retried += 1
            case "failed":
                report.failed += 1
                app.logger.error("push worker: delivery failed category=\(row.category) reason=\(result.error ?? "unknown")")
            default: report.skipped += 1
            }
        }
        report.purged = try await purge(now: now)
        return report
    }

    /// Finished rows are kept for three days (they carry the dedupe keys), revoked devices for 30 days.
    private func purge(now: Date) async throws -> Int {
        let db = app.db
        let old = try await PushOutbox.query(on: db).filter(\.$state != "pending").filter(\.$createdAt < now.addingTimeInterval(-3 * 86_400)).count()
        if old > 0 {
            try await PushOutbox.query(on: db).filter(\.$state != "pending").filter(\.$createdAt < now.addingTimeInterval(-3 * 86_400)).delete()
        }
        try await PushDevice.query(on: db).filter(\.$revokedAt < now.addingTimeInterval(-30 * 86_400)).delete()
        return old
    }

    // MARK: Lease (same pattern as CleanupScheduler)

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

/// An account that has at least one active device, with its settings.
struct Candidate: Sendable {
    let user: User
    let prefs: PushPrefsDTO
    var id: UUID { user.id! }

    static func load(on db: any Database) async throws -> [Candidate] {
        let ids = Set(try await PushDevice.query(on: db).filter(\.$revokedAt == nil).all(\.$userID))
        guard !ids.isEmpty else { return [] }
        var result: [Candidate] = []
        for user in try await User.query(on: db).filter(\.$id ~~ Array(ids)).all() {
            result.append(Candidate(user: user, prefs: try await PushService.prefs(of: user.requireID(), on: db)))
        }
        return result
    }
}

/// Finds trigger events and writes outbox rows. Rights are checked per recipient; the same check is repeated when sending.
struct PushTriggers: Sendable {
    let db: any Database
    let candidates: [Candidate]
    let since: Date
    let now: Date

    func enabled(_ category: PushCategory) -> [Candidate] { candidates.filter { $0.prefs.categories[category.rawValue] == true } }

    func canRead(_ user: User, _ taskID: UUID, role: ProjectRole) async -> TodoTask? {
        try? await ProjectAccess(user: user, db: db).task(taskID, role: role)
    }

    /// Inserts the row unless the dedupe key exists for this account; returns whether it was new.
    func enqueue(_ userID: UUID, _ category: PushCategory, _ event: PushEvent, key: String) async throws -> Bool {
        if try await PushOutbox.query(on: db).filter(\.$userID == userID).filter(\.$dedupeKey == key).count() > 0 { return false }
        let row = PushOutbox()
        row.userID = userID; row.category = category.rawValue; row.dedupeKey = key
        row.payload = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        row.dueAt = now; row.state = "pending"; row.attempts = 0; row.nextAttemptAt = now
        do { try await row.save(on: db) } catch {
            // Lost a race with another writer on the unique key: that counts as already enqueued.
            if try await PushOutbox.query(on: db).filter(\.$userID == userID).filter(\.$dedupeKey == key).count() > 0 { return false }
            throw error
        }
        return true
    }

    func run() async throws -> Int {
        try await reminders() + questions() + reviews() + comments()
    }

    private func reminders() async throws -> Int {
        let who = enabled(.reminders)
        guard !who.isEmpty, let sql = db as? any SQLDatabase else { return 0 }
        let ids = try await sql.raw("""
            SELECT p.id AS id FROM task_planning p JOIN tasks t ON t.id = p.id
            WHERE t.status <> 'done' AND p.reminders IS NOT NULL AND p.reminders <> '[]' LIMIT 5000
            """).all().map { try $0.decode(column: "id", as: UUID.self) }
        var count = 0
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            for planning in try await TaskPlanning.query(on: db).filter(\.$id ~~ chunk).all() {
                let due = planning.reminders.filter { $0 <= now && $0 > since }
                guard !due.isEmpty, let taskID = planning.id, let task = try await TodoTask.find(taskID, on: db),
                      let owner = who.first(where: { $0.id == task.ownerID }),
                      await canRead(owner.user, taskID, role: .read) != nil else { continue }
                for at in due {
                    let secs = Int(at.timeIntervalSince1970.rounded(.down))
                    let event = PushEvent(kind: "reminder", taskID: taskID, projectID: task.projectID, subjectID: nil, at: secs)
                    if try await enqueue(owner.id, .reminders, event, key: "reminder:\(taskID):\(secs)") { count += 1 }
                }
            }
        }
        return count
    }

    private func questions() async throws -> Int {
        let who = enabled(.agentQuestions)
        guard !who.isEmpty else { return 0 }
        var count = 0
        for q in try await TaskQuestion.query(on: db).filter(\.$state == "open").filter(\.$createdAt >= since).limit(200).all() {
            guard let qid = q.id, let task = try await TodoTask.find(q.taskID, on: db), let taskID = task.id else { continue }
            for c in who where !(q.askedByType == .person && q.askedByID == c.id) {
                guard await canRead(c.user, taskID, role: .comment) != nil else { continue }
                let event = PushEvent(kind: "question", taskID: taskID, projectID: task.projectID, subjectID: qid, at: nil)
                if try await enqueue(c.id, .agentQuestions, event, key: "question:\(qid)") { count += 1 }
            }
        }
        return count
    }

    private func reviews() async throws -> Int {
        let who = enabled(.agentReviews)
        guard !who.isEmpty else { return 0 }
        var count = 0
        for r in try await TaskReview.query(on: db).filter(\.$state == "pending").filter(\.$createdAt >= since).limit(200).all() {
            guard let rid = r.id, let task = try await TodoTask.find(r.taskID, on: db), let taskID = task.id else { continue }
            // A named reviewer is the only recipient; otherwise everybody who may decide (edit rights).
            for c in who where r.reviewerID == nil || r.reviewerID == c.id {
                if r.requestedByType == .person && r.requestedByID == c.id { continue }
                guard await canRead(c.user, taskID, role: .edit) != nil else { continue }
                let event = PushEvent(kind: "review", taskID: taskID, projectID: task.projectID, subjectID: rid, at: nil)
                if try await enqueue(c.id, .agentReviews, event, key: "review:\(rid)") { count += 1 }
            }
        }
        return count
    }

    /// New comments reach the task owner and everybody who commented on the task before; never the author.
    private func comments() async throws -> Int {
        let who = enabled(.comments)
        guard !who.isEmpty else { return 0 }
        var count = 0
        let recent = try await ActivityEvent.query(on: db).filter(\.$kind == "comment.created").filter(\.$createdAt >= max(since, now.addingTimeInterval(-3600)))
            .limit(100).all()
        for e in recent {
            guard let commentID = e.subjectID, let task = try await TodoTask.find(e.taskID, on: db), let taskID = task.id else { continue }
            var participants: Set<UUID> = [task.ownerID]
            for prior in try await ActivityEvent.query(on: db).filter(\.$taskID == taskID).filter(\.$kind == "comment.created")
                .filter(\.$actorType == .person).all() { participants.insert(prior.actorID) }
            for c in who where participants.contains(c.id) && !(e.actorType == .person && e.actorID == c.id) {
                guard await canRead(c.user, taskID, role: .read) != nil else { continue }
                let event = PushEvent(kind: "comment", taskID: taskID, projectID: task.projectID, subjectID: commentID, at: nil)
                if try await enqueue(c.id, .comments, event, key: "comment:\(commentID)") { count += 1 }
            }
        }
        return count
    }
}

// MARK: - Wiring and admin command

func configurePushWorker(_ app: Application) throws {
    let cfg = app.settings.apns
    guard cfg.enabled else {
        app.logger.info("push disabled (APNS_ENABLED is not true)")
        return
    }
    let sender = try APNsSender(config: cfg, transport: VaporAPNsTransport(client: app.client))
    app.apnsSender = sender
    app.lifecycle.use(PushWorker(app: app, sender: sender))
    app.logger.info("push enabled (APNs \(cfg.environment.rawValue) default, topics \(cfg.topics.joined(separator: ",")))")
}

struct PushTestCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "account-id") var accountID: String
        @Flag(name: "yes", help: "Confirm that a test notification is sent to the devices of this account.")
        var yes: Bool
    }
    let help = "Send a generic test notification to all active devices of an account (needs APNS_ENABLED=true)."
    func run(using context: CommandContext, signature: Signature) async throws {
        guard let id = UUID(uuidString: signature.accountID) else { throw Abort(.badRequest, reason: "invalid_account_id") }
        guard signature.yes else { throw Abort(.badRequest, reason: "confirmation_required: pass --yes") }
        let app = context.application
        guard let sender = app.apnsSender else { throw Abort(.badRequest, reason: "push_disabled: set APNS_ENABLED=true and the APNS_* variables") }
        let devices = try await PushDevice.query(on: app.db).filter(\.$userID == id).filter(\.$revokedAt == nil).sort(\.$id).all()
        guard !devices.isEmpty else { throw Abort(.notFound, reason: "no_active_devices: the account has not registered a device") }
        for d in devices {
            let message = PushContent.testMessage(locale: d.locale)
            let outcome = await sender.send(to: d, payload: try message.payload(), priority: message.priority, ttl: message.ttl, collapseKey: nil)
            if case .revoke = outcome { d.revokedAt = Date(); try await d.save(on: app.db) }
            context.console.print("device \(d.id!) (\(d.platform), \(d.environment), \(d.bundleID)): \(outcome)")
        }
    }
}
