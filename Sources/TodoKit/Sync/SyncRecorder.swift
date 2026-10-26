import Fluent
import SQLKit
import Vapor

/// Appends to the change log inside the caller's transaction. Writers hold the sharing-graph lock (taken first,
/// before any read, as everywhere else), which serialises sequence allocation across replicas; the lock is only
/// released at commit, so sequence order equals commit order and readers never see a gap fill in later.
enum SyncRecorder {
    static func nextSeq(on db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await lockSharingGraph(on: db)
        try await sql.raw("UPDATE sync_counter SET value = value + 1 WHERE id = \(bind: syncCounterID)").run()
        guard let row = try await sql.raw("SELECT value FROM sync_counter WHERE id = \(bind: syncCounterID)").first() else {
            throw Abort(.internalServerError, reason: "sync_counter_missing")
        }
        return try row.decode(column: "value", as: Int.self)
    }

    static func recordUpsert(type: String, id: UUID, projectID: UUID?, on db: any Database) async throws {
        let seq = try await nextSeq(on: db)
        try await SyncChange(seq: seq, entityType: type, entityID: id, kind: "upsert", projectID: projectID).save(on: db)
    }

    static func recordDelete(type: String, id: UUID, projectID: UUID?, audience: [UUID], on db: any Database) async throws {
        let seq = try await nextSeq(on: db)
        try await SyncChange(seq: seq, entityType: type, entityID: id, kind: "delete", projectID: projectID).save(on: db)
        for user in audience { try await SyncTombstoneAudience(seq: seq, userID: user).save(on: db) }
    }

    static func readers(of project: Project, on db: any Database) async throws -> [UUID] {
        var result: [UUID] = []
        for user in try await User.query(on: db).all() {
            if try await SharingAccess(user: user, db: db).visibility(project).role != nil { result.append(try user.requireID()) }
        }
        return result
    }

    /// True if the ID was ever deleted; client-chosen IDs may not resurrect a tombstoned entity.
    static func wasDeleted(_ id: UUID, on db: any Database) async throws -> Bool {
        try await SyncChange.query(on: db).filter(\.$entityID == id).filter(\.$kind == "delete").first() != nil
    }
}

/// Every save/delete of a project goes through here, whichever route or tool performs it.
struct SyncProjectMiddleware: AsyncModelMiddleware {
    func create(model: Project, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await SyncRecorder.recordUpsert(type: "project", id: model.requireID(), projectID: model.requireID(), on: db)
    }

    func update(model: Project, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db)
        try await SyncRecorder.recordUpsert(type: "project", id: model.requireID(), projectID: model.requireID(), on: db)
    }

    /// The database cascades to child projects and their tasks without firing model events, so tombstones for
    /// the whole subtree are written explicitly around the delete.
    func delete(model: Project, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        var queue = [model]
        var seen = Set<UUID>()
        var projects: [Project] = []
        while let current = queue.popLast() {
            guard seen.insert(try current.requireID()).inserted else { continue }
            projects.append(current)
            queue.append(contentsOf: try await Project.query(on: db).filter(\.$parentID == current.requireID()).all())
        }
        var plan: [(type: String, id: UUID, project: UUID, audience: [UUID])] = []
        for project in projects {
            let audience = try await SyncRecorder.readers(of: project, on: db)
            let pid = try project.requireID()
            for task in try await TodoTask.query(on: db).filter(\.$projectID == pid).all() {
                plan.append(("task", try task.requireID(), pid, audience))
            }
            plan.append(("project", pid, pid, audience))
        }
        try await next.delete(model, force: force, on: db)
        for item in plan {
            try await SyncRecorder.recordDelete(type: item.type, id: item.id, projectID: item.project, audience: item.audience, on: db)
        }
    }
}

struct SyncTaskMiddleware: AsyncModelMiddleware {
    func create(model: TodoTask, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await SyncRecorder.recordUpsert(type: "task", id: model.requireID(), projectID: model.projectID, on: db)
    }

    func update(model: TodoTask, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db)
        try await SyncRecorder.recordUpsert(type: "task", id: model.requireID(), projectID: model.projectID, on: db)
    }

    func delete(model: TodoTask, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        guard let project = try await Project.find(model.projectID, on: db) else {
            try await next.delete(model, force: force, on: db); return
        }
        let audience = try await SyncRecorder.readers(of: project, on: db)
        try await next.delete(model, force: force, on: db)
        try await SyncRecorder.recordDelete(type: "task", id: model.requireID(), projectID: model.projectID, audience: audience, on: db)
    }
}
