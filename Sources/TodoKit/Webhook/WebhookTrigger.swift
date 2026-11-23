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
              let endpointID = endpoint.id, db is any SQLDatabase else { return }
        guard let task = try await TodoTask.find(taskID, on: db) else { return }
        if try await WebhookExclusion.query(on: db).filter(\.$userID == userID).filter(\.$projectID == task.projectID).count() > 0 { return }
        try await bundle(userID: userID, endpointID: endpointID, mask: mask, now: now, on: db)
    }

    /// Atomic across replicas. The webhook row is locked first (MariaDB: `FOR UPDATE`; SQLite serialises writers), so bundling
    /// of one person is sequential; inside, the merge is a single `UPDATE anzahl = anzahl + 1, kinds_mask = kinds_mask | m`.
    /// The unique key (user_id, open_marker) rejects a second open row; the loser retries and merges.
    static func bundle(userID: UUID, endpointID: UUID, mask: Int, now: Date, on db: any Database) async throws {
        try await db.transaction { tx in
            guard let sql = tx as? any SQLDatabase else { return }
            try await lockRow(table: WebhookEndpoint.schema, id: endpointID, on: tx)
            // A bundle past its due time no longer takes events (the worker may not have picked it up yet).
            try await WebhookDelivery.query(on: tx).filter(\.$userID == userID).filter(\.$openMarker == WebhookDelivery.openValue)
                .filter(\.$dueAt <= now).set(\.$openMarker, to: nil).update()
            var lastError: (any Error)?
            for _ in 0..<4 {
                // Locking read on MariaDB: it must see the latest committed row, not the snapshot of the surrounding transaction.
                let suffix = sql.dialect.name == "sqlite" ? "" : " FOR UPDATE"
                let open = try await sql.raw("SELECT id FROM webhook_deliveries WHERE user_id = \(bind: userID) AND open_marker = \(bind: WebhookDelivery.openValue)\(unsafeRaw: suffix)").first()
                if let open {
                    let id = try open.decode(column: "id", as: UUID.self)
                    try await sql.raw("UPDATE webhook_deliveries SET anzahl = anzahl + 1, kinds_mask = kinds_mask | \(bind: mask) WHERE id = \(bind: id) AND open_marker = \(bind: WebhookDelivery.openValue)").run()
                    return
                }
                do {
                    try await WebhookDelivery(userID: userID, event: "person_action", anzahl: 1, kindsMask: mask,
                                              due: now.addingTimeInterval(WebhookLimits.bundleWindow), open: true, now: now).create(on: tx)
                    return
                } catch { lastError = error }  // lost the race for the open slot: merge into the winner's row
            }
            if let lastError { throw lastError }
        }
    }
}
