import Fluent
import Vapor

struct MandatedProjectDTO: Content {
    let id: UUID
    let name: String
}

/// Another connection of the same person as a mandated connection sees it: `projects` lists only what lies inside the
/// caller's own mandate; the rest of the target's grant stays invisible.
struct MandatedConnectionDTO: Content {
    let grantID: UUID
    let name: String
    let clientName: String?
    let scopes: [String]
    let lastUsedAt: Date?
    let projects: [MandatedProjectDTO]
}

struct MandatedProjectChangeDTO: Content {
    let grantID: UUID
    let name: String
    /// Mandate projects in the target's grant after the change.
    let projects: [MandatedProjectDTO]
    /// What actually changed (idempotent calls leave both empty).
    let added: [UUID]
    let removed: [UUID]
}

/// Card E71B0FF1, ADR 0032 addendum 24.11.2026: a connection with an active brain mandate reads and changes the project
/// list (`OAuthGrant.explicitProjects`, ADR 0037) of the person's OTHER connections, but only for projects named in its own mandate. The mandate
/// itself is never touched here. Same rules as `ConnectionService.add/remove` for the person's access and `projects_required`.
enum MandatedConnectionService {
    static let maxProjectsPerCall = 50

    /// An active mandate of exactly this connection, plain read (no change follows, so no lock).
    private static func activeMandate(userID: UUID, grantID: UUID, on db: any Database) async throws -> BrainMandate {
        guard let m = try await BrainMandate.query(on: db).filter(\.$userID == userID).filter(\.$grantID == grantID).filter(\.$revokedAt == .null).first() else {
            throw Abort(.forbidden, reason: "brain_mandate_required")
        }
        return m
    }

    /// Projects of `ids` the person can read now, with their names, in the order of `ids`.
    private static func readable(_ ids: [UUID], user: User, on db: any Database) async throws -> [MandatedProjectDTO] {
        let access = ProjectAccess(user: user, db: db)
        var out: [MandatedProjectDTO] = []
        for id in ids {
            do { out.append(MandatedProjectDTO(id: id, name: try await access.project(id).name)) }
            catch let e as any AbortError where e.status == .notFound || e.status == .forbidden { continue }
        }
        return out
    }

    static func list(user: User, caller: OAuthGrant, db: any Database) async throws -> [MandatedConnectionDTO] {
        let userID = try user.requireID(), callerID = try caller.requireID()
        let mandate = try await activeMandate(userID: userID, grantID: callerID, on: db)
        // ADR 0037: both sides resolved (explicit list, groups, "all except", read right).
        var resolver = ProjectSelectionResolver(userID: userID, db: db)
        let covered = Set(try await resolver.projects(of: mandate))
        let grants = try await OAuthGrant.query(on: db).filter(\.$userID == userID).filter(\.$revoked == false).all().filter { $0.id != callerID }
        let clients = try await ConnectionService.clientNames(grants, on: db)
        var out: [MandatedConnectionDTO] = []
        for g in grants {
            let inside = try await resolver.projects(of: g).filter(covered.contains)
            out.append(MandatedConnectionDTO(grantID: try g.requireID(), name: ConnectionNames.display(g, clientName: clients[g.clientID]),
                clientName: clients[g.clientID], scopes: g.scopes, lastUsedAt: g.lastUsedAt, projects: try await readable(inside, user: user, on: db)))
        }
        return out.sorted { ($0.name.lowercased(), $0.grantID.uuidString) < ($1.name.lowercased(), $1.grantID.uuidString) }
    }

    /// Check order: argument shape, own connection (403), foreign/unknown target (404), revoked target (409), caller's mandate
    /// (403 `brain_mandate_required`), projects inside the mandate (403 `outside_brain_mandate`), quote (400), then per added
    /// project the person's access (404). One transaction: any refusal applies nothing.
    static func set(user: User, caller: OAuthGrant, target targetID: UUID, add: [UUID], remove: [UUID], quote: String?,
                    db: any Database) async throws -> MandatedProjectChangeDTO {
        let userID = try user.requireID(), callerID = try caller.requireID()
        let adds = Set(add), removes = Set(remove)
        guard adds.count <= maxProjectsPerCall, removes.count <= maxProjectsPerCall, !(adds.isEmpty && removes.isEmpty),
              adds.isDisjoint(with: removes) else { throw Abort(.badRequest, reason: "invalid_projects") }
        guard targetID != callerID else { throw Abort(.forbidden, reason: "cannot_change_own_connection") }
        return try await db.transaction { tx in
            let (authority, grants) = try await lockedBrainAuthority(userID: userID, grantID: callerID, projectIDs: Array(adds.union(removes)), quote: quote,
                alsoLocking: [targetID], afterLock: { locked in
                    // A grant of another person looks exactly like a missing one.
                    guard let t = locked[targetID], t.userID == userID else { throw Abort(.notFound) }
                    guard !t.revoked else { throw Abort(.conflict, reason: "grant_revoked") }
                }, on: tx)
            guard let target = grants[targetID] else { throw Abort(.notFound) }
            let access = ProjectAccess(user: user, db: tx)
            for id in add { _ = try await access.project(id) }
            // ADR 0037: single projects on top of the target's rule. Adding lifts an exclusion of that project (an excluded
            // group refuses: the person's rule); removing a project a group or "all" brings in excludes it.
            var newlyAdded: [UUID] = [], newlyRemoved: [UUID] = []
            for id in add.uniqued() where try await target.include(id, on: tx) { newlyAdded.append(id) }
            for id in remove.uniqued() where try await target.exclude(id, on: tx) { newlyRemoved.append(id) }
            let projects = try await target.resolveProjects(on: tx, locking: true)
            if !adds.isEmpty {
                try await ConnectionAccessRequest.query(on: tx).filter(\.$grantID == targetID).filter(\.$projectID ~~ adds).set(\.$state, to: "granted").update()
            }
            let now = Date()
            for (kind, ids) in [("connection.project_added", newlyAdded), ("connection.project_removed", newlyRemoved)] {
                for id in ids {
                    let row = BrainConnectionAudit()
                    row.mandateID = authority.mandateID; row.userID = userID; row.grantID = callerID; row.targetGrantID = targetID
                    row.kind = kind; row.projectID = id; row.quote = authority.quote; row.createdAt = now
                    try await row.save(on: tx)
                }
            }
            let client = try await OAuthClient.find(target.clientID, on: tx)?.name
            return MandatedProjectChangeDTO(grantID: targetID, name: ConnectionNames.display(target, clientName: client),
                projects: try await readable(projects.filter { authority.mandateProjects.contains($0) }, user: user, on: tx),
                added: newlyAdded, removed: newlyRemoved)
        }
    }
}

private extension Array where Element: Hashable {
    /// First occurrences only, order kept.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
