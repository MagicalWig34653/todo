import Fluent
import FluentSQL
import SQLKit
import Vapor

/// ADR 0037 (card BEF08998, part 3): a connection's grant and a brain mandate select projects by an explicit list and,
/// optionally, a rule: groups, "all owned except", exclusions. THIS FILE is the only place that turns a selection into
/// projects; every check works on its result. Without a rule row the selection is the explicit list (the form before).
struct SelectionRule: Equatable, Codable, Sendable {
    static let selected = "selected", allExcept = "all_except"
    var mode: String = SelectionRule.selected
    var groupIDs: [UUID] = []
    var excludedProjectIDs: [UUID] = []
    var excludedGroupIDs: [UUID] = []
    /// Nothing beyond the explicit list: not stored.
    var isPlain: Bool { mode == Self.selected && groupIDs.isEmpty && excludedProjectIDs.isEmpty && excludedGroupIDs.isEmpty }
    /// Whether the selection names anything at all (an empty group still counts: it may get members).
    static func namesSomething(_ explicit: [UUID], _ rule: SelectionRule?) -> Bool {
        !explicit.isEmpty || rule.map { $0.mode == allExcept || !$0.groupIDs.isEmpty } == true
    }
}

/// The `selection` object of a request; absent keys mean empty.
struct SelectionInput: Content {
    var mode: String?
    var groupIDs: [UUID]?
    var excludedProjectIDs: [UUID]?
    var excludedGroupIDs: [UUID]?
}

/// The `selection` object of a response: the rule plus the explicitly chosen projects.
struct SelectionDTO: Content {
    let mode: String
    let projectIDs: [UUID]
    let groupIDs: [UUID]
    let excludedProjectIDs: [UUID]
    let excludedGroupIDs: [UUID]
    init?(explicit: [UUID], rule: SelectionRule?) {
        guard let rule else { return nil }
        mode = rule.mode; projectIDs = explicit; groupIDs = rule.groupIDs
        excludedProjectIDs = rule.excludedProjectIDs; excludedGroupIDs = rule.excludedGroupIDs
    }
}

enum SelectionLimits {
    static let maxGroups = 50
    static let maxMembers = 200
    static let maxExcluded = 500
}

// MARK: Models

/// A named set of projects, managed by the person only (REST with a session; agents can only read it).
final class ProjectGroup: Model, @unchecked Sendable {
    static let schema = "project_groups"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "name") var name: String
    /// Lowercased name; unique per person.
    @Field(key: "name_key") var nameKey: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class ProjectGroupMember: Model, @unchecked Sendable {
    static let schema = "project_group_members"
    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "project_id") var projectID: UUID
    init() {}
    init(groupID: UUID, projectID: UUID) { self.groupID = groupID; self.projectID = projectID }
}

/// The rule of one grant or mandate; `id` is the id of that grant or mandate.
final class ProjectSelectionRow: Model, @unchecked Sendable {
    static let schema = "project_selections"
    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "mode") var mode: String
    @Field(key: "group_ids") var groupIDs: [UUID]
    @Field(key: "excluded_project_ids") var excludedProjectIDs: [UUID]
    @Field(key: "excluded_group_ids") var excludedGroupIDs: [UUID]
    init() {}
    var rule: SelectionRule {
        SelectionRule(mode: mode, groupIDs: groupIDs, excludedProjectIDs: excludedProjectIDs, excludedGroupIDs: excludedGroupIDs)
    }
}

/// A project a connection created (MCP `create_project`). "All owned" never includes it: an agent must not widen another
/// connection's selection or a mandate by creating projects. The person includes it through a group or by choosing it.
final class AgentCreatedProject: Model, @unchecked Sendable {
    static let schema = "agent_created_projects"
    /// The project.
    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Field(key: "grant_id") var grantID: UUID
    init() {}
    init(projectID: UUID, grantID: UUID) { id = projectID; self.grantID = grantID }
}

/// Only new tables: existing grants and mandates stay byte for byte and keep their meaning (explicit list).
struct CreateProjectGroups: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ProjectGroup.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required).field("name_key", .string, .required)
            .field("created_at", .datetime, .required).field("updated_at", .datetime, .required)
            .unique(on: "user_id", "name_key").create()
        try await db.schema(ProjectGroupMember.schema).id()
            .field("group_id", .uuid, .required, .references(ProjectGroup.schema, "id", onDelete: .cascade))
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .unique(on: "group_id", "project_id").create()
        try await db.schema(ProjectSelectionRow.schema).field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("mode", .string, .required).field("group_ids", .json, .required)
            .field("excluded_project_ids", .json, .required).field("excluded_group_ids", .json, .required).create()
        try await db.schema(AgentCreatedProject.schema)
            .field("id", .uuid, .identifier(auto: false), .references("projects", "id", onDelete: .cascade))
            .field("grant_id", .uuid, .required).create()
    }
    func revert(on db: any Database) async throws {
        for table in [AgentCreatedProject.schema, ProjectSelectionRow.schema, ProjectGroupMember.schema, ProjectGroup.schema] {
            try await db.schema(table).delete()
        }
    }
}

// MARK: Resolution

/// Rows with `column IN values`, read with `FOR UPDATE` (MariaDB). A plain read inside a transaction could still see an
/// older snapshot and miss a removal that was committed before the caller got its locks.
private func rows<M: Model>(_ type: M.Type, column: String, in values: [UUID], locking: Bool, on db: any Database) async throws -> [M] {
    guard !values.isEmpty else { return [] }
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let lock = locking && sql.dialect.name != "sqlite" ? " FOR UPDATE" : ""
    let binds = values.sorted { $0.uuidString < $1.uuidString }
    return try await sql.raw("SELECT * FROM \(ident: M.schema) WHERE \(ident: column) IN (\(binds: binds)) ORDER BY \(ident: column)\(unsafeRaw: lock)")
        .all().map { try $0.decode(fluentModel: M.self) }
}

/// Resolves selections of ONE person. Create a new one for every check; it caches the sharing graph for its lifetime.
struct ProjectSelectionResolver {
    let userID: UUID
    let db: any Database
    /// True inside a deciding or writing transaction that already holds the grant or mandate row lock.
    var locking = false
    private var graph: (snapshot: SharingSnapshot, agentCreated: Set<UUID>)?

    init(userID: UUID, db: any Database, locking: Bool = false) {
        self.userID = userID; self.db = db; self.locking = locking
    }

    func rule(of subjectID: UUID) async throws -> SelectionRule? {
        try await rows(ProjectSelectionRow.self, column: "id", in: [subjectID], locking: locking, on: db).first?.rule
    }

    private mutating func loadGraph() async throws -> (snapshot: SharingSnapshot, agentCreated: Set<UUID>) {
        if let graph { return graph }
        guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound) }
        let (snapshot, _) = try await SharingAccess(user: user, db: db).snapshot()
        let created = try await AgentCreatedProject.query(on: db).filter(\.$id ~~ Array(snapshot.projects.keys)).all()
        let loaded = (snapshot, Set(created.compactMap(\.id)))
        graph = loaded
        return loaded
    }

    private mutating func readable(_ id: UUID) async throws -> Bool {
        let snapshot = try await loadGraph().snapshot
        guard let project = snapshot.projects[id] else { return false }
        return try snapshot.visibility(project).role != nil
    }

    /// Projects of this person's groups among `groupIDs` (groups of other people and deleted ones have none).
    func members(of groupIDs: [UUID]) async throws -> Set<UUID> {
        let own = try await rows(ProjectGroup.self, column: "id", in: groupIDs, locking: locking, on: db).filter { $0.userID == userID }
        return Set(try await rows(ProjectGroupMember.self, column: "group_id", in: own.compactMap(\.id), locking: locking, on: db).map(\.projectID))
    }

    /// Projects the person owns, split into those "all" includes and those a connection created. Team-owned ones are not "own".
    private mutating func owned() async throws -> (auto: Set<UUID>, agentCreated: Set<UUID>) {
        let (snapshot, created) = try await loadGraph()
        let mine = Set(snapshot.projects.compactMap { id, project -> UUID? in
            let row = snapshot.sharing[id]
            return (row?.ownerType ?? "person") == "person" && (row?.ownerID ?? project.ownerID) == userID ? id : nil
        })
        return (mine.subtracting(created), mine.intersection(created))
    }

    /// The resolution: (explicit + groups + "all owned") minus excluded projects and groups, cut with what the person can
    /// read now. Exclusion always wins. Explicit projects keep their order, the rest follows sorted.
    mutating func resolve(explicit: [UUID], rule: SelectionRule?) async throws -> [UUID] {
        var candidates = Set(explicit)
        var excluded = Set<UUID>()
        if let rule {
            // Locking reads (groups) before the first plain read (sharing graph): MariaDB snapshot isolation.
            candidates.formUnion(try await members(of: rule.groupIDs))
            excluded = Set(rule.excludedProjectIDs).union(try await members(of: rule.excludedGroupIDs))
            if rule.mode == SelectionRule.allExcept { candidates.formUnion(try await owned().auto) }
        }
        candidates.subtract(excluded)
        var seen = Set<UUID>(), out: [UUID] = []
        for id in explicit + candidates.sorted(by: { $0.uuidString < $1.uuidString }) where candidates.contains(id) && seen.insert(id).inserted {
            if try await readable(id) { out.append(id) }
        }
        return out
    }

    /// Agent-created projects of the person that an "all" selection leaves out (for the preview).
    mutating func leftOutByAll(explicit: [UUID], rule: SelectionRule?) async throws -> [UUID] {
        guard let rule, rule.mode == SelectionRule.allExcept else { return [] }
        let included = Set(try await resolve(explicit: explicit, rule: rule))
        let excluded = Set(rule.excludedProjectIDs).union(try await members(of: rule.excludedGroupIDs))
        return try await owned().agentCreated.subtracting(included).subtracting(excluded).sorted { $0.uuidString < $1.uuidString }
    }

    mutating func projects(of grant: OAuthGrant) async throws -> [UUID] {
        try await resolve(explicit: grant.explicitProjects, rule: try await rule(of: grant.requireID()))
    }

    mutating func projects(of mandate: BrainMandate) async throws -> [UUID] {
        try await resolve(explicit: mandate.explicitProjects, rule: try await rule(of: mandate.requireID()))
    }

    /// Read-only description for MCP (`get_connection`): mode, chosen and excluded groups by name, excluded projects only as a
    /// count (their ids could name projects outside the connection's reach).
    func describe(_ rule: SelectionRule?) async throws -> [String: JSONValue] {
        let rule = rule ?? SelectionRule()
        let named = try await rows(ProjectGroup.self, column: "id", in: rule.groupIDs + rule.excludedGroupIDs, locking: false, on: db)
            .filter { $0.userID == userID }
        func groups(_ ids: [UUID]) -> JSONValue {
            .array(named.filter { $0.id.map(ids.contains) ?? false }.sorted { $0.nameKey < $1.nameKey }
                .map { .object(["id": .string($0.id?.uuidString ?? ""), "name": .string($0.name)]) })
        }
        return ["mode": .string(rule.mode), "groups": groups(rule.groupIDs), "excludedGroups": groups(rule.excludedGroupIDs),
                "excludedProjectCount": .number(Double(rule.excludedProjectIDs.count))]
    }

    /// Checks a requested rule: known mode, bounded, and every group is the person's own (404 otherwise).
    func validate(_ input: SelectionInput?) async throws -> SelectionRule? {
        guard let input else { return nil }
        let mode = input.mode ?? SelectionRule.selected
        let groups = Set(input.groupIDs ?? []), excluded = Set(input.excludedProjectIDs ?? []), excludedGroups = Set(input.excludedGroupIDs ?? [])
        guard [SelectionRule.selected, SelectionRule.allExcept].contains(mode), groups.count <= SelectionLimits.maxGroups,
              excludedGroups.count <= SelectionLimits.maxGroups, excluded.count <= SelectionLimits.maxExcluded else {
            throw Abort(.badRequest, reason: "invalid_selection")
        }
        let named = Array(groups.union(excludedGroups))
        let own = try await rows(ProjectGroup.self, column: "id", in: named, locking: locking, on: db).filter { $0.userID == userID }
        guard own.count == named.count else { throw Abort(.notFound) }
        let sorted: (Set<UUID>) -> [UUID] = { $0.sorted { $0.uuidString < $1.uuidString } }
        let rule = SelectionRule(mode: mode, groupIDs: sorted(groups), excludedProjectIDs: sorted(excluded), excludedGroupIDs: sorted(excludedGroups))
        return rule.isPlain ? nil : rule
    }

    /// Stores or removes the rule of a grant or mandate. The caller holds its row lock.
    func store(_ rule: SelectionRule?, of subjectID: UUID) async throws {
        let row = try await rows(ProjectSelectionRow.self, column: "id", in: [subjectID], locking: locking, on: db).first
        guard let rule, !rule.isPlain else { try await row?.delete(on: db); return }
        let target = row ?? ProjectSelectionRow()
        if row == nil { target.id = subjectID; target.userID = userID }
        target.mode = rule.mode; target.groupIDs = rule.groupIDs
        target.excludedProjectIDs = rule.excludedProjectIDs; target.excludedGroupIDs = rule.excludedGroupIDs
        try await target.save(on: db)
    }
}

extension OAuthGrant {
    /// Resolves what this connection reaches now and keeps it for `effectiveProjects`.
    @discardableResult
    func resolveProjects(on db: any Database, locking: Bool = false) async throws -> [UUID] {
        var resolver = ProjectSelectionResolver(userID: userID, db: db, locking: locking)
        let ids = try await resolver.projects(of: self)
        resolvedProjects = ids
        return ids
    }

    /// Single-project edits (share dialog, access notice, `set_connection_projects`). The caller holds the grant row lock.
    /// Adding lifts an exclusion of this very project; an excluded group is the person's rule and refuses (409). Removing a
    /// project that a group or "all" still brings in excludes it. Returns whether the reach changed; the grant is saved.
    @discardableResult
    func include(_ projectID: UUID, on db: any Database) async throws -> Bool {
        var resolver = ProjectSelectionResolver(userID: userID, db: db, locking: true)
        let id = try requireID()
        var rule = try await resolver.rule(of: id)
        if try await resolver.resolve(explicit: explicitProjects, rule: rule).contains(projectID) { return false }
        if let excludedGroups = rule?.excludedGroupIDs, try await resolver.members(of: excludedGroups).contains(projectID) {
            throw Abort(.conflict, reason: "excluded_by_group")
        }
        if rule?.excludedProjectIDs.contains(projectID) == true {
            rule?.excludedProjectIDs.removeAll { $0 == projectID }
            try await resolver.store(rule, of: id)
        }
        if try await !resolver.resolve(explicit: explicitProjects, rule: rule).contains(projectID), !explicitProjects.contains(projectID) {
            explicitProjects.append(projectID)
        }
        try await save(on: db)
        try await resolveProjects(on: db, locking: true)
        return true
    }

    @discardableResult
    func exclude(_ projectID: UUID, on db: any Database) async throws -> Bool {
        var resolver = ProjectSelectionResolver(userID: userID, db: db, locking: true)
        let id = try requireID()
        var rule = try await resolver.rule(of: id)
        let reached = try await resolver.resolve(explicit: explicitProjects, rule: rule).contains(projectID)
        guard reached || explicitProjects.contains(projectID) else { return false }
        explicitProjects.removeAll { $0 == projectID }
        if rule != nil, try await resolver.resolve(explicit: explicitProjects, rule: rule).contains(projectID) {
            rule?.excludedProjectIDs.append(projectID)
            try await resolver.store(rule, of: id)
        }
        guard SelectionRule.namesSomething(explicitProjects, rule) || scopes.contains("projects:write") else {
            throw Abort(.badRequest, reason: "projects_required")
        }
        try await save(on: db)
        try await resolveProjects(on: db, locking: true)
        return true
    }

    /// Whether the person's rule excludes the project (then no access notice is raised for it).
    func excludes(_ projectID: UUID, on db: any Database) async throws -> Bool {
        let resolver = ProjectSelectionResolver(userID: userID, db: db)
        guard let rule = try await resolver.rule(of: requireID()) else { return false }
        if rule.excludedProjectIDs.contains(projectID) { return true }
        return try await resolver.members(of: rule.excludedGroupIDs).contains(projectID)
    }
}
