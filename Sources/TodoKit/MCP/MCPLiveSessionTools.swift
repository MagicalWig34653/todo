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
        Tool(name: "report_session_status", scope: "tasks:write",
             description: "Light heartbeat without a claimed card: tell the project what this session is doing right now, in one short sentence (up to 300 characters, for example 'Baue den Migrationstest'). One status per session name and project, overwritten by every call; at most one write per 10 seconds per session (429 rate_limited). Without updates it is marked orphaned after 30 minutes and hidden after 24 hours. Secrets are masked before storage; never report transcripts. Needs edit access to the project (and the project in your grant).",
             properties: ["projectID": Schema.uuid("The project you work in."),
                          "sessionName": Schema.string("Name of this session, for example the machine or window, 1 to 100 characters.", maxLength: 100),
                          "activity": Schema.string("What you are doing now, 1 to 300 characters.", maxLength: 300)],
             required: ["projectID", "sessionName", "activity"]),
        Tool(name: "get_overview_now", scope: "tasks:read",
             description: "What is happening now across your projects. Answer: {serverTime, now:{counts:{running, waiting, recentlyDone, silent}, running:[{kind task|session, projectID, projectName, taskID, title, text, worker, since, lastSignAt, ageSeconds, dueAt, percent}], waiting:[{kind question|review, id, projectID, projectName, taskID, taskTitle, text, createdAt}], recentlyDone:[{taskID, title, projectID, projectName, doneAt}], silent:[...like running]}, projects:[{projectID, projectName, lastActivityAt, runningTasks:[{taskID, title, worker, lastProgress, ageSeconds, percent}], sessions:[{sessionName, activity, updatedAt, ageSeconds, orphaned}], agentJobs, builds, openQuestions, pendingReviews, recentActivity}]}. now: running = cards in progress and sessions with a sign of life in the last 30 minutes (sessions whose sentence starts with 'Beendet' are left out), silent = in progress or session without a sign of life for more than 30 minutes, waiting = open questions and pending reviews, recentlyDone = cards finished in the last 6 hours; counts are the totals before limit. Agents: use compact=true (only serverTime and now, texts up to 140 characters, at most `limit` entries per list, default 10). Only projects you can read and that are in your grant; projects most recently active first.",
             properties: ["compact": Schema.boolean("true returns only {serverTime, now} (no projects), texts shortened to 140 characters, each list cut to limit. Recommended for agents."),
                          "limit": Schema.integer("Entries per list of now when compact=true (default 10, 1 to 50). The counts still hold the totals.", min: 1, max: 50)]),
    ]

    func callLiveSession(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        if name == "report_session_status" {
            let service = SessionStatusService(user: user, db: db, allowedProjects: Set(grant.projects))
            return try .encoded(try await service.report(projectID: uuid(a["projectID"]), sessionName: requiredString(a, "sessionName"), activity: requiredString(a, "activity")))
        }
        if name == "get_overview_now" {
            return try .encoded(try await OverviewNowService(user: user, db: db, allowedProjects: Set(grant.projects))
                .now(compact: optionalBool(a, "compact") ?? false, limit: intArgument(a["limit"], reason: "invalid_limit")))
        }
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
