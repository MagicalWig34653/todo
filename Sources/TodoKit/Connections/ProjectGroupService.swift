import Fluent
import SQLKit
import Vapor

struct ProjectGroupDTO: Content {
    let id: UUID
    let name: String
    /// Members the person can read now.
    let projectIDs: [UUID]
}

/// How a group change moves the reach of one connection or mandate of the person.
struct SelectionChangeDTO: Content {
    /// `mandate` | `connection`
    let kind: String
    let grantID: UUID
    let name: String
    let added: [UUID]
    let removed: [UUID]
}

struct ProjectGroupListResponse: Content { let groups: [ProjectGroupDTO] }
/// `group` is absent after a delete.
struct ProjectGroupChangeResponse: Content { let group: ProjectGroupDTO?; let changes: [SelectionChangeDTO] }
struct ProjectGroupInput: Content { var name: String?; var projectIDs: [UUID]? }
struct ProjectGroupsOfProject: Content { let groupIDs: [UUID]; let changes: [SelectionChangeDTO] }
struct ProjectGroupsOfProjectInput: Content { var groupIDs: [UUID] }
struct SelectionPreviewInput: Content { var projectIDs: [UUID]; var selection: SelectionInput? }
struct SelectionPreviewResponse: Content {
    /// What the selection reaches now.
    let projectIDs: [UUID]
    /// Own projects that "all" leaves out because a connection created them.
    let agentCreatedProjectIDs: [UUID]
}

/// ADR 0037: project groups of one person. Every write runs through `change`, which locks the person's mandates and
/// connections (the lock order of decisions: mandate, grant, groups), compares their reach before and after and writes the
/// audit rows of mandates. `dryRun` does the same and rolls back: the preview cannot drift from the real change.
enum ProjectGroupService {
    private struct Rollback<T: Sendable>: Error { let value: T; let changes: [SelectionChangeDTO] }

    private struct Subject {
        let kind: String
        let id: UUID
        let grantID: UUID
        let name: String
        let explicit: [UUID]
    }

    static func lock(userID: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        guard sql.dialect.name != "sqlite" else { return }
        for table in [BrainMandate.schema, OAuthGrant.schema] {
            // No ORDER BY id: MariaDB would then walk the whole primary key when the person owns most rows and lock other
            // people's rows (proven by testGroupChangeLocksOnlyThePersonsRows). The index starting with user_id keeps a
            // stable order; two group changes are serialised by the sharing lock anyway.
            _ = try await sql.raw("SELECT id FROM \(ident: table) WHERE user_id = \(bind: userID) FOR UPDATE").all()
        }
    }

    /// Active mandates and live connections of the person that carry a rule (only those depend on groups).
    private static func reach(userID: UUID, on db: any Database) async throws -> [(Subject, Set<UUID>)] {
        let ruled = Set(try await ProjectSelectionRow.query(on: db).filter(\.$userID == userID).all().compactMap(\.id))
        guard !ruled.isEmpty else { return [] }
        let grants = try await OAuthGrant.query(on: db).filter(\.$userID == userID).filter(\.$revoked == false).all()
        let clients = try await ConnectionService.clientNames(grants, on: db)
        var subjects: [Subject] = []
        for g in grants {
            let gid = try g.requireID(), name = ConnectionNames.display(g, clientName: clients[g.clientID])
            if ruled.contains(gid) { subjects.append(Subject(kind: "connection", id: gid, grantID: gid, name: name, explicit: g.explicitProjects)) }
            for m in try await BrainMandate.query(on: db).filter(\.$userID == userID).filter(\.$grantID == gid).filter(\.$revokedAt == .null).all() {
                let mid = try m.requireID()
                if ruled.contains(mid) { subjects.append(Subject(kind: "mandate", id: mid, grantID: gid, name: name, explicit: m.explicitProjects)) }
            }
        }
        var resolver = ProjectSelectionResolver(userID: userID, db: db)
        var out: [(Subject, Set<UUID>)] = []
        for s in subjects.sorted(by: { ($0.kind, $0.name, $0.id.uuidString) < ($1.kind, $1.name, $1.id.uuidString) }) {
            out.append((s, Set(try await resolver.resolve(explicit: s.explicit, rule: try await resolver.rule(of: s.id)))))
        }
        return out
    }

    /// `body` returns its result and the text for the protocol.
    private static func change<T: Sendable>(user: User, dryRun: Bool, db: any Database,
                                            _ body: @escaping @Sendable (any Database, UUID) async throws -> (T, String)) async throws -> (T, [SelectionChangeDTO]) {
        let userID = try user.requireID()
        do {
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                try await lock(userID: userID, on: tx)
                let before = try await reach(userID: userID, on: tx)
                let (value, note) = try await body(tx, userID)
                var after = Dictionary(uniqueKeysWithValues: try await reach(userID: userID, on: tx).map { ($0.0.id, $0.1) })
                var changes: [SelectionChangeDTO] = []
                let now = Date()
                for (subject, old) in before {
                    // A rule that became plain has no row any more: its reach is the explicit list now.
                    var new = after.removeValue(forKey: subject.id)
                    if new == nil {
                        var resolver = ProjectSelectionResolver(userID: userID, db: tx)
                        new = Set(try await resolver.resolve(explicit: subject.explicit, rule: nil))
                    }
                    let added = (new ?? []).subtracting(old).sorted { $0.uuidString < $1.uuidString }
                    let removed = old.subtracting(new ?? []).sorted { $0.uuidString < $1.uuidString }
                    guard !added.isEmpty || !removed.isEmpty else { continue }
                    changes.append(SelectionChangeDTO(kind: subject.kind, grantID: subject.grantID, name: subject.name, added: added, removed: removed))
                    guard subject.kind == "mandate", !dryRun else { continue }
                    for (kind, ids) in [("mandate.group_added", added), ("mandate.group_removed", removed)] {
                        for projectID in ids {
                            let row = BrainConnectionAudit()
                            row.mandateID = subject.id; row.userID = userID; row.grantID = subject.grantID; row.targetGrantID = subject.grantID
                            row.kind = kind; row.projectID = projectID; row.quote = note; row.createdAt = now
                            try await row.save(on: tx)
                        }
                    }
                }
                if dryRun { throw Rollback(value: value, changes: changes) }
                return (value, changes)
            }
        } catch let rollback as Rollback<T> {
            return (rollback.value, rollback.changes)
        }
    }

    private static func own(_ id: UUID, userID: UUID, on db: any Database) async throws -> ProjectGroup {
        guard let g = try await ProjectGroup.find(id, on: db), g.userID == userID else { throw Abort(.notFound) }
        return g
    }

    private static func dto(_ g: ProjectGroup, on db: any Database) async throws -> ProjectGroupDTO {
        var resolver = ProjectSelectionResolver(userID: g.userID, db: db)
        let id = try g.requireID()
        let members = try await resolver.resolve(explicit: [], rule: SelectionRule(groupIDs: [id]))
        return ProjectGroupDTO(id: id, name: g.name, projectIDs: members)
    }

    static func list(user: User, db: any Database) async throws -> [ProjectGroupDTO] {
        let groups = try await ProjectGroup.query(on: db).filter(\.$userID == user.requireID()).sort(\.$nameKey).all()
        var out: [ProjectGroupDTO] = []
        for g in groups { out.append(try await dto(g, on: db)) }
        return out
    }

    private static func apply(name: String?, to g: ProjectGroup, on db: any Database) async throws {
        guard let clean = ConnectionNames.clean(name) else { throw Abort(.badRequest, reason: "invalid_name") }
        let key = clean.lowercased()
        let clash = try await ProjectGroup.query(on: db).filter(\.$userID == g.userID).filter(\.$nameKey == key).first()
        guard clash == nil || clash?.id == g.id else { throw Abort(.conflict, reason: "name_taken") }
        g.name = clean; g.nameKey = key
    }

    /// Replaces the members. New ones must be readable by the person now; staying ones need no check, and members the
    /// person lost sight of are kept out of the list anyway.
    private static func setMembers(_ ids: [UUID], of g: ProjectGroup, user: User, on db: any Database) async throws {
        let wanted = Set(ids), gid = try g.requireID()
        guard wanted.count <= SelectionLimits.maxMembers else { throw Abort(.badRequest, reason: "invalid_projects") }
        let rows = try await ProjectGroupMember.query(on: db).filter(\.$groupID == gid).all()
        let present = Set(rows.map(\.projectID))
        for row in rows where !wanted.contains(row.projectID) { try await row.delete(on: db) }
        let access = ProjectAccess(user: user, db: db)
        for id in wanted.subtracting(present) {
            _ = try await access.project(id)
            try await ProjectGroupMember(groupID: gid, projectID: id).save(on: db)
        }
    }

    private static func note(_ names: [String]) -> String {
        "Projektgruppe geändert (Einstellungen): " + names.map { "„\($0)“" }.joined(separator: ", ")
    }

    static func create(_ input: ProjectGroupInput, user: User, db: any Database) async throws -> ProjectGroupChangeResponse {
        let (dto, changes) = try await change(user: user, dryRun: false, db: db) { tx, userID in
            guard try await ProjectGroup.query(on: tx).filter(\.$userID == userID).count() < SelectionLimits.maxGroups else {
                throw Abort(.badRequest, reason: "too_many_groups")
            }
            let g = ProjectGroup()
            g.userID = userID; g.createdAt = Date(); g.updatedAt = g.createdAt
            try await apply(name: input.name, to: g, on: tx)
            try await g.save(on: tx)
            try await setMembers(input.projectIDs ?? [], of: g, user: user, on: tx)
            return (try await Self.dto(g, on: tx), note([g.name]))
        }
        return ProjectGroupChangeResponse(group: dto, changes: changes)
    }

    static func update(_ id: UUID, _ input: ProjectGroupInput, dryRun: Bool, user: User, db: any Database) async throws -> ProjectGroupChangeResponse {
        let (dto, changes) = try await change(user: user, dryRun: dryRun, db: db) { tx, userID in
            let g = try await own(id, userID: userID, on: tx)
            if let name = input.name { try await apply(name: name, to: g, on: tx) }
            if let ids = input.projectIDs { try await setMembers(ids, of: g, user: user, on: tx) }
            g.updatedAt = Date(); try await g.save(on: tx)
            return (try await Self.dto(g, on: tx), note([g.name]))
        }
        return ProjectGroupChangeResponse(group: dto, changes: changes)
    }

    /// Deleting a group takes its projects out of every selection that included it. Where it was an exclusion, its current
    /// projects stay excluded one by one: a delete never widens.
    static func delete(_ id: UUID, dryRun: Bool, user: User, db: any Database) async throws -> ProjectGroupChangeResponse {
        let (_, changes) = try await change(user: user, dryRun: dryRun, db: db) { tx, userID in
            let g = try await own(id, userID: userID, on: tx)
            let resolver = ProjectSelectionResolver(userID: userID, db: tx, locking: true)
            let members = try await resolver.members(of: [id])
            for row in try await ProjectSelectionRow.query(on: tx).filter(\.$userID == userID).all() {
                var rule = row.rule
                guard rule.groupIDs.contains(id) || rule.excludedGroupIDs.contains(id) else { continue }
                if rule.excludedGroupIDs.contains(id) {
                    rule.excludedProjectIDs = Set(rule.excludedProjectIDs).union(members).sorted { $0.uuidString < $1.uuidString }
                }
                rule.groupIDs.removeAll { $0 == id }; rule.excludedGroupIDs.removeAll { $0 == id }
                // A plain rule is removed; the explicit list alone remains.
                try await resolver.store(rule, of: row.requireID())
            }
            try await ProjectGroupMember.query(on: tx).filter(\.$groupID == id).delete()
            let name = g.name
            try await g.delete(on: tx)
            return (true, note([name]))
        }
        return ProjectGroupChangeResponse(group: nil, changes: changes)
    }

    static func groups(ofProject projectID: UUID, user: User, db: any Database) async throws -> [UUID] {
        _ = try await ProjectAccess(user: user, db: db).project(projectID)
        let own = try await ProjectGroup.query(on: db).filter(\.$userID == user.requireID()).all().compactMap(\.id)
        guard !own.isEmpty else { return [] }
        return try await ProjectGroupMember.query(on: db).filter(\.$projectID == projectID).filter(\.$groupID ~~ own).all()
            .map(\.groupID).sorted { $0.uuidString < $1.uuidString }
    }

    /// The person's groups of one project (project settings and "new project").
    static func setGroups(ofProject projectID: UUID, _ groupIDs: [UUID], dryRun: Bool, user: User, db: any Database) async throws -> ProjectGroupsOfProject {
        let wanted = Set(groupIDs)
        let (ids, changes) = try await change(user: user, dryRun: dryRun, db: db) { tx, userID in
            _ = try await ProjectAccess(user: user, db: tx).project(projectID)
            let own = try await ProjectGroup.query(on: tx).filter(\.$userID == userID).sort(\.$nameKey).all()
            guard wanted.isSubset(of: Set(own.compactMap(\.id))) else { throw Abort(.notFound) }
            var touched: [String] = []
            for g in own {
                let gid = try g.requireID()
                let row = try await ProjectGroupMember.query(on: tx).filter(\.$groupID == gid).filter(\.$projectID == projectID).first()
                if wanted.contains(gid), row == nil {
                    guard try await ProjectGroupMember.query(on: tx).filter(\.$groupID == gid).count() < SelectionLimits.maxMembers else {
                        throw Abort(.badRequest, reason: "invalid_projects")
                    }
                    try await ProjectGroupMember(groupID: gid, projectID: projectID).save(on: tx); touched.append(g.name)
                } else if !wanted.contains(gid), let row {
                    try await row.delete(on: tx); touched.append(g.name)
                }
            }
            return (wanted.sorted { $0.uuidString < $1.uuidString }, note(touched))
        }
        return ProjectGroupsOfProject(groupIDs: ids, changes: changes)
    }

    static func preview(_ input: SelectionPreviewInput, user: User, db: any Database) async throws -> SelectionPreviewResponse {
        var resolver = ProjectSelectionResolver(userID: try user.requireID(), db: db)
        let rule = try await resolver.validate(input.selection, excludedLimit: .max)
        guard input.projectIDs.count <= BrainMandateLimits.maxProjects else { throw Abort(.badRequest, reason: "invalid_projects") }
        let ids = try await resolver.resolve(explicit: input.projectIDs, rule: rule)
        return SelectionPreviewResponse(projectIDs: ids, agentCreatedProjectIDs: try await resolver.leftOutByAll(explicit: input.projectIDs, rule: rule))
    }
}

/// Person sessions only (`requireUser`); there is deliberately no MCP tool that writes groups.
struct ProjectGroupController: RouteCollection {
    private struct DryRun: Content { var dryRun: Bool? }
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("project-groups", use: list)
        v1.post("project-groups", use: create)
        v1.patch("project-groups", ":id", use: update)
        v1.delete("project-groups", ":id", use: remove)
        v1.get("projects", ":id", "groups", use: ofProject)
        v1.put("projects", ":id", "groups", use: setOfProject)
        v1.post("project-selection", "preview", use: preview)
    }
    private func uuid(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }
    private func dryRun(_ req: Request) -> Bool { (try? req.query.decode(DryRun.self).dryRun) == true }
    @Sendable func list(_ req: Request) async throws -> ProjectGroupListResponse {
        ProjectGroupListResponse(groups: try await ProjectGroupService.list(user: req.requireUser(), db: req.db))
    }
    @Sendable func create(_ req: Request) async throws -> ProjectGroupChangeResponse {
        let user = try await req.requireUser()
        return try await ProjectGroupService.create(req.content.decode(ProjectGroupInput.self), user: user, db: req.db)
    }
    @Sendable func update(_ req: Request) async throws -> ProjectGroupChangeResponse {
        let user = try await req.requireUser()
        return try await ProjectGroupService.update(uuid(req), req.content.decode(ProjectGroupInput.self), dryRun: dryRun(req), user: user, db: req.db)
    }
    @Sendable func remove(_ req: Request) async throws -> ProjectGroupChangeResponse {
        let user = try await req.requireUser()
        return try await ProjectGroupService.delete(uuid(req), dryRun: dryRun(req), user: user, db: req.db)
    }
    @Sendable func ofProject(_ req: Request) async throws -> ProjectGroupsOfProject {
        let user = try await req.requireUser()
        return ProjectGroupsOfProject(groupIDs: try await ProjectGroupService.groups(ofProject: uuid(req), user: user, db: req.db), changes: [])
    }
    @Sendable func setOfProject(_ req: Request) async throws -> ProjectGroupsOfProject {
        let user = try await req.requireUser()
        return try await ProjectGroupService.setGroups(ofProject: uuid(req), req.content.decode(ProjectGroupsOfProjectInput.self).groupIDs,
            dryRun: dryRun(req), user: user, db: req.db)
    }
    @Sendable func preview(_ req: Request) async throws -> SelectionPreviewResponse {
        let user = try await req.requireUser()
        return try await ProjectGroupService.preview(req.content.decode(SelectionPreviewInput.self), user: user, db: req.db)
    }
}
