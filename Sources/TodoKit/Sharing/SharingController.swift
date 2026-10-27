import Fluent
import Vapor

struct TeamInput: Content { let name: String }
struct MemberInput: Content { let userID: UUID; let isAdmin: Bool }
struct GrantInput: Content { let principalType: String; let principalID: UUID; let role: ProjectRole }
struct InheritanceInput: Content { let version: Int; let inherits: Bool }
struct OwnerInput: Content { let version: Int; let ownerType: String; let ownerID: UUID }

/// Membership with optional resolved names; additive over the stored `TeamMembership` fields.
struct TeamMembershipDTO: Content {
    let id: UUID
    let teamID: UUID
    let userID: UUID
    let isAdmin: Bool
    let accepted: Bool
    let teamName: String?
    let displayName: String?
    init(_ m: TeamMembership, teamName: String?, displayName: String?) throws {
        id = try m.requireID(); teamID = m.teamID; userID = m.userID; isAdmin = m.isAdmin; accepted = m.accepted
        self.teamName = teamName; self.displayName = displayName
    }
}

struct SharingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("teams", use: listTeams)
        v1.post("teams", use: createTeam)
        v1.get("teams", ":teamID", "members", use: listMembers)
        v1.put("teams", ":teamID", "members", use: inviteMember)
        v1.post("teams", ":teamID", "accept", use: acceptMembership)
        v1.delete("teams", ":teamID", "members", ":userID", use: removeMember)
        v1.get("team-invitations", use: invitations)
        v1.get("projects", ":id", "grants", use: listGrants)
        v1.put("projects", ":id", "grants", use: putGrant)
        v1.delete("projects", ":id", "grants", ":grantID", use: deleteGrant)
        v1.put("projects", ":id", "inheritance", use: setInheritance)
        v1.put("projects", ":id", "owner", use: setOwner)
        v1.get("projects", ":id", "visibility", use: visibility)
    }

    private func id(_ req: Request, _ key: String = "id") throws -> UUID {
        guard let id = req.parameters.get(key, as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    /// All sharing mutations and planning writes take the same database lock before reading rights.
    private func write<T: Sendable>(_ req: Request,
        _ operation: @escaping @Sendable (SharingAccess) async throws -> T
    ) async throws -> T {
        let user = try await req.requireUser()
        return try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            let before = try await SyncRecorder.visibility(on: db)
            let result = try await operation(SharingAccess(user: user, db: db))
            try await SyncRecorder.recordVisibilityChanges(from: before, on: db)
            return result
        }
    }

    @Sendable func listTeams(_ req: Request) async throws -> [Team] {
        let access = SharingAccess(user: try await req.requireUser(), db: req.db)
        let ids = try await access.memberships().map(\.teamID)
        guard !ids.isEmpty else { return [] }
        return try await Team.query(on: req.db).filter(\.$id ~~ ids).all()
    }

    @Sendable func createTeam(_ req: Request) async throws -> Team {
        let input = try req.content.decode(TeamInput.self)
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw Abort(.badRequest, reason: "invalid_name") }
        return try await write(req) { access in
            let team = Team(name: name, founderID: try access.user.requireID())
            try await team.save(on: access.db)
            try await TeamMembership(teamID: team.requireID(), userID: access.user.requireID(),
                isAdmin: true, accepted: true).save(on: access.db)
            return team
        }
    }

    @Sendable func listMembers(_ req: Request) async throws -> [TeamMembershipDTO] {
        let access = SharingAccess(user: try await req.requireUser(), db: req.db)
        let tid = try id(req, "teamID")
        _ = try await access.requireTeam(tid)
        let members = try await TeamMembership.query(on: req.db).filter(\.$teamID == tid).all()
        let names = try await displayNames(members.map(\.userID), on: req.db)
        return try members.map { try TeamMembershipDTO($0, teamName: nil, displayName: names[$0.userID]) }
    }

    /// Pending invitations of the caller, including the team name so the invitee can decide knowingly.
    @Sendable func invitations(_ req: Request) async throws -> [TeamMembershipDTO] {
        let user = try await req.requireUser()
        let pending = try await TeamMembership.query(on: req.db).filter(\.$userID == user.requireID())
            .filter(\.$accepted == false).all()
        let teams = pending.isEmpty ? [] : try await Team.query(on: req.db).filter(\.$id ~~ pending.map(\.teamID)).all()
        let teamNames = Dictionary(uniqueKeysWithValues: try teams.map { (try $0.requireID(), $0.name) })
        return try pending.map { try TeamMembershipDTO($0, teamName: teamNames[$0.teamID], displayName: nil) }
    }

    @Sendable func inviteMember(_ req: Request) async throws -> TeamMembership {
        let input = try req.content.decode(MemberInput.self)
        let tid = try id(req, "teamID")
        return try await write(req) { access in
            let team = try await access.requireTeam(tid, admin: true)
            guard try await User.find(input.userID, on: access.db) != nil else { throw Abort(.notFound) }
            if input.userID == team.founderID && !input.isAdmin { throw Abort(.conflict, reason: "team_founder_required") }
            let member = try await TeamMembership.query(on: access.db).filter(\.$teamID == tid)
                .filter(\.$userID == input.userID).first()
                ?? TeamMembership(teamID: tid, userID: input.userID)
            member.isAdmin = input.isAdmin
            try await member.save(on: access.db)
            return member
        }
    }

    @Sendable func acceptMembership(_ req: Request) async throws -> HTTPStatus {
        let tid = try id(req, "teamID")
        return try await write(req) { access in
            guard let member = try await TeamMembership.query(on: access.db).filter(\.$teamID == tid)
                .filter(\.$userID == access.user.requireID()).first() else { throw Abort(.notFound) }
            member.accepted = true
            try await member.save(on: access.db)
            return .noContent
        }
    }

    @Sendable func removeMember(_ req: Request) async throws -> HTTPStatus {
        let tid = try id(req, "teamID"), uid = try id(req, "userID")
        return try await write(req) { access in
            let team = try await access.requireTeam(tid, admin: true)
            guard uid != team.founderID else { throw Abort(.conflict, reason: "team_founder_required") }
            guard let member = try await TeamMembership.query(on: access.db).filter(\.$teamID == tid)
                .filter(\.$userID == uid).first() else { throw Abort(.notFound) }
            try await member.delete(on: access.db)
            return .noContent
        }
    }

    @Sendable func listGrants(_ req: Request) async throws -> [ProjectGrant] {
        let user = try await req.requireUser(), pid = try id(req)
        _ = try await ProjectAccess(user: user, db: req.db).project(pid, role: .manage)
        return try await ProjectGrant.query(on: req.db).filter(\.$projectID == pid).all()
    }

    @Sendable func putGrant(_ req: Request) async throws -> ProjectGrant {
        let input = try req.content.decode(GrantInput.self), pid = try id(req)
        return try await write(req) { access in
            _ = try await ProjectAccess(user: access.user, db: access.db).project(pid, role: .manage)
            try await access.validatePrincipal(type: input.principalType, id: input.principalID)
            let grant = try await ProjectGrant.query(on: access.db).filter(\.$projectID == pid)
                .filter(\.$principalType == input.principalType).filter(\.$principalID == input.principalID).first()
                ?? ProjectGrant(projectID: pid, principalType: input.principalType, principalID: input.principalID, role: input.role)
            grant.role = input.role
            try await grant.save(on: access.db)
            return grant
        }
    }

    @Sendable func deleteGrant(_ req: Request) async throws -> HTTPStatus {
        let pid = try id(req), gid = try id(req, "grantID")
        return try await write(req) { access in
            _ = try await ProjectAccess(user: access.user, db: access.db).project(pid, role: .manage)
            guard let grant = try await ProjectGrant.find(gid, on: access.db), grant.projectID == pid else { throw Abort(.notFound) }
            try await grant.delete(on: access.db)
            return .noContent
        }
    }

    @Sendable func setInheritance(_ req: Request) async throws -> EffectiveVisibility {
        let input = try req.content.decode(InheritanceInput.self), pid = try id(req)
        return try await write(req) { access in
            let project = try await ProjectAccess(user: access.user, db: access.db).project(pid, role: .manage)
            guard project.version == input.version else { throw Abort(.conflict, reason: "version_conflict") }
            let policy = try await ProjectSharing.query(on: access.db).filter(\.$projectID == pid).first()
                ?? ProjectSharing(project: project)
            policy.inherits = input.inherits
            try await policy.save(on: access.db)
            project.version += 1
            try await project.save(on: access.db)
            return try await access.visibility(project)
        }
    }

    @Sendable func setOwner(_ req: Request) async throws -> EffectiveVisibility {
        let input = try req.content.decode(OwnerInput.self), pid = try id(req)
        return try await write(req) { access in
            let project = try await ProjectAccess(user: access.user, db: access.db).project(pid)
            guard try await access.visibility(project).canTransferOwnership else { throw Abort(.forbidden) }
            guard project.version == input.version else { throw Abort(.conflict, reason: "version_conflict") }
            try await access.validatePrincipal(type: input.ownerType, id: input.ownerID)
            if input.ownerType == "team" { _ = try await access.requireTeam(input.ownerID, admin: true) }
            let policy = try await ProjectSharing.query(on: access.db).filter(\.$projectID == pid).first()
                ?? ProjectSharing(project: project)
            policy.ownerType = input.ownerType; policy.ownerID = input.ownerID
            try await policy.save(on: access.db)
            project.version += 1
            try await project.save(on: access.db)
            return try await access.visibility(project)
        }
    }

    @Sendable func visibility(_ req: Request) async throws -> EffectiveVisibility {
        let user = try await req.requireUser()
        let project = try await ProjectAccess(user: user, db: req.db).project(id(req))
        if let targetID = req.query[UUID.self, at: "userID"], targetID != user.id {
            _ = try await SharingAccess(user: user, db: req.db).require(project, role: .manage)
            guard let target = try await User.find(targetID, on: req.db) else { throw Abort(.notFound) }
            return try await SharingAccess(user: target, db: req.db).visibility(project)
        }
        return try await SharingAccess(user: user, db: req.db).visibility(project)
    }
}
