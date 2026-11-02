import Fluent
import Vapor

/// Shared domain steps of grants and teams. REST (`SharingController`), MCP tools and confirmed actions all run these,
/// so rights checks, validation and sync entries stay identical.
enum SharingOperations {
    /// Runs `operation` and records the visibility changes. The caller already holds the sharing-graph lock inside a transaction.
    static func recorded<T: Sendable>(user: User, db: any Database,
        _ operation: @Sendable (SharingAccess) async throws -> T) async throws -> T {
        let before = try await SyncRecorder.visibility(on: db)
        let result = try await operation(SharingAccess(user: user, db: db))
        try await SyncRecorder.recordVisibilityChanges(from: before, on: db)
        return result
    }

    /// Transaction + sharing-graph lock + sync entries (all sharing mutations and planning writes take the same lock).
    static func write<T: Sendable>(user: User, db: any Database,
        _ operation: @escaping @Sendable (SharingAccess) async throws -> T) async throws -> T {
        try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            return try await recorded(user: user, db: tx, operation)
        }
    }

    static func createTeam(_ access: SharingAccess, name raw: String) async throws -> Team {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw Abort(.badRequest, reason: "invalid_name") }
        let team = Team(name: name, founderID: try access.user.requireID())
        try await team.save(on: access.db)
        try await TeamMembership(teamID: team.requireID(), userID: access.user.requireID(), isAdmin: true, accepted: true).save(on: access.db)
        return team
    }

    static func inviteMember(_ access: SharingAccess, teamID: UUID, userID: UUID, isAdmin: Bool) async throws -> TeamMembership {
        let team = try await access.requireTeam(teamID, admin: true)
        guard let invitee = try await User.find(userID, on: access.db) else { throw Abort(.notFound) }
        if invitee.isLocked { throw Abort(.conflict, reason: "account_disabled") }
        if userID == team.founderID && !isAdmin { throw Abort(.conflict, reason: "team_founder_required") }
        let member = try await TeamMembership.query(on: access.db).filter(\.$teamID == teamID).filter(\.$userID == userID).first()
            ?? TeamMembership(teamID: teamID, userID: userID)
        member.isAdmin = isAdmin
        try await member.save(on: access.db)
        return member
    }

    static func putGrant(_ access: SharingAccess, projectID: UUID, principalType: String, principalID: UUID, role: ProjectRole) async throws -> GrantDTO {
        _ = try await ProjectAccess(user: access.user, db: access.db).project(projectID, role: .manage)
        try await access.validatePrincipal(type: principalType, id: principalID)
        let grant = try await ProjectGrant.query(on: access.db).filter(\.$projectID == projectID)
            .filter(\.$principalType == principalType).filter(\.$principalID == principalID).first()
            ?? ProjectGrant(projectID: projectID, principalType: principalType, principalID: principalID, role: role)
        grant.role = role
        try await grant.save(on: access.db)
        return try await GrantDTO(grant, on: access.db)
    }

    static func deleteGrant(_ access: SharingAccess, projectID: UUID, grantID: UUID) async throws {
        _ = try await ProjectAccess(user: access.user, db: access.db).project(projectID, role: .manage)
        guard let grant = try await ProjectGrant.find(grantID, on: access.db), grant.projectID == projectID else { throw Abort(.notFound) }
        try await grant.delete(on: access.db)
    }

    /// Project plus all descendants (a grant on a project is inherited by its sub-projects).
    static func subtree(of root: UUID, on db: any Database) async throws -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for p in try await Project.query(on: db).all() {
            if let parent = p.parentID, let pid = p.id { children[parent, default: []].append(pid) }
        }
        var result: Set<UUID> = [root]
        var queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where result.insert(child).inserted { queue.append(child) }
        }
        return result
    }

    /// People the account already works with on this project: itself, the owner, existing grantees and members of its accepted teams.
    /// Everyone else is a stranger; sharing a project with a stranger needs the person's confirmation.
    static func isKnownPerson(_ id: UUID, project: Project, access: SharingAccess) async throws -> Bool {
        let me = try access.user.requireID()
        if id == me || id == project.ownerID { return true }
        let pid = try project.requireID()
        if let sharing = try await ProjectSharing.query(on: access.db).filter(\.$projectID == pid).first(),
           sharing.ownerType == "person", sharing.ownerID == id { return true }
        if try await ProjectGrant.query(on: access.db).filter(\.$projectID == pid).filter(\.$principalType == "person")
            .filter(\.$principalID == id).first() != nil { return true }
        let mine = try await access.memberships().map(\.teamID)
        guard !mine.isEmpty else { return false }
        return try await TeamMembership.query(on: access.db).filter(\.$userID == id).filter(\.$accepted == true)
            .filter(\.$teamID ~~ mine).first() != nil
    }

    /// Why a grant cannot be set directly by a connection (nil = direct execution is fine).
    static func grantNeedsConfirmation(_ access: SharingAccess, project: Project, principalType: String, principalID: UUID,
        role: ProjectRole, grantedProjects: Set<UUID>) async throws -> Bool {
        if role == .manage { return true }
        if principalType == "person", !(try await isKnownPerson(principalID, project: project, access: access)) { return true }
        return !(try await subtree(of: project.requireID(), on: access.db)).isSubset(of: grantedProjects)
    }
}

extension ConfirmableActions {
    private static func uuid(_ args: [String: String], _ key: String) throws -> UUID {
        guard let raw = args[key], let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return id
    }
    private static func parsedRole(_ args: [String: String]) throws -> ProjectRole {
        guard let raw = args["role"], let role = ProjectRole(rawValue: raw) else { throw Abort(.badRequest, reason: "invalid_role") }
        return role
    }
    private static func principalName(_ type: String, _ id: UUID, on db: any Database) async throws -> String {
        let name = type == "team" ? try await Team.find(id, on: db)?.name : try await User.find(id, on: db)?.displayName
        return name ?? "?"
    }
    private static func checkVersion(_ args: [String: String], _ project: Project) throws {
        if let raw = args["version"], let v = Int(raw), v != project.version { throw Abort(.conflict, reason: "version_conflict") }
    }

    static let setProjectGrant = ConfirmableAction(
        tool: "set_project_grant",
        describe: { args, user, db in
            let projectID = try uuid(args, "projectID"), principalID = try uuid(args, "principalID")
            let role = try parsedRole(args)
            guard let type = args["principalType"], ["person", "team"].contains(type) else { throw Abort(.badRequest, reason: "invalid_principal") }
            let project = try await ProjectAccess(user: user, db: db).project(projectID, role: .manage)
            try checkVersion(args, project)
            try await SharingAccess(user: user, db: db).validatePrincipal(type: type, id: principalID)
            let subs = try await SharingOperations.subtree(of: projectID, on: db).count - 1
            let name = try await principalName(type, principalID, on: db)
            var text = "Projekt „\(project.name)“ für \(type == "team" ? "das Team" : "") „\(name)“ mit der Rolle \(role.rawValue) freigeben"
            if subs > 0 { text += " (gilt auch für \(subs) Unterprojekt\(subs == 1 ? "" : "e"))" }
            return .init(summary: text, impact: ActionImpact(targetType: "project", targetID: projectID, targetName: project.name,
                subprojects: subs, destructive: false), projectIDs: [projectID])
        },
        execute: { args, user, db in
            let projectID = try uuid(args, "projectID"), principalID = try uuid(args, "principalID")
            let role = try parsedRole(args)
            let type = args["principalType"] ?? ""
            let project = try await ProjectAccess(user: user, db: db).project(projectID, role: .manage)
            try checkVersion(args, project)
            _ = try await SharingOperations.recorded(user: user, db: db) { access in
                try await SharingOperations.putGrant(access, projectID: projectID, principalType: type, principalID: principalID, role: role)
            }
            return "grant_set"
        },
        requiredScope: "sharing:write")

    static let revokeProjectGrant = ConfirmableAction(
        tool: "revoke_project_grant",
        describe: { args, user, db in
            let projectID = try uuid(args, "projectID"), grantID = try uuid(args, "grantID")
            let project = try await ProjectAccess(user: user, db: db).project(projectID, role: .manage)
            try checkVersion(args, project)
            guard let grant = try await ProjectGrant.find(grantID, on: db), grant.projectID == projectID else { throw Abort(.notFound) }
            let name = try await principalName(grant.principalType, grant.principalID, on: db)
            return .init(summary: "Freigabe von „\(name)“ (\(grant.role.rawValue)) am Projekt „\(project.name)“ entziehen",
                impact: ActionImpact(targetType: "project", targetID: projectID, targetName: project.name, destructive: true), projectIDs: [projectID])
        },
        execute: { args, user, db in
            let projectID = try uuid(args, "projectID"), grantID = try uuid(args, "grantID")
            let project = try await ProjectAccess(user: user, db: db).project(projectID, role: .manage)
            try checkVersion(args, project)
            try await SharingOperations.recorded(user: user, db: db) { access in
                try await SharingOperations.deleteGrant(access, projectID: projectID, grantID: grantID)
            }
            return "grant_revoked"
        },
        requiredScope: "sharing:write")

    /// Only used for admin invitations (an admin can later share team-owned projects); plain invitations run directly.
    static let inviteTeamAdmin = ConfirmableAction(
        tool: "invite_team_member",
        describe: { args, user, db in
            let teamID = try uuid(args, "teamID"), userID = try uuid(args, "userID")
            let team = try await SharingAccess(user: user, db: db).requireTeam(teamID, admin: true)
            guard let invitee = try await User.find(userID, on: db) else { throw Abort(.notFound) }
            if invitee.isLocked { throw Abort(.conflict, reason: "account_disabled") }
            let isAdmin = args["isAdmin"] == "true"
            return .init(summary: "„\(invitee.displayName)“ in das Team „\(team.name)“ einladen\(isAdmin ? " (als Admin)" : "")",
                impact: ActionImpact(targetType: "team", targetID: teamID, targetName: team.name, destructive: false), projectIDs: [])
        },
        execute: { args, user, db in
            let teamID = try uuid(args, "teamID"), userID = try uuid(args, "userID")
            _ = try await SharingOperations.recorded(user: user, db: db) { access in
                try await SharingOperations.inviteMember(access, teamID: teamID, userID: userID, isAdmin: args["isAdmin"] == "true")
            }
            return "invited"
        },
        requiredScope: "teams:write")

    static let sharingActions: [ConfirmableAction] = [setProjectGrant, revokeProjectGrant, inviteTeamAdmin]
}

extension MCPController {
    static let sharingTools: [Tool] = [
        Tool(name: "list_project_grants", scope: "sharing:read",
             description: "List who a project is shared with (person or team, role read|comment|edit|manage). Needs manage rights on the project, which must be in this connection's grant.",
             properties: ["projectID": Schema.uuid("Project id.")], required: ["projectID"]),
        Tool(name: "get_project_visibility", scope: "sharing:read",
             description: "Effective rights on a project: your role (read|comment|edit|manage), whether you own it, can delete it, whether it inherits grants from its parent. With userID (manage rights needed) the same for another person.",
             properties: ["projectID": Schema.uuid("Project id."), "userID": Schema.uuid("Optional other person; needs manage rights.")], required: ["projectID"]),
        Tool(name: "set_project_grant", scope: "sharing:write",
             description: "Share a project with a person or team or change their role (needs manage rights; the project must be in this connection's grant). This never widens the connection itself. Runs directly for your own teams and for people you already work with on the project (owner, grantees, members of your teams) with roles read|comment|edit. Role manage, strangers, and projects with sub-projects outside this connection's grant are turned into a confirmation request instead." + confirmationNote,
             properties: ["projectID": Schema.uuid("Project id."), "principalType": Schema.string("person or team.", values: ["person", "team"]),
                          "principalID": Schema.uuid("Id of the person or team (team: you must be an accepted member)."),
                          "role": Schema.string("Role to give.", values: ProjectRole.allCases.map(\.rawValue))],
             required: ["projectID", "principalType", "principalID", "role"]),
        Tool(name: "revoke_project_grant", scope: "sharing:write",
             description: "Withdraw a project share (needs manage rights)." + confirmationNote,
             properties: ["projectID": Schema.uuid("Project id."), "grantID": Schema.uuid("Grant id from list_project_grants."),
                          "version": Schema.integer("Optional current project version; a stale version fails with version_conflict when the user confirms.", min: 1)],
             required: ["projectID", "grantID"]),
        Tool(name: "list_teams", scope: "teams:read",
             description: "List the teams you are an accepted member of, with your admin flag and the founder."),
        Tool(name: "list_team_members", scope: "teams:read",
             description: "List the members of one of your teams with display name, admin flag and whether the invitation was accepted.",
             properties: ["teamID": Schema.uuid("Team id (you must be an accepted member).")], required: ["teamID"]),
        Tool(name: "create_team", scope: "teams:write",
             description: "Create a team; you become its founder and admin. A team grants no access to anything by itself.",
             properties: ["name": Schema.string("Team name, 1 to 200 characters.", maxLength: 200)], required: ["name"]),
        Tool(name: "invite_team_member", scope: "teams:write",
             description: "Invite a person to a team you administer. The person has to accept in Todolino; until then they have no access. Inviting as admin is turned into a confirmation request instead." + confirmationNote,
             properties: ["teamID": Schema.uuid("Team id."), "userID": Schema.uuid("Account id of the person."),
                          "isAdmin": Schema.boolean("Invite as team admin (default false; true needs confirmation).")],
             required: ["teamID", "userID"]),
    ]

    private struct TeamSummary: Encodable { let id: UUID; let name: String; let founderID: UUID; let isAdmin: Bool }

    func callSharing(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        guard let tool = Self.sharingTools.first(where: { $0.name == name }), grant.scopes.contains(tool.scope) else { throw Abort(.forbidden, reason: "insufficient_scope") }
        func role() throws -> ProjectRole {
            guard let raw = a["role"].string, let r = ProjectRole(rawValue: raw) else { throw Abort(.badRequest, reason: "invalid_role") }
            return r
        }
        func principalType() throws -> String {
            guard let t = a["principalType"].string, ["person", "team"].contains(t) else { throw Abort(.badRequest, reason: "invalid_principal") }
            return t
        }
        func confirm(_ tool: String, _ args: [String: String]) async throws -> JSONValue {
            let label = try await OAuthClient.find(grant.clientID, on: db)?.name
            let request = try await ActionRequestService.create(tool: tool, args: args, user: user, grant: grant, label: label, on: db)
            throw ConfirmationRequired(requestID: try request.requireID())
        }
        switch name {
        case "list_project_grants":
            let pid = try uuid(a["projectID"])
            _ = try await project(pid, user: user, grant: grant, db: db, role: .manage)
            var result: [GrantDTO] = []
            for g in try await ProjectGrant.query(on: db).filter(\.$projectID == pid).sort(\.$id).limit(200).all() {
                result.append(try await GrantDTO(g, on: db))
            }
            return try .encoded(result)
        case "get_project_visibility":
            let pid = try uuid(a["projectID"])
            let p = try await project(pid, user: user, grant: grant, db: db)
            if let target = try optionalUUID(a, "userID"), target != user.id {
                _ = try await SharingAccess(user: user, db: db).require(p, role: .manage)
                guard let other = try await User.find(target, on: db) else { throw Abort(.notFound) }
                return try .encoded(try await SharingAccess(user: other, db: db).visibility(p))
            }
            return try .encoded(try await SharingAccess(user: user, db: db).visibility(p))
        case "set_project_grant":
            let pid = try uuid(a["projectID"]), principalID = try uuid(a["principalID"])
            let type = try principalType(), r = try role()
            let p = try await project(pid, user: user, grant: grant, db: db, role: .manage)
            let args = ["projectID": pid.uuidString, "principalType": type, "principalID": principalID.uuidString, "role": r.rawValue]
            let access = SharingAccess(user: user, db: db)
            try await access.validatePrincipal(type: type, id: principalID)
            let needsConfirmation = try await SharingOperations.grantNeedsConfirmation(access, project: p, principalType: type,
                principalID: principalID, role: r, grantedProjects: Set(grant.projects))
            if needsConfirmation { return try await confirm(name, args) }
            let granted = Set(grant.projects)
            let dto = try await SharingOperations.write(user: user, db: db) { access in
                guard granted.contains(pid) else { throw Abort(.notFound) }
                return try await SharingOperations.putGrant(access, projectID: pid, principalType: type, principalID: principalID, role: r)
            }
            return try .encoded(dto)
        case "revoke_project_grant":
            let pid = try uuid(a["projectID"]), gid = try uuid(a["grantID"])
            _ = try await project(pid, user: user, grant: grant, db: db, role: .manage)
            var args = ["projectID": pid.uuidString, "grantID": gid.uuidString]
            if let v = try intArgument(a["version"], reason: "invalid_version") {
                guard v > 0 else { throw Abort(.badRequest, reason: "invalid_version") }
                args["version"] = String(v)
            }
            return try await confirm(name, args)
        case "list_teams":
            let access = SharingAccess(user: user, db: db)
            let memberships = try await access.memberships()
            guard !memberships.isEmpty else { return .array([]) }
            let admin = Dictionary(uniqueKeysWithValues: memberships.map { ($0.teamID, $0.isAdmin) })
            let teams = try await Team.query(on: db).filter(\.$id ~~ memberships.map(\.teamID)).sort(\.$name).limit(200).all()
            return try .encoded(teams.map { TeamSummary(id: $0.id!, name: $0.name, founderID: $0.founderID, isAdmin: admin[$0.id!] ?? false) })
        case "list_team_members":
            let tid = try uuid(a["teamID"])
            _ = try await SharingAccess(user: user, db: db).requireTeam(tid)
            let members = try await TeamMembership.query(on: db).filter(\.$teamID == tid).sort(\.$id).limit(500).all()
            let names = try await displayNames(members.map(\.userID), on: db)
            return try .encoded(members.map { try TeamMembershipDTO($0, teamName: nil, displayName: names[$0.userID]) })
        case "create_team":
            guard let raw = a["name"].string else { throw Abort(.badRequest, reason: "invalid_name") }
            let team = try await SharingOperations.write(user: user, db: db) { try await SharingOperations.createTeam($0, name: raw) }
            return try .encoded(TeamSummary(id: try team.requireID(), name: team.name, founderID: team.founderID, isAdmin: true))
        case "invite_team_member":
            let tid = try uuid(a["teamID"]), uid = try uuid(a["userID"])
            let isAdmin = try optionalBool(a, "isAdmin") ?? false
            if isAdmin { return try await confirm(name, ["teamID": tid.uuidString, "userID": uid.uuidString, "isAdmin": "true"]) }
            let member = try await SharingOperations.write(user: user, db: db) { try await SharingOperations.inviteMember($0, teamID: tid, userID: uid, isAdmin: false) }
            let names = try await displayNames([uid], on: db)
            return try .encoded(try TeamMembershipDTO(member, teamName: nil, displayName: names[uid]))
        default: throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }
}
