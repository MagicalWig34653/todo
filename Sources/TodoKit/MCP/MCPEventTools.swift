import Fluent
import Vapor

extension MCPController {
    /// Long-poll hint tool (docs/PUSH-AN-CLAUDE-CODE.md, option a). Built on LiveHub/`live_events` (ADR 0022).
    static let eventTools: [Tool] = [
        Tool(name: "wait_for_events", scope: "tasks:read",
             description: "Wait up to timeoutSeconds (1 to 25, default 20) until something changed on the board, then return hints only: {changed, token, hints:[{kind, taskID, projectID}]}. No content is returned; fetch it with get_question, list_open_questions, list_pending_reviews, get_command_center or list_comments. Call it without 'since' first to get a token, then pass the returned token back. Use it only to wait for an answer after a blocking ask_question, for a few rounds; it does not run in the background.",
             properties: ["since": Schema.string("Token from the previous call. Omit it on the first call: the tool then returns the current token immediately with changed=false.", maxLength: 200),
                          "timeoutSeconds": Schema.integer("How long to wait at most (default 20).", min: 1, max: 25)])
    ]

    struct EventHint: Encodable { let kind: String; let taskID: String; let projectID: String }
    struct EventsResponse: Encodable { let changed: Bool; let token: String; let hints: [EventHint] }

    static func hintKind(_ table: String) -> String {
        switch table {
        case "task_questions": return "question"
        case "task_reviews": return "review"
        case "comments": return "comment"
        case "task_progress_notes": return "progress"
        case "acceptance_criteria": return "criterion"
        case "attachments", "build_artifacts": return "attachment"
        default: return "other"
        }
    }

    func waitForEvents(_ a: JSONValue, req: Request, user: User, grant: OAuthGrant) async throws -> JSONValue {
        let a: JSONValue = a.isNull ? .object([:]) : a
        guard case .object(let args) = a, Set(args.keys).isSubset(of: ["since", "timeoutSeconds"]) else { throw Abort(.badRequest, reason: "invalid_arguments") }
        let db = req.db
        let settings = req.application.liveSettings
        guard settings.enabled else { throw Abort(.notFound) }
        let since = try optionalString(a, "since")
        let requested = try intArgument(a["timeoutSeconds"], reason: "invalid_timeout") ?? 20
        guard (1...25).contains(requested) else { throw Abort(.badRequest, reason: "invalid_timeout") }
        let timeout = min(requested, settings.maxWaitSeconds)
        let userID = try user.requireID(), grantID = try grant.requireID()

        func respond(_ snap: LiveToken.Snapshot, changed: Bool) async throws -> JSONValue {
            var hints: [EventHint] = []
            if changed, let since, let after = LiveToken.maxEventID(of: since) {
                // Re-read the grant: projects may have been withdrawn, or the grant revoked, while waiting.
                guard let current = try await OAuthGrant.find(grantID, on: db), !current.revoked else { throw Abort(.unauthorized) }
                hints = try await visibleHints(after: after, user: user, grant: current, db: db)
            }
            return try .encoded(EventsResponse(changed: changed, token: snap.token, hints: hints))
        }

        let initial = try await LiveToken.current(on: db)
        guard let since, !since.isEmpty else { return try await respond(initial, changed: false) }
        if since != initial.token { return try await respond(initial, changed: true) }

        let deadline = Date().addingTimeInterval(Double(timeout))
        while true {
            let slice = min(settings.sessionRecheckSeconds, max(0.05, deadline.timeIntervalSinceNow))
            let (registration, wake) = await req.application.liveHub.wait(user: userID, since: since, seconds: slice, settings: settings)
            if case .ok = registration {} else { throw Abort(.tooManyRequests, reason: "too_many_waiters") }
            // Revoking the grant ends the wait.
            guard let live = try await OAuthGrant.find(grantID, on: db), !live.revoked else { throw Abort(.unauthorized) }
            switch wake ?? .recheck {
            case .changed:
                return try await respond(try await LiveToken.current(on: db), changed: true)
            case .shutdown:
                return try await respond(try await LiveToken.current(on: db), changed: false)
            case .recheck:
                if deadline.timeIntervalSinceNow <= 0.01 {
                    let snap = try await LiveToken.current(on: db)
                    return try await respond(snap, changed: snap.token != since)
                }
            }
        }
    }

    /// Hints on projects the grant lists AND the account can currently read; everything else is dropped.
    private func visibleHints(after: Int, user: User, grant: OAuthGrant, db: any Database) async throws -> [EventHint] {
        let allowed = Set(grant.projects)
        var projectOfTask: [UUID: UUID?] = [:]
        var readable: [UUID: Bool] = [:]
        var result: [EventHint] = []
        var seen = Set<String>()
        for hint in try await LiveToken.taskHints(after: after, on: db) {
            if projectOfTask[hint.taskID] == nil {
                projectOfTask[hint.taskID] = .some(try await TodoTask.find(hint.taskID, on: db)?.projectID)
            }
            guard let project = projectOfTask[hint.taskID] ?? nil, allowed.contains(project) else { continue }
            if readable[project] == nil {
                readable[project] = (try? await ProjectAccess(user: user, db: db).project(project, role: .read)) != nil
            }
            guard readable[project] == true else { continue }
            let kind = Self.hintKind(hint.kind)
            guard seen.insert("\(kind)/\(hint.taskID)").inserted else { continue }
            result.append(EventHint(kind: kind, taskID: hint.taskID.uuidString, projectID: project.uuidString))
            if result.count >= 50 { break }
        }
        return result
    }
}
