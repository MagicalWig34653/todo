import Fluent
import Vapor

struct LiveSessionLimits: Sendable {
    var eventsPerMinutePerSession = 60
    var eventsPerMinutePerTask = 120
    /// Oldest events beyond this number are dropped when a new one arrives (the view only needs the recent past).
    var eventsPerTask = 500
    var sessionsPerTask = 10
    /// One connection cannot fill all slots of a card with junk names.
    var sessionsPerActorPerTask = 5
    /// Across all cards of the account.
    var eventsPerMinutePerAccount = 600
}

struct LiveSessionDTO: Content, Equatable {
    let id: UUID
    let name: String
    let model: String?
    let actorType: String
    let actorLabel: String?
    /// `active` | `ended`
    let status: String
    let currentStep: String?
    /// ISO 8601 with milliseconds (`.SSSZ`).
    let startedAt: String
    let lastSeenAt: String
    let endedAt: String?
    /// Active but silent for longer than `LiveSessionService.staleAfter`: probably gone without saying so.
    let stale: Bool

    init(_ s: TaskLiveSession, now: Date) throws {
        id = try s.requireID(); name = s.name; model = s.model; actorType = s.actorType; actorLabel = s.actorLabel
        status = s.status; currentStep = s.currentStep
        startedAt = LiveSessionService.iso(s.startedAt); lastSeenAt = LiveSessionService.iso(s.lastSeenAt)
        endedAt = s.endedAt.map(LiveSessionService.iso)
        stale = s.status == "active" && now.timeIntervalSince(s.lastSeenAt) > LiveSessionService.staleAfter
    }
}

struct LiveEventDTO: Content, Equatable {
    let id: UUID
    let sessionID: UUID
    let sessionName: String?
    let kind: String
    let text: String
    let clientUUID: UUID?
    let createdAt: String

    init(_ e: TaskLiveEvent, sessionName: String?) throws {
        id = try e.requireID(); sessionID = e.sessionID; self.sessionName = sessionName; kind = e.kind; text = e.text
        clientUUID = e.clientUUID; createdAt = LiveSessionService.iso(e.createdAt)
    }
}

struct LiveTaskResponse: Content {
    let taskID: UUID
    /// Server clock, so that clients can show "vor X s" without trusting their own.
    let serverTime: String
    /// Most recently active first.
    let sessions: [LiveSessionDTO]
    /// Newest first.
    let items: [LiveEventDTO]
    /// Pass as `cursor` for the next older page; nil on the last page.
    let nextCursor: String?
}

/// One business path for REST (read) and MCP (read and report). `allowedProjects` narrows an OAuth grant like in
/// `WorkflowService`; every rights failure is a 404. Texts are user data: never logged, never echoed in errors.
struct LiveSessionService: Sendable {
    static let maxText = 280
    static let maxName = 80
    static let defaultName = "main"
    static let defaultLimit = 50
    static let maxLimit = 200
    static let staleAfter: TimeInterval = 15 * 60
    /// A report that repeats the current step only refreshes the sign of life; not more often than this.
    static let heartbeatEvery: TimeInterval = 5
    static let eventKinds: Set<String> = ["tool", "note", "question", "progress"]

    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil
    var actor: WorkflowActor? = nil
    var limits = LiveSessionLimits()

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: Rights

    private func task(_ id: UUID, role: ProjectRole) async throws -> TodoTask {
        let task = try await ProjectAccess(user: user, db: db).task(id, role: role)
        if let allowedProjects, !allowedProjects.contains(task.projectID) { throw Abort(.notFound) }
        return task
    }

    // MARK: Input

    static func clean(_ raw: String?, max: Int, reason: String) throws -> String? {
        guard let raw else { return nil }
        guard raw.utf8.count <= max * 8 + 64 else { throw Abort(.badRequest, reason: reason) }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        // `count` counts graphemes: 200 000 combining marks are one character. Bound the bytes first.
        guard value.count <= max, value.utf8.count <= max * 4 else { throw Abort(.badRequest, reason: reason) }
        return value
    }

    /// Length is checked on the input, then the filter runs, then whitespace is flattened to a single line.
    static func compactText(_ raw: String?, reason: String) throws -> String? {
        guard let value = try clean(raw, max: maxText, reason: reason) else { return nil }
        let filtered = SecretFilter.redact(value).text
        let flat = filtered.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        return flat.count > maxText ? String(flat.prefix(maxText - 1)) + "…" : flat
    }

    static func sessionName(_ raw: String?) throws -> String {
        guard let name = try clean(raw, max: maxName, reason: "invalid_session") else { return defaultName }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Abort(.badRequest, reason: "invalid_session") }
        return SecretFilter.redact(name).text
    }

    /// Edit rights, and the card must not be done: its data is deleted 3 days after done, a later report would vanish silently.
    private func requireOpen(_ taskID: UUID) async throws {
        guard try await task(taskID, role: .edit).status != "done" else { throw Abort(.conflict, reason: "task_done") }
    }

    private func requireActor() throws -> WorkflowActor {
        guard let actor else { throw Abort(.forbidden) }
        return actor
    }

    // MARK: Session

    /// Finds or creates the session of this card; a parallel first report is settled by the unique key (card, name).
    private func session(taskID: UUID, name: String, actor: WorkflowActor, label: String?, model: String?) async throws -> TaskLiveSession {
        func existing() async throws -> TaskLiveSession? {
            try await TaskLiveSession.query(on: db).filter(\.$taskID == taskID).filter(\.$name == name).first()
        }
        // The name belongs to the connection that created it: another actor neither reads, renames nor ends it.
        func owned(_ s: TaskLiveSession) throws -> TaskLiveSession {
            guard s.actorID == actor.id else { throw Abort(.conflict, reason: "session_name_taken") }
            return s
        }
        if let s = try await existing() { return try owned(s) }
        guard try await TaskLiveSession.query(on: db).filter(\.$taskID == taskID).count() < limits.sessionsPerTask,
              try await TaskLiveSession.query(on: db).filter(\.$taskID == taskID).filter(\.$actorID == actor.id).count() < limits.sessionsPerActorPerTask else {
            throw Abort(.tooManyRequests, reason: "too_many_sessions")
        }
        let now = ChannelService.now()
        let s = TaskLiveSession()
        s.taskID = taskID; s.userID = try user.requireID(); s.name = name; s.model = model
        s.actorType = actor.type.rawValue.lowercased(); s.actorID = actor.id; s.actorLabel = label ?? actor.label
        s.status = "active"; s.startedAt = now; s.lastSeenAt = now
        do { try await s.save(on: db); return s }
        catch { if let s = try await existing() { return try owned(s) }; throw error }
    }

    /// Strictly after the card's newest event, so ordering by (time, id) never mixes up two events of one millisecond.
    private func nextTime(taskID: UUID) async throws -> Date {
        let now = ChannelService.now()
        if let last = try await TaskLiveEvent.query(on: db).filter(\.$taskID == taskID).sort(\.$createdAt, .descending).first()?.createdAt, now <= last {
            return last.addingTimeInterval(0.001)
        }
        return now
    }

    private func checkRate(taskID: UUID, sessionID: UUID) async throws {
        let since = Date().addingTimeInterval(-60)
        let perAccount = try await TaskLiveEvent.query(on: db).join(TaskLiveSession.self, on: \TaskLiveEvent.$sessionID == \TaskLiveSession.$id)
            .filter(TaskLiveSession.self, \.$userID == user.requireID()).filter(\.$createdAt > since).count()
        if perAccount >= limits.eventsPerMinutePerAccount { throw Abort(.tooManyRequests, headers: ["Retry-After": "10"], reason: "rate_limited") }
        let perSession = try await TaskLiveEvent.query(on: db).filter(\.$sessionID == sessionID).filter(\.$createdAt > since).count()
        let perTask = try await TaskLiveEvent.query(on: db).filter(\.$taskID == taskID).filter(\.$createdAt > since).count()
        if perSession >= limits.eventsPerMinutePerSession || perTask >= limits.eventsPerMinutePerTask {
            throw Abort(.tooManyRequests, headers: ["Retry-After": "10"], reason: "rate_limited")
        }
    }

    private func append(taskID: UUID, session: TaskLiveSession, kind: String, text: String, clientUUID: UUID?) async throws -> TaskLiveEvent {
        try await checkRate(taskID: taskID, sessionID: session.requireID())
        let e = TaskLiveEvent()
        e.taskID = taskID; e.sessionID = try session.requireID(); e.kind = kind; e.text = text; e.clientUUID = clientUUID
        e.createdAt = try await nextTime(taskID: taskID)
        try await e.save(on: db)
        try await prune(taskID: taskID)
        return e
    }

    /// Keeps the newest `eventsPerTask` events of the card; idempotent, so a lost race heals with the next report.
    private func prune(taskID: UUID) async throws {
        let total = try await TaskLiveEvent.query(on: db).filter(\.$taskID == taskID).count()
        guard total > limits.eventsPerTask else { return }
        let drop = try await TaskLiveEvent.query(on: db).filter(\.$taskID == taskID).sort(\.$createdAt).sort(\.$id).limit(total - limits.eventsPerTask).all()
        try await TaskLiveEvent.query(on: db).filter(\.$id ~~ drop.compactMap(\.id)).delete()
    }

    // MARK: Report

    /// Sets the current step (and writes it as a `step` event when it changed), or only refreshes the sign of life
    /// (`step` nil). `ended: true` closes the session; any later report reopens it.
    func reportStep(_ taskID: UUID, session name: String?, step: String?, model: String?, ended: Bool?, agentName: String?) async throws -> LiveSessionDTO {
        let actor = try requireActor()
        let name = try Self.sessionName(name)
        let text = try Self.compactText(step, reason: "invalid_step")
        let model = try Self.clean(model, max: 80, reason: "invalid_model").map { SecretFilter.redact($0).text }
        // Only an explicit agentName renames the session later; without one the connection's client name is the default label.
        guard (agentName?.utf8.count ?? 0) <= 400 else { throw Abort(.badRequest, reason: "invalid_agent_name") }
        let explicitLabel = try WorkflowService.optionalLabel(agentName, reason: "invalid_agent_name").map { SecretFilter.redact($0).text }
        try await requireOpen(taskID)
        let s = try await session(taskID: taskID, name: name, actor: actor, label: explicitLabel, model: model)
        let now = ChannelService.now()
        let reopens = s.status == "ended" && ended != true
        let closes = ended == true && s.status != "ended"
        let stepChanged = text != nil && text != s.currentStep
        let modelChanged = model != nil && model != s.model
        let labelChanged = explicitLabel != nil && explicitLabel != s.actorLabel
        let due = now.timeIntervalSince(s.lastSeenAt) >= Self.heartbeatEvery
        guard stepChanged || reopens || closes || modelChanged || labelChanged || due else { return try LiveSessionDTO(s, now: now) }
        if stepChanged, let text { _ = try await append(taskID: taskID, session: s, kind: "step", text: text, clientUUID: nil); s.currentStep = text }
        if let model { s.model = model }
        if let explicitLabel { s.actorLabel = explicitLabel }
        s.lastSeenAt = now
        if ended == true { s.status = "ended"; s.endedAt = s.endedAt ?? now } else { s.status = "active"; s.endedAt = nil }
        try await s.save(on: db)
        return try LiveSessionDTO(s, now: now)
    }

    /// Returns the event and whether it is new (false: replay of an earlier report with the same `clientUUID`).
    func reportEvent(_ taskID: UUID, session name: String?, kind: String, text raw: String, clientUUID: UUID?) async throws -> (event: LiveEventDTO, created: Bool) {
        let actor = try requireActor()
        guard Self.eventKinds.contains(kind) else { throw Abort(.badRequest, reason: "invalid_kind") }
        guard let text = try Self.compactText(raw, reason: "invalid_text") else { throw Abort(.badRequest, reason: "invalid_text") }
        let name = try Self.sessionName(name)
        try await requireOpen(taskID)
        let s = try await session(taskID: taskID, name: name, actor: actor, label: nil, model: nil)
        let sessionID = try s.requireID()

        func replay() async throws -> (LiveEventDTO, Bool)? {
            guard let key = clientUUID,
                  let existing = try await TaskLiveEvent.query(on: db).filter(\.$sessionID == sessionID).filter(\.$clientUUID == key).first() else { return nil }
            guard existing.kind == kind, existing.text == text else { throw Abort(.conflict, reason: "client_uuid_conflict") }
            return (try LiveEventDTO(existing, sessionName: s.name), false)
        }
        if let again = try await replay() { return again }
        let event: TaskLiveEvent
        do { event = try await append(taskID: taskID, session: s, kind: kind, text: text, clientUUID: clientUUID) }
        catch {
            if let again = try await replay() { return again }
            throw error
        }
        let now = event.createdAt
        if s.status == "ended" { s.status = "active"; s.endedAt = nil }
        s.lastSeenAt = now
        try await s.save(on: db)
        return (try LiveEventDTO(event, sessionName: s.name), true)
    }

    // MARK: Read

    func live(_ taskID: UUID, limit: Int?, cursor: String?, since: Date?) async throws -> LiveTaskResponse {
        let limit = limit ?? Self.defaultLimit
        guard (1...Self.maxLimit).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        let parsed = try cursor.map(ChannelService.parseCursor)
        _ = try await task(taskID, role: .read)
        let sessions = try await TaskLiveSession.query(on: db).filter(\.$taskID == taskID).sort(\.$lastSeenAt, .descending).all()
        var query = TaskLiveEvent.query(on: db).filter(\.$taskID == taskID)
        if let since { query = query.filter(\.$createdAt > since) }
        if let (date, id) = parsed {
            query = query.group(.or) { or in
                or.filter(\.$createdAt < date)
                or.group(.and) { $0.filter(\.$createdAt == date).filter(\.$id < id) }
            }
        }
        let rows = try await query.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit + 1).all()
        let page = Array(rows.prefix(limit))
        let next = rows.count > limit ? try page.last.map { "\(Int64(($0.createdAt.timeIntervalSince1970 * 1000).rounded())):\(try $0.requireID().uuidString)" } : nil
        let names = Dictionary(sessions.compactMap { s in s.id.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        return LiveTaskResponse(taskID: taskID, serverTime: Self.iso(now), sessions: try sessions.map { try LiveSessionDTO($0, now: now) },
                                items: try page.map { try LiveEventDTO($0, sessionName: names[$0.sessionID]) }, nextCursor: next)
    }
}

struct LiveSessionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("v1", "tasks", ":id", "live", use: read)
    }

    @Sendable func read(_ req: Request) async throws -> LiveTaskResponse {
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.notFound) }
        var limit: Int?
        if let raw = req.query[String.self, at: "limit"] {
            guard let value = Int(raw) else { throw Abort(.badRequest, reason: "invalid_limit") }
            limit = value
        }
        var since: Date?
        if let raw = req.query[String.self, at: "since"] {
            guard let date = SystemStatusService.parseDate(raw) else { throw Abort(.badRequest, reason: "invalid_since") }
            since = date
        }
        return try await LiveSessionService(user: user, db: req.db).live(id, limit: limit, cursor: req.query[String.self, at: "cursor"], since: since)
    }
}

extension ExpiredCleanup {
    /// Sessions and events of cards that have been done for longer than `liveSessionRetention`. A card that is open
    /// again (or finished again later, which refreshes `updated_at`) keeps its data.
    func purgeLiveSessions(on db: any Database, now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-liveSessionRetention)
        var total = 0
        while true {
            let ids = try await TaskLiveSession.query(on: db)
                .join(TodoTask.self, on: \TaskLiveSession.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$status == "done").filter(TodoTask.self, \.$updatedAt < cutoff)
                .sort(\TaskLiveSession.$id).limit(batchSize).all().compactMap(\.id)
            if ids.isEmpty { return total }
            try await TaskLiveEvent.query(on: db).filter(\.$sessionID ~~ ids).delete()
            try await TaskLiveSession.query(on: db).filter(\.$id ~~ ids).delete()
            total += ids.count
            if ids.count < batchSize { return total }
        }
    }
}
