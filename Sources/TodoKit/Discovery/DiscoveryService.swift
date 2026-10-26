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

    func search(_ criteria: DiscoveryCriteria, page: DiscoveryPagination) async throws -> DiscoveryPage<DiscoveryHit> {
        try await validate(criteria)
        let size = try page.size()
        let ownerID = try user.requireID()
        let cursor = try DiscoveryCursor.decode(page.cursor, ownerID: ownerID, scope: "search", criteria: criteria)
        guard cursor.map({ ["project", "task"].contains($0.kind) }) ?? true else { throw Abort(.badRequest) }
        let pattern = Self.pattern(criteria.q ?? "")
        var hits: [DiscoveryHit] = []
        // Scan bounded batches: inaccessible candidates cannot consume the public page or leak counts.
        if criteria.labelID == nil, criteria.status == nil, cursor?.kind != "task" {
            var after = cursor?.id
            while hits.count <= size {
                let query = Project.query(on: db)
                    .filter(.sql(embed: "name LIKE \(bind: pattern) ESCAPE '!'"))
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
