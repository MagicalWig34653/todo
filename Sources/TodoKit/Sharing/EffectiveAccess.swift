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
        case "person":
            guard let person = try await User.find(id, on: db) else { throw Abort(.notFound) }
            if person.isLocked { throw Abort(.conflict, reason: "account_disabled") }
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
    /// All projects (sorted like the lists) plus the sharing rows and grants they need, in four queries.
    func snapshot() async throws -> (snapshot: SharingSnapshot, ordered: [Project]) {
        let teams = try await memberships()
        let ordered = try await Project.query(on: db).sort(\.$createdAt).sort(\.$id).all()
        let sharing = Dictionary(uniqueKeysWithValues: try await ProjectSharing.query(on: db).all().map { ($0.projectID, $0) })
        let grants = Dictionary(grouping: try await ProjectGrant.query(on: db).all(), by: \.projectID)
        let projects = Dictionary(uniqueKeysWithValues: try ordered.map { (try $0.requireID(), $0) })
        return (SharingSnapshot(uid: try user.requireID(), teamIDs: Set(teams.map(\.teamID)), admins: Set(teams.filter(\.isAdmin).map(\.teamID)),
                                projects: projects, sharing: sharing, grants: grants), ordered)
    }
}

private extension Optional where Wrapped == UUID {
    func asyncFlatMap<T>(_ transform: (UUID) async throws -> T?) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
