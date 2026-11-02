import Fluent
import FluentSQL
import Vapor

struct DiscoveryPagination: Content {
    var limit: Int?
    var cursor: String?

    func size() throws -> Int {
        let value = limit ?? 50
        guard (1...100).contains(value) else { throw Abort(.badRequest) }
        return value
    }
}

/// Cursors carry only the last visible key. They never replace authorization or store result snapshots.
struct DiscoveryCursor: Codable {
    let ownerID: UUID
    let scope: String
    let criteria: DiscoveryCriteria
    let kind: String
    let id: UUID

    func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String?, ownerID: UUID, scope: String, criteria: DiscoveryCriteria) throws -> Self? {
        guard let raw else { return nil }
        guard raw.count <= 4096 else { throw Abort(.badRequest) }
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.ownerID == ownerID, cursor.scope == scope, cursor.criteria == criteria,
              ["project", "task", "label", "filter"].contains(cursor.kind)
        else { throw Abort(.badRequest) }
        return cursor
    }
}

struct DiscoveryService {
    let user: User
    let db: any Database
    var access: ProjectAccess { ProjectAccess(user: user, db: db) }

    func label(_ id: UUID) async throws -> DiscoveryLabel {
        guard let label = try await DiscoveryLabel.find(id, on: db), label.ownerID == user.id else {
            throw Abort(.notFound)
        }
        return label
    }

    func savedFilter(_ id: UUID) async throws -> DiscoverySavedFilter {
        guard let filter = try await DiscoverySavedFilter.find(id, on: db), filter.ownerID == user.id else {
            throw Abort(.notFound)
        }
        return filter
    }

    func task(_ id: UUID) async throws -> TodoTask {
        let task = try await access.task(id)
        _ = try await access.project(task.projectID)
        return task
    }

    func validate(_ criteria: DiscoveryCriteria) async throws {
        _ = try criteria.validated()
        if let id = criteria.projectID { _ = try await access.project(id) }
        if let id = criteria.labelID { _ = try await label(id) }
    }

    /// Explicit ESCAPE '!' works in SQLite and MariaDB regardless of backslash SQL mode.
    static func pattern(_ value: String) -> String {
        "%" + value.replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_") + "%"
    }

    func search(_ criteria: DiscoveryCriteria, page: DiscoveryPagination, projectIDs: Set<UUID>? = nil, tasksOnly: Bool = false) async throws -> DiscoveryPage<DiscoveryHit> {
        if let id = criteria.projectID, let projectIDs, !projectIDs.contains(id) { throw Abort(.notFound) }
        try await validate(criteria)
        let size = try page.size()
        let ownerID = try user.requireID()
        let cursor = try DiscoveryCursor.decode(page.cursor, ownerID: ownerID, scope: "search", criteria: criteria)
        guard cursor.map({ ["project", "task"].contains($0.kind) }) ?? true else { throw Abort(.badRequest) }
        let pattern = Self.pattern(criteria.q ?? "")
        var hits: [DiscoveryHit] = []
        // Scan bounded batches: inaccessible candidates cannot consume the public page or leak counts.
        if !tasksOnly, criteria.labelID == nil, criteria.status == nil, cursor?.kind != "task" {
            var after = cursor?.id
            while hits.count <= size {
                let query = Project.query(on: db)
                    .filter(.sql(embed: "name LIKE \(bind: pattern) ESCAPE '!'"))
                if let projectIDs { query.filter(\.$id ~~ Array(projectIDs)) }
                if let after { query.filter(\.$id > after) }
                if let id = criteria.projectID { query.filter(\.$id == id) }
                let candidates = try await query.sort(\.$id).range(0..<100).all()
                for candidate in candidates {
                    let id = try candidate.requireID()
                    after = id
                    do {
                        let project = try await access.project(id)
                        hits.append(DiscoveryHit(kind: "project", id: id, project: try await access.dto(project), task: nil))
                    } catch let error as AbortError where error.status == .notFound { continue }
                    if hits.count > size { break }
                }
                if candidates.count < 100 { break }
            }
        }
        var after = cursor?.kind == "task" ? cursor?.id : nil
        while hits.count <= size {
            let query = TodoTask.query(on: db).filter(.sql(embed: """
                (title LIKE \(bind: pattern) ESCAPE '!' OR description LIKE \(bind: pattern) ESCAPE '!'
                 OR project_id IN (SELECT id FROM projects WHERE name LIKE \(bind: pattern) ESCAPE '!'))
                """))
            if let projectIDs { query.filter(\.$projectID ~~ Array(projectIDs)) }
            if let after { query.filter(\.$id > after) }
            if let id = criteria.projectID { query.filter(\.$projectID == id) }
            if let status = criteria.status { query.filter(\.$status == status) }
            if let id = criteria.labelID {
                query.filter(.sql(embed: "tasks.id IN (SELECT task_id FROM discovery_task_labels WHERE label_id = \(bind: id))"))
            }
            let candidates = try await query.sort(\.$id).range(0..<100).all()
            for candidate in candidates {
                let id = try candidate.requireID()
                after = id
                do {
                    let task = try await task(id)
                    // A task may have moved after the candidate query; recheck the reloaded project too.
                    if let projectIDs, !projectIDs.contains(task.projectID) { continue }
                    let project = try await access.project(task.projectID)
                    hits.append(DiscoveryHit(kind: "task", id: id, project: try await access.dto(project), task: try TaskDTO(task)))
                } catch let error as AbortError where error.status == .notFound { continue }
                if hits.count > size { break }
            }
            if candidates.count < 100 { break }
        }
        let items = Array(hits.prefix(size))
        let next: String?
        if hits.count > size, let last = items.last {
            next = try DiscoveryCursor(ownerID: ownerID, scope: "search", criteria: criteria, kind: last.kind, id: last.id).encoded()
        } else { next = nil }
        return DiscoveryPage(items: items, nextCursor: next)
    }
}

extension DiscoveryService {
    static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw Abort(.badRequest, reason: "invalid_name") }
        return name
    }

    static func cleanColor(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.count == 7, raw.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "invalid_color") }
        return raw
    }

    func createLabel(name: String, color: String?) async throws -> DiscoveryLabelDTO {
        let label = DiscoveryLabel(ownerID: try user.requireID(), name: try Self.cleanName(name))
        label.color = try Self.cleanColor(color)
        try await label.save(on: db)
        return try DiscoveryLabelDTO(label)
    }

    func updateLabel(_ id: UUID, version: Int, name: String?, color: String?) async throws -> DiscoveryLabelDTO {
        try await db.transaction { tx in
            try await lockRow(table: DiscoveryLabel.schema, id: id, on: tx)
            let label = try await DiscoveryService(user: user, db: tx).label(id)
            guard label.version == version else { throw Abort(.conflict, reason: "version_conflict") }
            if let name { label.name = try Self.cleanName(name) }
            if let color { label.color = try Self.cleanColor(color) }
            label.version += 1
            try await label.save(on: tx)
            return try DiscoveryLabelDTO(label)
        }
    }

    func deleteLabel(_ id: UUID, version: Int? = nil) async throws {
        let row = try await label(id)
        if let version, row.version != version { throw Abort(.conflict, reason: "version_conflict") }
        try await row.delete(on: db)
    }

    /// Private metadata can be changed with read access, just like the REST label routes.
    /// Only this account's links are replaced; links owned by other readers are preserved.
    func setLabels(taskID: UUID, labelIDs: [UUID], replacing: Bool = true, attach: Bool = true, projectIDs: Set<UUID>? = nil) async throws {
        try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: TodoTask.schema, id: taskID, on: tx)
            let service = DiscoveryService(user: user, db: tx)
            let task = try await service.task(taskID)
            if let projectIDs, !projectIDs.contains(task.projectID) { throw Abort(.notFound) }
            for id in Set(labelIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
                try await lockRow(table: DiscoveryLabel.schema, id: id, on: tx)
                _ = try await service.label(id)
            }
            let own = try await DiscoveryLabel.query(on: tx).filter(\.$ownerID == user.requireID()).all().compactMap(\.id)
            let links = try await DiscoveryTaskLabel.query(on: tx).filter(\.$taskID == taskID).filter(\.$labelID ~~ own).all()
            let wanted = Set(labelIDs)
            for link in links where (replacing && !wanted.contains(link.labelID)) || (!attach && wanted.contains(link.labelID)) {
                try await link.delete(on: tx)
            }
            if attach {
                let existing = Set(links.map(\.labelID))
                for id in wanted.subtracting(existing) { try await DiscoveryTaskLabel(taskID: taskID, labelID: id).save(on: tx) }
            }
        }
    }

    func createFilter(name: String, criteria: DiscoveryCriteria) async throws -> DiscoveryFilterDTO {
        try await validate(criteria)
        let row = try DiscoverySavedFilter(ownerID: user.requireID(), name: Self.cleanName(name), criteria: criteria)
        try await row.save(on: db)
        return try DiscoveryFilterDTO(row)
    }

    func updateFilter(_ id: UUID, version: Int, name: String?, criteria: DiscoveryCriteria?) async throws -> DiscoveryFilterDTO {
        try await db.transaction { tx in
            try await lockRow(table: DiscoverySavedFilter.schema, id: id, on: tx)
            let service = DiscoveryService(user: user, db: tx)
            let row = try await service.savedFilter(id)
            guard row.version == version else { throw Abort(.conflict, reason: "version_conflict") }
            if let name { row.name = try Self.cleanName(name) }
            if let criteria {
                try await service.validate(criteria)
                row.criteria = String(decoding: try JSONEncoder().encode(criteria), as: UTF8.self)
            }
            row.version += 1
            try await row.save(on: tx)
            return try DiscoveryFilterDTO(row)
        }
    }

    func deleteFilter(_ id: UUID, version: Int? = nil) async throws {
        let row = try await savedFilter(id)
        if let version, row.version != version { throw Abort(.conflict, reason: "version_conflict") }
        try await row.delete(on: db)
    }
}
