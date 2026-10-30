import Fluent
import Vapor

struct CommandCenterController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("manual", use: manual)
        v1.get("command-center", use: commandCenter)
        v1.get("projects", ":id", "structure", use: structure)
        v1.get("projects", ":id", "agent-brief", use: getBrief)
        v1.put("projects", ":id", "agent-brief", use: putBrief)
        v1.get("questions", use: listQuestions)
        v1.get("questions", ":id", use: getQuestion)
        v1.post("questions", ":id", "answer", use: answerQuestion)
        v1.get("reviews", use: listReviews)
        v1.get("tasks", ":id", "context", use: context)
        v1.post("tasks", ":id", "claim", use: claim)
        v1.delete("tasks", ":id", "claim", use: release)
        v1.get("tasks", ":id", "progress-notes", use: listNotes)
        v1.post("tasks", ":id", "progress-notes", use: postNote)
        v1.get("tasks", ":id", "questions", use: taskQuestions)
        v1.post("tasks", ":id", "questions", use: ask)
        v1.post("tasks", ":id", "review", use: requestReview)
        v1.post("tasks", ":id", "review", "decision", use: decide)
        v1.put("tasks", ":id", "structure", use: setStructure)
        v1.get("tasks", ":id", "builds", use: builds)
        v1.post("builds", use: registerBuild)
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }
    private func service(_ req: Request) async throws -> WorkflowService {
        WorkflowService(user: try await req.requireUser(), db: req.db, attachments: { try CommandCenterAttachments.service() })
    }
    private func actor(_ req: Request) async throws -> WorkflowActor { try .person(try await req.requireUser()) }
    private func uuidQuery(_ req: Request, _ name: String) throws -> UUID? {
        guard let raw = req.query[String.self, at: name] else { return nil }
        guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_\(name)") }
        return id
    }

    /// Public: the manual contains no user data.
    @Sendable func manual(_ req: Request) async throws -> ManualResponse {
        try AgentManual.response(section: req.query[String.self, at: "section"])
    }

    @Sendable func commandCenter(_ req: Request) async throws -> CommandCenterResponse {
        let user = try await req.requireUser()
        var raw: [String: String] = [:]
        for item in req.url.query?.split(separator: "&") ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { raw[parts[0]] = parts[1] }
        }
        let query = try CommandCenterQuery(scope: raw["scope"], projectID: raw["projectID"], raw: raw)
        return try await CommandCenterService(user: user, db: req.db).build(query)
    }

    @Sendable func structure(_ req: Request) async throws -> ProjectStructureDTO {
        try await service(req).structure(id(req))
    }
    @Sendable func getBrief(_ req: Request) async throws -> AgentBriefDTO { try await service(req).brief(id(req)) }
    @Sendable func putBrief(_ req: Request) async throws -> AgentBriefDTO {
        try await service(req).putBrief(id(req), req.content.decode(AgentBriefRequest.self))
    }

    @Sendable func listQuestions(_ req: Request) async throws -> [QuestionDTO] {
        let limit = req.query[Int.self, at: "limit"] ?? 100
        return try await service(req).questions(projectID: uuidQuery(req, "projectID"), taskID: uuidQuery(req, "taskID"),
            state: req.query[String.self, at: "state"] ?? "open",
            includeSubprojects: req.query[Bool.self, at: "includeSubprojects"] ?? true, limit: limit)
    }
    @Sendable func getQuestion(_ req: Request) async throws -> QuestionDTO { try await service(req).question(id(req)) }
    @Sendable func answerQuestion(_ req: Request) async throws -> QuestionDTO {
        try await service(req).answer(id(req), value: req.content.decode(AnswerQuestionRequest.self).answer, actor: actor(req))
    }
    @Sendable func listReviews(_ req: Request) async throws -> [ReviewDTO] {
        try await service(req).reviews(projectID: uuidQuery(req, "projectID"), state: req.query[String.self, at: "state"] ?? "pending",
            includeSubprojects: req.query[Bool.self, at: "includeSubprojects"] ?? true, limit: req.query[Int.self, at: "limit"] ?? 100)
    }
    @Sendable func context(_ req: Request) async throws -> TaskContextDTO { try await service(req).context(id(req)) }
    @Sendable func claim(_ req: Request) async throws -> TaskContextDTO {
        let body = try? req.content.decode(ClaimTaskRequest.self)
        return try await service(req).claim(id(req), agentName: body?.agentName, takeOver: body?.takeOver ?? false, actor: actor(req))
    }
    @Sendable func release(_ req: Request) async throws -> TaskContextDTO {
        try await service(req).release(id(req), force: req.query[Bool.self, at: "force"] ?? false, actor: actor(req))
    }
    @Sendable func listNotes(_ req: Request) async throws -> [ProgressNoteDTO] {
        let taskID = try id(req)
        _ = try await service(req).readableTask(taskID)
        return try await TaskProgressNote.query(on: req.db).filter(\.$taskID == taskID)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(100).all().map(ProgressNoteDTO.init)
    }
    @Sendable func postNote(_ req: Request) async throws -> Response {
        let body = try req.content.decode(ProgressRequest.self)
        let dto = try await service(req).postProgress(id(req), note: body.note, percent: body.percent, label: nil, actor: actor(req))
        return try await dto.encodeResponse(status: .created, for: req)
    }
    @Sendable func taskQuestions(_ req: Request) async throws -> [QuestionDTO] {
        try await service(req).questions(projectID: nil, taskID: id(req), state: req.query[String.self, at: "state"] ?? "all")
    }
    @Sendable func ask(_ req: Request) async throws -> Response {
        let dto = try await service(req).ask(id(req), req.content.decode(AskQuestionRequest.self), actor: actor(req))
        return try await dto.encodeResponse(status: .created, for: req)
    }
    @Sendable func requestReview(_ req: Request) async throws -> ReviewDTO {
        try await service(req).requestReview(id(req), req.content.decode(RequestReviewRequest.self), actor: actor(req))
    }
    @Sendable func decide(_ req: Request) async throws -> ReviewDTO {
        let body = try req.content.decode(ReviewDecisionRequest.self)
        return try await service(req).decideReview(id(req), decision: body.decision, note: body.note, actor: actor(req))
    }
    @Sendable func setStructure(_ req: Request) async throws -> WorkflowDTO {
        try await service(req).setStructure(id(req), req.content.decode(StructureRequest.self), actor: actor(req))
    }
    @Sendable func builds(_ req: Request) async throws -> [BuildArtifactDTO] { try await service(req).builds(taskID: id(req)) }
    @Sendable func registerBuild(_ req: Request) async throws -> Response {
        let dto = try await service(req).registerBuild(req.content.decode(RegisterBuildRequest.self), actor: actor(req))
        return try await dto.encodeResponse(status: .created, for: req)
    }
}

func configureCommandCenter(_ app: Application) {
    app.migrations.add(CreateCommandCenter())
}
