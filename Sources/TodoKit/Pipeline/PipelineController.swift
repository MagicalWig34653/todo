import Vapor

/// REST of the card pipeline (contracts/pipeline.yaml): signed-in persons; rights come from the project, as for every task route.
struct PipelineController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let task = routes.grouped("v1", "tasks", ":id")
        task.get("pipeline", use: pipeline)
        task.put("plan", use: setPlan)
        task.post("plan", "decision", use: decide)
        task.put("pipeline", "steps", ":step", use: setStep)
        task.post("pipeline", "steps", ":step", "retry", use: retryStep)
        task.post("pipeline", "execution", use: start)
        task.post("pipeline", "execution", "continue", use: resume)
        task.post("pipeline", "execution", "stop", use: stop)
        let project = routes.grouped("v1", "projects", ":id")
        project.get("pipeline-settings", use: settings)
        project.patch("pipeline-settings", use: updateSettings)
    }

    private func context(_ req: Request) async throws -> (service: WorkflowService, actor: WorkflowActor, taskID: UUID) {
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return (WorkflowService(user: user, db: req.db), try .person(user), id)
    }

    @Sendable func pipeline(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        return try await c.service.pipeline(c.taskID)
    }
    @Sendable func setPlan(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        return try await c.service.setPlan(c.taskID, req.content.decode(SetPlanRequest.self), actor: c.actor)
    }
    @Sendable func decide(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        return try await c.service.decidePlan(c.taskID, req.content.decode(PlanDecisionRequest.self), actor: c.actor)
    }
    @Sendable func setStep(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        guard let step = req.parameters.get("step") else { throw Abort(.badRequest, reason: "invalid_step") }
        return try await c.service.setPipelineStep(c.taskID, step: step, req.content.decode(SetPipelineStepRequest.self), actor: c.actor)
    }
    @Sendable func retryStep(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        guard let step = req.parameters.get("step") else { throw Abort(.badRequest, reason: "invalid_step") }
        return try await c.service.retryPipelineStep(c.taskID, step: step, req.content.decode(RetryPipelineStepRequest.self), actor: c.actor)
    }
    @Sendable func start(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        return try await c.service.startExecution(c.taskID, req.content.decode(StartExecutionRequest.self), actor: c.actor)
    }
    /// The body is optional.
    @Sendable func resume(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        let body = (req.body.data?.readableBytes ?? 0) > 0 ? try req.content.decode(ContinueExecutionRequest.self) : ContinueExecutionRequest()
        return try await c.service.continueExecution(c.taskID, body, actor: c.actor)
    }
    @Sendable func stop(_ req: Request) async throws -> PipelineDTO {
        let c = try await context(req)
        return try await c.service.stopExecution(c.taskID, actor: c.actor)
    }
    @Sendable func settings(_ req: Request) async throws -> PipelineSettingsDTO {
        let c = try await context(req)
        return try await c.service.pipelineSettings(c.taskID)
    }
    /// The body is read as plain JSON: a `null` model or effort clears the field, which a Codable struct cannot tell from a missing one.
    @Sendable func updateSettings(_ req: Request) async throws -> PipelineSettingsDTO {
        let c = try await context(req)
        return try await c.service.updatePipelineSettings(c.taskID, req.content.decode(JSONValue.self), actor: c.actor)
    }
}
