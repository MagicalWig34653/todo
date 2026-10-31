import Fluent
import Vapor

/// Body of `PUT /v1/projects/{id}/position`. `parentID` absent = keep the viewer's current parent; present and
/// `null` = move to the root; present = move below that project (needs `version`).
struct ProjectPositionRequest: Content {
    let index: Int
    let version: Int?
    let parentSpecified: Bool
    let parentID: UUID?

    private enum Keys: String, CodingKey { case index, version, parentID }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        index = try c.decode(Int.self, forKey: .index)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        parentSpecified = c.contains(.parentID)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
    }

    init(index: Int, version: Int? = nil, parentSpecified: Bool = false, parentID: UUID? = nil) {
        self.index = index; self.version = version; self.parentSpecified = parentSpecified; self.parentID = parentID
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(index, forKey: .index)
        try c.encodeIfPresent(version, forKey: .version)
        if parentSpecified { try c.encode(parentID, forKey: .parentID) }
    }
}

struct FavoriteDTO: Content {
    let projectID: UUID
    let position: Int
}

struct FavoritesResponse: Content {
    let items: [FavoriteDTO]
}

struct ProjectPrefsDTO: Content {
    let projectID: UUID
    let view: String
    let sort: String
    let grouping: String
    let showCompleted: Bool
    /// `classic` | `management`: the stored choice, otherwise the derived default.
    let mode: String
    /// `user` when `mode` was chosen explicitly, `default` when derived (agent brief, runner/repo binding, open agent question).
    let modeSource: String
    let isFavorite: Bool
    let favoritePosition: Int?
    /// 0 while no preference was ever written for this project.
    let revision: Int
    let updatedAt: Date?

    init(projectID: UUID, state: ProjectUserState?, defaultMode: String) {
        self.projectID = projectID
        mode = state?.mode ?? defaultMode; modeSource = state?.mode == nil ? "default" : "user"
        view = state?.view ?? "list"; sort = state?.sortMode ?? "manual"
        grouping = state?.grouping ?? "column"; showCompleted = state?.showCompleted ?? true
        isFavorite = state?.isFavorite ?? false
        favoritePosition = state?.isFavorite == true ? state?.favoritePosition : nil
        revision = state?.revision ?? 0
        updatedAt = state.flatMap { $0.revision > 0 ? $0.updatedAt : nil }
    }
}

struct ProjectPrefsList: Content {
    let items: [ProjectPrefsDTO]
}

/// Sibling order, favourites and display preferences of one account (ADR 0012). All writes take the sharing-graph
/// lock first (replica-safe, serialises order renumbering) and then read.
struct ProjectStateService: Sendable {
    let user: User
    let db: any Database
    var access: ProjectAccess { ProjectAccess(user: user, db: db) }

    // MARK: Helpers

    private func visible() async throws -> [Project] { try await access.visibleProjects() }

    /// Parent as the viewer sees it: a hidden parent counts as "no parent" (same redaction as the project DTO).
    private func effectiveParent(_ project: Project, visibleIDs: Set<UUID>) -> UUID? {
        project.parentID.flatMap { visibleIDs.contains($0) ? $0 : nil }
    }

    private func state(_ projectID: UUID, create: Bool) async throws -> ProjectUserState? {
        if let row = try await ProjectUserState.query(on: db).filter(\.$userID == user.requireID())
            .filter(\.$projectID == projectID).first() { return row }
        guard create else { return nil }
        let row = ProjectUserState(userID: try user.requireID(), projectID: projectID)
        try await row.save(on: db)
        return row
    }

    // MARK: Sibling order

    func position(_ projectID: UUID, _ body: ProjectPositionRequest) async throws -> ProjectDTO {
        try await lockSharingGraph(on: db)
        if body.index < 0 { throw Abort(.badRequest, reason: "invalid_index") }
        let project = try await access.project(projectID, role: .read)
        var visibleProjects = try await visible()
        var visibleIDs = Set(try visibleProjects.map { try $0.requireID() })
        let current = effectiveParent(project, visibleIDs: visibleIDs)
        let target = body.parentSpecified ? body.parentID : current
        if target != current {
            // Re-parenting changes the shared tree, so it needs the same rights and version as PATCH.
            guard let expected = body.version else { throw Abort(.badRequest, reason: "version_required") }
            let managed = try await access.project(projectID, role: .manage)
            guard managed.version == expected else { throw Abort(.conflict, reason: "version_conflict") }
            if let newParent = target {
                _ = try await access.project(newParent, role: .manage)
                if try await access.isSelfOrDescendant(newParent, of: projectID) {
                    throw Abort(.unprocessableEntity, reason: "project_cycle")
                }
            }
            managed.parentID = target
            managed.version += 1
            try await managed.save(on: db)
            visibleProjects = try await visible()
            visibleIDs = Set(try visibleProjects.map { try $0.requireID() })
        }
        guard let moved = try await Project.find(projectID, on: db) else { throw Abort(.notFound) }
        guard visibleIDs.contains(projectID) else { return try await access.dto(moved) }
        let states = try await ProjectUserState.states(of: user, on: db)
        let effective = effectiveParent(moved, visibleIDs: visibleIDs)
        var siblings = visibleProjects.filter { effectiveParent($0, visibleIDs: visibleIDs) == effective }
        // Stable base order: stored position, then creation time, then ID (the order GET /v1/projects returns).
        siblings.sort { a, b in
            let pa = states[a.id!]?.orderPosition ?? Int.max, pb = states[b.id!]?.orderPosition ?? Int.max
            if pa != pb { return pa < pb }
            if a.createdAt != b.createdAt { return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast) }
            return a.id!.uuidString < b.id!.uuidString
        }
        siblings.removeAll { $0.id == projectID }
        siblings.insert(moved, at: min(body.index, siblings.count))
        for (i, sibling) in siblings.enumerated() {
            let id = try sibling.requireID()
            let existing = states[id]
            let row: ProjectUserState
            if let existing { row = existing } else { row = try await state(id, create: true)! }
            guard row.orderPosition != i else { continue }
            row.orderPosition = i
            try await row.save(on: db)
            // The position is part of the project DTO; sync clients of this account refresh the project.
            try await SyncRecorder.recordUpsert(type: "project", id: id, projectID: id, on: db)
        }
        return try await access.dto(moved)
    }

    // MARK: Favourites

    /// Visible favourites in order. Favourites of projects the account cannot see right now are kept but not listed.
    func favorites() async throws -> [FavoriteDTO] {
        let visibleIDs = Set(try await visible().map { try $0.requireID() })
        let rows = try await ProjectUserState.query(on: db).filter(\.$userID == user.requireID())
            .filter(\.$isFavorite == true).sort(\.$favoritePosition).sort(\.$projectID).all()
        return rows.filter { visibleIDs.contains($0.projectID) }.enumerated().map { FavoriteDTO(projectID: $0.element.projectID, position: $0.offset) }
    }

    /// Adds `projectID` to the favourites at `index` (default end) or moves it there. Idempotent.
    func setFavorite(_ projectID: UUID, index: Int?) async throws -> [FavoriteDTO] {
        try await lockSharingGraph(on: db)
        if let index, index < 0 { throw Abort(.badRequest, reason: "invalid_index") }
        _ = try await access.project(projectID, role: .read)
        let target = try await state(projectID, create: true)!
        try await renumberFavorites(inserting: target, at: index)
        return try await favorites()
    }

    func removeFavorite(_ projectID: UUID) async throws {
        try await lockSharingGraph(on: db)
        _ = try await access.project(projectID, role: .read)
        guard let row = try await state(projectID, create: false), row.isFavorite else { return }
        row.isFavorite = false
        row.revision += 1; row.updatedAt = Date()
        try await row.save(on: db)
        try await renumberFavorites(inserting: nil, at: nil)
        try await SyncRecorder.recordUpsert(type: "project", id: projectID, projectID: projectID, on: db)
    }

    /// Dense renumbering: visible favourites first (in order, with `inserting` placed at `index`), hidden ones after.
    private func renumberFavorites(inserting target: ProjectUserState?, at index: Int?) async throws {
        let visibleIDs = Set(try await visible().map { try $0.requireID() })
        let rows = try await ProjectUserState.query(on: db).filter(\.$userID == user.requireID())
            .filter(\.$isFavorite == true).sort(\.$favoritePosition).sort(\.$projectID).all()
        var shown = rows.filter { visibleIDs.contains($0.projectID) && $0.projectID != target?.projectID }
        let hidden = rows.filter { !visibleIDs.contains($0.projectID) }
        let wasFavorite = target?.isFavorite == true
        if let target { shown.insert(target, at: min(index ?? shown.count, shown.count)) }
        for (i, row) in (shown + hidden).enumerated() {
            let isTarget = row.projectID == target?.projectID
            guard row.favoritePosition != i || !row.isFavorite else { continue }
            row.isFavorite = true
            row.favoritePosition = i
            // Only the explicitly changed favourite bumps its preference revision; neighbours just shift.
            if isTarget { row.revision += 1; row.updatedAt = Date() }
            try await row.save(on: db)
            try await SyncRecorder.recordUpsert(type: "project", id: row.projectID, projectID: row.projectID, on: db)
        }
    }

    // MARK: Display preferences

    /// Projects that already involve agents or a repository: an agent brief with text, a runner binding, a repository
    /// binding or an open question asked by an integration/run. Their default mode is `management`, all others `classic`.
    func agentRelated(_ ids: [UUID]) async throws -> Set<UUID> {
        var found = Set<UUID>()
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            for brief in try await ProjectAgentBrief.query(on: db).filter(\.$id ~~ chunk).all()
            where !brief.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.insert(brief.id!) }
            for b in try await ProjectRunnerBinding.query(on: db).filter(\.$projectID ~~ chunk).all() { found.insert(b.projectID) }
            for b in try await ProjectBinding.query(on: db).filter(\.$id ~~ chunk).all() { found.insert(b.id!) }
            let questions = try await TaskQuestion.query(on: db)
                .join(TodoTask.self, on: \TaskQuestion.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID ~~ chunk)
                .filter(\.$state == "open").filter(\.$askedByType != .person).all()
            for q in questions { found.insert(try q.joined(TodoTask.self).projectID) }
        }
        return found
    }

    func defaultMode(_ projectID: UUID) async throws -> String {
        try await agentRelated([projectID]).contains(projectID) ? "management" : "classic"
    }

    func prefs(_ projectID: UUID) async throws -> ProjectPrefsDTO {
        _ = try await access.project(projectID, role: .read)
        let row = try await state(projectID, create: false)
        return ProjectPrefsDTO(projectID: projectID, state: row, defaultMode: row?.mode == nil ? try await defaultMode(projectID) : "classic")
    }

    /// Stored preferences (revision > 0); with `includeDefaults` every visible project, unwritten ones with default values.
    func allPrefs(includeDefaults: Bool = false) async throws -> ProjectPrefsList {
        let visibleIDs = Set(try await visible().map { try $0.requireID() })
        let rows = try await ProjectUserState.query(on: db).filter(\.$userID == user.requireID()).all()
        let byProject = Dictionary(rows.map { ($0.projectID, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = (includeDefaults ? Array(visibleIDs) : rows.filter { $0.revision > 0 && visibleIDs.contains($0.projectID) }.map(\.projectID)).sorted { $0.uuidString < $1.uuidString }
        let related = try await agentRelated(ids.filter { byProject[$0]?.mode == nil })
        return ProjectPrefsList(items: ids.map { id in
            ProjectPrefsDTO(projectID: id, state: byProject[id], defaultMode: related.contains(id) ? "management" : "classic")
        })
    }

    func updatePrefs(_ projectID: UUID, _ change: ProjectPrefsChange) async throws -> ProjectPrefsDTO {
        try await lockSharingGraph(on: db)
        _ = try await access.project(projectID, role: .read)
        let row = try await state(projectID, create: true)!
        guard row.revision == change.revision else { throw Abort(.conflict, reason: "revision_conflict") }
        if let v = change.view { row.view = v }
        if let v = change.sort { row.sortMode = v }
        if let v = change.grouping { row.grouping = v }
        if let v = change.showCompleted { row.showCompleted = v }
        if let v = change.mode { row.mode = v }
        row.revision += 1; row.updatedAt = Date()
        try await row.save(on: db)
        return ProjectPrefsDTO(projectID: projectID, state: row, defaultMode: row.mode == nil ? try await defaultMode(projectID) : "classic")
    }
}

/// Validated partial update of the display preferences.
struct ProjectPrefsChange: Decodable {
    let revision: Int
    let view: String?
    let sort: String?
    let grouping: String?
    let showCompleted: Bool?
    let mode: String?

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private enum Keys: String, CodingKey, CaseIterable { case revision, view, sort, grouping, showCompleted, mode }

    /// Strict: exact key set, strictly typed values, known enum values, `revision` >= 0, at least one preference.
    init(from decoder: any Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        guard any.allKeys.allSatisfy({ Keys(rawValue: $0.stringValue) != nil }) else {
            throw Abort(.badRequest, reason: "unknown_project_prefs_key")
        }
        let c = try decoder.container(keyedBy: Keys.self)
        guard let revision = try? c.decode(Int.self, forKey: .revision), revision >= 0 else {
            throw Abort(.badRequest, reason: "revision_required")
        }
        func choice(_ key: Keys, _ allowed: Set<String>) throws -> String? {
            guard c.contains(key) else { return nil }
            guard let value = try? c.decode(String.self, forKey: key), allowed.contains(value) else {
                throw Abort(.badRequest, reason: "invalid_\(key.rawValue)")
            }
            return value
        }
        self.revision = revision
        view = try choice(.view, ProjectUserState.views)
        sort = try choice(.sort, ProjectUserState.sorts)
        grouping = try choice(.grouping, ProjectUserState.groupings)
        mode = try choice(.mode, ProjectUserState.modes)
        if c.contains(.showCompleted) {
            guard let flag = try? c.decode(Bool.self, forKey: .showCompleted) else { throw Abort(.badRequest, reason: "invalid_showCompleted") }
            showCompleted = flag
        } else { showCompleted = nil }
        guard view != nil || sort != nil || grouping != nil || showCompleted != nil || mode != nil else {
            throw Abort(.badRequest, reason: "empty_project_prefs")
        }
    }
}
