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

    static func recordDelete(type: String, id: UUID, projectID: UUID?, audience: [UUID], kind: String = "delete", on db: any Database) async throws {
        let seq = try await nextSeq(on: db)
        try await SyncChange(seq: seq, entityType: type, entityID: id, kind: kind, projectID: projectID).save(on: db)
        for user in audience { try await SyncTombstoneAudience(seq: seq, userID: user).save(on: db) }
    }

    static func readers(of project: Project, on db: any Database) async throws -> [UUID] {
        var result: [UUID] = []
        for user in try await User.query(on: db).all() {
            if try await SharingAccess(user: user, db: db).visibility(project).role != nil { result.append(try user.requireID()) }
        }
        return result
    }

    struct VisibilitySnapshot {
        let readers: [UUID: Set<UUID>]
        let parents: [UUID: UUID]
    }

    /// Transaction-local comparison only; all authoritative rights and emitted events live in the database.
    /// Callers already hold lockSharingGraph before their first read and keep it until commit.
    static func visibility(on db: any Database) async throws -> VisibilitySnapshot {
        var readers: [UUID: Set<UUID>] = [:]
        var parents: [UUID: UUID] = [:]
        for project in try await Project.query(on: db).all() {
            let id = try project.requireID()
            readers[id] = Set(try await self.readers(of: project, on: db))
            parents[id] = project.parentID
        }
        return VisibilitySnapshot(readers: readers, parents: parents)
    }

    static func recordVisibilityChanges(from before: VisibilitySnapshot, on db: any Database) async throws {
        let after = try await visibility(on: db)
        for id in after.readers.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let old = before.readers[id] ?? [], new = after.readers[id] ?? []
            let lost = old.subtracting(new)
            let gained = new.subtracting(old)
            // A still-readable isolated child also needs a refresh when its redacted parent reference changes.
            let parentChanged = old.intersection(new).contains { user in
                let oldParent = before.parents[id].flatMap { before.readers[$0]?.contains(user) == true ? $0 : nil }
                let newParent = after.parents[id].flatMap { after.readers[$0]?.contains(user) == true ? $0 : nil }
                return oldParent != newParent
            }
            if !gained.isEmpty || parentChanged {
                try await recordUpsert(type: "project", id: id, projectID: id, on: db)
            }
            if !lost.isEmpty {
                try await recordDelete(type: "project", id: id, projectID: id, audience: Array(lost), kind: "revoke", on: db)
            }
            guard !gained.isEmpty || !lost.isEmpty else { continue }
            for column in try await ProjectColumn.query(on: db).filter(\.$projectID == id).sort(\.$id).all() {
                if !gained.isEmpty { try await recordUpsert(type: "column", id: column.requireID(), projectID: id, on: db) }
                if !lost.isEmpty {
                    try await recordDelete(type: "column", id: column.requireID(), projectID: id, audience: Array(lost), kind: "revoke", on: db)
                }
            }
            for task in try await TodoTask.query(on: db).filter(\.$projectID == id).sort(\.$id).all() {
                if !gained.isEmpty {
                    try await recordUpsert(type: "task", id: task.requireID(), projectID: id, on: db)
                }
                if !lost.isEmpty {
                    try await recordDelete(type: "task", id: task.requireID(), projectID: id,
                        audience: Array(lost), kind: "revoke", on: db)
                }
            }
        }
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
        let stored = try await Project.find(model.requireID(), on: db)
        let before = stored?.parentID != model.parentID ? try await SyncRecorder.visibility(on: db) : nil
        try await next.update(model, on: db)
        if let before { try await SyncRecorder.recordVisibilityChanges(from: before, on: db) }
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
            for column in try await ProjectColumn.query(on: db).filter(\.$projectID == pid).all() {
                plan.append(("column", try column.requireID(), pid, audience))
            }
            for task in try await TodoTask.query(on: db).filter(\.$projectID == pid).all() {
                plan.append(("task", try task.requireID(), pid, audience))
            }
            plan.append(("project", pid, pid, audience))
        }
        let taskIDs = plan.filter { $0.type == "task" }.map(\.id)
        let labelIDs = taskIDs.isEmpty ? [] : Set(try await DiscoveryTaskLabel.query(on: db).filter(\.$taskID ~~ taskIDs).all().map(\.labelID))
        try await next.delete(model, force: force, on: db)
        for item in plan {
            try await SyncRecorder.recordDelete(type: item.type, id: item.id, projectID: item.project, audience: item.audience, on: db)
        }
        // Cascading link removal fires no model events: refresh the labels that referenced the deleted tasks.
        for id in labelIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await SyncRecorder.recordUpsert(type: "label", id: id, projectID: nil, on: db)
        }
    }
}

struct SyncTaskMiddleware: AsyncModelMiddleware {
    func create(model: TodoTask, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await SyncRecorder.recordUpsert(type: "task", id: model.requireID(), projectID: model.projectID, on: db)
    }

    func update(model: TodoTask, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let stored = try await TodoTask.find(model.requireID(), on: db)
        var lost = Set<UUID>()
        if let stored, stored.projectID != model.projectID,
           let source = try await Project.find(stored.projectID, on: db),
           let target = try await Project.find(model.projectID, on: db) {
            let old = Set(try await SyncRecorder.readers(of: source, on: db))
            let new = Set(try await SyncRecorder.readers(of: target, on: db))
            lost = old.subtracting(new)
        }
        try await next.update(model, on: db)
        if !lost.isEmpty {
            try await SyncRecorder.recordDelete(type: "task", id: model.requireID(), projectID: model.projectID,
                audience: Array(lost), kind: "revoke", on: db)
        }
        try await SyncRecorder.recordUpsert(type: "task", id: model.requireID(), projectID: model.projectID, on: db)
    }

    func delete(model: TodoTask, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        // Cascading link removal fires no model events: refresh the owner's labels that referenced this task.
        let labelIDs = try await DiscoveryTaskLabel.query(on: db).filter(\.$taskID == model.requireID()).all().map(\.labelID)
        guard let project = try await Project.find(model.projectID, on: db) else {
            try await next.delete(model, force: force, on: db)
            for id in labelIDs { try await SyncRecorder.recordUpsert(type: "label", id: id, projectID: nil, on: db) }
            return
        }
        let audience = try await SyncRecorder.readers(of: project, on: db)
        try await next.delete(model, force: force, on: db)
        try await SyncRecorder.recordDelete(type: "task", id: model.requireID(), projectID: model.projectID, audience: audience, on: db)
        for id in labelIDs { try await SyncRecorder.recordUpsert(type: "label", id: id, projectID: nil, on: db) }
    }
}

/// Labels are private to their owner (ADR 0020): upserts and tombstones concern only the owning account.
struct SyncLabelMiddleware: AsyncModelMiddleware {
    func create(model: DiscoveryLabel, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await SyncRecorder.recordUpsert(type: "label", id: model.requireID(), projectID: nil, on: db)
    }

    func update(model: DiscoveryLabel, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db)
        try await SyncRecorder.recordUpsert(type: "label", id: model.requireID(), projectID: nil, on: db)
    }

    func delete(model: DiscoveryLabel, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.delete(model, force: force, on: db)
        try await SyncRecorder.recordDelete(type: "label", id: model.requireID(), projectID: nil, audience: [model.ownerID], on: db)
    }
}

/// Attaching or detaching a label changes the label's `taskIDs`, so the label is re-delivered.
struct SyncLabelLinkMiddleware: AsyncModelMiddleware {
    func create(model: DiscoveryTaskLabel, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await SyncRecorder.recordUpsert(type: "label", id: model.labelID, projectID: nil, on: db)
    }

    func delete(model: DiscoveryTaskLabel, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.delete(model, force: force, on: db)
        try await SyncRecorder.recordUpsert(type: "label", id: model.labelID, projectID: nil, on: db)
    }
}

/// Board columns are part of the change feed; deletion tombstones go to the project's readers.
struct SyncColumnMiddleware: AsyncModelMiddleware {
    func create(model: ProjectColumn, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await SyncRecorder.recordUpsert(type: "column", id: model.requireID(), projectID: model.projectID, on: db)
    }

    func update(model: ProjectColumn, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db)
        try await SyncRecorder.recordUpsert(type: "column", id: model.requireID(), projectID: model.projectID, on: db)
    }

    func delete(model: ProjectColumn, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let audience = try await Project.find(model.projectID, on: db).asyncMap { try await SyncRecorder.readers(of: $0, on: db) } ?? []
        try await next.delete(model, force: force, on: db)
        try await SyncRecorder.recordDelete(type: "column", id: model.requireID(), projectID: model.projectID, audience: audience, on: db)
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let v = self else { return nil }
        return try await f(v)
    }
}
