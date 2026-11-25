import Vapor

/// REST of the card pipeline (contracts/pipeline.yaml): signed-in persons; rights come from the project, as for every task route.
struct PipelineController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let task = routes.grouped("v1", "tasks", ":id")
        task.get("pipeline", use: pipeline)
        task.put("plan", use: setPlan)
        task.post("plan", "decision", use: decide)
        task.put("pipeline", "steps", ":step", use: setStep)
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
}
