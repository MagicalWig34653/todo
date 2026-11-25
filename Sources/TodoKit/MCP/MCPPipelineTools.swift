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
             description: "Report the state of one pipeline step. developer, validation, tester and review need an approved plan for any state but pending (plan_not_approved; not needed when the project switched the planner off). planner takes pending, running or failed (writing the plan finishes it). approval follows from the decision (step_managed). The note replaces the previous one; omitting it clears it. Pass planVersion (from get_task_pipeline) so that a stale agent cannot overwrite the steps of a newer plan (plan_changed). A step the project switched off is refused (step_disabled). To repeat a failed step use retry_pipeline_step: a direct pending is allowed but does not count as a fix round.",
             properties: ["taskID": taskIDField,
                          "step": Schema.string("planner, developer, validation, tester or review.",
                              values: PipelineStepName.allCases.filter { $0 != .approval }.map(\.rawValue)),
                          "state": Schema.string("pending, running, done, failed or skipped.", values: PipelineStepState.settable),
                          "note": Schema.string("Optional short result or reason, up to 2000 characters.", maxLength: PipelineLimits.maxNote),
                          "planVersion": Schema.integer("Optional but recommended: the plan version you work on (plan_changed if it is not the current one).", min: 1),
                          "agentName": agentNameField],
             required: ["taskID", "step", "state"]),
        Tool(name: "retry_pipeline_step", scope: "tasks:write",
             description: "Put one FAILED pipeline step back to pending as a counted fix round (step_retried). Only the failed step changes; nothing is started. Refused: step not failed (step_not_failed), approval (step_managed), a step the project switched off (step_disabled), a stale planVersion (plan_changed), no more rounds left for the current plan version (fix_rounds_exhausted; get_task_pipeline shows fixRounds {used, max, remaining}). The note replaces the previous one; omitting it clears it.",
             properties: ["taskID": taskIDField,
                          "step": Schema.string("planner, developer, validation, tester or review.",
                              values: PipelineStepName.allCases.filter { $0 != .approval }.map(\.rawValue)),
                          "planVersion": Schema.integer("Optional but recommended: the plan version you work on (plan_changed if it is not the current one).", min: 1),
                          "note": Schema.string("Optional short note, up to 2000 characters.", maxLength: PipelineLimits.maxNote),
                          "agentName": agentNameField],
             required: ["taskID", "step"]),
        Tool(name: "get_pipeline_settings", scope: "projects:read",
             description: "Read the pipeline settings of one project: which steps are on (planner, approval, developer, validation, tester, review), model and effort per role (planner, developer, tester, reviewer; missing = default of the runner), maxFixRounds (0 to 10, default 3), notifyOnWaitingApproval, revision (0 without a row) and the latest 20 changes. Without a stored row the defaults are returned.",
             properties: ["projectID": Schema.uuid("Project id (must be in this connection's grant).")], required: ["projectID"]),
        Tool(name: "update_pipeline_settings", scope: "projects:write",
             description: "Change the pipeline settings of a project (partial update, only the sent fields change). Needs manage on the project AND the person's brain mandate for this connection and project plus a quote of their words (brain_mandate_required, outside_brain_mandate, quote_required, invalid_quote): model and effort decide the cost, so a connection never raises them on its own. revision is required (current value from get_pipeline_settings, 0 without a row; revision_conflict otherwise). model must match [A-Za-z0-9._:/-]+ (1 to 100 characters, invalid_model), effort is low, medium, high, xhigh or max (invalid_effort); null clears a model or effort. Unknown or empty updates are invalid_pipeline_settings. Repeating the same content changes nothing. The decision is entered in the mandate log (kind pipeline.settings).",
             properties: ["projectID": Schema.uuid("Project id (must be in this connection's grant)."),
                          "revision": Schema.integer("Current revision of the settings (0 if never written).", min: 0),
                          "steps": .object(["type": .string("object"), "description": .string("Switch steps on or off: any of planner, approval, developer, validation, tester, review as true or false."),
                                            "additionalProperties": .object(["type": .string("boolean")])]),
                          "roles": .object(["type": .string("object"), "description": .string("Per role (planner, developer, tester, reviewer) an object with model and/or effort; null clears the field."),
                                            "additionalProperties": .object(["type": .string("object"), "description": .string("model (string or null) and effort (low, medium, high, xhigh, max or null).")])]),
                          "maxFixRounds": Schema.integer("Fix rounds per plan version, 0 (retry never allowed) to 10.", min: 0, max: PipelineSettingsLimits.maxFixRoundsCeiling),
                          "notifyOnWaitingApproval": Schema.boolean("Tell people (Für dich, command center, push) when a plan waits for approval."),
                          "quote": quoteField],
             required: ["projectID", "revision"]),
    ]

    func callPipeline(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        let service = WorkflowService(user: user, db: db, allowedProjects: Set(grant.projects))
        let actor = try await self.actor(grant: grant, db: db)
        switch name {
        case "get_pipeline_settings":
            return try .encoded(try await service.pipelineSettings(try uuid(a["projectID"])))
        case "update_pipeline_settings":
            // The same JSON object as the REST body, without the arguments that only MCP knows.
            var body: [String: JSONValue] = [:]
            for key in ["revision", "steps", "roles", "maxFixRounds", "notifyOnWaitingApproval"] where a[key] != .null || key == "revision" { body[key] = a[key] }
            return try .encoded(try await service.updatePipelineSettings(try uuid(a["projectID"]), .object(body), quote: optionalString(a, "quote"), actor: actor))
        default: break
        }
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
                agentName: try optionalString(a, "agentName"), planVersion: try intArgument(a["planVersion"], reason: "invalid_planVersion"))
            return try .encoded(try await service.setPipelineStep(taskID, step: requiredString(a, "step"), body, actor: actor))
        case "retry_pipeline_step":
            let body = RetryPipelineStepRequest(planVersion: try intArgument(a["planVersion"], reason: "invalid_planVersion"),
                note: try optionalString(a, "note"), agentName: try optionalString(a, "agentName"))
            return try .encoded(try await service.retryPipelineStep(taskID, step: requiredString(a, "step"), body, actor: actor))
        default: throw Abort(.notFound)
        }
    }
}
