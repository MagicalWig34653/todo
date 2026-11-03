import Fluent
import Vapor

enum ConnectionNames {
    static let maxLength = 80
    /// Trimmed, whitespace collapsed; nil when empty, too long or containing control characters.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !value.isEmpty, value.count <= maxLength, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    /// The name a new connection gets when the person does not choose one.
    static func defaultName(_ clientName: String?) -> String {
        clean(clientName.map { String($0.prefix(maxLength)) }) ?? "MCP"
    }
    static func display(_ grant: OAuthGrant, clientName: String?) -> String { grant.name ?? defaultName(clientName) }
}

/// A connection as a participant of a project (share dialog). Its access never exceeds its owner's: `role` is the owner's role.
struct ConnectionDTO: Content {
    let grantID: UUID
    let name: String
    let clientName: String?
    let ownerID: UUID
    let ownerName: String?
    let isOwn: Bool
    let role: ProjectRole?
    let scopes: [String]
    let lastUsedAt: Date?
}

struct FeedAccessRequestDTO: Content {
    let id: UUID
    let grantID: UUID
    let connectionName: String
    let projectID: UUID
    let projectName: String
    /// The connection's access is capped by this role of the owner (no separate role).
    let role: ProjectRole
    let count: Int
    let firstAt: Date
    let lastAt: Date
    let allowPath: String
    let ignorePath: String
}

enum ConnectionService {
    /// Writes of `last_used_at` are throttled to this interval.
    static let usageInterval: TimeInterval = 300
    /// A looping agent raises the counter at most once per interval.
    static let requestInterval: TimeInterval = 60

    static func touch(_ grant: OAuthGrant, db: any Database, now: Date = Date()) async {
        guard grant.lastUsedAt.map({ now.timeIntervalSince($0) > usageInterval }) ?? true, let id = grant.id else { return }
        grant.lastUsedAt = now
        _ = try? await OAuthGrant.query(on: db).filter(\.$id == id).set(\.$lastUsedAt, to: now).update()
    }

    static func clientNames(_ grants: [OAuthGrant], on db: any Database) async throws -> [UUID: String] {
        let ids = Set(grants.map(\.clientID))
        guard !ids.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: try await OAuthClient.query(on: db).filter(\.$id ~~ ids).all().compactMap { c in c.id.map { ($0, c.name) } })
    }

    // MARK: Share dialog

    /// Connections whose grant lists the project and whose owner can still read it.
    static func list(project: Project, actor: User, db: any Database) async throws -> [ConnectionDTO] {
        let pid = try project.requireID()
        let grants = try await OAuthGrant.query(on: db).filter(\.$revoked == false).all().filter { $0.projects.contains(pid) }
        let clients = try await clientNames(grants, on: db)
        let ownerIDs = Array(Set(grants.map(\.userID)))
        let owners: [UUID: User] = ownerIDs.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: try await User.query(on: db).filter(\.$id ~~ ownerIDs).all().compactMap { u in u.id.map { ($0, u) } })
        var result: [ConnectionDTO] = []
        for g in grants {
            guard let owner = owners[g.userID], !owner.isLocked, let role = try await SharingAccess(user: owner, db: db).visibility(project).role else { continue }
            result.append(ConnectionDTO(grantID: try g.requireID(), name: ConnectionNames.display(g, clientName: clients[g.clientID]), clientName: clients[g.clientID],
                ownerID: g.userID, ownerName: owner.displayName, isOwn: g.userID == actor.id, role: role, scopes: g.scopes, lastUsedAt: g.lastUsedAt))
        }
        return result.sorted { ($0.name.lowercased(), $0.grantID.uuidString) < ($1.name.lowercased(), $1.grantID.uuidString) }
    }

    /// Adds a project to the caller's own connection (same rules as `PUT /oauth/grants/{id}/projects`: the person needs access now).
    @discardableResult
    static func add(project projectID: UUID, grantID: UUID, user: User, db: any Database) async throws -> OAuthGrant {
        try await db.transaction { tx in
            try await lockRow(table: OAuthGrant.schema, id: grantID, on: tx)
            guard let g = try await OAuthGrant.find(grantID, on: tx), g.userID == user.id else { throw Abort(.notFound) }
            guard !g.revoked else { throw Abort(.conflict, reason: "grant_revoked") }
            _ = try await ProjectAccess(user: user, db: tx).project(projectID)
            if !g.projects.contains(projectID) { g.projects.append(projectID); try await g.save(on: tx) }
            try await ConnectionAccessRequest.query(on: tx).filter(\.$grantID == grantID).filter(\.$projectID == projectID).set(\.$state, to: "granted").update()
            return g
        }
    }

    /// Removes a project from a connection; the owner of the connection or a manager of the project may do it.
    static func remove(project projectID: UUID, grantID: UUID, actor: User, db: any Database) async throws {
        try await db.transaction { tx in
            try await lockRow(table: OAuthGrant.schema, id: grantID, on: tx)
            guard let g = try await OAuthGrant.find(grantID, on: tx), g.projects.contains(projectID) else { throw Abort(.notFound) }
            if g.userID != actor.id { _ = try await ProjectAccess(user: actor, db: tx).project(projectID, role: .manage) }
            guard g.projects.count > 1 || g.scopes.contains("projects:write") else { throw Abort(.badRequest, reason: "projects_required") }
            g.projects.removeAll { $0 == projectID }
            try await g.save(on: tx)
        }
    }

    @discardableResult
    static func rename(grantID: UUID, name: String?, user: User, db: any Database) async throws -> OAuthGrant {
        guard let clean = ConnectionNames.clean(name) else { throw Abort(.badRequest, reason: "invalid_name") }
        return try await db.transaction { tx in
            try await lockRow(table: OAuthGrant.schema, id: grantID, on: tx)
            guard let g = try await OAuthGrant.find(grantID, on: tx), g.userID == user.id else { throw Abort(.notFound) }
            g.name = clean; try await g.save(on: tx)
            return g
        }
    }

    // MARK: Access requests (ADR 0028)

    /// Called after a tool call failed with not_found/forbidden. Records the denied project (and the project of a denied task)
    /// when the owner can read it. Never throws and never changes what the agent sees.
    static func noteDenied(arguments a: JSONValue, grant: OAuthGrant, user: User, db: any Database, now: Date = Date()) async {
        do {
            var candidates = Set<UUID>()
            if let s = a["projectID"].string, let id = UUID(uuidString: s) { candidates.insert(id) }
            for key in ["taskID", "id"] {
                if let s = a[key].string, let id = UUID(uuidString: s), let task = try await TodoTask.find(id, on: db) { candidates.insert(task.projectID) }
            }
            for pid in candidates where !grant.projects.contains(pid) { try await record(projectID: pid, grant: grant, user: user, db: db, now: now) }
        } catch {}
    }

    static func record(projectID: UUID, grant: OAuthGrant, user: User, db: any Database, now: Date) async throws {
        let grantID = try grant.requireID()
        guard let project = try await Project.find(projectID, on: db),
              try await SharingAccess(user: user, db: db).visibility(project).role != nil else { return }
        // Cheap flood guard before taking the lock.
        if let row = try await ConnectionAccessRequest.query(on: db).filter(\.$grantID == grantID).filter(\.$projectID == projectID).first(),
           now.timeIntervalSince(row.lastAt) < requestInterval { return }
        try await db.transaction { tx in
            try await lockRow(table: OAuthGrant.schema, id: grantID, on: tx)
            guard let live = try await OAuthGrant.find(grantID, on: tx), !live.revoked, !live.projects.contains(projectID) else { return }
            if let row = try await ConnectionAccessRequest.query(on: tx).filter(\.$grantID == grantID).filter(\.$projectID == projectID).first() {
                guard now.timeIntervalSince(row.lastAt) >= requestInterval else { return }
                if row.state == "granted" { row.state = "open"; row.count = 1; row.firstAt = now } else { row.count += 1 }
                row.lastAt = now; try await row.save(on: tx)
            } else {
                try await ConnectionAccessRequest(grantID: grantID, projectID: projectID, userID: user.requireID(), now: now).save(on: tx)
            }
        }
    }

    /// Open notices of the person: grant alive, project still outside the grant and still readable.
    static func openRequests(user: User, scopeProjects: [UUID: Project], db: any Database, limit: Int = 20) async throws -> [FeedAccessRequestDTO] {
        let rows = try await ConnectionAccessRequest.query(on: db).filter(\.$userID == user.requireID()).filter(\.$state == "open")
            .sort(\.$lastAt, .descending).limit(100).all()
        guard !rows.isEmpty else { return [] }
        let grants = Dictionary(uniqueKeysWithValues: try await OAuthGrant.query(on: db).filter(\.$id ~~ Array(Set(rows.map(\.grantID)))).all().compactMap { g in g.id.map { ($0, g) } })
        let clients = try await clientNames(Array(grants.values), on: db)
        let access = SharingAccess(user: user, db: db)
        var out: [FeedAccessRequestDTO] = []
        for r in rows {
            guard let g = grants[r.grantID], !g.revoked, !g.projects.contains(r.projectID), let project = scopeProjects[r.projectID],
                  let role = try await access.visibility(project).role, let id = r.id else { continue }
            out.append(FeedAccessRequestDTO(id: id, grantID: r.grantID, connectionName: ConnectionNames.display(g, clientName: clients[g.clientID]),
                projectID: r.projectID, projectName: project.name, role: role, count: r.count, firstAt: r.firstAt, lastAt: r.lastAt,
                allowPath: "/v1/connection-access-requests/\(id)/allow", ignorePath: "/v1/connection-access-requests/\(id)/ignore"))
            if out.count >= limit { break }
        }
        return out
    }

    static func allow(requestID: UUID, user: User, db: any Database) async throws {
        guard let r = try await ConnectionAccessRequest.find(requestID, on: db), r.userID == user.id else { throw Abort(.notFound) }
        try await add(project: r.projectID, grantID: r.grantID, user: user, db: db)
    }

    static func ignore(requestID: UUID, user: User, db: any Database) async throws {
        guard let r = try await ConnectionAccessRequest.find(requestID, on: db), r.userID == user.id else { throw Abort(.notFound) }
        r.state = "ignored"; try await r.save(on: db)
    }
}

struct ConnectionController: RouteCollection {
    struct AddInput: Content { let grantID: UUID }
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("projects", ":id", "connections", use: list)
        v1.put("projects", ":id", "connections", use: add)
        v1.delete("projects", ":id", "connections", ":grantID", use: remove)
        v1.post("connection-access-requests", ":id", "allow", use: allow)
        v1.post("connection-access-requests", ":id", "ignore", use: ignore)
    }
    private func uuid(_ req: Request, _ key: String) throws -> UUID {
        guard let id = req.parameters.get(key, as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func list(_ req: Request) async throws -> [ConnectionDTO] {
        let user = try await req.requireUser()
        let project = try await ProjectAccess(user: user, db: req.db).project(uuid(req, "id"), role: .manage)
        return try await ConnectionService.list(project: project, actor: user, db: req.db)
    }
    @Sendable func add(_ req: Request) async throws -> [ConnectionDTO] {
        let user = try await req.requireUser(), input = try req.content.decode(AddInput.self)
        let pid = try uuid(req, "id")
        let project = try await ProjectAccess(user: user, db: req.db).project(pid, role: .manage)
        try await ConnectionService.add(project: pid, grantID: input.grantID, user: user, db: req.db)
        return try await ConnectionService.list(project: project, actor: user, db: req.db)
    }
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        try await ConnectionService.remove(project: uuid(req, "id"), grantID: uuid(req, "grantID"), actor: user, db: req.db)
        return .noContent
    }
    @Sendable func allow(_ req: Request) async throws -> HTTPStatus {
        try await ConnectionService.allow(requestID: uuid(req, "id"), user: req.requireUser(), db: req.db); return .noContent
    }
    @Sendable func ignore(_ req: Request) async throws -> HTTPStatus {
        try await ConnectionService.ignore(requestID: uuid(req, "id"), user: req.requireUser(), db: req.db); return .noContent
    }
}
