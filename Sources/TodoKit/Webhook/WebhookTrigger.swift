import Fluent
import SQLKit
import Vapor

/// What the trigger knows about who is acting. Some write paths shared by REST and MCP record their activity with the person as
/// actor (the MCP caller acts as the person who granted the connection); those must not wake the webhook, or the listener would
/// wake itself in a loop (ADR 0035, item 5). The guard is fail-closed: an event only counts when the request was authenticated
/// as a person session (`requireUser` sets `personKey` to the user id after it verified the session). A write path without the
/// mark (background job, new entry point) wakes nothing: the worst case is a missed wake-up, never a loop. The MCP endpoint
/// additionally sets `key`, which vetoes everything. Both marks live on the request logger, which every `req.db` and every
/// transaction handle derived from it carries (a task-local would be lost in Fluent's transaction closure, which runs on an
/// event loop callback). The values are a fixed word and the user id, no card data.
enum WebhookAgentContext {
    static let key = "todolino.agent_request"
    static let personKey = "todolino.person_session"
    static func mark(_ req: Request) { req.logger[metadataKey: key] = "mcp" }
    static func markPersonSession(_ req: Request, userID: UUID) { req.logger[metadataKey: personKey] = .string(userID.uuidString) }
    static func isMarked(_ db: any Database) -> Bool { db.logger[metadataKey: key] != nil }
    /// True when the handle belongs to a request that `requireUser` accepted for exactly this person.
    static func isPersonSession(_ db: any Database, userID: UUID) -> Bool { db.logger[metadataKey: personKey] == .string(userID.uuidString) }
}

/// ADR 0035: an `ActivityEvent` created by the webhook owner (actor type Person) with a whitelisted kind in a project that
/// is not excluded is added to the 60 second bundle of that person. Runs in the writer's transaction, so a rolled back
/// action leaves no trace. An error here is logged (type only) and never fails the request.
struct WebhookTriggerMiddleware: AsyncModelMiddleware {
    typealias Model = ActivityEvent

    func create(model: ActivityEvent, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        guard model.actorType == .person, WebhookAgentContext.isPersonSession(db, userID: model.actorID), !WebhookAgentContext.isMarked(db), let mask = WebhookKinds.mask(model.kind),
              // Follow-up cards created by the system (recurrence) carry the source card as subject; nobody acted on them.
              !(model.kind == "task.created" && model.subjectID != nil)
        else { return }
        do { try await WebhookBundler.record(userID: model.actorID, taskID: model.taskID, mask: mask, on: db) }
        catch { db.logger.warning("webhook: could not buffer an event (\(type(of: error)))") }
    }
}

enum WebhookBundler {
    /// Adds one event to the open bundle of the person (creating it when none is open). Cheap exits come first: persons without
    /// an enabled webhook cost one indexed read.
    static func record(userID: UUID, taskID: UUID, mask: Int, now: Date = Date(), on db: any Database) async throws {
        guard let endpoint = try await WebhookEndpoint.query(on: db).filter(\.$userID == userID).first(), endpoint.enabled,
              db is any SQLDatabase else { return }
        guard let task = try await TodoTask.find(taskID, on: db) else { return }
        if try await WebhookExclusion.query(on: db).filter(\.$userID == userID).filter(\.$projectID == task.projectID).count() > 0 { return }
        try await bundle(userID: userID, mask: mask, now: now, on: db)
    }

    /// Atomic across replicas without locking the webhook row: the merge is one upsert on the unique key (user_id, open_marker),
    /// `INSERT ... ON DUPLICATE KEY UPDATE` (MariaDB) or `ON CONFLICT DO UPDATE` (SQLite). It either creates the open bundle or adds
    /// to it (`anzahl + 1`, `kinds_mask | m`) in one statement: no read-then-write window and never a second open row. Only the
    /// open bundle row is locked, and only until the surrounding transaction ends; the webhook row is not touched, so a person's
    /// requests do not queue up on it or deadlock over it (the former `FOR UPDATE` on `webhook_endpoints` lived as long as the
    /// request transaction). A bundle past its due time no longer takes events: it is closed first, by primary key, after a plain
    /// read; an `UPDATE` that matches nothing would take gap locks on MariaDB, and two writers doing that and then inserting deadlock.
    static func bundle(userID: UUID, mask: Int, now: Date, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        let open = WebhookDelivery.openValue
        if let overdue = try await sql.raw("SELECT id FROM webhook_deliveries WHERE user_id = \(bind: userID) AND open_marker = \(bind: open) AND due_at <= \(bind: now)").first() {
            let id = try overdue.decode(column: "id", as: UUID.self)
            try await sql.raw("UPDATE webhook_deliveries SET open_marker = NULL WHERE id = \(bind: id) AND open_marker = \(bind: open)").run()
        }
        let due = now.addingTimeInterval(WebhookLimits.bundleWindow)
        let merge = sql.dialect.name == "sqlite"
            ? "ON CONFLICT (user_id, open_marker) DO UPDATE SET anzahl = anzahl + 1, kinds_mask = kinds_mask | \(mask)"
            : "ON DUPLICATE KEY UPDATE anzahl = anzahl + 1, kinds_mask = kinds_mask | \(mask)"
        try await sql.raw("""
            INSERT INTO webhook_deliveries (id, user_id, state, event, anzahl, kinds_mask, attempts, next_attempt_at, due_at, open_marker, created_at)
            VALUES (\(bind: UUID()), \(bind: userID), 'pending', 'person_action', 1, \(bind: mask), 0, \(bind: due), \(bind: due), \(bind: open), \(bind: now))
            \(unsafeRaw: merge)
            """).run()
    }
}
