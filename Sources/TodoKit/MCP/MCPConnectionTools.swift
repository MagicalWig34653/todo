import Fluent
import Vapor

/// Card E71B0FF1 (ADR 0032 addendum 24.11.2026): a connection that holds the person's brain mandate reads and changes the
/// project lists of the person's other connections, limited to the projects of its own mandate. Domain code lives in
/// `MandatedConnectionService`; there is deliberately no tool that changes a mandate.
extension MCPController {
    static let connectionTools: [Tool] = [
        Tool(name: "list_connections", scope: "projects:read",
             description: "List the person's other (not revoked) MCP connections: [{grantID, name, clientName, scopes, lastUsedAt, projects:[{id,name}]}]. projects shows only the projects that are part of THIS connection's brain mandate; everything else a connection may see stays invisible. Needs the person's brain mandate for this connection (brain_mandate_required). Use it to find the grantID for set_connection_projects."),
        Tool(name: "set_connection_projects", scope: "projects:write",
             description: "On behalf of the person, add projects to or remove them from the project list of another connection of the same person (for example a watcher connection that does not see a project and therefore never wakes the brain). Only projects in this connection's brain mandate can be named (outside_brain_mandate, nothing is applied then); adding needs that the person can read the project now. Needs the person's brain mandate (brain_mandate_required), a quote of their words (quote_required) and is refused for this connection itself (cannot_change_own_connection); a connection of another person is not_found, a revoked one grant_revoked. Idempotent: adding what is there or removing what is not is no error. Removing the last project of a connection without the scope projects:write is projects_required. Answer: {grantID, name, projects (inside the mandate, after the change), added, removed}. Every change is audited with the quote (GET /v1/settings/brain-mandate/audit). Mandates themselves cannot be changed by agents.",
             properties: ["grantID": Schema.uuid("Id of the target connection (from list_connections)."),
                          "addProjectIDs": Schema.stringArray("Project ids to add to the target connection (up to 50, no overlap with removeProjectIDs).", maxItems: 50),
                          "removeProjectIDs": Schema.stringArray("Project ids to remove from the target connection (up to 50).", maxItems: 50),
                          "quote": Schema.string("The person's own words that authorise this change (required, up to 2000 characters).", maxLength: 2000)],
             required: ["grantID"]),
    ]

    func callConnection(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        switch name {
        case "list_connections":
            return try .encoded(try await MandatedConnectionService.list(user: user, caller: grant, db: db))
        case "set_connection_projects":
            let target = try uuid(a["grantID"])
            let add = try projectIDs(a, "addProjectIDs"), remove = try projectIDs(a, "removeProjectIDs")
            return try .encoded(try await MandatedConnectionService.set(user: user, caller: grant, target: target, add: add, remove: remove,
                quote: try optionalString(a, "quote"), db: db))
        default: throw Abort(.notFound)
        }
    }

    /// Absent or null = empty; anything but an array of UUID strings is rejected (`invalid_projects` / `invalid_id`).
    private func projectIDs(_ a: JSONValue, _ key: String) throws -> [UUID] {
        if a[key].isNull { return [] }
        guard case .array(let items) = a[key], items.count <= MandatedConnectionService.maxProjectsPerCall else { throw Abort(.badRequest, reason: "invalid_projects") }
        return try items.map { try uuid($0) }
    }
}
