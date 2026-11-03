import Fluent
import Vapor

/// The "current project" of an account-wide MCP read (get_command_center, list_open_questions, list_pending_reviews).
/// One login covers all projects of a person, so the server cannot know which project an agent works in. The agent
/// passes `projectID` (from `.todolino.json`); the answer then names it as `currentProject`, filters to it
/// (`scope: "project"`, default) or, with `scope: "account"`, keeps everything and marks foreign entries.
struct MCPProjectContext {
    /// Current project (id, name); nil when the call carried no projectID.
    let current: (id: UUID, name: String)?
    /// Current project plus its sub-projects: entries of these are not foreign.
    let familyIDs: Set<UUID>
    /// Project to hand to the service (nil = whole account).
    let filterProjectID: UUID?

    static let noProjectHint = "No current project: this answer covers ALL projects of the account. Pass projectID (from .todolino.json) to filter to your project. Never work on, mention or offer tasks of other projects."
    static let accountHint = "scope=account: entries with foreignProject=true belong to other projects. Never claim, edit, mention or offer them; work only on currentProject."

    static func resolve(projectID: UUID?, scope: String?, user: User, db: any Database, allowed: Set<UUID>?) async throws -> MCPProjectContext {
        if let scope, !["project", "account"].contains(scope) { throw Abort(.badRequest, reason: "invalid_scope") }
        guard let projectID else {
            if scope == "project" { throw Abort(.badRequest, reason: "project_required") }
            return MCPProjectContext(current: nil, familyIDs: [], filterProjectID: nil)
        }
        let family = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: true, allowed: allowed)
        guard let project = family.projects[projectID] else { throw Abort(.notFound) }
        return MCPProjectContext(current: (projectID, project.name), familyIDs: Set(family.projects.keys),
                                 filterProjectID: scope == "account" ? nil : projectID)
    }

    var hint: String? {
        if current == nil { return Self.noProjectHint }
        return filterProjectID == nil ? Self.accountHint : nil
    }

    var currentJSON: JSONValue {
        guard let current else { return .null }
        return .object(["id": .string(current.id.uuidString), "name": .string(current.name)])
    }

    /// Adds `currentProject` and `hint` to an object answer.
    func decorate(_ value: JSONValue) -> JSONValue {
        guard case .object(var o) = value else { return value }
        o["currentProject"] = currentJSON
        if let hint { o["hint"] = .string(hint) }
        return .object(o)
    }

    /// Wraps a list answer: {currentProject, hint?, items}.
    func wrap(items: JSONValue) -> JSONValue { decorate(.object(["items": items])) }

    /// Sets `foreignProject` on an entry when the current project is known.
    func mark(_ entry: JSONValue, projectID: String?) -> JSONValue {
        guard current != nil, case .object(var o) = entry else { return entry }
        let id = projectID.flatMap(UUID.init(uuidString:))
        o["foreignProject"] = .bool(id.map { !familyIDs.contains($0) } ?? false)
        return .object(o)
    }

    func markRows(_ rows: JSONValue) -> JSONValue {
        guard current != nil, case .array(let list) = rows else { return rows }
        return .array(list.map { mark($0, projectID: $0["projectID"].string) })
    }

    func markCards(_ center: JSONValue) -> JSONValue {
        guard current != nil, case .object(var o) = center else { return center }
        func cards(_ list: [JSONValue]) -> [JSONValue] { list.map { mark($0, projectID: $0["project"]["id"].string) } }
        if case .array(let lanes) = o["lanes"] ?? .null {
            o["lanes"] = .array(lanes.map { lane in
                guard case .object(var l) = lane, case .array(let list) = l["cards"] ?? .null else { return lane }
                l["cards"] = .array(cards(list)); return .object(l)
            })
        }
        if case .array(let list) = o["items"] ?? .null { o["items"] = .array(cards(list)) }
        return .object(o)
    }
}
