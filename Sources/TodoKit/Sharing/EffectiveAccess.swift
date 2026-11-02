import Fluent
import Vapor

struct EffectiveVisibility: Content {
    let projectID: UUID
    let userID: UUID
    let role: ProjectRole?
    let canTransferOwnership: Bool
    let canDelete: Bool
    let canManageTeam: Bool
    let canStartAgent: Bool
    let inherits: Bool
}

struct SharingAccess {
    let user: User
    let db: any Database

    func memberships() async throws -> [TeamMembership] {
        try await TeamMembership.query(on: db).filter(\.$userID == user.requireID()).filter(\.$accepted == true).all()
    }

    func visibility(_ project: Project) async throws -> EffectiveVisibility {
        let uid = try user.requireID()
        let teams = try await memberships()
        let teamIDs = Set(teams.map(\.teamID))
        let admins = Set(teams.filter(\.isAdmin).map(\.teamID))
        let pid = try project.requireID()
        let own = try await ProjectSharing.query(on: db).filter(\.$projectID == pid).first()
        let ownerType = own?.ownerType ?? "person"
        let ownerID = own?.ownerID ?? project.ownerID
        let owner = ownerType == "person" ? ownerID == uid : admins.contains(ownerID)
        var role: ProjectRole? = owner ? .manage : (ownerType == "team" && teamIDs.contains(ownerID) ? .read : nil)
        var current: Project? = project
        var seen = Set<UUID>()
        while let p = current {
            let id = try p.requireID()
            guard seen.insert(id).inserted else { throw Abort(.conflict, reason: "project_cycle") }
            let grants = try await ProjectGrant.query(on: db).filter(\.$projectID == id).all()
            for grant in grants where (grant.principalType == "person" && grant.principalID == uid)
                || (grant.principalType == "team" && teamIDs.contains(grant.principalID)) {
                if grant.role.rank > (role?.rank ?? -1) { role = grant.role }
            }
            let policy = try await ProjectSharing.query(on: db).filter(\.$projectID == id).first()
            if policy?.inherits == false { break }
            current = try await p.parentID.asyncFlatMap { try await Project.find($0, on: db) }
        }
        return EffectiveVisibility(projectID: pid, userID: uid, role: role, canTransferOwnership: owner,
            canDelete: owner, canManageTeam: ownerType == "team" && admins.contains(ownerID),
            canStartAgent: false, inherits: own?.inherits ?? true)
    }

    func require(_ project: Project, role: ProjectRole = .read) async throws -> EffectiveVisibility {
        let result = try await visibility(project)
        guard let actual = result.role else { throw Abort(.notFound) }
        guard actual.rank >= role.rank else { throw Abort(.forbidden) }
        return result
    }

    func requireTeam(_ id: UUID, admin: Bool = false) async throws -> Team {
        guard let membership = try await TeamMembership.query(on: db).filter(\.$teamID == id)
            .filter(\.$userID == user.requireID()).filter(\.$accepted == true).first(),
            let team = try await Team.find(id, on: db) else { throw Abort(.notFound) }
        if admin && !membership.isAdmin { throw Abort(.forbidden) }
        return team
    }

    func validatePrincipal(type: String, id: UUID) async throws {
        switch type {
        case "person": guard try await User.find(id, on: db) != nil else { throw Abort(.notFound) }
        case "team": _ = try await requireTeam(id)
        default: throw Abort(.badRequest, reason: "invalid_principal")
        }
    }
}

/// The sharing graph loaded once (a handful of queries) so lists can compute many projects' visibility in memory.
/// `visibility` mirrors `SharingAccess.visibility` exactly; keep both in step.
struct SharingSnapshot {
    let uid: UUID
    let teamIDs: Set<UUID>
    let admins: Set<UUID>
    let projects: [UUID: Project]
    let sharing: [UUID: ProjectSharing]
    let grants: [UUID: [ProjectGrant]]

    func visibility(_ project: Project) throws -> EffectiveVisibility {
        let pid = try project.requireID()
        let own = sharing[pid]
        let ownerType = own?.ownerType ?? "person"
        let ownerID = own?.ownerID ?? project.ownerID
        let owner = ownerType == "person" ? ownerID == uid : admins.contains(ownerID)
        var role: ProjectRole? = owner ? .manage : (ownerType == "team" && teamIDs.contains(ownerID) ? .read : nil)
        var current: Project? = project
        var seen = Set<UUID>()
        while let p = current {
            let id = try p.requireID()
            guard seen.insert(id).inserted else { throw Abort(.conflict, reason: "project_cycle") }
            for grant in grants[id] ?? [] where (grant.principalType == "person" && grant.principalID == uid)
                || (grant.principalType == "team" && teamIDs.contains(grant.principalID)) {
                if grant.role.rank > (role?.rank ?? -1) { role = grant.role }
            }
            if sharing[id]?.inherits == false { break }
            current = p.parentID.flatMap { projects[$0] }
        }
        return EffectiveVisibility(projectID: pid, userID: uid, role: role, canTransferOwnership: owner,
            canDelete: owner, canManageTeam: ownerType == "team" && admins.contains(ownerID),
            canStartAgent: false, inherits: own?.inherits ?? true)
    }
}

extension SharingAccess {
    /// Only the projects that can matter for this account, plus their sharing rows and grants.
    /// Seeds: projects it owns (person or via an accepted team), projects with a grant for it or its teams.
    /// Then all descendants (inherited rights) and all ancestors (inheritance chain, hidden parents).
    /// Every other project has no role for this account, so `visibility` equals `SharingAccess.visibility`
    /// for all loaded projects; unloaded ones are simply not readable (and unrelated cycles are not touched).
    func snapshot() async throws -> (snapshot: SharingSnapshot, ordered: [Project]) {
        let uid = try user.requireID()
        let teams = try await memberships()
        let teamIDs = Set(teams.map(\.teamID))
        var loaded: [UUID: Project] = [:]
        func add(_ rows: [Project]) throws -> [Project] {
            var fresh: [Project] = []
            for p in rows { if loaded.updateValue(p, forKey: try p.requireID()) == nil { fresh.append(p) } }
            return fresh
        }
        func chunks<T>(_ values: [T]) -> [[T]] { stride(from: 0, to: values.count, by: 500).map { Array(values[$0..<min($0 + 500, values.count)]) } }

        var seedIDs = Set<UUID>()
        let ownedRows = try await ProjectSharing.query(on: db).filter(\.$ownerType == "person").filter(\.$ownerID == uid).all()
        seedIDs.formUnion(ownedRows.map(\.projectID))
        if !teamIDs.isEmpty {
            seedIDs.formUnion(try await ProjectSharing.query(on: db).filter(\.$ownerType == "team").filter(\.$ownerID ~~ teamIDs).all().map(\.projectID))
            seedIDs.formUnion(try await ProjectGrant.query(on: db).filter(\.$principalType == "team").filter(\.$principalID ~~ teamIDs).all().map(\.projectID))
        }
        seedIDs.formUnion(try await ProjectGrant.query(on: db).filter(\.$principalType == "person").filter(\.$principalID == uid).all().map(\.projectID))
        // Projects without an overlay row are owned by projects.owner_id (a superset is harmless).
        var frontier = try add(try await Project.query(on: db).filter(\.$ownerID == uid).all())
        for chunk in chunks(Array(seedIDs)) { frontier += try add(try await Project.query(on: db).filter(\.$id ~~ chunk).all()) }
        // Descendants, level by level.
        var level = frontier
        while !level.isEmpty {
            var next: [Project] = []
            for chunk in chunks(try level.map { try $0.requireID() }) {
                next += try add(try await Project.query(on: db).filter(\.$parentID ~~ chunk).all())
            }
            level = next
        }
        // Ancestors, level by level (also of the ancestors themselves; the seen set stops cycles).
        level = Array(loaded.values)
        while !level.isEmpty {
            let missing = Set(level.compactMap(\.parentID)).filter { loaded[$0] == nil }
            var next: [Project] = []
            for chunk in chunks(Array(missing)) { next += try add(try await Project.query(on: db).filter(\.$id ~~ chunk).all()) }
            level = next
        }
        let ids = Array(loaded.keys)
        var sharing: [UUID: ProjectSharing] = [:], grants: [UUID: [ProjectGrant]] = [:]
        for chunk in chunks(ids) {
            for row in try await ProjectSharing.query(on: db).filter(\.$projectID ~~ chunk).all() { sharing[row.projectID] = row }
            for g in try await ProjectGrant.query(on: db).filter(\.$projectID ~~ chunk).all() { grants[g.projectID, default: []].append(g) }
        }
        let ordered = loaded.values.sorted {
            let (a, b) = ($0.createdAt, $1.createdAt)
            if a != b { return (a ?? .distantPast) < (b ?? .distantPast) }
            return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }
        return (SharingSnapshot(uid: uid, teamIDs: teamIDs, admins: Set(teams.filter(\.isAdmin).map(\.teamID)),
                                projects: loaded, sharing: sharing, grants: grants), ordered)
    }
}

extension Optional where Wrapped == UUID {
    func asyncFlatMap<T>(_ transform: (UUID) async throws -> T?) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
