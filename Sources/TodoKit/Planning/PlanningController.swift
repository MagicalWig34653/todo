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

/// Central effective project rights for every planning route. Missing and hidden objects yield 404.
struct ProjectAccess {
    let user: User
    let db: any Database

    func project(_ id: UUID, role: ProjectRole = .read) async throws -> Project {
        guard let project = try await Project.find(id, on: db) else { throw Abort(.notFound) }
        _ = try await SharingAccess(user: user, db: db).require(project, role: role)
        return project
    }

    func task(_ id: UUID, role: ProjectRole = .read) async throws -> TodoTask {
        guard let task = try await TodoTask.find(id, on: db) else { throw Abort(.notFound) }
        _ = try await project(task.projectID, role: role)
        return task
    }

    func visibleProjects() async throws -> [Project] {
        var result: [Project] = []
        for project in try await Project.query(on: db).sort(\.$createdAt).sort(\.$id).all() {
            if try await SharingAccess(user: user, db: db).visibility(project).role != nil { result.append(project) }
        }
        return result
    }

    func dto(_ project: Project) async throws -> ProjectDTO {
        if let parentID = project.parentID, let parent = try await Project.find(parentID, on: db),
            try await SharingAccess(user: user, db: db).visibility(parent).role == nil {
            let redacted = Project(ownerID: project.ownerID, parentID: nil, name: project.name)
            redacted.id = project.id; redacted.version = project.version
            return try ProjectDTO(redacted)
        }
        return try ProjectDTO(project)
    }

    func requireDeletion(_ project: Project) async throws {
        guard try await SharingAccess(user: user, db: db).visibility(project).canDelete else { throw Abort(.forbidden) }
        // Cascading deletion must not destroy another owner's or a hidden descendant's content.
        for candidate in try await Project.query(on: db).all() {
            if try await isSelfOrDescendant(candidate.requireID(), of: project.requireID()),
                try await SharingAccess(user: user, db: db).visibility(candidate).canDelete == false {
                throw Abort(.conflict, reason: "subtree_ownership_required")
            }
        }
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

/// Shared write operations for projects and tasks. Callers (REST routes and the sync mutation endpoint) run them
/// inside a transaction after `lockSharingGraph`; all permission checks live here so neither path can bypass them.
enum PlanningOperations {
    static func cleanName(_ raw: String, reason: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw Abort(.badRequest, reason: reason) }
        return name
    }

    static func createProject(user: User, db: any Database, id: UUID? = nil, body: CreateProjectRequest) async throws -> Project {
        let access = ProjectAccess(user: user, db: db)
        if let parent = body.parentID { _ = try await access.project(parent, role: .manage) }
        let project = Project(
            ownerID: try user.requireID(), parentID: body.parentID, name: try cleanName(body.name, reason: "invalid_name"))
        project.id = id
        try await project.save(on: db)
        return project
    }

    static func updateProject(user: User, db: any Database, id projectID: UUID, body: UpdateProjectRequest) async throws -> ProjectDTO {
        let access = ProjectAccess(user: user, db: db)
        try await lockRow(table: Project.schema, id: projectID, on: db)
        let project = try await access.project(projectID, role: .manage)
        guard project.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
        if let name = body.name { project.name = try cleanName(name, reason: "invalid_name") }
        if body.moveToRoot == true {
            project.parentID = nil
        } else if let newParent = body.parentID ?? nil {
            _ = try await access.project(newParent, role: .manage)
            if try await access.isSelfOrDescendant(newParent, of: projectID) {
                throw Abort(.unprocessableEntity, reason: "project_cycle")
            }
            project.parentID = newParent
        }
        project.version += 1
        try await project.save(on: db)
        return try await access.dto(project)
    }

    static func deleteProject(user: User, db: any Database, id projectID: UUID, expectedVersion: Int? = nil) async throws {
        let access = ProjectAccess(user: user, db: db)
        let project = try await access.project(projectID)
        if let expectedVersion, project.version != expectedVersion { throw Abort(.conflict, reason: "version_conflict") }
        try await access.requireDeletion(project)
        try await project.delete(on: db)
    }

    static func createTask(user: User, db: any Database, id: UUID? = nil, body: CreateTaskRequest) async throws -> TodoTask {
        _ = try await ProjectAccess(user: user, db: db).project(body.projectID, role: .edit)
        let task = TodoTask(
            ownerID: try user.requireID(), projectID: body.projectID,
            title: try cleanName(body.title, reason: "invalid_title"), details: body.description ?? "")
        task.id = id
        try await task.save(on: db)
        return task
    }

    static func deleteTask(user: User, db: any Database, id taskID: UUID, expectedVersion: Int? = nil) async throws {
        let access = ProjectAccess(user: user, db: db)
        let task = try await access.task(taskID, role: .edit)
        if let expectedVersion, task.version != expectedVersion { throw Abort(.conflict, reason: "version_conflict") }
        let project = try await access.project(task.projectID)
        guard try await SharingAccess(user: user, db: db).visibility(project).canDelete else {
            throw Abort(.forbidden)
        }
        try await task.delete(on: db)
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

    // MARK: Projects

    @Sendable func listProjects(_ req: Request) async throws -> [ProjectDTO] {
        let user = try await req.requireUser()
        let access = ProjectAccess(user: user, db: req.db)
        var result: [ProjectDTO] = []
        for project in try await access.visibleProjects() { result.append(try await access.dto(project)) }
        return result
    }

    @Sendable func createProject(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let body = try req.content.decode(CreateProjectRequest.self)
        let project = try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            return try await PlanningOperations.createProject(user: user, db: db, body: body)
        }
        return try await ProjectDTO(project).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateProject(_ req: Request) async throws -> ProjectDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(UpdateProjectRequest.self)
        let projectID = try id(req)
        return try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            return try await PlanningOperations.updateProject(user: user, db: db, id: projectID, body: body)
        }
    }

    @Sendable func deleteProject(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        let projectID = try id(req)
        return try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            try await PlanningOperations.deleteProject(user: user, db: db, id: projectID)
            return .noContent
        }
    }

    // MARK: Tasks

    @Sendable func listTasks(_ req: Request) async throws -> [TaskDTO] {
        let user = try await req.requireUser()
        let access = ProjectAccess(user: user, db: req.db)
        let visibleIDs = try await access.visibleProjects().map { try $0.requireID() }
        var query = TodoTask.query(on: req.db).filter(\.$projectID ~~ visibleIDs)
        if let projectID = req.query[UUID.self, at: "projectID"] {
            _ = try await ProjectAccess(user: user, db: req.db).project(projectID)
            query = query.filter(\.$projectID == projectID)
        }
        guard !visibleIDs.isEmpty else { return [] }
        return try await query.sort(\.$createdAt).sort(\.$id).all().map(TaskDTO.init)
    }

    @Sendable func createTask(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let body = try req.content.decode(CreateTaskRequest.self)
        let task = try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            return try await PlanningOperations.createTask(user: user, db: db, body: body)
        }
        return try await TaskDTO(task).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateTask(_ req: Request) async throws -> TaskDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(UpdateTaskRequest.self)
        let taskID = try id(req)
        return try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            let access = ProjectAccess(user: user, db: db)
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            let task = try await access.task(taskID, role: .edit)
            guard task.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
            if let title = body.title { task.title = try PlanningOperations.cleanName(title, reason: "invalid_title") }
            if let description = body.description { task.details = description }
            if let status = body.status {
                guard TaskStatus.all.contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
                task.status = status
            }
            if let projectID = body.projectID {
                _ = try await access.project(projectID, role: .edit)
                task.projectID = projectID
            }
            task.version += 1
            try await task.save(on: db)
            return try TaskDTO(task)
        }
    }

    @Sendable func deleteTask(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        let taskID = try id(req)
        return try await req.db.transaction { db in
            try await lockSharingGraph(on: db)
            try await PlanningOperations.deleteTask(user: user, db: db, id: taskID)
            return .noContent
        }
    }
}
