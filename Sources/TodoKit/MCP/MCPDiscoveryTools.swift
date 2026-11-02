import Fluent
import Vapor

extension MCPController {
    static let discoveryTools: [Tool] = [
        Tool(name: "search_tasks", scope: "tasks:read", description: "Search tasks in readable projects explicitly allowed by this connection. No other project contents are returned.", properties: ["query": Schema.string("Search text (up to 500 characters).", maxLength: 500), "projectID": Schema.uuid("Optional allowed project."), "status": Schema.string("Optional task status.", values: TaskStatus.all.sorted()), "limit": Schema.integer("Maximum results (default 50).", min: 1, max: 100)], required: ["query"]),
        Tool(name: "list_labels", scope: "labels:read", description: "List up to 100 labels owned by your account; other accounts’ private metadata is never included."),
        Tool(name: "create_label", scope: "labels:write", description: "Create a label in your private account metadata, with an optional #RRGGBB color.", properties: ["name": Schema.string("Label name, 1 to 200 characters."), "color": Schema.string("Optional #RRGGBB color.")], required: ["name"]),
        Tool(name: "update_label", scope: "labels:write", description: "Update your private label using its current version.", properties: ["labelID": Schema.uuid("Your label id."), "version": Schema.integer("Current version.", min: 1), "name": Schema.string("New name."), "color": Schema.string("New #RRGGBB color.")], required: ["labelID", "version"]),
        Tool(name: "set_task_labels", scope: "labels:write", description: "Replace your private label assignments on a readable task in this connection. Other people's assignments are preserved.", properties: ["taskID": Schema.uuid("Allowed task."), "labelIDs": Schema.stringArray("Your label ids; empty removes your assignments.", maxItems: 100)], required: ["taskID", "labelIDs"]),
        Tool(name: "delete_label", scope: "labels:write", description: "Delete your private label and its assignments." + confirmationNote, properties: ["labelID": Schema.uuid("Your label id."), "version": Schema.integer("Optional current version.", min: 1)], required: ["labelID"]),
        Tool(name: "list_filters", scope: "filters:read", description: "List up to 100 private saved filters owned by your account, including their criteria and versions."),
        Tool(name: "create_filter", scope: "filters:write", description: "Save a private task filter. query is search text or {q?, projectID?, labelID?, status?}.", properties: ["name": Schema.string("Filter name, 1 to 200 characters."), "query": discoveryQuerySchema], required: ["name", "query"]),
        Tool(name: "update_filter", scope: "filters:write", description: "Update a private saved filter using its current version.", properties: ["filterID": Schema.uuid("Your saved filter id."), "version": Schema.integer("Current version.", min: 1), "name": Schema.string("New name."), "query": discoveryQuerySchema], required: ["filterID", "version"]),
        Tool(name: "run_filter", scope: "filters:read", description: "Run your saved task filter, restricted to readable projects allowed by this connection. Also requires tasks:read.", properties: ["filterID": Schema.uuid("Your saved filter id."), "limit": Schema.integer("Maximum results (default 50).", min: 1, max: 100)], required: ["filterID"]),
        Tool(name: "delete_filter", scope: "filters:write", description: "Delete your private saved filter." + confirmationNote, properties: ["filterID": Schema.uuid("Your saved filter id."), "version": Schema.integer("Optional current version.", min: 1)], required: ["filterID"]),
    ]

    static var discoveryQuerySchema: JSONValue {
        .object(["description": .string("Search text or structured criteria {q?, projectID?, labelID?, status?}."), "oneOf": .array([
            Schema.string("Search text.", maxLength: 500),
            .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object([
                "q": Schema.string("Search text.", maxLength: 500), "projectID": Schema.uuid("Project id."), "labelID": Schema.uuid("Your label id."), "status": Schema.string("Task status.", values: TaskStatus.all.sorted())])])])])
    }

    func callDiscovery(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        guard let tool = Self.discoveryTools.first(where: { $0.name == name }), grant.scopes.contains(tool.scope) else { throw Abort(.forbidden, reason: "insufficient_scope") }
        let a = a.isNull ? JSONValue.object([:]) : a
        guard case .object(let args) = a, Set(args.keys).isSubset(of: Set(tool.properties.keys)), tool.required.allSatisfy({ args[$0] != nil && !a[$0].isNull }) else { throw Abort(.badRequest, reason: "invalid_arguments") }
        let service = DiscoveryService(user: user, db: db)
        func version(required: Bool = true) throws -> Int? {
            let v = try intArgument(a["version"], reason: "invalid_version")
            guard v.map({ $0 > 0 }) ?? !required else { throw Abort(.badRequest, reason: "invalid_version") }
            return v
        }
        func criteria(_ value: JSONValue) async throws -> DiscoveryCriteria {
            let c: DiscoveryCriteria
            if let q = value.string { c = DiscoveryCriteria(q: q) }
            else {
                guard case .object(let keys) = value, Set(keys.keys).isSubset(of: ["q", "projectID", "labelID", "status"]) else { throw Abort(.badRequest, reason: "invalid_query") }
                c = try value.decode(DiscoveryCriteria.self)
            }
            if let p = c.projectID { _ = try await project(p, user: user, grant: grant, db: db) }
            try await service.validate(c)
            return c
        }
        func search(_ c: DiscoveryCriteria) async throws -> JSONValue {
            guard grant.scopes.contains("tasks:read") else { throw Abort(.forbidden, reason: "insufficient_scope") }
            let limit = try intArgument(a["limit"], reason: "invalid_limit") ?? 50
            guard (1...100).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
            return try .encoded(await service.search(c, page: DiscoveryPagination(limit: limit), projectIDs: Set(grant.projects), tasksOnly: true))
        }
        switch name {
        case "search_tasks":
            let c = DiscoveryCriteria(q: try requiredString(a, "query"), projectID: a["projectID"].isNull ? nil : try uuid(a["projectID"]), status: try optionalString(a, "status"))
            return try await search(c)
        case "list_labels":
            return try .encoded(await DiscoveryLabel.query(on: db).filter(\.$ownerID == user.requireID()).sort(\.$id).limit(100).all().map(DiscoveryLabelDTO.init))
        case "create_label": return try .encoded(await service.createLabel(name: requiredString(a, "name"), color: optionalString(a, "color")))
        case "update_label": return try .encoded(await service.updateLabel(uuid(a["labelID"]), version: version()!, name: optionalString(a, "name"), color: optionalString(a, "color")))
        case "set_task_labels":
            let id = try uuid(a["taskID"])
            guard case .array(let ids) = a["labelIDs"], ids.count <= 100 else { throw Abort(.badRequest, reason: "invalid_labelIDs") }
            let labelIDs = try ids.map { try uuid($0) }
            try await service.setLabels(taskID: id, labelIDs: labelIDs, projectIDs: Set(grant.projects))
            return .object(["ok": .bool(true)])
        case "list_filters":
            return try .encoded(await DiscoverySavedFilter.query(on: db).filter(\.$ownerID == user.requireID()).sort(\.$id).limit(100).all().map(DiscoveryFilterDTO.init))
        case "create_filter": return try .encoded(await service.createFilter(name: requiredString(a, "name"), criteria: criteria(a["query"])))
        case "update_filter": return try .encoded(await service.updateFilter(uuid(a["filterID"]), version: version()!, name: optionalString(a, "name"), criteria: a["query"].isNull ? nil : try await criteria(a["query"])))
        case "run_filter":
            let row = try await service.savedFilter(uuid(a["filterID"]))
            return try await search(DiscoveryFilterDTO(row).criteria)
        case "delete_label", "delete_filter":
            let key = name == "delete_label" ? "labelID" : "filterID"
            var values = [key: try uuid(a[key]).uuidString]
            if let v = try version(required: false) { values["version"] = String(v) }
            let label = try await OAuthClient.find(grant.clientID, on: db)?.name
            let r = try await ActionRequestService.create(tool: name, args: values, user: user, grant: grant, label: label, on: db)
            throw ConfirmationRequired(requestID: try r.requireID())
        default: throw Abort(.badRequest, reason: "unknown_tool")
        }
    }
}

extension ConfirmableActions {
    static let discoveryActions: [ConfirmableAction] = [privateMetadataDeletion(label: true), privateMetadataDeletion(label: false)]

    private static func privateMetadataDeletion(label: Bool) -> ConfirmableAction {
        let key = label ? "labelID" : "filterID"
        return ConfirmableAction(tool: label ? "delete_label" : "delete_filter", describe: { args, user, db in
            guard let raw = args[key], let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            let service = DiscoveryService(user: user, db: db)
            let name: String
            let version: Int
            if label { let row = try await service.label(id); name = row.name; version = row.version }
            else { let row = try await service.savedFilter(id); name = row.name; version = row.version }
            if let expected = args["version"], Int(expected) != version { throw Abort(.conflict, reason: "version_conflict") }
            return .init(summary: "\(label ? "Privates Label" : "Gespeicherten Filter") „\(name)“ löschen", impact: ActionImpact(targetType: label ? "label" : "filter", targetID: id, targetName: name, destructive: true), projectIDs: [])
        }, execute: { args, user, db in
            guard let raw = args[key], let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            let service = DiscoveryService(user: user, db: db)
            if label { try await service.deleteLabel(id, version: args["version"].flatMap(Int.init)) }
            else { try await service.deleteFilter(id, version: args["version"].flatMap(Int.init)) }
            return "deleted"
        }, requiredScope: label ? "labels:write" : "filters:write")
    }
}
