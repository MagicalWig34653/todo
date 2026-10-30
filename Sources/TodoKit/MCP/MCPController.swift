import Fluent
import Vapor

struct MCPController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("mcp", use: handle)
        routes.get("mcp") { req -> HTTPStatus in
            try Self.validateOrigin(req)
            return .methodNotAllowed
        }
    }
    static let versions = ["2025-03-26", "2025-06-18", "2025-11-25"]
    static func validateOrigin(_ req: Request) throws {
        if let origin = req.headers.first(name: .origin),
           origin != req.application.settings.relyingPartyOrigin && origin != OAuthController.issuer { throw Abort(.forbidden) }
    }
    @Sendable func handle(_ req: Request) async throws -> Response {
        try Self.validateOrigin(req)
        guard let raw = req.headers.bearerAuthorization?.token,
              let secret = try await OAuthSecret.query(on: req.db).filter(\.$hash == AuthSupport.hash(raw)).first(),
              secret.kind == "access", secret.expiresAt > Date(), let gid = secret.grantID,
              let grant = try await OAuthGrant.find(gid, on: req.db), !grant.revoked,
              grant.resource == OAuthController.resource,
              let user = try await User.find(grant.userID, on: req.db) else {
            return Response(status: .unauthorized, headers: ["WWW-Authenticate": "Bearer resource_metadata=\"\(OAuthController.issuer)/.well-known/oauth-protected-resource/mcp\", scope=\"\(OAuthController.scopes.joined(separator: " "))\""])
        }
        if let version = req.headers.first(name: "MCP-Protocol-Version"), !Self.versions.contains(version) { throw Abort(.badRequest, reason: "unsupported_protocol_version") }
        let body: JSONValue
        do { body = try req.content.decode(JSONValue.self) }
        catch { return try await rpcError(id: .null, code: -32700, message: "Parse error").encodeResponse(for: req) }
        let id = body["id"]
        guard case .object(let fields) = body, body["jsonrpc"] == .string("2.0"), let method = body["method"].string,
              fields["id"] == nil || id.string != nil || { if case .number = id { return true }; return false }() else {
            return try await rpcError(id: .null, code: -32600, message: "Invalid request").encodeResponse(for: req)
        }
        if fields["id"] == nil {
            return Response(status: .accepted)
        }
        let result: JSONValue
        switch method {
        case "initialize":
            let requested = body["params"]["protocolVersion"].string ?? ""
            result = .object(["protocolVersion": .string(Self.versions.contains(requested) ? requested : "2025-11-25"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("Todo"), "version": .string("1.0")])])
        case "ping": result = .object([:])
        case "tools/list": result = .object(["tools": .array(Self.tools.filter { grant.scopes.contains($0.scope) }.map(\.definition))])
        case "tools/call":
            guard let name = body["params"]["name"].string, let tool = Self.tools.first(where: { $0.name == name }) else {
                return try await rpcError(id: id, code: -32602, message: "Unknown tool").encodeResponse(for: req)
            }
            do {
                guard grant.scopes.contains(tool.scope) else { throw Abort(.forbidden, reason: "insufficient_scope") }
                let value = try await call(name, arguments: body["params"]["arguments"], user: user, grant: grant, db: req.db)
                let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(false)])
            } catch {
                let message = (error as? any AbortError).map { $0.status == .notFound ? "not_found" : $0.reason } ?? "invalid_arguments"
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
            }
        default: return try await rpcError(id: id, code: -32601, message: "Method not found").encodeResponse(for: req)
        }
        return try await JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encodeResponse(for: req)
    }
    func rpcError(id: JSONValue, code: Double, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(code), "message": .string(message)])])
    }
    struct Tool {
        let name: String; let scope: String; let properties: [String: JSONValue]; let required: [String]
        var definition: JSONValue { .object(["name": .string(name), "description": .string(name.replacingOccurrences(of: "_", with: " ")),
            "inputSchema": .object(["type": .string("object"), "properties": .object(properties), "required": .strings(required), "additionalProperties": .bool(false)])]) }
    }
    static let string: JSONValue = .object(["type": .string("string")])
    static let tools: [Tool] = [
        Tool(name: "list_projects", scope: "projects:read", properties: [:], required: []),
        Tool(name: "list_tasks", scope: "tasks:read", properties: ["projectID": string], required: ["projectID"]),
        Tool(name: "get_task", scope: "tasks:read", properties: ["id": string], required: ["id"]),
        Tool(name: "create_task", scope: "tasks:write", properties: ["projectID": string, "title": string, "description": string], required: ["projectID", "title"]),
        Tool(name: "update_task", scope: "tasks:write", properties: ["id": string, "version": .object(["type": .string("integer")]), "title": string, "description": string, "status": string, "projectID": string], required: ["id", "version"]),
        Tool(name: "list_comments", scope: "tasks:read", properties: ["taskID": string], required: ["taskID"]),
        Tool(name: "add_comment", scope: "comments:write", properties: ["taskID": string, "body": string, "idempotencyKey": string], required: ["taskID", "body"]),
        Tool(name: "get_progress", scope: "agents:read", properties: ["taskID": string], required: ["taskID"]),
        Tool(name: "list_attachments", scope: "attachments:read", properties: ["taskID": string], required: ["taskID"]),
        Tool(name: "get_attachment", scope: "attachments:read", properties: ["id": string], required: ["id"]),
        Tool(name: "list_columns", scope: "projects:read", properties: ["projectID": string], required: ["projectID"]),
        Tool(name: "move_task_to_column", scope: "tasks:write", properties: ["id": string, "version": .object(["type": .string("integer")]), "columnID": .object(["type": .array([.string("string"), .string("null")])]), "index": .object(["type": .string("integer")])], required: ["id", "version", "columnID"]),
        Tool(name: "create_column", scope: "tasks:write", properties: ["projectID": string, "name": string, "color": string, "isDone": .object(["type": .string("boolean")]), "index": .object(["type": .string("integer")])], required: ["projectID", "name"]),
        Tool(name: "rename_column", scope: "tasks:write", properties: ["id": string, "version": .object(["type": .string("integer")]), "name": string], required: ["id", "version", "name"]),
        Tool(name: "delete_column", scope: "tasks:write", properties: ["id": string, "version": .object(["type": .string("integer")]), "moveTo": string], required: ["id"])
    ]
    /// Task access = the grant lists the task's project AND the user's current role suffices (REST rules).
    func task(_ id: UUID, user: User, grant: OAuthGrant, db: any Database, role: ProjectRole = .read) async throws -> TodoTask {
        let task = try await ProjectAccess(user: user, db: db).task(id, role: role)
        _ = try await project(task.projectID, user: user, grant: grant, db: db, role: role)
        return task
    }
    /// Effective rights = explicitly granted project IDs AND the user's current effective role (incl. teams).
    func project(_ id: UUID, user: User, grant: OAuthGrant, db: any Database, role: ProjectRole = .read) async throws -> Project {
        guard grant.projects.contains(id) else { throw Abort(.notFound) }
        return try await ProjectAccess(user: user, db: db).project(id, role: role)
    }
    func uuid(_ value: JSONValue) throws -> UUID {
        guard let s = value.string, let id = UUID(uuidString: s) else { throw Abort(.badRequest, reason: "invalid_id") }; return id
    }
    func cleanTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw Abort(.badRequest, reason: "invalid_title") }; return value
    }
    func call(_ name: String, arguments a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        guard case .object(let args) = a, let tool = Self.tools.first(where: { $0.name == name }),
              Set(args.keys).isSubset(of: Set(tool.properties.keys)), tool.required.allSatisfy({ args[$0] != nil }) else { throw Abort(.badRequest, reason: "invalid_arguments") }
        switch name {
        case "list_projects":
            var result: [JSONValue] = []
            for id in grant.projects {
                do {
                    let p = try await project(id, user: user, grant: grant, db: db)
                    result.append(.object(["id": .string(try p.requireID().uuidString), "name": .string(p.name),
                        "version": .number(Double(p.version)),
                        "description": p.details.map { .string($0) } ?? .null, "color": p.color.map { .string($0) } ?? .null,
                        "parentID": p.parentID.flatMap { grant.projects.contains($0) ? .string($0.uuidString) : nil } ?? .null]))
                }
                catch let e as any AbortError where e.status == .notFound { continue }
            }
            return .array(result)
        case "list_tasks":
            let id = try uuid(a["projectID"])
            _ = try await project(id, user: user, grant: grant, db: db)
            let tasks = try await TodoTask.query(on: db).filter(\.$projectID == id).sort(\.$createdAt).sort(\.$id).all()
            return try .encoded(tasks.map(TaskDTO.init))
        case "get_task":
            let task = try await ProjectAccess(user: user, db: db).task(uuid(a["id"]))
            _ = try await project(task.projectID, user: user, grant: grant, db: db)
            return try .encoded(TaskDTO(task))
        case "create_task":
            let b = try a.decode(CreateTaskRequest.self)
            let t = try await db.transaction { db -> TodoTask in
                try await lockSharingGraph(on: db)
                _ = try await project(b.projectID, user: user, grant: grant, db: db, role: .edit)
                let t = TodoTask(ownerID: try user.requireID(), projectID: b.projectID, title: try cleanTitle(b.title), details: b.description ?? "")
                try await t.save(on: db); return t
            }
            return try .encoded(TaskDTO(t))
        case "update_task":
            let id = try uuid(a["id"]), b = try a.decode(UpdateTaskRequest.self)
            return try await db.transaction { db in
                try await lockSharingGraph(on: db)
                try await lockRow(table: TodoTask.schema, id: id, on: db)
                let t = try await ProjectAccess(user: user, db: db).task(id)
                _ = try await project(t.projectID, user: user, grant: grant, db: db, role: .edit)
                guard t.version == b.version else { throw Abort(.conflict, reason: "version_conflict") }
                let before = t.status
                if let p = b.projectID {
                    _ = try await project(p, user: user, grant: grant, db: db, role: .edit)
                    if p != t.projectID { t.columnID = nil; t.boardPosition = 0 }
                    t.projectID = p
                }
                if let title = b.title { t.title = try cleanTitle(title) }
                if let d = b.description { t.details = d }
                if let s = b.status { guard TaskStatus.all.contains(s) else { throw Abort(.badRequest, reason: "invalid_status") }; t.status = s }
                if t.status != before || b.projectID != nil { try await ColumnService.reconcile(t, on: db) }
                t.version += 1; try await t.save(on: db); return try .encoded(TaskDTO(t))
            }
        case "list_comments":
            let task = try await task(uuid(a["taskID"]), user: user, grant: grant, db: db)
            let comments = try await TaskComment.query(on: db).filter(\.$taskID == task.requireID()).sort(\.$id).all()
            return try .encoded(comments.map(CommentDTO.init))
        case "add_comment":
            guard let body = a["body"].string else { throw Abort(.badRequest, reason: "invalid_arguments") }
            let taskID = try uuid(a["taskID"])
            if !a["idempotencyKey"].isNull && a["idempotencyKey"].string == nil { throw Abort(.badRequest, reason: "invalid_idempotency_key") }
            let projects = grant.projects, grantID = try grant.requireID()
            // Same service as REST; the grant's project list is checked again on the locked task.
            let dto = try await CommentService.create(taskID: taskID, user: user, body: body, idempotencyKey: a["idempotencyKey"].string,
                actor: (.integration, grantID), scope: { t in guard projects.contains(t.projectID) else { throw Abort(.notFound) } }, on: db)
            return try .encoded(dto)
        case "get_progress":
            let task = try await task(uuid(a["taskID"]), user: user, grant: grant, db: db)
            // Agent jobs are visible to the project owner only, exactly like GET /v1/agents/jobs/:id.
            _ = try await ProjectAccess(user: user, db: db).startAgent(in: task.projectID)
            let taskID = try task.requireID()
            var jobs: [JSONValue] = []
            for job in try await AgentJob.query(on: db).filter(\.$taskID == taskID).filter(\.$projectID == task.projectID).sort(\.$id).all() {
                var runs: [AgentRunDTO] = []
                for run in try await AgentRun.query(on: db).filter(\.$jobID == job.requireID()).sort(\.$id).all() {
                    runs.append(try await AgentRunDTO(run, job: job, on: db))
                }
                jobs.append(.object(["job": try .encoded(AgentJobDTO(job)), "runs": try .encoded(runs.map { RunProgress($0) })]))
            }
            return .array(jobs)
        case "list_attachments":
            let task = try await task(uuid(a["taskID"]), user: user, grant: grant, db: db)
            let items = try await Attachment.query(on: db).filter(\.$taskID == task.requireID()).filter(\.$status == "complete").sort(\.$id).all()
            return try .encoded(items.map(AttachmentDTO.init))
        case "get_attachment":
            // Metadata only: file content is never embedded; download stays a separate authenticated REST call.
            guard let att = try await Attachment.find(uuid(a["id"]), on: db), att.status == "complete" else { throw Abort(.notFound) }
            _ = try await task(att.taskID, user: user, grant: grant, db: db)
            return try .encoded(AttachmentDTO(att))
        case "list_columns":
            // Board view of one granted project (same service as GET /v1/projects/{id}/board).
            let id = try uuid(a["projectID"])
            _ = try await project(id, user: user, grant: grant, db: db)
            return try .encoded(try await ColumnService(user: user, db: db).board(id))
        case "move_task_to_column":
            let id = try uuid(a["id"])
            guard case .number(let v) = a["version"], v == v.rounded() else { throw Abort(.badRequest, reason: "invalid_arguments") }
            var columnID: UUID?
            if !a["columnID"].isNull { columnID = try uuid(a["columnID"]) }
            var index: Int?
            if !a["index"].isNull { guard case .number(let n) = a["index"], n == n.rounded() else { throw Abort(.badRequest, reason: "invalid_index") }; index = Int(n) }
            let request = MoveTaskRequest(version: Int(v), columnID: columnID, index: index)
            return try await db.transaction { db in
                try await lockSharingGraph(on: db)
                let t = try await ProjectAccess(user: user, db: db).task(id)
                _ = try await project(t.projectID, user: user, grant: grant, db: db, role: .edit)
                return try .encoded(try await ColumnService(user: user, db: db).move(id, request))
            }
        case "create_column":
            let projectID = try uuid(a["projectID"])
            guard let name = a["name"].string else { throw Abort(.badRequest, reason: "invalid_name") }
            let color: String?
            if a["color"].isNull { color = nil } else { guard let c = a["color"].string else { throw Abort(.badRequest, reason: "invalid_color") }; color = c }
            let isDone: Bool?
            if a["isDone"].isNull { isDone = nil } else { guard case .bool(let b) = a["isDone"] else { throw Abort(.badRequest, reason: "invalid_arguments") }; isDone = b }
            let index = try intArgument(a["index"], reason: "invalid_index")
            return try await db.transaction { db in
                try await lockSharingGraph(on: db)
                _ = try await project(projectID, user: user, grant: grant, db: db, role: .edit)
                let column = try await ColumnService(user: user, db: db).create(projectID,
                    CreateColumnRequest(name: name, color: color, isDone: isDone, index: index))
                return try .encoded(ColumnDTO(column))
            }
        case "rename_column":
            let id = try uuid(a["id"])
            guard let version = try intArgument(a["version"], reason: "invalid_arguments"), let name = a["name"].string else {
                throw Abort(.badRequest, reason: "invalid_arguments")
            }
            return try await db.transaction { db in
                try await lockSharingGraph(on: db)
                try await grantedColumn(id, user: user, grant: grant, db: db)
                let column = try await ColumnService(user: user, db: db).update(id,
                    UpdateColumnRequest(version: version, name: name, color: nil, isDone: nil, index: nil))
                return try .encoded(ColumnDTO(column))
            }
        case "delete_column":
            let id = try uuid(a["id"])
            let version = try intArgument(a["version"], reason: "invalid_arguments")
            var moveTo: UUID??
            if !a["moveTo"].isNull {
                guard let raw = a["moveTo"].string else { throw Abort(.badRequest, reason: "invalid_move_to") }
                if raw == "none" { moveTo = .some(nil) }
                else if let target = UUID(uuidString: raw) { moveTo = .some(target) }
                else { throw Abort(.badRequest, reason: "invalid_move_to") }
            }
            let target = moveTo
            try await db.transaction { db in
                try await lockSharingGraph(on: db)
                try await grantedColumn(id, user: user, grant: grant, db: db)
                try await ColumnService(user: user, db: db).delete(id, moveTo: target, expectedVersion: version)
            }
            return .object(["deleted": .bool(true)])
        default: throw Abort(.badRequest)
        }
    }

    /// Optional integer argument: absent/null = nil, anything but a whole number is rejected.
    func intArgument(_ value: JSONValue, reason: String) throws -> Int? {
        if value.isNull { return nil }
        guard case .number(let n) = value, n == n.rounded(), abs(n) < 1e9 else { throw Abort(.badRequest, reason: reason) }
        return Int(n)
    }

    /// The column's project must be in the grant and editable by the user (404 otherwise).
    func grantedColumn(_ id: UUID, user: User, grant: OAuthGrant, db: any Database) async throws {
        guard let column = try await ProjectColumn.find(id, on: db) else { throw Abort(.notFound) }
        _ = try await project(column.projectID, user: user, grant: grant, db: db, role: .edit)
    }
}

/// Run view for MCP: lease state and the persisted checkpoint, without repeating the job.
private struct RunProgress: Content {
    let id: UUID; let generation: Int; let leaseUntil: Date; let endedAt: Date?; let checkpoint: AgentCheckpointInput?
    init(_ r: AgentRunDTO) { id = r.id; generation = r.generation; leaseUntil = r.leaseUntil; endedAt = r.endedAt; checkpoint = r.checkpoint }
}
