import Fluent
import Vapor

/// Admin hands over the projects of a locked or anonymized account to an active person or a team (docs/VERWALTUNG.md).
/// Same ownership rule as `PUT /projects/{id}/owner`: the `ProjectSharing` overlay carries the owner, runner access of
/// the former owner ends. Grants of other people stay as they are; nothing is widened.
enum ProjectTransfer {
    struct Target: Content { let type: String; let id: UUID }
    struct Input: Content { let to: Target; let projectIDs: [UUID]? }
    struct Row: Content {
        let id: UUID, name: String, taskCount: Int
        let parentID: UUID?, parentName: String?
    }
    struct Moved: Content { let id: UUID, name: String }
    struct Result: Content { let transferred: Int; let projects: [Moved]; let to: Target }
    struct AdminTeam: Content { let id: UUID, name: String, activeAdmins: Int }

    /// Projects whose effective owner is this person (the sharing overlay wins over `projects.owner_id`).
    static func owned(by uid: UUID, on db: any Database) async throws -> [Project] {
        let created = try await Project.query(on: db).filter(\.$ownerID == uid).all()
        let createdIDs = try created.map { try $0.requireID() }
        let overlays = createdIDs.isEmpty ? [] : try await ProjectSharing.query(on: db).filter(\.$projectID ~~ createdIDs).all()
        let overridden = Set(overlays.map(\.projectID))
        let handedBack = try await ProjectSharing.query(on: db).filter(\.$ownerType == "person").filter(\.$ownerID == uid).all().map(\.projectID)
        var result = try created.filter { !overridden.contains(try $0.requireID()) }
        let have = Set(try result.map { try $0.requireID() })
        for id in handedBack where !have.contains(id) {
            if let p = try await Project.find(id, on: db) { result.append(p) }
        }
        return result.sorted { ($0.name, $0.id?.uuidString ?? "") < ($1.name, $1.id?.uuidString ?? "") }
    }

    static func requireLocked(_ id: UUID, on db: any Database) async throws -> User {
        guard let user = try await User.find(id, on: db) else { throw Abort(.notFound) }
        guard user.isLocked else {
            throw SettingsProblem(code: "account_not_disabled", key: nil, message: "Projekte lassen sich nur von gesperrten oder anonymisierten Konten übertragen.")
        }
        return user
    }

    static func list(for uid: UUID, on db: any Database) async throws -> [Row] {
        _ = try await requireLocked(uid, on: db)
        let projects = try await owned(by: uid, on: db)
        var rows: [Row] = []
        for p in projects {
            let pid = try p.requireID()
            let parentName = try await p.parentID.asyncFlatMap { try await Project.find($0, on: db)?.name }
            rows.append(Row(id: pid, name: p.name, taskCount: try await TodoTask.query(on: db).filter(\.$projectID == pid).count(),
                            parentID: p.parentID, parentName: parentName))
        }
        return rows
    }

    /// Teams that can receive projects: at least one accepted administrator with an active account.
    static func teams(on db: any Database) async throws -> [AdminTeam] {
        let admins = try await TeamMembership.query(on: db).filter(\.$isAdmin == true).filter(\.$accepted == true).all()
        let userIDs = Array(Set(admins.map(\.userID)))
        let users = userIDs.isEmpty ? [] : try await User.query(on: db).filter(\.$id ~~ userIDs).all()
        let lockedIDs = Set(users.filter(\.isLocked).compactMap(\.id))
        var active: [UUID: Int] = [:]
        for m in admins where !lockedIDs.contains(m.userID) { active[m.teamID, default: 0] += 1 }
        guard !active.isEmpty else { return [] }
        return try await Team.query(on: db).filter(\.$id ~~ Array(active.keys)).sort(\.$name).all()
            .map { AdminTeam(id: try $0.requireID(), name: $0.name, activeAdmins: active[try $0.requireID()] ?? 0) }
    }

    static func transfer(from uid: UUID, input: Input, actor: User, on database: any Database) async throws -> Result {
        guard ["person", "team"].contains(input.to.type) else { throw Abort(.badRequest, reason: "invalid_principal") }
        return try await database.transaction { db in
            try await lockSharingGraph(on: db)
            let before = try await SyncRecorder.visibility(on: db)
            _ = try await requireLocked(uid, on: db)
            try await validateTarget(input.to, on: db)

            let owned = try await owned(by: uid, on: db)
            let ownedIDs = Set(try owned.map { try $0.requireID() })
            var chosen = Set<UUID>()
            if let ids = input.projectIDs, !ids.isEmpty {
                for id in ids {
                    guard ownedIDs.contains(id) else {
                        throw SettingsProblem(code: "project_not_owned", key: nil, message: "Ein ausgewähltes Projekt gehört dem gesperrten Konto nicht (mehr).")
                    }
                    chosen.insert(id)
                }
                // Sub-projects follow their parent, but only those the locked account owns as well.
                var grew = true
                while grew {
                    grew = false
                    for p in owned {
                        let id = try p.requireID()
                        if !chosen.contains(id), let parent = p.parentID, chosen.contains(parent) { chosen.insert(id); grew = true }
                    }
                }
            } else {
                chosen = ownedIDs
            }

            var moved: [Moved] = []
            for p in owned {
                let pid = try p.requireID()
                guard chosen.contains(pid) else { continue }
                let policy = try await ProjectSharing.query(on: db).filter(\.$projectID == pid).first() ?? ProjectSharing(project: p)
                policy.ownerType = input.to.type; policy.ownerID = input.to.id
                try await policy.save(on: db)
                try await AgentService.revokeRunnerAccess(projectID: pid, on: db)
                p.version += 1
                try await p.save(on: db)
                moved.append(Moved(id: pid, name: p.name))
            }
            try await SyncRecorder.recordVisibilityChanges(from: before, on: db)

            let e = ServerSettingAudit()
            e.settingKey = "admin.transfer"; e.action = "account"; e.actorID = actor.id; e.actorName = actor.displayName
            e.detail = "transfer:\(uid.uuidString.lowercased()):\(input.to.type):\(input.to.id.uuidString.lowercased()):\(moved.count)"
            try await e.save(on: db)
            return Result(transferred: moved.count, projects: moved, to: input.to)
        }
    }

    private static func validateTarget(_ to: Target, on db: any Database) async throws {
        switch to.type {
        case "person":
            guard let person = try await User.find(to.id, on: db) else { throw Abort(.notFound) }
            if person.isLocked {
                throw SettingsProblem(code: "transfer_target_disabled", key: nil, message: "Das Ziel-Konto ist gesperrt. Wähle eine aktive Person oder ein Team.")
            }
        default:
            guard try await Team.find(to.id, on: db) != nil else { throw Abort(.notFound) }
            guard try await teams(on: db).contains(where: { $0.id == to.id }) else {
                throw SettingsProblem(code: "team_without_active_admin", key: nil, message: "Das Team hat keinen aktiven Administrator. Wähle ein anderes Team.")
            }
        }
    }
}

struct ProjectTransferController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("v1", "admin").grouped(SettingsProblemMiddleware())
        admin.get("users", ":id", "projects", use: list)
        admin.post("users", ":id", "transfer-projects", use: transfer)
        admin.get("teams", use: teams)
    }

    private func userID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    @Sendable func list(_ req: Request) async throws -> [ProjectTransfer.Row] {
        _ = try await req.requireAdmin()
        return try await ProjectTransfer.list(for: userID(req), on: req.db)
    }

    @Sendable func transfer(_ req: Request) async throws -> ProjectTransfer.Result {
        let actor = try await req.requireAdmin()
        let input = try req.content.decode(ProjectTransfer.Input.self)
        return try await ProjectTransfer.transfer(from: userID(req), input: input, actor: actor, on: req.db)
    }

    @Sendable func teams(_ req: Request) async throws -> [ProjectTransfer.AdminTeam] {
        _ = try await req.requireAdmin()
        return try await ProjectTransfer.teams(on: req.db)
    }
}
