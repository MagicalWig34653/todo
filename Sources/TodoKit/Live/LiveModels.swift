import Fluent
import SQLKit
import Vapor

/// Live refresh (ADR 0022). Writes that are not part of the sync change log (comments, questions, reviews,
/// progress, attachments, agent jobs, ...) append a row to `live_events` inside the writer's transaction.
/// Insert-only on purpose: no hot row, so no new lock ordering against the sharing-graph lock (a counter row
/// updated by writers that hold task row locks could deadlock with sync writers). The table is a hint log only;
/// it carries no entity data and is trimmed to the newest rows.
struct CreateLiveEvents: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("live_events")
            .field("id", .int64, .identifier(auto: true))
            .field("kind", .string, .required)
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema("live_events").delete() }
}

func configureLive(_ app: Application) {
    app.migrations.add(CreateLiveEvents())
}

/// Appends a hint row after any save/delete of `M`, in the caller's transaction (db is the transaction handle).
struct LiveEventMiddleware<M: Fluent.Model>: AsyncModelMiddleware {
    typealias Model = M
    func create(model: M, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db); try await LiveToken.touch(M.schema, on: db)
    }
    func update(model: M, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db); try await LiveToken.touch(M.schema, on: db)
    }
    func delete(model: M, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.delete(model, force: force, on: db); try await LiveToken.touch(M.schema, on: db)
    }
}

func registerLiveMiddleware(_ app: Application) {
    func use<M: Fluent.Model>(_ type: M.Type) { app.databases.middleware.use(LiveEventMiddleware<M>()) }
    use(TaskComment.self); use(ActivityEvent.self); use(AcceptanceCriterion.self)
    use(TaskWorkflow.self); use(TaskQuestion.self); use(TaskReview.self); use(TaskProgressNote.self)
    use(BuildArtifact.self); use(ProjectAgentBrief.self); use(Attachment.self)
    use(AgentJob.self); use(AgentQuestion.self); use(AgentAnswer.self)
    use(ProjectComment.self); use(ProjectActivityEvent.self); use(ProjectUserState.self)
    use(PlanningDependency.self); use(PlanningMilestone.self); use(PlanningMilestoneTask.self)
    use(UserPreferences.self)
}

enum LiveToken {
    /// Window (in ids) over which rows are counted. A transaction that commits late with a lower id than an
    /// already visible row still changes the count, so the token changes (no gap blindness).
    static let window = 500
    static let keep = 5000

    static func touch(_ kind: String, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("INSERT INTO live_events (kind) VALUES (\(bind: kind))").run()
    }

    struct Snapshot: Equatable, Sendable {
        let token: String
        let cursor: String
    }

    /// Three indexed single-row/range reads; no joins, plain SQL for SQLite and MariaDB.
    static func current(on db: any Database) async throws -> Snapshot {
        guard let sql = db as? any SQLDatabase,
              let head = try await sql.raw("SELECT value FROM sync_counter WHERE id = \(bind: syncCounterID)").first()
        else { throw Abort(.internalServerError) }
        let seq = try head.decode(column: "value", as: Int.self)
        let maxRow = try await sql.raw("SELECT COALESCE(MAX(id), 0) AS m FROM live_events").first()
        let m = try maxRow?.decode(column: "m", as: Int.self) ?? 0
        let low = max(0, m - window)
        let countRow = try await sql.raw("SELECT COUNT(*) AS c FROM live_events WHERE id > \(bind: low)").first()
        let c = try countRow?.decode(column: "c", as: Int.self) ?? 0
        return Snapshot(token: "l\(seq).\(m).\(c)", cursor: SyncController.cursor(seq))
    }

    static func trim(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        let maxRow = try await sql.raw("SELECT COALESCE(MAX(id), 0) AS m FROM live_events").first()
        let m = try maxRow?.decode(column: "m", as: Int.self) ?? 0
        if m > keep { try await sql.raw("DELETE FROM live_events WHERE id <= \(bind: m - keep)").run() }
    }
}
