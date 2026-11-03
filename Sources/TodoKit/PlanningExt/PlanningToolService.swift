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

    /// Edges whose both ends are visible tasks inside the project (or its subtree); hidden ends never leak.
    func projectDependencies(_ projectID: UUID, includeSubprojects: Bool) async throws -> PlanningGraphDTO {
        _ = try await access.project(projectID)
        var ids: Set<UUID> = [projectID]
        if includeSubprojects {
            let all = try await Project.query(on: db).all()
            var children: [UUID: [UUID]] = [:]
            for p in all { if let parent = p.parentID, let id = p.id { children[parent, default: []].append(id) } }
            var stack = [projectID]
            while let current = stack.popLast() { for c in children[current] ?? [] where ids.insert(c).inserted { stack.append(c) } }
        }
        let rows = try await TodoTask.query(on: db).filter(\.$projectID ~~ Array(ids)).all()
        let taskIDs = Set(rows.compactMap(\.id))
        let edges = try await PlanningDependency.query(on: db).filter(\.$taskID ~~ Array(taskIDs)).sort(\.$id).all()
            .filter { taskIDs.contains($0.prerequisiteID) }
        var visible: [UUID: Bool] = [:]
        func canSee(_ id: UUID) async throws -> Bool {
            if let known = visible[id] { return known }
            do { _ = try await task(id); visible[id] = true } catch let error as AbortError where error.status == .notFound { visible[id] = false }
            return visible[id] ?? false
        }
        var result: [PlanningDependencyEdgeDTO] = []
        for e in edges {
            guard try await canSee(e.taskID), try await canSee(e.prerequisiteID) else { continue }
            result.append(PlanningDependencyEdgeDTO(taskID: e.taskID, prerequisiteID: e.prerequisiteID))
        }
        var nodes: [PlanningGraphNodeDTO] = []
        let flows = Dictionary(uniqueKeysWithValues: try await TaskWorkflow.query(on: db).filter(\.$id ~~ Array(taskIDs)).all().compactMap { w in w.id.map { ($0, w) } })
        for t in rows { if let id = t.id, try await canSee(id) {
            let w = flows[id]
            nodes.append(PlanningGraphNodeDTO(taskID: id, kind: w?.kind ?? "task", parentTaskID: w?.parentTaskID, createdAt: t.createdAt, updatedAt: t.updatedAt))
        } }
        return PlanningGraphDTO(edges: result, tasks: nodes)
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

    func milestones(_ projectID: UUID, allowedProjects: Set<UUID>? = nil, limit: Int? = nil) async throws -> [PlanningMilestoneDTO] {
        _ = try await access.project(projectID)
        var query = PlanningMilestone.query(on: db).filter(\.$projectID == projectID).sort(\.$id)
        if let limit { query = query.limit(limit) }
        var result: [PlanningMilestoneDTO] = []
        for m in try await query.all() {
            var tasks: [TaskDTO] = []
            for link in try await PlanningMilestoneTask.query(on: db).filter(\.$milestoneID == m.requireID()).sort(\.$id).all() {
                do {
                    let t = try await task(link.taskID)
                    guard allowedProjects == nil || allowedProjects!.contains(t.projectID) else { continue }
                    if try await access.isSelfOrDescendant(t.projectID, of: projectID), limit == nil || tasks.count < limit! { tasks.append(try TaskDTO(t)) }
                } catch let error as AbortError where error.status == .notFound { continue }
            }
            result.append(PlanningMilestoneDTO(milestone: m, tasks: tasks))
        }
        return result
    }
}
