import Fluent
import Vapor

/// PATCH /v1/tasks/{id}/schedule (ADR 0033). Only keys present in the JSON are applied; `null` clears.
struct ScheduleUpdate: Content {
    var version: Int
    var plannedAt: Date?
    var plannedMinutes: Int?
    var plannedAllDay: Bool?
    var hasPlannedAt = false, hasPlannedMinutes = false, hasPlannedAllDay = false

    private enum CodingKeys: String, CodingKey { case version, plannedAt, plannedMinutes, plannedAllDay }

    init(version: Int, plannedAt: Date?? = nil, plannedMinutes: Int?? = nil, plannedAllDay: Bool? = nil) {
        self.version = version
        if let plannedAt { hasPlannedAt = true; self.plannedAt = plannedAt }
        if let plannedMinutes { hasPlannedMinutes = true; self.plannedMinutes = plannedMinutes }
        if let plannedAllDay { hasPlannedAllDay = true; self.plannedAllDay = plannedAllDay }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        hasPlannedAt = c.contains(.plannedAt); plannedAt = try c.decodeIfPresent(Date.self, forKey: .plannedAt)
        hasPlannedMinutes = c.contains(.plannedMinutes); plannedMinutes = try c.decodeIfPresent(Int.self, forKey: .plannedMinutes)
        hasPlannedAllDay = c.contains(.plannedAllDay); plannedAllDay = try c.decodeIfPresent(Bool.self, forKey: .plannedAllDay)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        if hasPlannedAt { try c.encode(plannedAt, forKey: .plannedAt) }
        if hasPlannedMinutes { try c.encode(plannedMinutes, forKey: .plannedMinutes) }
        if hasPlannedAllDay { try c.encode(plannedAllDay, forKey: .plannedAllDay) }
    }
}

struct ScheduleEntryDTO: Content {
    var taskID: UUID
    var projectID: UUID
    var title: String
    var status: String
    var version: Int
    var plannedAt: Date?
    var plannedMinutes: Int?
    var plannedAllDay: Bool
    var dueAt: Date?
    var blocked: Bool
    var canEdit: Bool
    /// Stage C: owner allowed the guard to start this card at `plannedAt` (one time); `autoStartedAt` is the hand-over time.
    var autoStart: Bool
    var autoStartedAt: Date?
    var jobState: String?
    var repositoryKey: String?
    var conflicts: [String]
}

struct ScheduleResponse: Content {
    var from: Date
    var to: Date
    var truncated: Bool
    var items: [ScheduleEntryDTO]
}

extension PlanningService.ReadScope {
    mutating func canEdit(_ projectID: UUID) throws -> Bool {
        guard let project = snapshot.projects[projectID], let role = try snapshot.visibility(project).role else { return false }
        return role.rank >= ProjectRole.edit.rank
    }
}

extension PlanningService {
    private static let activeJobStates: Set<String> = ["queued", "claimed", "running", "waiting_for_answer"]

    /// Partial write for calendar drag and drop. Keeps priority, recurrence, reminders and `dueAt` untouched.
    func schedule(_ id: UUID, update: ScheduleUpdate) async throws -> PlanningTaskDTO {
        try await lock()
        try await lockRow(table: TodoTask.schema, id: id, on: db)
        let t = try await task(id, role: .edit)
        guard t.version == update.version else { throw Abort(.conflict, reason: "version_conflict") }
        guard t.status != "done" else { throw Abort(.conflict, reason: "task_done") }
        guard update.hasPlannedAt || update.hasPlannedMinutes || update.hasPlannedAllDay else {
            throw Abort(.badRequest, reason: "invalid_schedule")
        }
        let p = try await TaskPlanning.find(id, on: db) ?? TaskPlanning(taskID: id)
        let start = update.hasPlannedAt ? update.plannedAt : p.plannedAt
        var minutes = update.hasPlannedMinutes ? update.plannedMinutes : p.plannedMinutes
        var allDay = update.hasPlannedAllDay ? (update.plannedAllDay ?? false) : p.plannedAllDay
        try ScheduleRules.validateMinutes(minutes)
        if start == nil {
            if p.recurrence != nil && p.dueAt == nil { throw Abort(.badRequest, reason: "recurrence_requires_date") }
            if update.hasPlannedAllDay && update.plannedAllDay == true { throw Abort(.badRequest, reason: "all_day_requires_planned_at") }
            minutes = nil; allDay = false
        }
        let before = (start: p.plannedAt, minutes: p.plannedMinutes, allDay: p.plannedAllDay)
        p.plannedAt = start; p.plannedMinutes = minutes; p.plannedAllDay = allDay
        try await AutoStartService.scheduleChanged(p, taskID: id, projectID: t.projectID, before: before, user: user, integrationGrant: nil, on: db)
        try await p.save(on: db)
        // The version bump saves the task row and thereby emits the sync upsert.
        t.version += 1
        try await t.save(on: db)
        try await appendActivity(taskID: id, actorType: .person, actorID: user.requireID(), kind: "task.scheduled", subjectID: nil, on: db)
        return try PlanningTaskDTO(t, p)
    }

    /// Open tasks without a planned start (calendar sidebar). Priority descending, then due date, then id.
    func unscheduled(projectID: UUID?, limit: Int) async throws -> [PlanningTaskDTO] {
        guard (1...ScheduleRules.maxItems).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        if let projectID { _ = try await access.project(projectID) }
        var result: [PlanningTaskDTO] = []
        for task in try await visibleTasks() where task.status != "done" && (projectID == nil || task.projectID == projectID) {
            let p = try await TaskPlanning.find(task.requireID(), on: db)
            if p?.plannedAt != nil { continue }
            result.append(try PlanningTaskDTO(task, p))
        }
        result.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
            return a.task.id.uuidString < b.task.id.uuidString
        }
        return Array(result.prefix(limit))
    }

    /// Calendar window for REST and MCP. `allowedProjects` is the OAuth grant (nil for sessions).
    func scheduleWindow(from: Date, to: Date, projectID: UUID?, limit: Int?, allowedProjects: Set<UUID>? = nil) async throws -> ScheduleResponse {
        guard from < to else { throw Abort(.badRequest, reason: "invalid_window") }
        guard to.timeIntervalSince(from) <= Double(ScheduleRules.maxWindowDays) * 86400 else { throw Abort(.badRequest, reason: "window_too_large") }
        let limit = limit ?? ScheduleRules.maxItems
        guard (1...ScheduleRules.maxItems).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        if let projectID { _ = try await access.project(projectID) }
        guard try await IdentityRateLimit.take(scope: "schedule", subject: user.requireID().uuidString, limit: 120, window: 60, on: db) else {
            throw Abort(.tooManyRequests, reason: "rate_limited")
        }
        var scope = try await readScope()
        // Only start times up to 24 h before the window can still run into it.
        let earliest = from.addingTimeInterval(-86400)
        var plans: [TaskPlanning] = []
        let started = try await TaskPlanning.query(on: db).filter(\.$plannedAt >= earliest).filter(\.$plannedAt < to).all()
        let due = try await TaskPlanning.query(on: db).filter(\.$dueAt >= from).filter(\.$dueAt < to).all()
        var seen = Set<UUID>()
        for p in started + due { if let id = p.id, seen.insert(id).inserted { plans.append(p) } }
        var tasks: [UUID: TodoTask] = [:]
        for chunk in Self.chunked(Array(seen)) { for t in try await TodoTask.query(on: db).filter(\.$id ~~ chunk).all() { if let id = t.id { tasks[id] = t } } }
        var visible: [(TodoTask, TaskPlanning)] = []
        for p in plans {
            guard let id = p.id, let t = tasks[id], try scope.canRead(t.projectID) else { continue }
            if let allowedProjects, !allowedProjects.contains(t.projectID) { continue }
            if let projectID, !scope.isSelfOrDescendant(t.projectID, of: projectID) { continue }
            let inDue = p.dueAt.map { $0 >= from && $0 < to } ?? false
            var inPlan = false
            if let s = p.plannedAt {
                if p.plannedAllDay { inPlan = s >= from && s < to }
                else {
                    let end = s.addingTimeInterval(Double(p.plannedMinutes ?? ScheduleRules.defaultMinutes) * 60)
                    inPlan = s < to && end > from
                }
            }
            if inPlan || inDue { visible.append((t, p)) }
        }
        visible.sort { a, b in
            switch (a.1.plannedAt, b.1.plannedAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.1.dueAt != b.1.dueAt { return (a.1.dueAt ?? .distantFuture) < (b.1.dueAt ?? .distantFuture) }
            return (a.0.id?.uuidString ?? "") < (b.0.id?.uuidString ?? "")
        }
        let truncated = visible.count > limit
        let page = Array(visible.prefix(limit))
        let entries = try await entries(for: page, scope: &scope)
        return ScheduleResponse(from: from, to: to, truncated: truncated, items: entries)
    }

    private static func chunked<T>(_ values: [T], _ size: Int = 500) -> [[T]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    private func entries(for page: [(TodoTask, TaskPlanning)], scope: inout ReadScope) async throws -> [ScheduleEntryDTO] {
        let ids = try page.map { try $0.0.requireID() }
        var edges: [PlanningDependency] = []
        for chunk in Self.chunked(ids) { edges += try await PlanningDependency.query(on: db).filter(\.$taskID ~~ chunk).all() }
        var prerequisiteTasks: [UUID: TodoTask] = [:], prerequisitePlans: [UUID: TaskPlanning] = [:]
        let prerequisiteIDs = Array(Set(edges.map(\.prerequisiteID)))
        for chunk in Self.chunked(prerequisiteIDs) {
            for t in try await TodoTask.query(on: db).filter(\.$id ~~ chunk).all() { if let id = t.id { prerequisiteTasks[id] = t } }
            for p in try await TaskPlanning.query(on: db).filter(\.$id ~~ chunk).all() { if let id = p.id { prerequisitePlans[id] = p } }
        }
        // Newest job per task: highest revision, then the one no other job names as its predecessor.
        var jobs: [UUID: AgentJob] = [:]
        for chunk in Self.chunked(ids) {
            let rows = try await AgentJob.query(on: db).filter(\.$taskID ~~ chunk).all()
            let replaced = Set(rows.compactMap(\.previousJobID))
            for job in rows {
                guard let existing = jobs[job.taskID] else { jobs[job.taskID] = job; continue }
                let newer = job.taskRevision != existing.taskRevision ? job.taskRevision > existing.taskRevision : !replaced.contains(job.id ?? UUID())
                if newer { jobs[job.taskID] = job }
            }
        }
        var bindings: [UUID: ProjectRunnerBinding] = [:]
        for id in Set(jobs.values.map(\.bindingID)) { if let b = try await ProjectRunnerBinding.find(id, on: db) { bindings[id] = b } }

        func end(_ p: TaskPlanning) -> Date? {
            p.plannedAt.map { $0.addingTimeInterval(Double(p.plannedMinutes ?? ScheduleRules.defaultMinutes) * 60) }
        }
        var result: [ScheduleEntryDTO] = []
        for (t, p) in page {
            let id = try t.requireID()
            var conflicts: [String] = []
            let taskEnd = end(p)
            if let due = p.dueAt, let start = p.plannedAt, !p.plannedAllDay, (taskEnd ?? start) > due || start > due { conflicts.append("after_due") }
            var blocked = false
            for edge in edges where edge.taskID == id {
                guard let prerequisite = prerequisiteTasks[edge.prerequisiteID] else { continue }
                if prerequisite.status != "done" { blocked = true }
                guard try scope.canRead(prerequisite.projectID) else { continue }
                if prerequisite.status != "done", !conflicts.contains("prerequisite_open") { conflicts.append("prerequisite_open") }
                if let start = p.plannedAt, let pp = prerequisitePlans[edge.prerequisiteID], let preEnd = end(pp), preEnd > start,
                   !conflicts.contains("prerequisite_later") { conflicts.append("prerequisite_later") }
            }
            let job = jobs[id]
            result.append(ScheduleEntryDTO(
                taskID: id, projectID: t.projectID, title: t.title, status: t.status, version: t.version,
                plannedAt: p.plannedAt, plannedMinutes: p.plannedMinutes, plannedAllDay: p.plannedAllDay, dueAt: p.dueAt,
                blocked: blocked, canEdit: try scope.canEdit(t.projectID), autoStart: p.autoStart, autoStartedAt: p.autoStartedAt,
                jobState: job?.state, repositoryKey: job.flatMap { bindings[$0.bindingID]?.repositoryKey }, conflicts: conflicts))
        }
        // Two cards with an active agent job on the same repository that overlap in time: the runner serializes them.
        let timed = zip(page, result.indices).compactMap { pair -> (Int, String, Date, Date)? in
            let ((_, p), index) = pair
            let entry = result[index]
            guard let key = entry.repositoryKey, let state = entry.jobState, Self.activeJobStates.contains(state),
                  !p.plannedAllDay, let s = p.plannedAt, let e = end(p) else { return nil }
            return (index, key, s, e)
        }
        for a in timed {
            for b in timed where a.0 != b.0 && a.1 == b.1 && a.2 < b.3 && b.2 < a.3 {
                if !result[a.0].conflicts.contains("repository_overlap") { result[a.0].conflicts.append("repository_overlap") }
            }
        }
        return result
    }
}
