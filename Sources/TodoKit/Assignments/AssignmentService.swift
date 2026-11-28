import Fluent
import Vapor

/// A person who can be made responsible in a project. Only the name and the id: nothing else is needed to assign.
struct AssigneeDTO: Content {
    let userID: UUID
    let displayName: String
    /// Subset of `task`, `question`, `review` (depends on the person's role in the project).
    let assignableTo: [String]
    /// True for the account that asks (for an agent: the person of its connection).
    let isMe: Bool
}

/// Body of the three assignment routes. The key is required, so that an empty body never clears an assignment.
struct AssigneeRequest: Content {
    /// `null` removes the responsible person.
    let assigneeID: UUID?
    init(assigneeID: UUID?) { self.assigneeID = assigneeID }
    private enum CodingKeys: String, CodingKey { case assigneeID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.assigneeID) else { throw Abort(.badRequest, reason: "assignee_required") }
        assigneeID = try c.decodeIfPresent(UUID.self, forKey: .assigneeID)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assigneeID, forKey: .assigneeID)
    }
}

/// Everything that is open and concerns one person (ADR 0043).
struct ForMeResponse: Content {
    let generatedAt: Date
    let projectID: UUID?
    /// Unfinished cards assigned to the caller, newest change first.
    var tasks: [TaskDTO]
    /// Open questions the caller is responsible for (named, or through the card), oldest first.
    var questions: [QuestionDTO]
    /// Pending reviews the caller is responsible for, oldest first.
    var reviews: [ReviewDTO]
    /// True when a list was cut at `limit`.
    var truncated: Bool
}

extension WorkflowService {
    /// Refuses everyone who may not hold this responsibility. Unknown, locked and unrelated accounts get the same answer.
    static func requireAssignable(_ userID: UUID, to kind: AssignmentKind, projectID: UUID,
                                  reason: String = "invalid_assignee", on db: any Database) async throws {
        guard try await ResponsibilityResolver(db: db).isAssignable(userID, to: kind, projectID: projectID) else {
            throw Abort(.badRequest, reason: reason)
        }
    }

    /// A named reviewer restricts who decides, so only that person or the project management may change or remove it.
    static func requireReviewHandover(_ current: UUID?, projectID: UUID, user: User, on db: any Database) async throws {
        guard let current, current != (try user.requireID()) else { return }
        do { _ = try await ProjectAccess(user: user, db: db).project(projectID, role: .manage) }
        catch { throw Abort(.forbidden, reason: "not_the_reviewer") }
    }

    func assignTask(_ taskID: UUID, to assignee: UUID?, actor: WorkflowActor) async throws -> TaskDTO {
        try await mutate(taskID, role: .edit) { task, tx in
            if let assignee { try await Self.requireAssignable(assignee, to: .task, projectID: task.projectID, on: tx) }
            guard task.assigneeID != assignee else { return try TaskDTO(task) }
            task.assigneeID = assignee; task.version += 1
            try await task.save(on: tx)
            try await appendActivity(taskID: taskID, actorType: actor.type, actorID: actor.id, kind: "task.assigned", subjectID: nil, on: tx)
            return try TaskDTO(task)
        }
    }

    func assignQuestion(_ questionID: UUID, to assignee: UUID?, actor: WorkflowActor) async throws -> QuestionDTO {
        guard let initial = try await TaskQuestion.find(questionID, on: db) else { throw Abort(.notFound) }
        return try await mutate(initial.taskID, role: .edit) { task, tx in
            guard let q = try await TaskQuestion.find(questionID, on: tx) else { throw Abort(.notFound) }
            guard q.state == "open" else { throw Abort(.conflict, reason: "question_not_open") }
            // Answering a runner question follows the runner's own rights; it cannot be handed to somebody else.
            guard q.agentQuestionID == nil else { throw Abort(.conflict, reason: "runner_item") }
            if let assignee { try await Self.requireAssignable(assignee, to: .question, projectID: task.projectID, on: tx) }
            guard q.assigneeID != assignee else { return try QuestionDTO(q) }
            q.assigneeID = assignee; q.assignedAt = Date(); q.version += 1
            try await q.save(on: tx)
            try await appendActivity(taskID: q.taskID, actorType: actor.type, actorID: actor.id, kind: "question.assigned", subjectID: q.id, on: tx)
            return try QuestionDTO(q)
        }
    }

    func assignReview(_ reviewID: UUID, to assignee: UUID?, actor: WorkflowActor) async throws -> ReviewDTO {
        guard let initial = try await TaskReview.find(reviewID, on: db) else { throw Abort(.notFound) }
        let user = self.user
        return try await mutate(initial.taskID, role: .edit) { task, tx in
            guard let r = try await TaskReview.find(reviewID, on: tx) else { throw Abort(.notFound) }
            guard r.state == "pending" else { throw Abort(.conflict, reason: "no_pending_review") }
            guard r.agentJobID == nil else { throw Abort(.conflict, reason: "runner_item") }
            try await Self.requireReviewHandover(r.reviewerID, projectID: task.projectID, user: user, on: tx)
            if let assignee { try await Self.requireAssignable(assignee, to: .review, projectID: task.projectID, on: tx) }
            guard r.reviewerID != assignee else { return try ReviewDTO(r) }
            r.reviewerID = assignee; r.assignedAt = Date(); r.version += 1
            try await r.save(on: tx)
            try await appendActivity(taskID: r.taskID, actorType: actor.type, actorID: actor.id, kind: "review.assigned", subjectID: r.id, on: tx)
            return try ReviewDTO(r)
        }
    }

    /// People with access to a project, for whoever may assign there (edit). The candidates are gathered from owner,
    /// teams and grants along the inheritance chain; each is then checked with the normal visibility rule.
    func assignees(_ projectID: UUID) async throws -> [AssigneeDTO] {
        let project = try await self.project(projectID, role: .edit)
        var people = Set<UUID>(), teams = Set<UUID>()
        let sharing = try await ProjectSharing.query(on: db).filter(\.$projectID == projectID).first()
        if sharing?.ownerType == "team" { teams.insert(sharing!.ownerID) } else { people.insert(sharing?.ownerID ?? project.ownerID) }
        var current: Project? = project
        var seen = Set<UUID>()
        while let p = current, let id = p.id, seen.insert(id).inserted {
            for grant in try await ProjectGrant.query(on: db).filter(\.$projectID == id).all() {
                if grant.principalType == "team" { teams.insert(grant.principalID) } else { people.insert(grant.principalID) }
            }
            if try await ProjectSharing.query(on: db).filter(\.$projectID == id).first()?.inherits == false { break }
            current = try await p.parentID.asyncFlatMap { try await Project.find($0, on: db) }
        }
        if !teams.isEmpty {
            people.formUnion(try await TeamMembership.query(on: db).filter(\.$teamID ~~ Array(teams)).filter(\.$accepted == true).all().map(\.userID))
        }
        let me = try user.requireID()
        let resolver = ResponsibilityResolver(db: db)
        let names = try await displayNames(Array(people), on: db)
        var result: [AssigneeDTO] = []
        for (id, name) in names {
            guard let role = try await resolver.role(of: id, projectID: projectID) else { continue }
            result.append(AssigneeDTO(userID: id, displayName: name,
                assignableTo: AssignmentKind.allCases.filter { role.rank >= $0.role.rank }.map(\.rawValue), isMe: id == me))
        }
        return result.sorted { ($0.displayName.lowercased(), $0.userID.uuidString) < ($1.displayName.lowercased(), $1.userID.uuidString) }
    }

    static let forMeDefaultLimit = 100

    func forMe(projectID: UUID?, includeSubprojects: Bool = true, limit: Int = WorkflowService.forMeDefaultLimit,
               now: Date = Date()) async throws -> ForMeResponse {
        guard (1...200).contains(limit) else { throw Abort(.badRequest, reason: "invalid_filter") }
        let me = try user.requireID()
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: includeSubprojects, allowed: allowedProjects)
        var response = ForMeResponse(generatedAt: now, projectID: projectID, tasks: [], questions: [], reviews: [], truncated: false)
        let inScope = Array(scope.projectIDs)
        guard !inScope.isEmpty else { return response }
        // All of the caller's cards, finished ones too: their questions still wait for an answer.
        let cards = try await TodoTask.query(on: db).filter(\.$assigneeID == me).filter(\.$projectID ~~ inScope)
            .sort(\.$updatedAt, .descending).sort(\.$id).all()
        let cardIDs = try cards.map { try $0.requireID() }
        let resolver = ResponsibilityResolver(db: db)

        var open: [TodoTask] = []
        for card in cards where card.status != "done" {
            guard try await resolver.isAssignable(me, to: .task, projectID: card.projectID) else { continue }
            open.append(card)
        }
        response.truncated = open.count > limit
        let shown = Array(open.prefix(limit))
        var planning: [UUID: TaskPlanning] = [:]
        for row in try await TaskPlanning.query(on: db).filter(\.$id ~~ shown.map { try $0.requireID() }).all() { planning[try row.requireID()] = row }
        response.tasks = try shown.map { var dto = try TaskDTO($0); dto.planning = TaskPlanningSummary(planning[dto.id]); return dto }

        // Candidates: named on the item, or on one of the caller's cards. The effective rule then decides.
        let questions = try await TaskQuestion.query(on: db).filter(\.$state == "open").group(.or) { any in
            any.filter(\.$assigneeID == me)
            if !cardIDs.isEmpty { any.filter(\.$taskID ~~ cardIDs) }
        }.sort(\.$createdAt).sort(\.$id).all()
        let reviews = try await TaskReview.query(on: db).filter(\.$state == "pending").group(.or) { any in
            any.filter(\.$reviewerID == me)
            if !cardIDs.isEmpty { any.filter(\.$taskID ~~ cardIDs) }
        }.sort(\.$createdAt).sort(\.$id).all()
        var tasks: [UUID: TodoTask] = [:]
        let taskIDs = Array(Set(questions.map(\.taskID) + reviews.map(\.taskID)))
        if !taskIDs.isEmpty {
            for task in try await TodoTask.query(on: db).filter(\.$id ~~ taskIDs).filter(\.$projectID ~~ inScope).all() { tasks[try task.requireID()] = task }
        }
        let askers = try await displayNames(questions.compactMap { $0.askedByType == .person ? $0.askedByID : nil }, on: db)
        for q in questions {
            guard let task = tasks[q.taskID], try await resolver.audience(of: q, task: task) == .only(me) else { continue }
            if response.questions.count == limit { response.truncated = true; break }
            var dto = try QuestionDTO(q)
            dto.taskTitle = task.title; dto.projectID = task.projectID; dto.projectName = scope.projects[task.projectID]?.name
            if q.askedByType == .person { dto.askedByName = askers[q.askedByID] }
            response.questions.append(dto)
        }
        var mine: [(TaskReview, TodoTask)] = []
        for r in reviews {
            guard let task = tasks[r.taskID], try await resolver.audience(of: r, task: task) == .only(me) else { continue }
            if mine.count == limit { response.truncated = true; break }
            mine.append((r, task))
        }
        let brainIDs = try await ReviewBrain.reviewIDs(taskIDs: Array(Set(mine.map { $0.0.taskID })), userID: me, on: db)
        response.reviews = try mine.map { r, task in
            var dto = try ReviewDTO(r)
            dto.taskTitle = task.title; dto.projectID = task.projectID; dto.projectName = scope.projects[task.projectID]?.name
            dto.brainRecommended = brainIDs.contains(dto.id)
            return dto
        }
        return response
    }
}

struct AssignmentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("for-me", use: forMe)
        v1.get("projects", ":id", "assignees", use: assignees)
        v1.put("tasks", ":id", "assignee", use: assignTask)
        v1.put("questions", ":id", "assignee", use: assignQuestion)
        v1.put("reviews", ":id", "assignee", use: assignReview)
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }
    private func service(_ req: Request) async throws -> WorkflowService {
        WorkflowService(user: try await req.requireUser(), db: req.db)
    }
    private func actor(_ req: Request) async throws -> WorkflowActor { try .person(try await req.requireUser()) }

    @Sendable func forMe(_ req: Request) async throws -> ForMeResponse {
        let service = try await service(req)
        var projectID: UUID?
        if let raw = req.query[String.self, at: "projectID"] {
            guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_projectID") }
            projectID = id
        }
        var include = true
        if let raw = req.query[String.self, at: "includeSubprojects"] {
            guard raw == "true" || raw == "false" else { throw Abort(.badRequest, reason: "invalid_includeSubprojects") }
            include = raw == "true"
        }
        var limit = WorkflowService.forMeDefaultLimit
        if let raw = req.query[String.self, at: "limit"] { guard let v = Int(raw) else { throw Abort(.badRequest, reason: "invalid_filter") }; limit = v }
        return try await service.forMe(projectID: projectID, includeSubprojects: include, limit: limit)
    }
    @Sendable func assignees(_ req: Request) async throws -> [AssigneeDTO] { try await service(req).assignees(id(req)) }
    @Sendable func assignTask(_ req: Request) async throws -> TaskDTO {
        let service = try await service(req)
        return try await service.assignTask(id(req), to: req.content.decode(AssigneeRequest.self).assigneeID, actor: actor(req))
    }
    @Sendable func assignQuestion(_ req: Request) async throws -> QuestionDTO {
        let service = try await service(req)
        return try await service.assignQuestion(id(req), to: req.content.decode(AssigneeRequest.self).assigneeID, actor: actor(req))
    }
    @Sendable func assignReview(_ req: Request) async throws -> ReviewDTO {
        let service = try await service(req)
        return try await service.assignReview(id(req), to: req.content.decode(AssigneeRequest.self).assigneeID, actor: actor(req))
    }
}
