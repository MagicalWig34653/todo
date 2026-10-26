import Fluent
import Vapor

struct PlanningData: Content {
    var dueAt: Date?
    var plannedAt: Date?
    var priority: Int
    var recurrence: RecurrenceRule?
    var reminders: [Date]

    func validate() throws {
        guard (0...3).contains(priority), reminders.count <= 100 else { throw Abort(.badRequest) }
        try recurrence?.validate()
        if recurrence != nil && dueAt == nil && plannedAt == nil {
            throw Abort(.badRequest, reason: "recurrence_requires_date")
        }
    }
}

struct PlanningTaskDTO: Content {
    var task: TaskDTO
    var dueAt: Date?
    var plannedAt: Date?
    var priority: Int
    var position: Int
    var recurrence: RecurrenceRule?
    var reminders: [Date]
    init(_ task: TodoTask, _ planning: TaskPlanning?) throws {
        self.task = try TaskDTO(task)
        dueAt = planning?.dueAt; plannedAt = planning?.plannedAt
        priority = planning?.priority ?? 0; position = planning?.position ?? 0
        recurrence = planning?.recurrence; reminders = planning?.reminders ?? []
    }
}

struct PlanningService: Sendable {
    let user: User
    let db: any Database
    var access: ProjectAccess { ProjectAccess(user: user, db: db) }

    func task(_ id: UUID) async throws -> TodoTask {
        let task = try await access.task(id)
        _ = try await access.project(task.projectID)
        return task
    }

    /// Serializes graph and board mutations for this actor across replicas, including cross-project edges.
    func lock() async throws { try await lockRow(table: User.schema, id: user.requireID(), on: db) }

    func put(_ id: UUID, data: PlanningData) async throws -> PlanningTaskDTO {
        try data.validate()
        try await lock()
        try await lockRow(table: TodoTask.schema, id: id, on: db)
        let t = try await task(id)
        let p = try await TaskPlanning.find(id, on: db) ?? TaskPlanning(taskID: id)
        p.dueAt = data.dueAt; p.plannedAt = data.plannedAt; p.priority = data.priority
        p.recurrence = data.recurrence; p.reminders = data.reminders
        try await p.save(on: db)
        // Also reconcile already completed tasks, including completions before recurrence was configured.
        if t.status == "done" { try await spawnNext(t, planning: p) }
        return try PlanningTaskDTO(t, p)
    }

    func addDependency(_ id: UUID, prerequisite: UUID) async throws {
        try await lock()
        _ = try await task(id); _ = try await task(prerequisite)
        guard id != prerequisite else { throw Abort(.unprocessableEntity, reason: "dependency_cycle") }
        let edges = try await PlanningDependency.query(on: db).all()
        var stack = [prerequisite], visited = Set<UUID>()
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == id { throw Abort(.unprocessableEntity, reason: "dependency_cycle") }
            stack.append(contentsOf: edges.filter { $0.taskID == current }.map(\.prerequisiteID))
        }
        if !edges.contains(where: { $0.taskID == id && $0.prerequisiteID == prerequisite }) {
            try await PlanningDependency(id, prerequisite).save(on: db)
        }
    }

    func blocked(_ id: UUID) async throws -> Bool {
        for edge in try await PlanningDependency.query(on: db).filter(\.$taskID == id).all() {
            if let prerequisite = try await TodoTask.find(edge.prerequisiteID, on: db), prerequisite.status != "done" {
                return true
            }
        }
        return false
    }

    func update(_ id: UUID, body: UpdateTaskRequest) async throws -> TaskDTO {
        try await lock()
        try await lockRow(table: TodoTask.schema, id: id, on: db)
        let t = try await task(id)
        guard t.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
        if let title = body.title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 200 else { throw Abort(.badRequest, reason: "invalid_title") }
            t.title = value
        }
        if let details = body.description { t.details = details }
        if let status = body.status {
            guard TaskStatus.all.contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
            t.status = status
        }
        if let project = body.projectID {
            _ = try await access.project(project)
            // Existing dependency/milestone links must not escape their authorized project scope on move.
            if project != t.projectID {
                try await PlanningDependency.query(on: db).group(.or) {
                    $0.filter(\.$taskID == id).filter(\.$prerequisiteID == id)
                }.delete()
                try await PlanningMilestoneTask.query(on: db).filter(\.$taskID == id).delete()
                if let p = try await TaskPlanning.find(id, on: db) { p.position = 0; try await p.save(on: db) }
            }
            t.projectID = project
        }
        t.version += 1
        try await t.save(on: db)
        if t.status == "done", let p = try await TaskPlanning.find(id, on: db) { try await spawnNext(t, planning: p) }
        return try TaskDTO(t)
    }

    /// Caller holds the source task row lock. Receipt and successor commit with completion in one transaction.
    func spawnNext(_ source: TodoTask, planning: TaskPlanning) async throws {
        let id = try source.requireID()
        guard let rule = planning.recurrence, try await PlanningOccurrence.find(id, on: db) == nil else { return }
        let due = try planning.dueAt.map(rule.next)
        let planned = try planning.plannedAt.map(rule.next)
        guard let anchor = due ?? planned else { throw Abort(.badRequest, reason: "recurrence_requires_date") }
        if let until = rule.until, anchor > until {
            try await PlanningOccurrence(source: id, next: nil).save(on: db)
            return
        }
        let next = TodoTask(ownerID: source.ownerID, projectID: source.projectID, title: source.title, details: source.details)
        try await next.save(on: db)
        let p = TaskPlanning(taskID: try next.requireID())
        p.dueAt = due; p.plannedAt = planned; p.priority = planning.priority; p.recurrence = rule
        p.reminders = try planning.reminders.map(rule.next)
        try await p.save(on: db)
        try await PlanningOccurrence(source: id, next: next.requireID()).save(on: db)
    }

    func visibleTasks() async throws -> [TodoTask] {
        var result: [TodoTask] = []
        for t in try await TodoTask.query(on: db).sort(\.$id).all() {
            do { result.append(try await task(t.requireID())) }
            catch let error as AbortError where error.status == .notFound { continue }
        }
        return result
    }
}

/// Keep the established PATCH API as the atomic completion entry point without editing its controller.
struct PlanningCompletionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let parts = request.url.path.split(separator: "/")
        guard request.method == .PATCH, parts.count == 3, parts[0] == "v1", parts[1] == "tasks",
              let id = UUID(uuidString: String(parts[2])) else { return try await next.respond(to: request) }
        let user = try await request.requireUser()
        let body = try request.content.decode(UpdateTaskRequest.self)
        let dto = try await request.db.transaction { db in
            try await PlanningService(user: user, db: db).update(id, body: body)
        }
        return try await dto.encodeResponse(for: request)
    }
}
