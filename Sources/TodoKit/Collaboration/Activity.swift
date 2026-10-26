import Fluent
import SQLKit
import Vapor

/// Records an event as part of the caller's authorized operation. Actor identity must come from
/// trusted server context, never a client-provided actor. Pass the operation's transaction database
/// to commit the business change and event together. All writers serialize on the task row.
public func recordActivity(
    taskID: UUID, authorizedUserID: UUID, actorType: ActivityActorType, actorID: UUID,
    kind: String, subjectID: UUID? = nil, on db: any Database
) async throws {
    guard !kind.isEmpty, kind.count <= 100 else { throw Abort(.badRequest, reason: "invalid_activity_kind") }
    try await db.transaction { db in
        try await lockRow(table: TodoTask.schema, id: taskID, on: db)
        guard let user = try await User.find(authorizedUserID, on: db) else { throw Abort(.notFound) }
        _ = try await ProjectAccess(user: user, db: db).task(taskID)
        try await appendActivity(taskID: taskID, actorType: actorType, actorID: actorID, kind: kind, subjectID: subjectID, on: db)
    }
}

/// Caller must hold the task row lock inside a transaction and have checked ProjectAccess.
func appendActivity(taskID: UUID, actorType: ActivityActorType, actorID: UUID, kind: String, subjectID: UUID?, on db: any Database) async throws {
    let lastSequence: Int
    if let sql = db as? any SQLDatabase, sql.dialect.name != "sqlite" {
        // A locking read sees the latest committed sequence even if an enclosing transaction
        // already established a repeatable-read snapshot before calling recordActivity.
        lastSequence = try await sql.raw("SELECT \(ident: "sequence") FROM \(ident: ActivityEvent.schema) WHERE \(ident: "task_id") = \(bind: taskID) ORDER BY \(ident: "sequence") DESC LIMIT 1 FOR UPDATE")
            .first(decodingColumn: "sequence", as: Int.self) ?? 0
    } else {
        lastSequence = try await ActivityEvent.query(on: db).filter(\.$taskID == taskID)
            .sort(\.$sequence, .descending).first()?.sequence ?? 0
    }
    let event = ActivityEvent()
    event.taskID = taskID; event.sequence = lastSequence + 1
    event.actorType = actorType; event.actorID = actorID; event.kind = kind; event.subjectID = subjectID
    try await event.save(on: db)
}
