import Fluent
import Vapor

// MARK: - DTOs

struct DailyBriefItem: Content, Equatable {
    let id: UUID
    let title: String
    /// Nil only for confirmation requests, which belong to the account and not to a project.
    let projectID: UUID?
    /// `question` | `review` | `confirmation` | `task` | `project` | `decision`
    let kind: String
}

struct DailyBriefSection: Content, Equatable {
    /// `waiting` | `decisions` | `orphaned` | `stale` | `running` | `done`
    let key: String
    let title: String
    /// Total before the item list was shortened.
    let count: Int
    let truncated: Bool
    let items: [DailyBriefItem]
}

struct DailyBriefSummary: Content, Equatable {
    /// openQuestions + pendingReviews + pendingConfirmations
    let waiting: Int
    let openQuestions: Int
    let pendingReviews: Int
    let pendingConfirmations: Int
    let orphanedClaims: Int
    let staleProjects: Int
    /// In-progress tasks with a claim that are not orphaned.
    let running: Int
    /// Tasks done since `since`.
    let done: Int
    /// Journal decisions recorded since `since` that the person has not reviewed yet.
    var decisionsToReview: Int = 0
}

struct DailyBriefResponse: Content {
    let generatedAt: Date
    let since: Date
    /// `account` | `project`
    let scope: String
    let projectID: UUID?
    /// `full` | `line`
    let format: String
    /// One German line, at most 200 characters.
    let line: String
    /// `full` only.
    let summary: DailyBriefSummary?
    /// `full` only; ordered by priority (waiting, decisions, orphaned, stale, running, done).
    let sections: [DailyBriefSection]?
}

// MARK: - Service

/// Daily brief ("Tagesbericht"): a short, priority-ordered read of what needs the person, what is stuck, what runs and
/// what got done. Shared by REST and MCP; the scope is resolved like `get_command_center` (readable projects, OAuth
/// grant), so nothing outside the caller's rights appears. The number of queries is constant per chunk of 400 projects.
struct DailyBriefService: Sendable {
    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil
    /// Injectable clock (tests, scheduler).
    var clock: @Sendable () -> Date = { Date() }

    static let itemLimit = 5
    static let lineLimit = 200
    static let titleLimit = 120
    private static let chunkSize = 400

    // MARK: Parameters

    /// Start of yesterday in UTC. The account has no time zone setting, so UTC is the day boundary everywhere.
    static func defaultSince(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
    }

    /// ISO 8601 date-time or a plain date (YYYY-MM-DD, UTC midnight). Anything else is `invalid_since`.
    static func parseSince(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateOnly = ISO8601DateFormatter(); dateOnly.formatOptions = [.withFullDate]; dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = plain.date(from: raw) ?? fractional.date(from: raw) ?? dateOnly.date(from: raw) else {
            throw Abort(.badRequest, reason: "invalid_since")
        }
        return date
    }

    static func parseFormat(_ raw: String?) throws -> String {
        guard let raw else { return "full" }
        guard ["full", "line"].contains(raw) else { throw Abort(.badRequest, reason: "invalid_format") }
        return raw
    }

    // MARK: Line

    /// Never longer than `lineLimit` characters, whatever the numbers are.
    static func line(for s: DailyBriefSummary) -> String {
        var attention: [String] = []
        if s.waiting > 0 { attention.append("\(s.waiting) \(s.waiting == 1 ? "wartet" : "warten") auf dich") }
        if s.decisionsToReview > 0 { attention.append("\(s.decisionsToReview) \(s.decisionsToReview == 1 ? "Entscheidung" : "Entscheidungen") zu prüfen") }
        if s.orphanedClaims > 0 { attention.append("\(s.orphanedClaims) verwaist") }
        if s.staleProjects > 0 { attention.append("\(s.staleProjects) \(s.staleProjects == 1 ? "Projekt" : "Projekte") veraltet") }
        var activity: [String] = []
        if s.done > 0 { activity.append("\(s.done) erledigt") }
        if s.running > 0 { activity.append("\(s.running) \(s.running == 1 ? "läuft" : "laufen")") }
        let head = attention.isEmpty ? "Alles ruhig: nichts wartet auf dich." : attention.joined(separator: ", ")
        let text = activity.isEmpty ? head : head + " · " + activity.joined(separator: ", ")
        return text.count <= lineLimit ? text : String(text.prefix(lineLimit - 1)) + "…"
    }

    // MARK: Build

    private struct Row { let at: Date; let item: DailyBriefItem }
    private struct Part { var count = 0; var rows: [Row] = [] }

    /// Runs `fetch` per chunk of project ids and merges counts and the oldest/newest rows.
    private func gather(_ ids: [UUID], newestFirst: Bool = false, _ fetch: ([UUID]) async throws -> Part) async throws -> Part {
        var merged = Part()
        var index = 0
        while index < ids.count {
            let part = try await fetch(Array(ids[index..<min(index + Self.chunkSize, ids.count)]))
            index += Self.chunkSize
            merged.count += part.count
            merged.rows += part.rows
        }
        merged.rows.sort { newestFirst ? $0.at > $1.at : $0.at < $1.at }
        merged.rows = Array(merged.rows.prefix(Self.itemLimit))
        return merged
    }

    private static func clip(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count <= titleLimit ? t : String(t.prefix(titleLimit - 1)) + "…"
    }

    func build(projectID: UUID? = nil, since requested: Date? = nil, format: String = "full") async throws -> DailyBriefResponse {
        let now = clock()
        let since = requested ?? Self.defaultSince(now: now)
        guard since <= now else { throw Abort(.badRequest, reason: "invalid_since") }
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: true, allowed: allowedProjects)
        let ids = scope.projectIDs

        // Waiting for the person: open questions, pending reviews (undone tasks only), confirmation requests.
        let questions = try await gather(ids) { chunk in
            let base = { TaskQuestion.query(on: db).join(TodoTask.self, on: \TaskQuestion.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TodoTask.self, \.$status != "done")
                .filter(TaskQuestion.self, \.$state == "open") }
            let rows = try await base().sort(TaskQuestion.self, \.$createdAt).sort(TaskQuestion.self, \.$id).limit(Self.itemLimit).all()
            return Part(count: try await base().count(), rows: try rows.map { q in
                let task = try q.joined(TodoTask.self)
                return Row(at: q.createdAt ?? .distantPast, item: DailyBriefItem(id: try q.requireID(), title: Self.clip(task.title), projectID: task.projectID, kind: "question"))
            })
        }
        let reviews = try await gather(ids) { chunk in
            let base = { TaskReview.query(on: db).join(TodoTask.self, on: \TaskReview.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TodoTask.self, \.$status != "done")
                .filter(TaskReview.self, \.$state == "pending") }
            let rows = try await base().sort(TaskReview.self, \.$createdAt).sort(TaskReview.self, \.$id).limit(Self.itemLimit).all()
            return Part(count: try await base().count(), rows: try rows.map { r in
                let task = try r.joined(TodoTask.self)
                return Row(at: r.createdAt ?? .distantPast, item: DailyBriefItem(id: try r.requireID(), title: Self.clip(task.title), projectID: task.projectID, kind: "review"))
            })
        }
        // Account-wide, like the command center: only without project narrowing and without an OAuth grant.
        var confirmations = Part()
        if projectID == nil, allowedProjects == nil {
            let userID = try user.requireID()
            let base = { ActionRequest.query(on: db).filter(\.$userID == userID).filter(\.$state == "pending").filter(\.$expiresAt > now) }
            let rows = try await base().sort(\.$createdAt).sort(\.$id).limit(Self.itemLimit).all()
            confirmations = Part(count: try await base().count(), rows: try rows.map {
                Row(at: $0.createdAt ?? .distantPast, item: DailyBriefItem(id: try $0.requireID(), title: Self.clip($0.summary), projectID: nil, kind: "confirmation"))
            })
        }
        let waitingRows = (questions.rows + reviews.rows + confirmations.rows).sorted { $0.at < $1.at }.prefix(Self.itemLimit).map(\.item)
        let waiting = questions.count + reviews.count + confirmations.count

        // Journal decisions since `since` that still wait for a verdict, newest first (morning review).
        let decisions = try await gather(ids, newestFirst: true) { chunk in
            let base = { TaskDecision.query(on: db).join(TodoTask.self, on: \TaskDecision.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TaskDecision.self, \.$state == "open")
                .filter(TaskDecision.self, \.$createdAt >= since) }
            let rows = try await base().sort(TaskDecision.self, \.$createdAt, .descending).sort(TaskDecision.self, \.$id).limit(Self.itemLimit).all()
            return Part(count: try await base().count(), rows: try rows.map { d in
                let task = try d.joined(TodoTask.self)
                return Row(at: d.createdAt ?? .distantPast, item: DailyBriefItem(id: try d.requireID(), title: Self.clip(d.decision), projectID: task.projectID, kind: "decision"))
            })
        }

        // Claimed in-progress tasks: orphaned (no sign of life for over 24 hours) or running.
        var claimed: [(task: TodoTask, claimedAt: Date?)] = []
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + Self.chunkSize, ids.count)])
            index += Self.chunkSize
            let tasks = try await TodoTask.query(on: db).filter(\.$projectID ~~ chunk).filter(\.$status == "in_progress").all()
            let taskIDs = tasks.compactMap(\.id)
            var inner = 0
            var workflows: [UUID: TaskWorkflow] = [:]
            while inner < taskIDs.count {
                for wf in try await TaskWorkflow.query(on: db).filter(\.$id ~~ Array(taskIDs[inner..<min(inner + Self.chunkSize, taskIDs.count)])).all() { workflows[wf.id!] = wf }
                inner += Self.chunkSize
            }
            for task in tasks { if let wf = workflows[task.id!], wf.claimedByID != nil { claimed.append((task, wf.claimedAt)) } }
        }
        let signOfLife = try await ClaimLiveness.lastSignOfLife(
            claims: Dictionary(claimed.map { ($0.task.id!, $0.claimedAt) }, uniquingKeysWith: { first, _ in first }), on: db)
        var orphaned: [(at: Date, item: DailyBriefItem)] = [], running: [(at: Date, item: DailyBriefItem)] = []
        for entry in claimed {
            let id = entry.task.id!, last = signOfLife[id]
            let item = DailyBriefItem(id: id, title: Self.clip(entry.task.title), projectID: entry.task.projectID, kind: "task")
            if ClaimLiveness.isOrphaned(status: "in_progress", hasClaim: true, lastSignOfLife: last, now: now) { orphaned.append((last ?? .distantPast, item)) }
            else { running.append((last ?? .distantPast, item)) }
        }
        orphaned.sort { ($0.at, $0.item.id.uuidString) < ($1.at, $1.item.id.uuidString) }
        running.sort { $0.at != $1.at ? $0.at > $1.at : $0.item.id.uuidString < $1.item.id.uuidString }

        // Stale repository syncs (same rule and order as get_stale_projects, bound projects only).
        let stale = try await ProjectSyncService.entries(scope: scope, on: db, now: now, includeSummary: false)
            .filter { $0.sync.bound && $0.sync.state != "fresh" }
            .sorted { a, b in
                let (x, y) = (a.sync.daysSince ?? Int.max, b.sync.daysSince ?? Int.max)
                return x != y ? x > y : (a.name, a.projectID.uuidString) < (b.name, b.projectID.uuidString)
            }

        // Done since `since` (inclusive), newest first. Tasks carry no completion time; updatedAt is what the
        // command center uses for its done lane as well.
        let done = try await gather(ids, newestFirst: true) { chunk in
            let base = { TodoTask.query(on: db).filter(\.$projectID ~~ chunk).filter(\.$status == "done").filter(\.$updatedAt >= since) }
            let rows = try await base().sort(\.$updatedAt, .descending).sort(\.$id).limit(Self.itemLimit).all()
            return Part(count: try await base().count(), rows: try rows.map {
                Row(at: $0.updatedAt ?? .distantPast, item: DailyBriefItem(id: try $0.requireID(), title: Self.clip($0.title), projectID: $0.projectID, kind: "task"))
            })
        }

        let summary = DailyBriefSummary(waiting: waiting, openQuestions: questions.count, pendingReviews: reviews.count,
            pendingConfirmations: confirmations.count, orphanedClaims: orphaned.count, staleProjects: stale.count,
            running: running.count, done: done.count, decisionsToReview: decisions.count)
        let line = Self.line(for: summary)
        let scopeName = projectID == nil ? "account" : "project"
        guard format == "full" else {
            return DailyBriefResponse(generatedAt: now, since: since, scope: scopeName, projectID: projectID, format: "line", line: line, summary: nil, sections: nil)
        }
        func section(_ key: String, _ title: String, _ count: Int, _ items: [DailyBriefItem]) -> DailyBriefSection {
            let shown = Array(items.prefix(Self.itemLimit))
            return DailyBriefSection(key: key, title: title, count: count, truncated: count > shown.count, items: shown)
        }
        let sections = [
            section("waiting", "Wartet auf dich", waiting, Array(waitingRows)),
            section("decisions", "Entscheidungen zu prüfen", decisions.count, decisions.rows.map(\.item)),
            section("orphaned", "Verwaist", orphaned.count, orphaned.map(\.item)),
            section("stale", "Veraltete Projekte", stale.count,
                    stale.map { DailyBriefItem(id: $0.projectID, title: Self.clip($0.name), projectID: $0.projectID, kind: "project") }),
            section("running", "Läuft", running.count, running.map(\.item)),
            section("done", "Erledigt", done.count, done.rows.map(\.item)),
        ]
        return DailyBriefResponse(generatedAt: now, since: since, scope: scopeName, projectID: projectID, format: "full", line: line,
                                  summary: summary, sections: sections)
    }
}
