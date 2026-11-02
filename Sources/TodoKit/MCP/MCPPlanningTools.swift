import Fluent
import Vapor

extension MCPController {
    static let planningTools: [Tool] = [
        Tool(name: "get_task_planning", scope: "tasks:read", description: "Read task planning (REST planning DTO; dates in UTC).", properties: ["taskID": Schema.uuid("Task id.")], required: ["taskID"]),
        Tool(name: "update_task_planning", scope: "tasks:write", description: "Patch planning; omitted fields stay, null clears dates/recurrence. dueDate YYYY-MM-DD and dueTime HH:mm use UTC (midnight by default). dueAt/plannedAt accept REST ISO 8601 timestamps. Optional version checks and increments task version.", properties: [
            "taskID": Schema.uuid("Task id."), "version": Schema.integer("Optional current task version.", min: 0),
            "dueDate": Schema.nullable("string", "UTC calendar date YYYY-MM-DD; null clears due date."), "dueTime": Schema.nullable("string", "UTC time HH:mm; requires a due date."),
            "dueAt": Schema.nullable("string", "REST due timestamp, ISO 8601. Do not combine with dueDate/dueTime."),
            "plannedAt": Schema.nullable("string", "REST planned timestamp, ISO 8601."),
            "priority": Schema.integer("Priority 0 through 3.", min: 0, max: 3),
            "recurrence": .object(["type": .array([.string("object"), .string("null")]), "description": .string("REST rule: frequency daily|weekly|monthly, interval 1..1000, timeZone (IANA), optional until ISO 8601."), "properties": .object(["frequency": Schema.string("Frequency.", values: ["daily", "weekly", "monthly"]), "interval": Schema.integer("Interval.", min: 1, max: 1000), "timeZone": Schema.string("IANA zone."), "until": Schema.nullable("string", "Optional ISO 8601 end date.")]), "required": .strings(["frequency", "interval", "timeZone"])]),
            "reminders": Schema.stringArray("ISO 8601 reminder timestamps; replaces all reminders, maximum 100.", maxItems: 100)], required: ["taskID"]),
        Tool(name: "list_planned_tasks", scope: "tasks:read", description: "List open tasks like REST planning views, restricted to granted projects; default limit 50, maximum 200. Today uses UTC.", properties: ["view": Schema.string("View.", values: ["today", "upcoming", "up_next"]), "projectID": Schema.uuid("Optional project filter."), "limit": Schema.integer("Result limit.", min: 1, max: 200)], required: ["view"]),
        Tool(name: "set_dependencies", scope: "tasks:write", description: "Replace blockers atomically (class B). Both sides must be granted; cycles fail. Empty array clears blockers.", properties: ["taskID": Schema.uuid("Blocked task."), "blockedBy": Schema.stringArray("Prerequisite task UUIDs; maximum 100.", maxItems: 100)], required: ["taskID", "blockedBy"]),
        Tool(name: "list_dependencies", scope: "tasks:read", description: "List visible prerequisite tasks; default limit 50, maximum 200.", properties: ["taskID": Schema.uuid("Blocked task."), "limit": Schema.integer("Result limit.", min: 1, max: 200)], required: ["taskID"]),
        Tool(name: "remove_dependency", scope: "tasks:write", description: "Remove one blocker (class B); both tasks must be granted.", properties: ["taskID": Schema.uuid("Blocked task."), "otherTaskID": Schema.uuid("Prerequisite task.")], required: ["taskID", "otherTaskID"]),
        Tool(name: "list_milestones", scope: "tasks:read", description: "List milestones with granted, readable member tasks; default limit 50, maximum 200 (also per milestone's tasks).", properties: ["projectID": Schema.uuid("Milestone project."), "limit": Schema.integer("Result limit.", min: 1, max: 200)], required: ["projectID"]),
        Tool(name: "create_milestone", scope: "tasks:write", description: "Create a milestone in a granted project (class A, edit role required).", properties: ["projectID": Schema.uuid("Project."), "title": Schema.string("Title, 1..200 characters.", maxLength: 200), "dueDate": Schema.string("Optional UTC date YYYY-MM-DD or ISO 8601 timestamp.")], required: ["projectID", "title"]),
        Tool(name: "assign_milestone", scope: "tasks:write", description: "Assign task to milestone of its project or an ancestor (class A); both projects must be granted and editable.", properties: ["taskID": Schema.uuid("Task."), "milestoneID": Schema.uuid("Milestone.")], required: ["taskID", "milestoneID"]),
        Tool(name: "unassign_milestone", scope: "tasks:write", description: "Remove a task from a granted milestone (class A, edit role required).", properties: ["taskID": Schema.uuid("Task."), "milestoneID": Schema.uuid("Milestone.")], required: ["taskID", "milestoneID"]),
        Tool(name: "delete_milestone", scope: "tasks:write", description: "Delete milestone (class C); tasks remain." + confirmationNote, properties: ["milestoneID": Schema.uuid("Milestone.")], required: ["milestoneID"])
    ]

    func callPlanning(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        let service = PlanningService(user: user, db: db)
        @Sendable func grantedTask(_ id: UUID, on db: any Database, role: ProjectRole = .read) async throws -> TodoTask {
            // Grant first: a forbidden role must never disclose an out-of-grant object.
            guard let t = try await TodoTask.find(id, on: db), grant.projects.contains(t.projectID) else { throw Abort(.notFound) }
            return try await PlanningService(user: user, db: db).task(id, role: role)
        }
        @Sendable func grantedMilestone(_ id: UUID, on db: any Database, role: ProjectRole = .read) async throws -> PlanningMilestone {
            guard let m = try await PlanningMilestone.find(id, on: db), grant.projects.contains(m.projectID) else { throw Abort(.notFound) }
            return try await PlanningService(user: user, db: db).milestone(id, role: role)
        }
        func limit() throws -> Int {
            let n = try intArgument(a["limit"], reason: "invalid_limit") ?? 50
            guard (1...200).contains(n) else { throw Abort(.badRequest, reason: "invalid_limit") }; return n
        }
        switch name {
        case "get_task_planning":
            let id = try uuid(a["taskID"]), t = try await grantedTask(id, on: db)
            let planning = try await TaskPlanning.find(id, on: db)
            return try .encoded(PlanningTaskDTO(t, planning))
        case "update_task_planning":
            let id = try uuid(a["taskID"])
            let version = try intArgument(a["version"], reason: "invalid_version")
            guard version == nil || version! >= 0 else { throw Abort(.badRequest, reason: "invalid_version") }
            return try await db.transaction { tx in
                let s = PlanningService(user: user, db: tx)
                try await s.lock()
                _ = try await grantedTask(id, on: tx, role: .edit)
                let p = try await TaskPlanning.find(id, on: tx)
                let data = try planningPatch(a, current: p)
                return try .encoded(await s.put(id, data: data, expectedVersion: version))
            }
        case "list_planned_tasks":
            let view = try requiredString(a, "view"), count = try limit()
            guard ["today", "upcoming", "up_next"].contains(view) else { throw Abort(.badRequest, reason: "invalid_view") }
            let pid = a["projectID"].isNull ? nil : try uuid(a["projectID"])
            if let pid { _ = try await project(pid, user: user, grant: grant, db: db) }
            let tasks = try await service.plannedTasks(mode: view == "up_next" ? "up-next" : view)
            return try .encoded(Array(tasks.filter { grant.projects.contains($0.task.projectID) && (pid == nil || $0.task.projectID == pid) }.prefix(count)))
        case "set_dependencies", "remove_dependency":
            let id = try uuid(a["taskID"])
            let ids: [UUID]
            if name == "remove_dependency" { ids = [try uuid(a["otherTaskID"])] }
            else {
                guard case .array(let values) = a["blockedBy"], values.count <= 100 else { throw Abort(.badRequest, reason: "invalid_dependencies") }
                ids = try values.map(uuid)
                guard Set(ids).count == ids.count else { throw Abort(.badRequest, reason: "invalid_dependencies") }
            }
            try await db.transaction { tx in
                let s = PlanningService(user: user, db: tx)
                try await s.lock(); _ = try await grantedTask(id, on: tx, role: .edit)
                for other in ids { _ = try await grantedTask(other, on: tx) }
                if name == "remove_dependency" { try await s.removeDependency(id, prerequisite: ids[0]) }
                else {
                    let existing = try await PlanningDependency.query(on: tx).filter(\.$taskID == id).all()
                    // Replacing must not silently remove an edge outside this connection's grant.
                    for edge in existing { _ = try await grantedTask(edge.prerequisiteID, on: tx) }
                    try await s.setDependencies(id, blockedBy: ids)
                }
            }
            return .object(["ok": .bool(true), "effect": .string(name == "set_dependencies" ? "Blockers replaced." : "Blocker removed.")])
        case "list_dependencies":
            let id = try uuid(a["taskID"]), count = try limit()
            _ = try await grantedTask(id, on: db)
            var result: [TaskDTO] = []
            for t in try await service.dependencies(id) where grant.projects.contains(t.projectID) {
                if result.count < count { result.append(try TaskDTO(t)) }
            }
            return try .encoded(result)
        case "create_milestone":
            let pid = try uuid(a["projectID"]), title = try requiredString(a, "title")
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                _ = try await project(pid, user: user, grant: grant, db: tx, role: .edit)
                return try .encoded(await PlanningService(user: user, db: tx).createMilestone(projectID: pid, title: title, dueAt: planningDate(a["dueDate"], dateOnly: true)))
            }
        case "list_milestones":
            let pid = try uuid(a["projectID"]), count = try limit()
            _ = try await project(pid, user: user, grant: grant, db: db)
            return try .encoded(await service.milestones(pid, allowedProjects: Set(grant.projects), limit: count))
        case "assign_milestone", "unassign_milestone":
            let id = try uuid(a["taskID"]), mid = try uuid(a["milestoneID"])
            try await db.transaction { tx in
                let s = PlanningService(user: user, db: tx)
                try await s.lock()
                _ = try await grantedTask(id, on: tx, role: .edit); _ = try await grantedMilestone(mid, on: tx, role: .edit)
                try await s.milestoneMembership(mid, taskID: id, remove: name == "unassign_milestone")
            }
            return .object(["ok": .bool(true)])
        case "delete_milestone":
            let id = try uuid(a["milestoneID"])
            _ = try await grantedMilestone(id, on: db, role: .edit)
            let label = try await OAuthClient.find(grant.clientID, on: db)?.name
            let r = try await ActionRequestService.create(tool: name, args: ["milestoneID": id.uuidString], user: user, grant: grant, label: label, on: db)
            throw ConfirmationRequired(requestID: try r.requireID())
        default: throw Abort(.badRequest, reason: "unknown_tool")
        }
    }

    private func planningDate(_ value: JSONValue, dateOnly: Bool = false) throws -> Date? {
        if value.isNull { return nil }
        guard let text = value.string else { throw Abort(.badRequest, reason: "invalid_date") }
        if dateOnly, text.count == 10 { return try planningDay(text, time: "00:00") }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else { throw Abort(.badRequest, reason: "invalid_date") }; return date
    }

    private func planningDay(_ day: String, time: String) throws -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd HH:mm"; f.isLenient = false
        let text = day + " " + time
        guard day.count == 10, time.count == 5, let date = f.date(from: text), f.string(from: date) == text else { throw Abort(.badRequest, reason: "invalid_date") }
        return date
    }

    private func planningPatch(_ a: JSONValue, current p: TaskPlanning?) throws -> PlanningData {
        guard case .object(let fields) = a else { throw Abort(.badRequest) }
        var data = PlanningData(dueAt: p?.dueAt, plannedAt: p?.plannedAt, priority: p?.priority ?? 0, recurrence: p?.recurrence, reminders: p?.reminders ?? [])
        if fields["dueAt"] != nil {
            guard fields["dueDate"] == nil, fields["dueTime"] == nil else { throw Abort(.badRequest, reason: "invalid_date") }
            data.dueAt = try planningDate(a["dueAt"])
        }
        if fields["dueDate"] != nil || fields["dueTime"] != nil {
            if fields["dueDate"] != nil && a["dueDate"].isNull {
                guard a["dueTime"].isNull else { throw Abort(.badRequest, reason: "invalid_date") }
                data.dueAt = nil
            } else {
                let day: String
                if fields["dueDate"] != nil { day = try requiredString(a, "dueDate") }
                else if let due = data.dueAt { day = String(ISO8601DateFormatter().string(from: due).prefix(10)) }
                else { throw Abort(.badRequest, reason: "invalid_date") }
                data.dueAt = try planningDay(day, time: a["dueTime"].isNull ? "00:00" : requiredString(a, "dueTime"))
            }
        }
        if fields["plannedAt"] != nil { data.plannedAt = try planningDate(a["plannedAt"]) }
        if fields["priority"] != nil {
            guard let n = try intArgument(a["priority"], reason: "invalid_priority") else { throw Abort(.badRequest, reason: "invalid_priority") }; data.priority = n
        }
        if fields["recurrence"] != nil {
            if a["recurrence"].isNull { data.recurrence = nil }
            else {
                let r = a["recurrence"]
                guard case .object(let object) = r, Set(object.keys).isSubset(of: ["frequency", "interval", "timeZone", "until"]),
                      let interval = try intArgument(r["interval"], reason: "invalid_recurrence") else { throw Abort(.badRequest, reason: "invalid_recurrence") }
                data.recurrence = RecurrenceRule(frequency: try requiredString(r, "frequency"), interval: interval, timeZone: try requiredString(r, "timeZone"), until: try planningDate(r["until"]))
            }
        }
        if fields["reminders"] != nil {
            guard case .array(let values) = a["reminders"], values.count <= 100 else { throw Abort(.badRequest, reason: "invalid_reminders") }
            data.reminders = try values.map { guard let date = try planningDate($0) else { throw Abort(.badRequest, reason: "invalid_reminders") }; return date }
        }
        try data.validate(); return data
    }
}

extension ConfirmableActions {
    static let deleteMilestone = ConfirmableAction(tool: "delete_milestone", describe: { args, user, db in
        guard let raw = args["milestoneID"], let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_id") }
        let m = try await PlanningService(user: user, db: db).milestone(id, role: .edit)
        var projects: Set<UUID> = [m.projectID]
        let links = try await PlanningMilestoneTask.query(on: db).filter(\.$milestoneID == id).all()
        for link in links {
            let task = try await PlanningService(user: user, db: db).task(link.taskID)
            projects.insert(task.projectID)
        }
        return .init(summary: "Meilenstein „\(m.title)“ löschen (Aufgaben bleiben erhalten)", impact: ActionImpact(targetType: "milestone", targetID: id, targetName: m.title, tasks: links.count, destructive: true), projectIDs: projects)
    }, execute: { args, user, db in
        guard let raw = args["milestoneID"], let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_id") }
        try await PlanningService(user: user, db: db).deleteMilestone(id)
        return "deleted"
    })
}
