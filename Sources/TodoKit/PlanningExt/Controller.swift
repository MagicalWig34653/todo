import Fluent
import Vapor

struct PlanningReorder: Content { var projectID: UUID; var status: String; var taskIDs: [UUID] }
struct PlanningDependencyInput: Content { var prerequisiteID: UUID }
struct PlanningMilestoneInput: Content { var projectID: UUID; var title: String; var dueAt: Date? }
struct PlanningMilestoneDTO: Content { var milestone: PlanningMilestone; var tasks: [TaskDTO] }

struct PlanningExtController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Installed before the application's responder is constructed.
        if let app = routes as? Application { app.middleware.use(PlanningCompletionMiddleware()) }
        let r = routes.grouped("v1", "planning")
        r.get("tasks", ":id", use: get)
        r.put("tasks", ":id", use: put)
        r.get("today", use: today)
        r.get("upcoming", use: upcoming)
        r.get("up-next", use: upNext)
        r.get("board", use: board)
        r.put("board", "reorder", use: reorder)
        r.get("tasks", ":id", "dependencies", use: dependencies)
        r.put("tasks", ":id", "dependencies", use: addDependency)
        r.delete("tasks", ":id", "dependencies", ":other", use: removeDependency)
        r.post("milestones", use: createMilestone)
        r.get("milestones", use: milestones)
        r.delete("milestones", ":id", use: deleteMilestone)
        r.put("milestones", ":id", "tasks", ":other", use: attach)
        r.delete("milestones", ":id", "tasks", ":other", use: detach)
    }

    private func id(_ req: Request, _ name: String = "id") throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.badRequest) }; return id
    }
    private func service(_ req: Request) async throws -> PlanningService {
        PlanningService(user: try await req.requireUser(), db: req.db)
    }
    @Sendable func get(_ req: Request) async throws -> PlanningTaskDTO {
        let s = try await service(req), id = try id(req)
        return try await PlanningTaskDTO(s.task(id), TaskPlanning.find(id, on: req.db))
    }
    @Sendable func put(_ req: Request) async throws -> PlanningTaskDTO {
        let s = try await service(req), id = try id(req), data = try req.content.decode(PlanningData.self)
        return try await req.db.transaction { db in try await PlanningService(user: s.user, db: db).put(id, data: data) }
    }
    private func list(_ req: Request, mode: String) async throws -> [PlanningTaskDTO] {
        let s = try await service(req)
        var calendar = Calendar(identifier: .gregorian)
        let zone = try req.query.get(String?.self, at: "timeZone") ?? "UTC"
        guard let timeZone = TimeZone(identifier: zone) else { throw Abort(.badRequest) }
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date()), end = calendar.date(byAdding: .day, value: 1, to: start)!
        var result: [PlanningTaskDTO] = []
        for task in try await s.visibleTasks() where task.status != "done" {
            let p = try await TaskPlanning.find(task.requireID(), on: req.db)
            if mode == "up-next" {
                if try await s.blocked(task.requireID()) { continue }
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
    @Sendable func today(_ req: Request) async throws -> [PlanningTaskDTO] { try await list(req, mode: "today") }
    @Sendable func upcoming(_ req: Request) async throws -> [PlanningTaskDTO] { try await list(req, mode: "upcoming") }
    @Sendable func upNext(_ req: Request) async throws -> [PlanningTaskDTO] { try await list(req, mode: "up-next") }
    @Sendable func board(_ req: Request) async throws -> [PlanningTaskDTO] {
        let s = try await service(req), project = try req.query.get(UUID.self, at: "projectID")
        let status = try req.query.get(String.self, at: "status")
        _ = try await s.access.project(project)
        guard TaskStatus.all.contains(status) else { throw Abort(.badRequest) }
        var result: [PlanningTaskDTO] = []
        for t in try await s.visibleTasks() where t.projectID == project && t.status == status {
            result.append(try await PlanningTaskDTO(t, TaskPlanning.find(t.requireID(), on: req.db)))
        }
        return result.sorted { $0.position == $1.position ? $0.task.id.uuidString < $1.task.id.uuidString : $0.position < $1.position }
    }
    @Sendable func reorder(_ req: Request) async throws -> HTTPStatus {
        let s = try await service(req), body = try req.content.decode(PlanningReorder.self)
        guard TaskStatus.all.contains(body.status), Set(body.taskIDs).count == body.taskIDs.count else { throw Abort(.badRequest) }
        try await req.db.transaction { db in
            let s = PlanningService(user: s.user, db: db)
            try await s.lock(); _ = try await s.access.project(body.projectID)
            let tasks = try await s.visibleTasks().filter { $0.projectID == body.projectID && $0.status == body.status }
            guard Set(try tasks.map { try $0.requireID() }) == Set(body.taskIDs) else { throw Abort(.conflict, reason: "board_changed") }
            for (position, id) in body.taskIDs.enumerated() {
                let p = try await TaskPlanning.find(id, on: db) ?? TaskPlanning(taskID: id)
                p.position = position; try await p.save(on: db)
            }
        }
        return .noContent
    }
    @Sendable func dependencies(_ req: Request) async throws -> [TaskDTO] {
        let s = try await service(req), id = try id(req)
        _ = try await s.task(id)
        var result: [TaskDTO] = []
        for edge in try await PlanningDependency.query(on: req.db).filter(\.$taskID == id).all() {
            do { result.append(try await TaskDTO(s.task(edge.prerequisiteID))) }
            catch let error as AbortError where error.status == .notFound { continue }
        }
        return result
    }
    @Sendable func addDependency(_ req: Request) async throws -> HTTPStatus {
        let s = try await service(req), id = try id(req), body = try req.content.decode(PlanningDependencyInput.self)
        try await req.db.transaction { db in try await PlanningService(user: s.user, db: db).addDependency(id, prerequisite: body.prerequisiteID) }
        return .noContent
    }
    @Sendable func removeDependency(_ req: Request) async throws -> HTTPStatus {
        let s = try await service(req), id = try id(req), other = try id(req, "other")
        try await req.db.transaction { db in
            let s = PlanningService(user: s.user, db: db)
            try await s.lock(); _ = try await s.task(id); _ = try await s.task(other)
            try await PlanningDependency.query(on: db).filter(\.$taskID == id).filter(\.$prerequisiteID == other).delete()
        }
        return .noContent
    }
    private func milestone(_ id: UUID, service s: PlanningService) async throws -> PlanningMilestone {
        guard let m = try await PlanningMilestone.find(id, on: s.db) else { throw Abort(.notFound) }
        _ = try await s.access.project(m.projectID)
        return m
    }
    @Sendable func createMilestone(_ req: Request) async throws -> PlanningMilestone {
        let s = try await service(req), body = try req.content.decode(PlanningMilestoneInput.self)
        _ = try await s.access.project(body.projectID)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw Abort(.badRequest) }
        let m = PlanningMilestone(projectID: body.projectID, title: title, dueAt: body.dueAt)
        try await m.save(on: req.db); return m
    }
    @Sendable func milestones(_ req: Request) async throws -> [PlanningMilestoneDTO] {
        let s = try await service(req), project = try req.query.get(UUID.self, at: "projectID")
        _ = try await s.access.project(project)
        var result: [PlanningMilestoneDTO] = []
        for m in try await PlanningMilestone.query(on: req.db).filter(\.$projectID == project).all() {
            var tasks: [TaskDTO] = []
            for link in try await PlanningMilestoneTask.query(on: req.db).filter(\.$milestoneID == m.requireID()).all() {
                do {
                    let t = try await s.task(link.taskID)
                    if try await s.access.isSelfOrDescendant(t.projectID, of: project) { tasks.append(try TaskDTO(t)) }
                } catch let error as AbortError where error.status == .notFound { continue }
            }
            result.append(PlanningMilestoneDTO(milestone: m, tasks: tasks))
        }
        return result
    }
    @Sendable func deleteMilestone(_ req: Request) async throws -> HTTPStatus {
        let s = try await service(req)
        try await milestone(id(req), service: s).delete(on: req.db); return .noContent
    }
    private func membership(_ req: Request, remove: Bool) async throws -> HTTPStatus {
        let s = try await service(req), id = try id(req), other = try id(req, "other")
        try await req.db.transaction { db in
            let s = PlanningService(user: s.user, db: db)
            try await s.lock()
            let m = try await milestone(id, service: s), t = try await s.task(other)
            guard try await s.access.isSelfOrDescendant(t.projectID, of: m.projectID) else { throw Abort(.unprocessableEntity) }
            let query = PlanningMilestoneTask.query(on: db).filter(\.$milestoneID == id).filter(\.$taskID == other)
            if remove { try await query.delete() }
            else if try await query.first() == nil { try await PlanningMilestoneTask(id, other).save(on: db) }
        }
        return .noContent
    }
    @Sendable func attach(_ req: Request) async throws -> HTTPStatus { try await membership(req, remove: false) }
    @Sendable func detach(_ req: Request) async throws -> HTTPStatus { try await membership(req, remove: true) }
}
