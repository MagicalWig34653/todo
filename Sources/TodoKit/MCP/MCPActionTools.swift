import Fluent
import Vapor

extension MCPController {
    static let confirmationNote = " Large action: it does not run immediately. The call returns confirmation_required with an actionRequestID; the user confirms or rejects it in Todolino. Wait with wait_for_events / get_action_request, do not call it again."

    /// Class C tools (ADR 0026): they only create a confirmation request.
    static let actionTools: [Tool] = [
        Tool(name: "delete_project", scope: "projects:write",
             description: "Delete a project with all its tasks and sub-projects (irreversible; owner only)." + confirmationNote,
             properties: ["projectID": Schema.uuid("Project id (must be in this connection's grant, together with all sub-projects)."),
                          "version": Schema.integer("Optional current project version; a stale version fails with version_conflict when the user confirms.", min: 0)],
             required: ["projectID"]),
        Tool(name: "delete_task", scope: "tasks:write",
             description: "Delete a task with its comments, questions and attachments (irreversible)." + confirmationNote,
             properties: ["taskID": Schema.uuid("Task id."),
                          "version": Schema.integer("Optional current task version.", min: 0)],
             required: ["taskID"]),
        Tool(name: "transfer_project_owner", scope: "projects:write",
             description: "Hand the ownership of a project to another person or team (owner only; the previous owner loses owner rights)." + confirmationNote,
             properties: ["projectID": Schema.uuid("Project id."),
                          "ownerType": Schema.string("person or team.", values: ["person", "team"]),
                          "ownerID": Schema.uuid("Id of the new owner (person or team)."),
                          "version": Schema.integer("Current project version.", min: 0)],
             required: ["projectID", "ownerType", "ownerID", "version"]),
        Tool(name: "list_action_requests", scope: "",
             description: "List the confirmation requests this connection created (newest first) with state pending|rejected|expired|executed|failed, summary and result.",
             properties: ["state": Schema.string("Optional filter.", values: ["pending", "confirmed", "rejected", "expired", "executed", "failed"])]),
        Tool(name: "get_action_request", scope: "",
             description: "Read one confirmation request of this connection: state, summary and, once decided, the result ({ok, code}). pending means the user has not decided yet.",
             properties: ["id": Schema.uuid("actionRequestID from confirmation_required.")], required: ["id"]),
    ]

    func callActions(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        func versionArg() throws -> [String: String] {
            guard let v = try intArgument(a["version"], reason: "invalid_version") else { return [:] }
            return ["version": String(v)]
        }
        func confirm(_ tool: String, _ args: [String: String]) async throws -> JSONValue {
            let label = try await OAuthClient.find(grant.clientID, on: db)?.name
            let request = try await ActionRequestService.create(tool: tool, args: args, user: user, grant: grant, label: label, on: db)
            throw ConfirmationRequired(requestID: try request.requireID())
        }
        switch name {
        case "delete_project":
            return try await confirm(name, try versionArg().merging(["projectID": uuid(a["projectID"]).uuidString]) { $1 })
        case "delete_task":
            return try await confirm(name, try versionArg().merging(["taskID": uuid(a["taskID"]).uuidString]) { $1 })
        case "transfer_project_owner":
            let type = try requiredString(a, "ownerType")
            guard ["person", "team"].contains(type) else { throw Abort(.badRequest, reason: "invalid_principal") }
            return try await confirm(name, try versionArg().merging(["projectID": uuid(a["projectID"]).uuidString, "ownerType": type,
                "ownerID": uuid(a["ownerID"]).uuidString]) { $1 })
        case "list_action_requests":
            let grantID = try grant.requireID()
            let rows = try await ActionRequestService(user: user, db: db).list(state: try optionalString(a, "state")).filter { $0.grantID == grantID }
            return try .encoded(rows.map { try ActionRequestDTO($0) })
        case "get_action_request":
            let r = try await ActionRequestService(user: user, db: db).get(uuid(a["id"]))
            guard r.grantID == (try grant.requireID()) else { throw Abort(.notFound) }
            return try .encoded(try ActionRequestDTO(r))
        default: throw Abort(.badRequest)
        }
    }
}
