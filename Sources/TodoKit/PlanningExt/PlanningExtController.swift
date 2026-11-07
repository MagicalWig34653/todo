import Fluent
import Vapor

struct PlanningReorder: Content { var projectID: UUID; var status: String; var taskIDs: [UUID] }
struct PlanningDependencyInput: Content { var prerequisiteID: UUID }
struct PlanningMilestoneInput: Content { var projectID: UUID; var title: String; var dueAt: Date? }
struct PlanningDependencyEdgeDTO: Content { var taskID: UUID; var prerequisiteID: UUID }
/// Per-task facts the graph view needs and the plain task list does not carry.
/// `title`, `status`, `projectID` and `dueAt` are only set with `details=true` (then the view needs no separate task lists).
/// One build (all completed artifacts of one build id on one task); `createdAt` is the newest artifact.
struct PlanningGraphBuildDTO: Content { var buildID: String; var label: String?; var platform: String?; var count: Int; var createdAt: Date? }
struct PlanningGraphNodeDTO: Content {
    var taskID: UUID; var kind: String; var parentTaskID: UUID?; var createdAt: Date?; var updatedAt: Date?; var claimedLabel: String?
    var title: String? = nil; var status: String? = nil; var projectID: UUID? = nil; var dueAt: Date? = nil
    /// Only with `details=true`; builds of the task grouped by build id, newest first (omitted when there are none).
    var builds: [PlanningGraphBuildDTO]? = nil
}
struct PlanningGraphMemberDTO: Content { var taskID: UUID; var status: String }
struct PlanningGraphMilestoneDTO: Content { var id: UUID; var title: String; var dueAt: Date?; var tasks: [PlanningGraphMemberDTO] }
/// `milestones` is only set with `details=true`.
struct PlanningGraphDTO: Content { var edges: [PlanningDependencyEdgeDTO]; var tasks: [PlanningGraphNodeDTO]; var milestones: [PlanningGraphMilestoneDTO]? = nil }
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
        r.get("dependencies", use: projectDependencies)
        r.put("tasks", ":id", "dependencies", use: addDependency)
        r.delete("tasks", ":id", "dependencies", ":other", use: removeDependency)
        r.post("milestones", use: createMilestone)
        r.get("milestones", use: milestones)
        r.delete("milestones", ":id", use: deleteMilestone)
        r.put("milestones", ":id", "tasks", ":other", use: attach)
        r.delete("milestones", ":id", "tasks", ":other", use: detach)
    }

    private func param(_ req: Request, _ name: String = "id") throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.badRequest) }; return id
    }
    private func service(_ req: Request) async throws -> PlanningService {
        PlanningService(user: try await req.requireUser(), db: req.db)
    }
    @Sendable func get(_ req: Request) async throws -> PlanningTaskDTO {
        let s = try await service(req), id = try param(req)
        return try await PlanningTaskDTO(s.task(id), TaskPlanning.find(id, on: req.db))
    }
    @Sendable func put(_ req: Request) async throws -> PlanningTaskDTO {
        let s = try await service(req), id = try param(req), data = try req.content.decode(PlanningData.self)
        return try await req.db.transaction { db in try await PlanningService(user: s.user, db: db).put(id, data: data) }
    }
    private func list(_ req: Request, mode: String) async throws -> [PlanningTaskDTO] {
        try await service(req).plannedTasks(mode: mode, timeZone: req.query.get(String?.self, at: "timeZone") ?? "UTC")
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
        try await req.db.transaction { db in
            try await PlanningService(user: s.user, db: db).reorderBoard(projectID: body.projectID, status: body.status, taskIDs: body.taskIDs)
        }
        return .noContent
    }
    @Sendable func dependencies(_ req: Request) async throws -> [TaskDTO] {
        try await service(req).dependencies(param(req)).map { try TaskDTO($0) }
    }
    /// All dependency edges between visible tasks of a project (optionally with its sub-projects) in one call.
    @Sendable func projectDependencies(_ req: Request) async throws -> PlanningGraphDTO {
        let project = try req.query.get(UUID.self, at: "projectID")
        let includeSub = (try? req.query.get(Bool.self, at: "includeSubprojects")) ?? false
        let details = (try? req.query.get(Bool.self, at: "details")) ?? false
        return try await service(req).projectDependencies(project, includeSubprojects: includeSub, details: details)
    }
    @Sendable func addDependency(_ req: Request) async throws -> HTTPStatus {
        let s = try await service(req), id = try param(req), body = try req.content.decode(PlanningDependencyInput.self)
        try await req.db.transaction { db in try await PlanningService(user: s.user, db: db).addDependency(id, prerequisite: body.prerequisiteID) }
        return .noContent
    }
    @Sendable func removeDependency(_ req: Request) async throws -> HTTPStatus {
        let s = try await service(req), id = try param(req), other = try param(req, "other")
        try await req.db.transaction { db in try await PlanningService(user: s.user, db: db).removeDependency(id, prerequisite: other) }
        return .noContent
    }
    @Sendable func createMilestone(_ req: Request) async throws -> PlanningMilestone {
        let s = try await service(req), body = try req.content.decode(PlanningMilestoneInput.self)
        return try await s.createMilestone(projectID: body.projectID, title: body.title, dueAt: body.dueAt)
    }
    @Sendable func milestones(_ req: Request) async throws -> [PlanningMilestoneDTO] {
        try await service(req).milestones(req.query.get(UUID.self, at: "projectID"))
    }
    @Sendable func deleteMilestone(_ req: Request) async throws -> HTTPStatus {
        try await service(req).deleteMilestone(param(req)); return .noContent
    }
    private func membership(_ req: Request, remove: Bool) async throws -> HTTPStatus {
        let s = try await service(req), id = try param(req), other = try param(req, "other")
        try await req.db.transaction { db in
            try await PlanningService(user: s.user, db: db).milestoneMembership(id, taskID: other, remove: remove)
        }
        return .noContent
    }
    @Sendable func attach(_ req: Request) async throws -> HTTPStatus { try await membership(req, remove: false) }
    @Sendable func detach(_ req: Request) async throws -> HTTPStatus { try await membership(req, remove: true) }
}
