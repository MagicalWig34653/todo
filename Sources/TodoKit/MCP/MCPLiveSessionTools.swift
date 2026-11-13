import Fluent
import Vapor

/// Live view per card (ADR 0031). The agent reports compact events about itself; people read them on the card.
/// Same service as REST (`LiveSessionService`); rights are those of `post_progress` (edit role) and `get_task_context` (read).
extension MCPController {
    static let liveSessionTools: [Tool] = [
        Tool(name: "report_session_step", scope: "tasks:write",
             description: "Tell the card's live view what you are doing right now: one short step (up to 280 characters, for example 'Schreibe den Migrationstest'). Call it when the step changes, not per command. Without step it only refreshes your sign of life; with ended=true the session is closed (a later report reopens it). Secrets are masked before storage ([gefiltert]); never report transcripts or file contents. Rate limited per session and card (429 rate_limited).",
             properties: ["taskID": Schema.uuid("The card you work on (needs write access)."),
                          "step": Schema.string("Current step, 1 to 280 characters. Omit to only send a heartbeat.", maxLength: 280),
                          "session": Schema.string("Name of your working session on this card, for example the machine or window (default main, up to 80 characters).", maxLength: 80),
                          "model": Schema.string("Optional model name shown next to the session.", maxLength: 80),
                          "ended": Schema.boolean("true closes the session."),
                          "agentName": Schema.string("Optional label of the agent, up to 100 characters.", maxLength: 100)],
             required: ["taskID"]),
        Tool(name: "report_session_event", scope: "tasks:write",
             description: "Add one compact event to the card's live view: kind tool (a tool or command you ran, summarised), note, question (you are waiting for an answer; use ask_question for the real question) or progress. Text up to 280 characters, single line, secrets are masked before storage. Retrying with the same clientUUID returns the original event instead of a duplicate. Only the newest 500 events per card are kept; they are deleted 3 days after the card is done.",
             properties: ["taskID": Schema.uuid("The card you work on (needs write access)."),
                          "kind": Schema.string("Event kind.", values: ["tool", "note", "question", "progress"]),
                          "text": Schema.string("Compact text, 1 to 280 characters.", maxLength: 280),
                          "session": Schema.string("Name of your working session (default main).", maxLength: 80),
                          "clientUUID": Schema.uuid("Idempotency key chosen by the sender.")],
             required: ["taskID", "kind", "text"]),
        Tool(name: "get_task_live", scope: "tasks:read",
             description: "Read the live view of a card: {taskID, serverTime, sessions:[{id, name, model, actorType, actorLabel, status, currentStep, startedAt, lastSeenAt, endedAt, stale}], items:[{id, sessionID, sessionName, kind, text, createdAt}], nextCursor}. Events are newest first; pass nextCursor as cursor for older ones, since for only newer ones. Needs read access to the card's project.",
             properties: ["taskID": Schema.uuid("The card."),
                          "limit": Schema.integer("Maximum events per page (default 50).", min: 1, max: 200),
                          "cursor": Schema.string("nextCursor of the previous page.", maxLength: 80),
                          "since": Schema.string("ISO 8601 date-time: only events created after it.", maxLength: 40)],
             required: ["taskID"]),
    ]

    func callLiveSession(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        let taskID = try uuid(a["taskID"])
        var service = LiveSessionService(user: user, db: db, allowedProjects: Set(grant.projects))
        switch name {
        case "report_session_step":
            service.actor = try await actor(grant: grant, db: db)
            return try .encoded(try await service.reportStep(taskID, session: optionalString(a, "session"), step: optionalString(a, "step"),
                model: optionalString(a, "model"), ended: optionalBool(a, "ended"), agentName: optionalString(a, "agentName")))
        case "report_session_event":
            service.actor = try await actor(grant: grant, db: db)
            return try .encoded(try await service.reportEvent(taskID, session: optionalString(a, "session"), kind: requiredString(a, "kind"),
                text: requiredString(a, "text"), clientUUID: optionalUUID(a, "clientUUID")).event)
        case "get_task_live":
            var since: Date?
            if let raw = try optionalString(a, "since") {
                guard let date = SystemStatusService.parseDate(raw) else { throw Abort(.badRequest, reason: "invalid_since") }
                since = date
            }
            return try .encoded(try await service.live(taskID, limit: intArgument(a["limit"], reason: "invalid_limit"), cursor: optionalString(a, "cursor"), since: since))
        default:
            throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }
}
