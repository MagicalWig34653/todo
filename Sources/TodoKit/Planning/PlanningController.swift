import Fluent
import Vapor

struct ProjectDTO: Content {
    let id: UUID
    let parentID: UUID?
    let name: String
    let version: Int

    init(_ p: Project) throws {
        id = try p.requireID()
        parentID = p.parentID
        name = p.name
        version = p.version
    }
}

struct CreateProjectRequest: Content {
    let name: String
    let parentID: UUID?
}

/// `version` is the version the client last saw; a mismatch yields 409 instead of a silent overwrite.
struct UpdateProjectRequest: Content {
    let version: Int
    let name: String?
    let parentID: UUID??
    let moveToRoot: Bool?
}

struct TaskDTO: Content {
    let id: UUID
    let projectID: UUID
    let title: String
    let description: String
    let status: String
    let version: Int

    init(_ t: TodoTask) throws {
        id = try t.requireID()
        projectID = t.projectID
        title = t.title
        description = t.details
        status = t.status
        version = t.version
    }
}

struct CreateTaskRequest: Content {
    let projectID: UUID
    let title: String
    let description: String?
}

struct UpdateTaskRequest: Content {
    let version: Int
    let title: String?
    let description: String?
    let status: String?
    let projectID: UUID?
}

enum TaskStatus {
    static let all: Set<String> = ["open", "in_progress", "in_review", "done"]
}

/// Central access checks. Later stages (teams, grants) extend these functions only, so every route keeps
/// going through one place. Missing and foreign objects are indistinguishable (404).
struct ProjectAccess {
    let user: User
    let db: any Database

    func project(_ id: UUID) async throws -> Project {
        guard let project = try await Project.find(id, on: db), project.ownerID == user.id else {
            throw Abort(.notFound)
        }
        return project
    }

    func task(_ id: UUID) async throws -> TodoTask {
        guard let task = try await TodoTask.find(id, on: db), task.ownerID == user.id else {
            throw Abort(.notFound)
        }
        return task
    }

    /// True if `candidate` is `project` itself or one of its descendants.
    func isSelfOrDescendant(_ candidate: UUID, of project: UUID) async throws -> Bool {
        var current: UUID? = candidate
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted {
            if id == project { return true }
            current = try await Project.find(id, on: db)?.parentID
        }
        return false
    }
}

struct PlanningController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("projects", use: listProjects)
        v1.post("projects", use: createProject)
        v1.patch("projects", ":id", use: updateProject)
        v1.delete("projects", ":id", use: deleteProject)
        v1.get("tasks", use: listTasks)
        v1.post("tasks", use: createTask)
        v1.patch("tasks", ":id", use: updateTask)
        v1.delete("tasks", ":id", use: deleteTask)
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    private func cleanName(_ raw: String, reason: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw Abort(.badRequest, reason: reason) }
        return name
    }

    // MARK: Projects

    @Sendable func listProjects(_ req: Request) async throws -> [ProjectDTO] {
        let user = try await req.requireUser()
        return try await Project.query(on: req.db).filter(\.$ownerID == (try user.requireID()))
            .sort(\.$createdAt).sort(\.$id).all().map(ProjectDTO.init)
    }

    @Sendable func createProject(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let body = try req.content.decode(CreateProjectRequest.self)
        let access = ProjectAccess(user: user, db: req.db)
        if let parent = body.parentID { _ = try await access.project(parent) }
        let project = Project(
            ownerID: try user.requireID(), parentID: body.parentID, name: try cleanName(body.name, reason: "invalid_name"))
        try await project.save(on: req.db)
        return try await ProjectDTO(project).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateProject(_ req: Request) async throws -> ProjectDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(UpdateProjectRequest.self)
        let projectID = try id(req)
        return try await req.db.transaction { db in
            let access = ProjectAccess(user: user, db: db)
            try await lockRow(table: Project.schema, id: projectID, on: db)
            let project = try await access.project(projectID)
            guard project.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
            if let name = body.name { project.name = try cleanName(name, reason: "invalid_name") }
            if body.moveToRoot == true {
                project.parentID = nil
            } else if let newParent = body.parentID ?? nil {
                _ = try await access.project(newParent)
                if try await access.isSelfOrDescendant(newParent, of: projectID) {
                    throw Abort(.unprocessableEntity, reason: "project_cycle")
                }
                project.parentID = newParent
            }
            project.version += 1
            try await project.save(on: db)
            return try ProjectDTO(project)
        }
    }

    @Sendable func deleteProject(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        let project = try await ProjectAccess(user: user, db: req.db).project(try id(req))
        try await project.delete(on: req.db)
        return .noContent
    }

    // MARK: Tasks

    @Sendable func listTasks(_ req: Request) async throws -> [TaskDTO] {
        let user = try await req.requireUser()
        var query = TodoTask.query(on: req.db).filter(\.$ownerID == (try user.requireID()))
        if let projectID = req.query[UUID.self, at: "projectID"] {
            _ = try await ProjectAccess(user: user, db: req.db).project(projectID)
            query = query.filter(\.$projectID == projectID)
        }
        return try await query.sort(\.$createdAt).sort(\.$id).all().map(TaskDTO.init)
    }

    @Sendable func createTask(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let body = try req.content.decode(CreateTaskRequest.self)
        _ = try await ProjectAccess(user: user, db: req.db).project(body.projectID)
        let task = TodoTask(
            ownerID: try user.requireID(), projectID: body.projectID,
            title: try cleanName(body.title, reason: "invalid_title"), details: body.description ?? "")
        try await task.save(on: req.db)
        return try await TaskDTO(task).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateTask(_ req: Request) async throws -> TaskDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(UpdateTaskRequest.self)
        let taskID = try id(req)
        return try await req.db.transaction { db in
            let access = ProjectAccess(user: user, db: db)
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            guard let task = try await TodoTask.find(taskID, on: db),
                task.ownerID == user.id
            else { throw Abort(.notFound) }
            guard task.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
            if let title = body.title { task.title = try cleanName(title, reason: "invalid_title") }
            if let description = body.description { task.details = description }
            if let status = body.status {
                guard TaskStatus.all.contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
                task.status = status
            }
            if let projectID = body.projectID {
                _ = try await access.project(projectID)
                task.projectID = projectID
            }
            task.version += 1
            try await task.save(on: db)
            return try TaskDTO(task)
        }
    }

    @Sendable func deleteTask(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        try await ProjectAccess(user: user, db: req.db).task(try id(req)).delete(on: req.db)
        return .noContent
    }
}
