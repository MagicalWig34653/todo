import Fluent
import Vapor

extension PlanningService {
    func plannedTasks(mode: String, timeZone: String = "UTC") async throws -> [PlanningTaskDTO] {
        var calendar = Calendar(identifier: .gregorian)
        let zone = timeZone
        guard let timeZone = TimeZone(identifier: zone) else { throw Abort(.badRequest) }
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date()), end = calendar.date(byAdding: .day, value: 1, to: start)!
        var result: [PlanningTaskDTO] = []
        for task in try await visibleTasks() where task.status != "done" {
            let p = try await TaskPlanning.find(task.requireID(), on: db)
            if mode == "up-next" {
                if try await blocked(task.requireID()) { continue }
            } else {
                guard let due = p?.dueAt else { continue }
                if mode == "today" ? !(due >= start && due < end) : due < end { continue }
            }
            result.append(try PlanningTaskDTO(task, p))
        }
        return result.sorted { a, b in
            if mode == "up-next", a.priority != b.priority { return a.priority > b.priority }
            if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
            return a.task.id.uuidString < b.task.id.uuidString
        }
    }

    func removeDependency(_ id: UUID, prerequisite: UUID) async throws {
        try await lock(); _ = try await task(id, role: .edit); _ = try await task(prerequisite)
        let query = PlanningDependency.query(on: db).filter(\.$taskID == id).filter(\.$prerequisiteID == prerequisite)
        if try await query.first() != nil {
            try await query.delete()
            try await appendActivity(taskID: id, actorType: .person, actorID: user.requireID(), kind: "task.dependency_removed", subjectID: prerequisite, on: db)
        }
    }

    func milestone(_ id: UUID, role: ProjectRole = .read) async throws -> PlanningMilestone {
        guard let m = try await PlanningMilestone.find(id, on: db) else { throw Abort(.notFound) }
        _ = try await access.project(m.projectID, role: role)
        return m
    }

    func createMilestone(projectID: UUID, title: String, dueAt: Date?) async throws -> PlanningMilestone {
        _ = try await access.project(projectID, role: .edit)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw Abort(.badRequest, reason: "invalid_title") }
        let m = PlanningMilestone(projectID: projectID, title: title, dueAt: dueAt)
        try await m.save(on: db)
        return m
    }

    func deleteMilestone(_ id: UUID) async throws {
        try await milestone(id, role: .edit).delete(on: db)
    }

    func milestoneMembership(_ id: UUID, taskID: UUID, remove: Bool) async throws {
        try await lock()
        let m = try await milestone(id, role: .edit), t = try await task(taskID, role: .edit)
        guard try await access.isSelfOrDescendant(t.projectID, of: m.projectID) else { throw Abort(.unprocessableEntity) }
        let query = PlanningMilestoneTask.query(on: db).filter(\.$milestoneID == id).filter(\.$taskID == taskID)
        if remove { try await query.delete() }
        else if try await query.first() == nil { try await PlanningMilestoneTask(id, taskID).save(on: db) }
    }
}

extension PlanningService {
    func dependencies(_ id: UUID) async throws -> [TodoTask] {
        _ = try await task(id)
        var result: [TodoTask] = []
        for edge in try await PlanningDependency.query(on: db).filter(\.$taskID == id).sort(\.$id).all() {
            do { result.append(try await task(edge.prerequisiteID)) }
            catch let error as AbortError where error.status == .notFound { continue }
        }
        return result
    }

    /// Which projects the caller may read, from one sharing snapshot (same rules as `SharingAccess.visibility`),
    /// instead of several queries per task or per milestone member.
    struct ReadScope {
        let snapshot: SharingSnapshot
        private var cache: [UUID: Bool] = [:]
        init(_ snapshot: SharingSnapshot) { self.snapshot = snapshot }
        mutating func canRead(_ projectID: UUID) throws -> Bool {
            if let known = cache[projectID] { return known }
            let result = try snapshot.projects[projectID].map { try snapshot.visibility($0).role != nil } ?? false
            cache[projectID] = result
            return result
        }
        func isSelfOrDescendant(_ candidate: UUID, of project: UUID) -> Bool {
            var current: UUID? = candidate
            var seen = Set<UUID>()
            while let id = current, seen.insert(id).inserted {
                if id == project { return true }
                current = snapshot.projects[id]?.parentID
            }
            return false
        }
    }

    func readScope() async throws -> ReadScope { ReadScope(try await SharingAccess(user: user, db: db).snapshot().snapshot) }

    private func chunks<T>(_ values: [T], _ size: Int = 500) -> [[T]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    /// Edges whose both ends are visible tasks inside the project (or its subtree); hidden ends never leak.
    /// A constant number of queries: one sharing snapshot, then batched reads. `details` adds per-task title, status,
    /// project and due date plus the milestones with their visible members, so the graph view needs only this call.
    func projectDependencies(_ projectID: UUID, includeSubprojects: Bool, details: Bool = false) async throws -> PlanningGraphDTO {
        _ = try await access.project(projectID)
        var scope = try await readScope()
        var ids: Set<UUID> = [projectID]
        if includeSubprojects {
            var children: [UUID: [UUID]] = [:]
            for (id, p) in scope.snapshot.projects { if let parent = p.parentID { children[parent, default: []].append(id) } }
            var stack = [projectID]
            while let current = stack.popLast() { for c in children[current] ?? [] where ids.insert(c).inserted { stack.append(c) } }
        }
        let readable = try ids.filter { try scope.canRead($0) }
        var rows: [TodoTask] = []
        for chunk in chunks(Array(readable)) { rows += try await TodoTask.query(on: db).filter(\.$projectID ~~ chunk).all() }
        let taskIDs = Set(rows.compactMap(\.id))
        var edges: [PlanningDependency] = []
        for chunk in chunks(Array(taskIDs)) { edges += try await PlanningDependency.query(on: db).filter(\.$taskID ~~ chunk).all() }
        edges.sort { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
        let result = edges.filter { taskIDs.contains($0.prerequisiteID) }.map { PlanningDependencyEdgeDTO(taskID: $0.taskID, prerequisiteID: $0.prerequisiteID) }
        var flows: [UUID: TaskWorkflow] = [:]
        for chunk in chunks(Array(taskIDs)) { for w in try await TaskWorkflow.query(on: db).filter(\.$id ~~ chunk).all() { if let id = w.id { flows[id] = w } } }
        var plans: [UUID: TaskPlanning] = [:]
        if details { for chunk in chunks(Array(taskIDs)) { for p in try await TaskPlanning.query(on: db).filter(\.$id ~~ chunk).all() { if let id = p.id { plans[id] = p } } } }
        var buildsByTask: [UUID: [BuildArtifactDTO]] = [:]
        if details { for chunk in chunks(Array(taskIDs)) { buildsByTask.merge(try await WorkflowService.builds(of: chunk, on: db)) { a, _ in a } } }
        var nodes: [PlanningGraphNodeDTO] = []
        for t in rows {
            guard let id = t.id else { continue }
            let w = flows[id]
            var node = PlanningGraphNodeDTO(taskID: id, kind: w?.kind ?? "task", parentTaskID: w?.parentTaskID, createdAt: t.createdAt, updatedAt: t.updatedAt, claimedLabel: w?.claimedLabel)
            if details { node.title = t.title; node.status = t.status; node.projectID = t.projectID; node.dueAt = plans[id]?.dueAt; node.builds = Self.buildGroups(buildsByTask[id] ?? []) }
            nodes.append(node)
        }
        var milestones: [PlanningGraphMilestoneDTO]? = nil
        if details {
            milestones = try await milestoneRows(projectID, scope: &scope, allowedProjects: nil, limit: nil).map { m, tasks in
                PlanningGraphMilestoneDTO(id: try m.requireID(), title: m.title, dueAt: m.dueAt, tasks: try tasks.map { PlanningGraphMemberDTO(taskID: try $0.requireID(), status: $0.status) })
            }
        }
        return PlanningGraphDTO(edges: result, tasks: nodes, milestones: milestones)
    }

    /// Artifacts (newest first) grouped by build id, in order of the newest artifact; nil when there are none.
    static func buildGroups(_ artifacts: [BuildArtifactDTO]) -> [PlanningGraphBuildDTO]? {
        var order: [String] = []
        var groups: [String: PlanningGraphBuildDTO] = [:]
        for a in artifacts {
            if var g = groups[a.buildID] { g.count += 1; groups[a.buildID] = g; continue }
            order.append(a.buildID)
            groups[a.buildID] = PlanningGraphBuildDTO(buildID: a.buildID, label: a.label, platform: a.platform, count: 1, createdAt: a.createdAt)
        }
        return order.isEmpty ? nil : order.compactMap { groups[$0] }
    }

    /// Replace as one transaction, preserving the REST add path's cycle and role checks.
    func setDependencies(_ id: UUID, blockedBy ids: [UUID]) async throws {
        try await lock(); _ = try await task(id, role: .edit)
        let existing = try await PlanningDependency.query(on: db).filter(\.$taskID == id).all()
        for edge in existing where !ids.contains(edge.prerequisiteID) {
            try await removeDependency(id, prerequisite: edge.prerequisiteID)
        }
        for other in ids { try await addDependency(id, prerequisite: other) }
    }

    /// Milestones of the project with their visible members inside its subtree, in a constant number of queries.
    func milestoneRows(_ projectID: UUID, scope: inout ReadScope, allowedProjects: Set<UUID>?, limit: Int?) async throws -> [(PlanningMilestone, [TodoTask])] {
        var query = PlanningMilestone.query(on: db).filter(\.$projectID == projectID).sort(\.$id)
        if let limit { query = query.limit(limit) }
        let ms = try await query.all()
        guard !ms.isEmpty else { return [] }
        var links: [PlanningMilestoneTask] = []
        for chunk in chunks(try ms.map { try $0.requireID() }) { links += try await PlanningMilestoneTask.query(on: db).filter(\.$milestoneID ~~ chunk).all() }
        links.sort { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
        var tasks: [UUID: TodoTask] = [:]
        for chunk in chunks(Array(Set(links.map(\.taskID)))) { for t in try await TodoTask.query(on: db).filter(\.$id ~~ chunk).all() { if let id = t.id { tasks[id] = t } } }
        var byMilestone: [UUID: [PlanningMilestoneTask]] = [:]
        for l in links { byMilestone[l.milestoneID, default: []].append(l) }
        var result: [(PlanningMilestone, [TodoTask])] = []
        for m in ms {
            var members: [TodoTask] = []
            for link in byMilestone[try m.requireID()] ?? [] {
                guard let t = tasks[link.taskID], try scope.canRead(t.projectID) else { continue }
                guard allowedProjects == nil || allowedProjects!.contains(t.projectID) else { continue }
                if scope.isSelfOrDescendant(t.projectID, of: projectID), limit == nil || members.count < limit! { members.append(t) }
            }
            result.append((m, members))
        }
        return result
    }

    func milestones(_ projectID: UUID, allowedProjects: Set<UUID>? = nil, limit: Int? = nil) async throws -> [PlanningMilestoneDTO] {
        _ = try await access.project(projectID)
        var scope = try await readScope()
        return try await milestoneRows(projectID, scope: &scope, allowedProjects: allowedProjects, limit: limit).map { PlanningMilestoneDTO(milestone: $0.0, tasks: try $0.1.map { try TaskDTO($0) }) }
    }
}
