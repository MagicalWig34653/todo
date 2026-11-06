import Fluent
import Vapor

/// Repository bindings and sync records (ADR 0018). REST and MCP use the same methods; `allowedProjects` narrows an
/// OAuth grant to its project list (404 outside, like every MCP tool).
struct ProjectSyncService: Sendable {
    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil

    static let maxStaleDays = 365
    static let maxBindings = 10

    private func checkScope(_ id: UUID) throws {
        if let allowedProjects, !allowedProjects.contains(id) { throw Abort(.notFound) }
    }

    func project(_ id: UUID, role: ProjectRole = .read) async throws -> Project {
        try checkScope(id)
        return try await ProjectAccess(user: user, db: db).project(id, role: role)
    }

    static func cleanDays(_ days: Int?) throws -> Int? {
        guard let days else { return nil }
        guard (1...maxStaleDays).contains(days) else { throw Abort(.badRequest, reason: "invalid_stale_after_days") }
        return days
    }

    /// Bindings of a project in default order (oldest first).
    private static func bindings(of projectID: UUID, on db: any Database) async throws -> [ProjectRepositoryBinding] {
        try await ProjectRepositoryBinding.query(on: db).filter(\.$projectID == projectID).sort(\.$createdAt).sort(\.$id).all()
    }

    /// Sync state of one project (read right). Unbound projects report `bound: false`; with several bindings the
    /// stalest one is reported unless `repository` names one.
    func status(_ projectID: UUID, repository: String? = nil) async throws -> ProjectSyncDTO {
        _ = try await project(projectID)
        let all = try await Self.bindings(of: projectID, on: db)
        guard let repository else { return ProjectSyncDTO.make(stalest: all) }
        let key = try RepositoryKey.normalize(repository)
        guard let match = all.first(where: { $0.repoKey == key }) else { throw Abort(.conflict, reason: "not_bound") }
        return ProjectSyncDTO.make(match)
    }

    /// Adds a repository binding (an existing key only changes the threshold; history is never reset) and/or changes the
    /// staleness threshold. Without `repository` the project must have exactly one binding.
    func bind(_ projectID: UUID, repository: String?, staleAfterDays: Int?) async throws -> ProjectSyncDTO {
        let days = try Self.cleanDays(staleAfterDays)
        let key = try repository.map(RepositoryKey.normalize)
        let user = self.user, allowed = allowedProjects
        do {
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                try await lockRow(table: Project.schema, id: projectID, on: tx)
                if let allowed, !allowed.contains(projectID) { throw Abort(.notFound) }
                let project = try await ProjectAccess(user: user, db: tx).project(projectID, role: .edit)
                let existing = try await Self.bindings(of: projectID, on: tx)
                let target: ProjectRepositoryBinding?
                if let key {
                    target = existing.first { $0.repoKey == key }
                } else {
                    guard existing.count == 1 else { throw Abort(.badRequest, reason: "repository_required") }
                    target = existing[0]
                }
                if let target {
                    if let days, target.staleAfterDays != days { target.staleAfterDays = days; target.version += 1; try await target.save(on: tx) }
                    return ProjectSyncDTO.make(target)
                }
                guard let key else { throw Abort(.badRequest, reason: "repository_required") }
                if existing.count >= Self.maxBindings { throw Abort(.conflict, reason: "too_many_bindings") }
                if try await ProjectRepositoryBinding.query(on: tx).filter(\.$ownerID == project.ownerID).filter(\.$repoKey == key).first() != nil {
                    throw Abort(.conflict, reason: "repository_already_bound")
                }
                let binding = ProjectRepositoryBinding(projectID: projectID, ownerID: project.ownerID, repoKey: key,
                                                       staleAfterDays: days ?? ProjectSyncDTO.defaultStaleAfterDays)
                try await binding.save(on: tx)
                return ProjectSyncDTO.make(binding)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "repository_already_bound")
        }
    }

    /// Creates the binding inside a caller transaction (create_project). The caller holds the locks and the rights.
    static func bindNew(_ project: Project, repository: String, staleAfterDays: Int?, on db: any Database) async throws -> ProjectSyncDTO {
        let key = try RepositoryKey.normalize(repository)
        let days = try cleanDays(staleAfterDays)
        if try await ProjectRepositoryBinding.query(on: db).filter(\.$ownerID == project.ownerID).filter(\.$repoKey == key).first() != nil {
            throw Abort(.conflict, reason: "repository_already_bound")
        }
        let binding = ProjectRepositoryBinding(projectID: try project.requireID(), ownerID: project.ownerID, repoKey: key,
                                               staleAfterDays: days ?? ProjectSyncDTO.defaultStaleAfterDays)
        try await binding.save(on: db)
        return ProjectSyncDTO.make(binding)
    }

    /// Finds the projects bound to a repository that the user can see (and this connection may use).
    func find(repository: String) async throws -> RepositoryLookupDTO {
        let key = try RepositoryKey.normalize(repository)
        var matches: [RepositoryMatch] = []
        var outside = 0
        for row in try await ProjectRepositoryBinding.query(on: db).filter(\.$repoKey == key).all() {
            let id = row.projectID
            guard let project = try? await ProjectAccess(user: user, db: db).project(id) else { continue }
            if let allowedProjects, !allowedProjects.contains(id) { outside += 1; continue }
            matches.append(RepositoryMatch(projectID: id, name: project.name, sync: ProjectSyncDTO.make(row)))
        }
        matches.sort { ($0.name, $0.projectID.uuidString) < ($1.name, $1.projectID.uuidString) }
        let hint: String
        switch (matches.count, outside) {
        case (1, _): hint = "Bound project found. Call get_project_structure and session_start-style briefing, then continue; do not create a new project."
        case (0, 0): hint = "No project is bound to this repository. Create one with create_project (repository set) or bind an existing project with bind_repository after asking the user."
        case (0, _): hint = "A project bound to this repository exists for this account but is not part of this connection's grant. Do not create a duplicate: ask the user to reconnect Todolino (/mcp) and include that project, or to extend the connection in the Todolino app."
        default: hint = "Several projects are bound to this repository. Ask the user which one to use."
        }
        return RepositoryLookupDTO(repository: key, found: matches.count == 1, matches: matches, outsideGrant: outside, hint: hint)
    }

    /// Records that the project was reconciled with the repository now (edit right, binding required).
    func recordSync(_ projectID: UUID, summary rawSummary: String, repoRef rawRef: String?, actor: WorkflowActor,
                    agentName: String?, repository: String? = nil) async throws -> ProjectSyncDTO {
        let summary = try WorkflowService.text(rawSummary, reason: "invalid_summary")
        let ref = try WorkflowService.optionalLabel(rawRef, max: 200, reason: "invalid_repo_ref")
        let label = try WorkflowService.optionalLabel(agentName, reason: "invalid_agent_name") ?? actor.label ?? "agent"
        let key = try repository.map(RepositoryKey.normalize)
        let user = self.user, allowed = allowedProjects
        return try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: Project.schema, id: projectID, on: tx)
            if let allowed, !allowed.contains(projectID) { throw Abort(.notFound) }
            _ = try await ProjectAccess(user: user, db: tx).project(projectID, role: .edit)
            let existing = try await Self.bindings(of: projectID, on: tx)
            guard !existing.isEmpty else { throw Abort(.conflict, reason: "not_bound") }
            let chosen: ProjectRepositoryBinding?
            if let key { chosen = existing.first { $0.repoKey == key } } else {
                guard existing.count == 1 else { throw Abort(.conflict, reason: "repository_required") }
                chosen = existing[0]
            }
            guard let binding = chosen else { throw Abort(.conflict, reason: "not_bound") }
            binding.lastSyncedAt = Date(); binding.lastSyncedByType = actor.type.rawValue; binding.lastSyncedByLabel = label
            binding.lastRepoRef = ref; binding.lastSummary = summary; binding.version += 1
            try await binding.save(on: tx)
            return ProjectSyncDTO.make(binding)
        }
    }

    /// Bound projects whose data is stale or was never synced (optionally also unbound projects).
    func stale(projectID: UUID?, includeUnbound: Bool) async throws -> [ProjectSyncEntry] {
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: true, allowed: allowedProjects)
        let entries = try await Self.entries(scope: scope, on: db, includeSummary: false)
        return entries.filter { $0.sync.state != "fresh" && (includeUnbound || $0.sync.bound) }
            .sorted { a, b in
                let (x, y) = (a.sync.daysSince ?? Int.max, b.sync.daysSince ?? Int.max)
                return x != y ? x > y : a.name < b.name
            }
    }

    /// Sync entries for every project in `scope`, ordered by name.
    static func entries(scope: CommandCenterScope, on db: any Database, now: Date = Date(), includeSummary: Bool = true) async throws -> [ProjectSyncEntry] {
        let ids = scope.projectIDs
        var bindings: [UUID: [ProjectRepositoryBinding]] = [:]
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 400, ids.count)])
            index += 400
            for b in try await ProjectRepositoryBinding.query(on: db).filter(\.$projectID ~~ chunk).all() { bindings[b.projectID, default: []].append(b) }
        }
        return scope.projects.values.map {
            ProjectSyncEntry(projectID: $0.id!, name: $0.name, sync: ProjectSyncDTO.make(stalest: bindings[$0.id!] ?? [], now: now, includeSummary: includeSummary))
        }.sorted { ($0.name, $0.projectID.uuidString) < ($1.name, $1.projectID.uuidString) }
    }
}
