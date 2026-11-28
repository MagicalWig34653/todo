import Fluent
import Vapor

extension MCPController {
    static let assigneeField = Schema.uuid("Optional user id of the one person this is for (from list_assignees). Only people with access to the project can be named; that person alone gets the push and sees it in 'For me'. Omit to keep it open for everybody (or for the card's assignee).")

    /// Responsibility (ADR 0043).
    static let assignmentTools: [Tool] = [
        Tool(name: "list_assignees", scope: "tasks:write",
             description: "Who can be made responsible in one project: userID, displayName, assignableTo (task, question, review) and isMe (the person of this connection). Needs edit rights. Use the ids as assigneeID; no other personal data is returned.",
             properties: ["projectID": Schema.uuid("Project id.")], required: ["projectID"]),
        Tool(name: "set_assignee", scope: "tasks:write",
             description: "Make one person responsible for a card, an open question or a pending review, or remove it (assigneeID null). Pass exactly one of taskID, questionID, reviewID. A review that already names somebody can only be redirected by that person or a project manager (not_the_reviewer). Setting a card's assignee also directs its questions, reviews, plans and reminders that name nobody else.",
             properties: ["taskID": Schema.uuid("Card to assign."), "questionID": Schema.uuid("Open question to assign."),
                          "reviewID": Schema.uuid("Pending review to assign."),
                          "assigneeID": Schema.nullable("string", "User id from list_assignees, or null to remove the assignment.")],
             required: ["assigneeID"]),
        Tool(name: "list_for_me", scope: "tasks:read",
             description: "Everything open that concerns the person of this connection: unfinished cards assigned to them, open questions and pending reviews they are responsible for (named, or through the card). Pass projectID (current project) like get_command_center: the answer names currentProject. Items without a responsible person are not listed here (see list_open_questions, list_pending_reviews).",
             properties: ["projectID": currentProjectID, "scope": accountScope,
                          "limit": Schema.integer("Maximum entries per list (default 100).", min: 1, max: 200)]),
    ]

    func callAssignment(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) async throws -> JSONValue {
        let service = workflowService(user: user, grant: grant, db: db, settings: settings)
        let actor = try await self.actor(grant: grant, db: db)
        switch name {
        case "list_assignees":
            return .object(["items": try .encoded(try await service.assignees(uuid(a["projectID"])))])
        case "set_assignee":
            let targets = ["taskID", "questionID", "reviewID"].filter { !a[$0].isNull }
            guard targets.count == 1, let target = targets.first else { throw Abort(.badRequest, reason: "invalid_target") }
            let assignee = try optionalUUID(a, "assigneeID"), id = try uuid(a[target])
            switch target {
            case "taskID": return try .encoded(try await service.assignTask(id, to: assignee, actor: actor))
            case "questionID": return try .encoded(try await service.assignQuestion(id, to: assignee, actor: actor))
            default: return try .encoded(try await service.assignReview(id, to: assignee, actor: actor))
            }
        case "list_for_me":
            let context = try await MCPProjectContext.resolve(projectID: optionalUUID(a, "projectID"), scope: optionalString(a, "scope"),
                user: user, db: db, allowed: Set(grant.effectiveProjects))
            let result = try await service.forMe(projectID: context.filterProjectID,
                limit: intArgument(a["limit"], reason: "invalid_limit") ?? WorkflowService.forMeDefaultLimit)
            return context.decorate(.object([
                "tasks": context.markRows(try .encoded(result.tasks)),
                "questions": context.markRows(try .encoded(result.questions)),
                "reviews": context.markRows(try .encoded(result.reviews)),
                "truncated": .bool(result.truncated)]))
        default: throw Abort(.notFound)
        }
    }
}
