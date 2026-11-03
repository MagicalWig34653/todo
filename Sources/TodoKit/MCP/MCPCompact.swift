import Vapor

/// Compact MCP answers for `get_command_center` and `list_open_questions` (REST and PWA keep the full shapes).
/// Keys stay the same; bulky parts are emptied or shortened and `compact: true` marks the reduced form.
enum MCPCompact {
    static let cardFields: Set<String> = ["task", "project", "kind", "isFeature", "parentTaskID", "lane", "progress", "agent", "openQuestionCount",
        "questions", "pendingReview", "blockedReason", "blockedBy", "latestUpdate", "builds", "buildCount", "nextDue", "priority", "subtasks", "subtaskCount"]
    static let questionFields: Set<String> = ["id", "taskID", "taskTitle", "projectID", "projectName", "askedByType", "askedByID", "askedByLabel",
        "askedByName", "prompt", "options", "blocking", "state", "answer", "answeredBy", "answeredVia", "answeredAt", "createdAt", "agentQuestionID", "version"]
    private static let dropFromQuestion: Set<String> = ["askedByID", "answeredBy", "answeredVia", "agentQuestionID", "version"]

    static let compactLaneLimit = 10, compactUpdatesLimit = 5, compactListLimit = 20
    static let updateTextLimit = 160, cardTextLimit = 200, promptLimit = 240

    /// Parses a comma-separated field list; `nil` when absent, `invalid_fields` for unknown names.
    static func fields(_ raw: String?, allowed: Set<String>) throws -> Set<String>? {
        guard let raw, !raw.isEmpty else { return nil }
        let set = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard !set.isEmpty, set.isSubset(of: allowed) else { throw Abort(.badRequest, reason: "invalid_fields") }
        return set
    }

    static func truncated(_ value: JSONValue, _ limit: Int) -> JSONValue {
        guard let s = value.string, s.count > limit else { return value }
        return .string(String(s.prefix(limit)) + "…")
    }

    private static func keep(_ object: [String: JSONValue], _ fields: Set<String>?, always: Set<String>) -> [String: JSONValue] {
        guard let fields else { return object }
        return object.filter { fields.contains($0.key) || always.contains($0.key) }
    }

    static func question(_ value: JSONValue, compact: Bool, fields: Set<String>?) -> JSONValue {
        guard case .object(var o) = value else { return value }
        if let fields { return .object(keep(o, fields, always: ["id"])) }
        if compact { for key in dropFromQuestion { o[key] = nil } }
        return .object(o)
    }

    static func questions(_ value: JSONValue, compact: Bool, fields: Set<String>?) -> JSONValue {
        guard case .array(let rows) = value else { return value }
        return .array(rows.map { question($0, compact: compact, fields: fields) })
    }

    static func card(_ value: JSONValue, compact: Bool, fields: Set<String>?) -> JSONValue {
        guard case .object(var o) = value else { return value }
        if compact {
            if case .array(let subtasks) = o["subtasks"] ?? .null { o["subtaskCount"] = .number(Double(subtasks.count)); o["subtasks"] = .array([]) }
            o["builds"] = .array([])
            if case .object(var update) = o["latestUpdate"] ?? .null { update["text"] = truncated(update["text"] ?? .null, cardTextLimit); o["latestUpdate"] = .object(update) }
            if case .array(let qs) = o["questions"] ?? .null {
                o["questions"] = .array(qs.map { q in
                    guard case .object(var qo) = q else { return q }
                    qo["prompt"] = truncated(qo["prompt"] ?? .null, promptLimit)
                    return .object(qo)
                })
            }
            if case .object(var project) = o["project"] ?? .null { project["color"] = nil; o["project"] = .object(project) }
        }
        return .object(keep(o, fields, always: ["task"]))
    }

    static func commandCenter(_ value: JSONValue, compact: Bool, fields: Set<String>?) -> JSONValue {
        guard case .object(var o) = value else { return value }
        if case .array(let lanes) = o["lanes"] ?? .null {
            o["lanes"] = .array(lanes.map { lane in
                guard case .object(var l) = lane, case .array(let cards) = l["cards"] ?? .null else { return lane }
                l["cards"] = .array(cards.map { card($0, compact: compact, fields: fields) })
                return .object(l)
            })
        }
        if case .array(let items) = o["items"] ?? .null { o["items"] = .array(items.map { card($0, compact: compact, fields: fields) }) }
        guard compact else { return .object(o) }
        o["compact"] = .bool(true)
        o["builds"] = .array([])
        if case .array(let updates) = o["updates"] ?? .null {
            o["updates"] = .array(updates.map { u in
                guard case .object(var uo) = u else { return u }
                uo["text"] = truncated(uo["text"] ?? .null, updateTextLimit)
                return .object(uo)
            })
        }
        if case .array(let projects) = o["projects"] ?? .null {
            o["projects"] = .array(projects.map { p in
                guard case .object(var po) = p, case .object(let sync) = po["sync"] ?? .null else { return p }
                po["sync"] = .object(sync.filter { ["bound", "state", "daysSince", "staleAfterDays"].contains($0.key) })
                return .object(po)
            })
        }
        return .object(o)
    }
}
