import Fluent
import Vapor

/// Card pipeline over MCP (card 74EC341D); the rules live in `WorkflowService` (Pipeline/PipelineService.swift).
extension MCPController {
    static let pipelineTools: [Tool] = [
        Tool(name: "get_task_pipeline", scope: "tasks:read",
             description: "Read the pipeline of one task: the current plan (version, Markdown body, state proposed|approved|changes_requested, decision comment), the six steps planner, approval, developer, validation, tester, review with their state and note, and the latest audit entries. Poll it (or use wait_for_events) to see whether your plan was decided.",
             properties: ["taskID": taskIDField], required: ["taskID"]),
        Tool(name: "set_task_plan", scope: "tasks:write",
             description: "Write the plan of a task for approval (Markdown, 1 to 20000 characters; secrets are masked). A new text is a new version in state proposed, needs a new approval and resets the steps developer, validation, tester and review. Repeating the same text while it is proposed changes nothing. Pass expectedVersion (0 = no plan yet) to avoid overwriting someone else's version (plan_changed). Do not decide your own plan.",
             properties: ["taskID": taskIDField,
                          "plan": Schema.string("The plan as Markdown, 1 to 20000 characters.", maxLength: PipelineLimits.maxPlan),
                          "expectedVersion": Schema.integer("Optional: the plan version you read (0 if there is none yet).", min: 0),
                          "agentName": agentNameField],
             required: ["taskID", "plan"]),
        Tool(name: "decide_plan", scope: "tasks:write",
             description: "Approve the proposed plan or request changes on behalf of the user steering you. Needs the person's brain mandate for this connection and project (brain_mandate_required / outside_brain_mandate) and a quote of their words (quote_required). Refused for a plan written by this same connection (cannot_decide_own_plan). Normally people decide in the app.",
             properties: ["taskID": taskIDField,
                          "decision": Schema.string("approve or request_changes.", values: ["approve", "request_changes"]),
                          "version": Schema.integer("The plan version being decided (plan_changed if it is not the current one).", min: 1),
                          "comment": Schema.string("Comment up to 4000 characters, required for request_changes.", maxLength: PipelineLimits.maxComment),
                          "quote": quoteField],
             required: ["taskID", "decision", "version"]),
        Tool(name: "set_pipeline_step", scope: "tasks:write",
             description: "Report the state of one pipeline step. developer, validation, tester and review need an approved plan for any state but pending (plan_not_approved). planner takes pending, running or failed (writing the plan finishes it). approval follows from the decision (step_managed). The note replaces the previous one; omitting it clears it.",
             properties: ["taskID": taskIDField,
                          "step": Schema.string("planner, developer, validation, tester or review.",
                              values: PipelineStepName.allCases.filter { $0 != .approval }.map(\.rawValue)),
                          "state": Schema.string("pending, running, done, failed or skipped.", values: PipelineStepState.settable),
                          "note": Schema.string("Optional short result or reason, up to 2000 characters.", maxLength: PipelineLimits.maxNote),
                          "agentName": agentNameField],
             required: ["taskID", "step", "state"]),
    ]

    func callPipeline(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        let service = WorkflowService(user: user, db: db, allowedProjects: Set(grant.projects))
        let actor = try await self.actor(grant: grant, db: db)
        let taskID = try uuid(a["taskID"])
        switch name {
        case "get_task_pipeline":
            return try .encoded(try await service.pipeline(taskID))
        case "set_task_plan":
            let body = SetPlanRequest(body: try requiredString(a, "plan"),
                expectedVersion: try intArgument(a["expectedVersion"], reason: "invalid_expectedVersion"),
                agentName: try optionalString(a, "agentName"))
            return try .encoded(try await service.setPlan(taskID, body, actor: actor))
        case "decide_plan":
            let body = PlanDecisionRequest(decision: try requiredString(a, "decision"),
                version: try intArgument(a["version"], reason: "invalid_version"), comment: try optionalString(a, "comment"))
            return try .encoded(try await service.decidePlan(taskID, body, quote: optionalString(a, "quote"), actor: actor))
        case "set_pipeline_step":
            let body = SetPipelineStepRequest(state: try requiredString(a, "state"), note: try optionalString(a, "note"),
                agentName: try optionalString(a, "agentName"))
            return try .encoded(try await service.setPipelineStep(taskID, step: requiredString(a, "step"), body, actor: actor))
        default: throw Abort(.notFound)
        }
    }
}
