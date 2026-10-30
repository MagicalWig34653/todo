import Vapor

struct ManualSection: Content {
    let id: String
    let title: String
}

struct ManualResponse: Content {
    let version: String
    /// Section ids of the whole manual (use as `section`).
    let sections: [ManualSection]
    /// Set when a single section was requested.
    let section: String?
    let format: String
    /// Markdown (the whole manual or the requested section).
    let content: String
    /// Machine-readable conventions (lanes, columns, states, tools, limits).
    let conventions: JSONValue
}

/// Versioned agent manual (`docs/agent-manual.md`, embedded by `scripts/embed-agent-manual.sh`) and the structured
/// conventions derived from the code (ADR 0014).
enum AgentManual {
    static let markdown = AgentManualContent.text

    static var version: String {
        guard let first = markdown.split(separator: "\n", maxSplits: 1).first,
              let range = first.range(of: "manual-version:") else { return "0.0.0" }
        return first[range.upperBound...].replacingOccurrences(of: "-->", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func slug(_ title: String) -> String {
        title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }

    /// `## ` headings split the manual into sections.
    static var parsed: [(id: String, title: String, body: String)] {
        var result: [(String, String, String)] = []
        var current: (String, String, [String])?
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") {
                if let c = current { result.append((c.0, c.1, c.2.joined(separator: "\n"))) }
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                current = (slug(title), title, [line])
            } else if current != nil { current!.2.append(line) }
        }
        if let c = current { result.append((c.0, c.1, c.2.joined(separator: "\n"))) }
        return result
    }

    static var sections: [ManualSection] { parsed.map { ManualSection(id: $0.id, title: $0.title) } }

    static func response(section: String?) throws -> ManualResponse {
        var content = markdown
        var selected: String?
        if let section {
            let key = slug(section)
            guard let found = parsed.first(where: { $0.id == key }) else { throw Abort(.notFound, reason: "unknown_section") }
            content = found.body; selected = found.id
        }
        return ManualResponse(version: version, sections: sections, section: selected, format: "markdown", content: content,
            conventions: conventions)
    }

    static func lane(_ key: String, _ title: String, _ rule: String) -> JSONValue {
        .object(["key": .string(key), "title": .string(title), "rule": .string(rule)])
    }

    /// Structured conventions; derived from the same constants the services use.
    static var conventions: JSONValue {
        let columns: [JSONValue] = ColumnRole.template.map { .object([
            "name": .string($0.name), "role": .string($0.role.rawValue), "isDone": .bool($0.role == .done),
            "aliases": .strings(ColumnRole.aliases[$0.role] ?? []),
        ]) }
        let tools: [JSONValue] = MCPController.tools.map { .object([
            "name": .string($0.name), "scope": .string($0.scope), "summary": .string($0.description),
        ]) }
        return .object([
            "manualVersion": .string(version),
            "lanes": .array([
                lane("running", "Läuft", "status in_progress, claimed, active runner job or column role working"),
                lane("question", "Frage offen", "at least one open question on the task or one of its subtasks"),
                lane("review", "Review fällig", "status in_review, pending review or column role review"),
                lane("ready", "Bereit", "status open and not in a backlog column"),
                lane("blocked", "Blockiert", "blockedReason set or an unfinished prerequisite"),
                lane("done", "Erledigt kürzlich", "status done within doneWithinDays (default 7)"),
            ]),
            "laneAssignmentOrder": .strings(["done", "question", "review", "blocked", "running", "ready"]),
            "columnTemplate": .object(["name": .string("agent_workflow"), "columns": .array(columns)]),
            "taskStatuses": .strings(["open", "in_progress", "in_review", "done"]),
            "taskKinds": .strings(["task", "feature"]),
            "questionStates": .strings(["open", "answered", "withdrawn"]),
            "reviewStates": .strings(["pending", "accepted", "changes_requested", "withdrawn"]),
            "reviewDecisions": .strings(["accept", "request_changes"]),
            "progressSources": .strings(["status", "subtasks", "criteria", "agent", "none"]),
            "attachmentMediaTypes": .strings(["image/png", "image/jpeg", "image/webp", "application/pdf"]),
            "briefHeadings": .strings(["Goals", "Constraints", "Definition of done", "Agent rules"]),
            "limits": .object([
                "inlineAttachmentBytes": .number(Double(WorkflowLimits.inlineAttachmentBytes)),
                "textMaxCharacters": .number(Double(WorkflowLimits.maxText)),
                "briefMaxCharacters": .number(Double(WorkflowLimits.maxBrief)),
                "questionOptionsMax": .number(20),
            ]),
            "tools": .array(tools),
        ])
    }
}
