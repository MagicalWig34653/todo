import Fluent
import Vapor

struct OverviewNow: Content {
    struct Progress: Content { let note: String; let at: String }
    struct RunningTask: Content {
        let taskID: UUID
        let title: String
        /// Label of the claimant (agent or person), nil when nobody claimed the card.
        let worker: String?
        let lastProgress: Progress?
        /// Seconds since the claim, or since the last change of the card when it is not claimed.
        let ageSeconds: Int
        /// Percent (0-100) of the newest progress note of the card that carried one, nil if none did.
        let percent: Int?
    }
    struct Session: Content {
        let sessionName: String
        let activity: String
        let updatedAt: String
        let ageSeconds: Int
        /// No sign of life for longer than `OverviewNowService.orphanedAfter`.
        let orphaned: Bool
    }
    struct Job: Content { let jobID: UUID; let taskID: UUID; let state: String; let mode: String; let progress: String }
    struct Build: Content {
        /// Id of the build artifact (one screenshot). Unique per entry, unlike `buildID`, which screenshots of one build share.
        let id: UUID
        let taskID: UUID; let buildID: String; let label: String?; let platform: String?; let createdAt: String
        /// The build ID when it looks like a commit hash (7-40 lowercase hex characters), else nil. Not a CI status.
        let commit: String?
        /// building | succeeded | failed; absent when the agent never reported one.
        let status: String?
    }
    struct Open: Content { let id: UUID; let taskID: UUID; let taskTitle: String; let text: String; let createdAt: String }
    struct Event: Content {
        let taskID: UUID; let taskTitle: String; let kind: String; let actorType: String; let createdAt: String
        /// Only for build.added / build.status_changed (from the build artifact); absent otherwise.
        var label: String? = nil; var platform: String? = nil; var status: String? = nil
    }
    struct Entry: Content {
        let projectID: UUID
        let projectName: String
        let lastActivityAt: String
        let runningTasks: [RunningTask]
        let sessions: [Session]
        let agentJobs: [Job]
        let builds: [Build]
        let openQuestions: [Open]
        let pendingReviews: [Open]
        let recentActivity: [Event]
    }

    /// One line of `now.running` / `now.silent`: a card in progress or a session without a card.
    struct NowActive: Content {
        /// `task` | `session`
        let kind: String
        let projectID: UUID
        let projectName: String
        /// Only for kind `task`.
        let taskID: UUID?
        /// Card title (task) or session name (session).
        let title: String
        /// One sentence: newest progress note of the card (one line, 200 characters) or the activity of the session; may be empty.
        let text: String
        let worker: String?
        /// Only for tasks: start of the claim, else the last change of the card.
        let since: String?
        let lastSignAt: String
        let ageSeconds: Int
        /// Only for tasks with a due date (`planning.dueAt`).
        let dueAt: String?
        /// Only for tasks, like `runningTasks[].percent`.
        let percent: Int?
    }
    struct NowWaiting: Content {
        /// `question` | `review`
        let kind: String
        let id: UUID
        let projectID: UUID
        let projectName: String
        let taskID: UUID
        let taskTitle: String
        let text: String
        let createdAt: String
    }
    struct NowDone: Content { let taskID: UUID; let title: String; let projectID: UUID; let projectName: String; let doneAt: String }
    struct NowCounts: Content { let running: Int; let waiting: Int; let recentlyDone: Int; let silent: Int }
    /// "Now" over all readable projects (contract session-status 1.4.0). `counts` are the totals before any cut.
    struct NowBlock: Content {
        let counts: NowCounts
        let running: [NowActive]
        let waiting: [NowWaiting]
        let recentlyDone: [NowDone]
        let silent: [NowActive]
    }

    let serverTime: String
    /// Always set by `OverviewNowService`.
    var now: NowBlock?
    /// Most recently active project first; projects without anything to show are left out. Absent when compact.
    var projects: [Entry]?
}

/// Bundled "what is happening now" over every project the account can read (ADR 0034). Read only; rights are the
/// sharing graph (`ProjectAccess.visibleProjects`), narrowed by the OAuth grant for MCP. Texts are user data.
struct OverviewNowService: Sendable {
    static let orphanedAfter: TimeInterval = 30 * 60
    static let hiddenAfter: TimeInterval = 24 * 3600
    static let activityLimit = 10
    static let buildEventKinds: Set<String> = ["build.added", "build.status_changed"]
    static let buildLimit = 5
    static let activeJobStates = ["queued", "claimed", "running", "waiting_for_answer"]
    /// `now`: a card or session counts as running while its last sign of life is at most this old.
    static let runningWithin: TimeInterval = 30 * 60
    static let doneWithin: TimeInterval = 6 * 3600
    /// Entries per `now` list in the full answer.
    static let fullListLimit = 100
    static let compactDefaultLimit = 10
    static let compactLimitRange = 1...50
    static let compactTextLimit = 140
    static let nowTextLimit = 200
    /// Cards in progress read for `now` (the per-project `runningTasks` keep their limit of 300).
    static let nowCardLimit = 1000

    /// One line of at most `max` characters; longer text ends with an ellipsis.
    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
    /// Sentences such as "Beendet: fertig" mark a closed session; it is neither running nor silent.
    static func isEndedSentence(_ activity: String) -> Bool {
        activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("beendet")
    }

    /// 7-40 lowercase hex characters: abbreviated or full commit hash.
    static func commit(from buildID: String) -> String? {
        (7...40).contains(buildID.utf8.count) && buildID.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) ? buildID : nil
    }

    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil

    /// `compact`: only `serverTime` and `now`, every list cut to `limit` (default 10, 1...50, else 400 `invalid_limit`),
    /// texts shortened to 140 characters. Otherwise the full answer: `projects` as before plus `now` with at most 100 per list.
    func now(compact: Bool = false, limit: Int? = nil) async throws -> OverviewNow {
        if let limit, !Self.compactLimitRange.contains(limit) { throw Abort(.badRequest, reason: "invalid_limit") }
        let cap = compact ? (limit ?? Self.compactDefaultLimit) : Self.fullListLimit
        let clock = Date()
        var projects = try await ProjectAccess(user: user, db: db).visibleProjects()
        if let allowedProjects { projects = projects.filter { allowedProjects.contains($0.id ?? UUID()) } }
        let ids = try projects.map { try $0.requireID() }
        let iso = LiveSessionService.iso
        guard !ids.isEmpty else {
            let empty = OverviewNow.NowBlock(counts: .init(running: 0, waiting: 0, recentlyDone: 0, silent: 0), running: [], waiting: [], recentlyDone: [], silent: [])
            return OverviewNow(serverTime: iso(clock), now: empty, projects: compact ? nil : [])
        }
        var projectNames: [UUID: String] = [:]
        for project in projects { projectNames[try project.requireID()] = project.name }

        // Running cards with worker and last progress note.
        let running = try await TodoTask.query(on: db).filter(\.$projectID ~~ ids).filter(\.$status == "in_progress").sort(\.$updatedAt, .descending).limit(Self.nowCardLimit).all()
        let runningIDs = try running.map { try $0.requireID() }
        let workflows = Dictionary(uniqueKeysWithValues: try await TaskWorkflow.query(on: db).filter(\.$id ~~ runningIDs).all().compactMap { w in w.id.map { ($0, w) } })
        var lastNote: [UUID: TaskProgressNote] = [:]
        for note in try await TaskProgressNote.query(on: db).filter(\.$taskID ~~ runningIDs).sort(\.$createdAt, .descending).limit(2000).all() where lastNote[note.taskID] == nil {
            lastNote[note.taskID] = note
        }
        var lastPercent: [UUID: Int] = [:]
        for note in try await TaskProgressNote.query(on: db).filter(\.$taskID ~~ runningIDs).filter(\.$percent != nil).sort(\.$createdAt, .descending).limit(2000).all() {
            if let percent = note.percent, lastPercent[note.taskID] == nil { lastPercent[note.taskID] = percent }
        }
        var runningByProject: [UUID: [OverviewNow.RunningTask]] = [:]
        var activityAt: [UUID: Date] = [:]
        func touch(_ project: UUID, _ date: Date?) { if let date, date > (activityAt[project] ?? .distantPast) { activityAt[project] = date } }
        for task in running.prefix(300) {
            let id = try task.requireID(), wf = workflows[id], note = lastNote[id]
            let since = wf?.claimedAt ?? task.updatedAt ?? clock
            touch(task.projectID, note?.createdAt ?? task.updatedAt)
            runningByProject[task.projectID, default: []].append(OverviewNow.RunningTask(
                taskID: id, title: task.title, worker: wf?.claimedLabel ?? wf?.claimedByType,
                lastProgress: note.flatMap { n in n.createdAt.map { OverviewNow.Progress(note: n.note, at: iso($0)) } },
                ageSeconds: max(0, Int(clock.timeIntervalSince(since))), percent: lastPercent[id]))
        }

        // `now`: the sign of life of a card is the one `list_tasks orphaned` uses (claim, progress note, comment, activity,
        // runner event) plus the live view of the card. A card in progress without any sign is silent.
        var nowRunning: [(Date, OverviewNow.NowActive)] = [], nowSilent: [(Date, OverviewNow.NowActive)] = []
        func isRunning(_ last: Date) -> Bool { Double(max(0, Int(clock.timeIntervalSince(last)))) <= Self.runningWithin }
        var claims: [UUID: Date?] = [:]
        for id in runningIDs { claims[id] = workflows[id]?.claimedAt }
        var signOfLife = try await ClaimLiveness.lastSignOfLife(claims: claims, on: db)
        for live in try await TaskLiveSession.query(on: db).filter(\.$taskID ~~ runningIDs).all() where live.lastSeenAt > (signOfLife[live.taskID] ?? .distantPast) {
            signOfLife[live.taskID] = live.lastSeenAt
        }
        let planning = Dictionary(uniqueKeysWithValues: try await TaskPlanning.query(on: db).filter(\.$id ~~ runningIDs).all().compactMap { p in p.id.map { ($0, p) } })
        for task in running {
            let id = try task.requireID(), wf = workflows[id]
            let since = wf?.claimedAt ?? task.updatedAt ?? clock
            let sign = signOfLife[id], last = sign ?? since
            let row = OverviewNow.NowActive(
                kind: "task", projectID: task.projectID, projectName: projectNames[task.projectID] ?? "", taskID: id, title: task.title,
                text: Self.oneLine(lastNote[id]?.note ?? "", max: Self.nowTextLimit), worker: wf?.claimedLabel ?? wf?.claimedByType,
                since: iso(since), lastSignAt: iso(last), ageSeconds: max(0, Int(clock.timeIntervalSince(last))),
                dueAt: planning[id]?.dueAt.map(iso), percent: lastPercent[id])
            if sign != nil, isRunning(last) { nowRunning.append((last, row)) } else { nowSilent.append((last, row)) }
        }

        // Heartbeats: orphaned after 30 minutes, hidden after 24 hours.
        var sessionsByProject: [UUID: [OverviewNow.Session]] = [:]
        let visibleSince = clock.addingTimeInterval(-Self.hiddenAfter)
        for s in try await SessionStatus.query(on: db).filter(\.$projectID ~~ ids).filter(\.$updatedAt > visibleSince).sort(\.$updatedAt, .descending).limit(500).all() {
            touch(s.projectID, s.updatedAt)
            let age = max(0, Int(clock.timeIntervalSince(s.updatedAt)))
            sessionsByProject[s.projectID, default: []].append(OverviewNow.Session(
                sessionName: s.sessionName, activity: s.activity, updatedAt: iso(s.updatedAt), ageSeconds: age, orphaned: Double(age) > Self.orphanedAfter))
            guard !Self.isEndedSentence(s.activity) else { continue }
            let row = OverviewNow.NowActive(
                kind: "session", projectID: s.projectID, projectName: projectNames[s.projectID] ?? "", taskID: nil, title: s.sessionName,
                text: Self.oneLine(s.activity, max: Self.nowTextLimit), worker: nil, since: nil, lastSignAt: iso(s.updatedAt), ageSeconds: age, dueAt: nil, percent: nil)
            if isRunning(s.updatedAt) { nowRunning.append((s.updatedAt, row)) } else { nowSilent.append((s.updatedAt, row)) }
        }

        var jobsByProject: [UUID: [OverviewNow.Job]] = [:]
        if !compact {
            for job in try await AgentJob.query(on: db).filter(\.$projectID ~~ ids).filter(\.$state ~~ Self.activeJobStates).limit(300).all() {
                jobsByProject[job.projectID, default: []].append(OverviewNow.Job(
                    jobID: try job.requireID(), taskID: job.taskID, state: job.state, mode: job.mode, progress: String(job.progress.prefix(200))))
            }
        }

        var waiting: [(Date, OverviewNow.NowWaiting)] = []
        var questionsByProject: [UUID: [OverviewNow.Open]] = [:]
        for q in try await TaskQuestion.query(on: db).join(TodoTask.self, on: \TaskQuestion.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids).filter(\.$state == "open").sort(\.$createdAt, .descending).limit(200).all() {
            let task = try q.joined(TodoTask.self)
            touch(task.projectID, q.createdAt)
            questionsByProject[task.projectID, default: []].append(OverviewNow.Open(
                id: try q.requireID(), taskID: q.taskID, taskTitle: task.title, text: String(q.prompt.prefix(200)), createdAt: iso(q.createdAt ?? clock)))
            waiting.append((q.createdAt ?? clock, OverviewNow.NowWaiting(
                kind: "question", id: try q.requireID(), projectID: task.projectID, projectName: projectNames[task.projectID] ?? "", taskID: q.taskID,
                taskTitle: task.title, text: Self.oneLine(q.prompt, max: Self.nowTextLimit), createdAt: iso(q.createdAt ?? clock))))
        }
        var reviewsByProject: [UUID: [OverviewNow.Open]] = [:]
        for r in try await TaskReview.query(on: db).join(TodoTask.self, on: \TaskReview.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids).filter(\.$state == "pending").sort(\.$createdAt, .descending).limit(200).all() {
            let task = try r.joined(TodoTask.self)
            touch(task.projectID, r.createdAt)
            reviewsByProject[task.projectID, default: []].append(OverviewNow.Open(
                id: try r.requireID(), taskID: r.taskID, taskTitle: task.title, text: String(r.summary.prefix(200)), createdAt: iso(r.createdAt ?? clock)))
            waiting.append((r.createdAt ?? clock, OverviewNow.NowWaiting(
                kind: "review", id: try r.requireID(), projectID: task.projectID, projectName: projectNames[task.projectID] ?? "", taskID: r.taskID,
                taskTitle: task.title, text: Self.oneLine(r.summary, max: Self.nowTextLimit), createdAt: iso(r.createdAt ?? clock))))
        }
        // The lists above stop at 200 each; the totals for `counts` come from their own queries.
        let questionTotal = try await TaskQuestion.query(on: db).join(TodoTask.self, on: \TaskQuestion.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids).filter(\.$state == "open").count()
        let reviewTotal = try await TaskReview.query(on: db).join(TodoTask.self, on: \TaskReview.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids).filter(\.$state == "pending").count()

        // Done cards: the card's `updated_at` is the time it was last changed. For a done card that is the time it was
        // finished unless someone edited it afterwards (the command center's done lane uses the same source).
        let doneSince = clock.addingTimeInterval(-Self.doneWithin)
        func doneQuery() -> QueryBuilder<TodoTask> {
            TodoTask.query(on: db).filter(\.$projectID ~~ ids).filter(\.$status == "done").filter(\.$updatedAt >= doneSince)
        }
        let doneTotal = try await doneQuery().count()
        let doneRows = try await doneQuery().sort(\.$updatedAt, .descending).sort(\.$id).limit(cap).all()

        let clip: (String) -> String = { compact ? Self.oneLine($0, max: Self.compactTextLimit) : $0 }
        func ordered(_ rows: [(Date, OverviewNow.NowActive)]) -> [OverviewNow.NowActive] {
            rows.sorted { ($0.0, $0.1.title) > ($1.0, $1.1.title) }.prefix(cap).map { _, a in
                OverviewNow.NowActive(kind: a.kind, projectID: a.projectID, projectName: clip(a.projectName), taskID: a.taskID, title: clip(a.title), text: clip(a.text),
                    worker: a.worker, since: a.since, lastSignAt: a.lastSignAt, ageSeconds: a.ageSeconds, dueAt: a.dueAt, percent: a.percent)
            }
        }
        let block = OverviewNow.NowBlock(
            counts: .init(running: nowRunning.count, waiting: questionTotal + reviewTotal, recentlyDone: doneTotal, silent: nowSilent.count),
            running: ordered(nowRunning),
            waiting: waiting.sorted { ($0.0, $0.1.id.uuidString) > ($1.0, $1.1.id.uuidString) }.prefix(cap).map { _, w in
                OverviewNow.NowWaiting(kind: w.kind, id: w.id, projectID: w.projectID, projectName: clip(w.projectName), taskID: w.taskID,
                    taskTitle: clip(w.taskTitle), text: clip(w.text), createdAt: w.createdAt)
            },
            recentlyDone: try doneRows.map { t in
                OverviewNow.NowDone(taskID: try t.requireID(), title: clip(t.title), projectID: t.projectID,
                    projectName: clip(projectNames[t.projectID] ?? ""), doneAt: iso(t.updatedAt ?? clock))
            },
            silent: ordered(nowSilent))
        if compact { return OverviewNow(serverTime: iso(clock), now: block, projects: nil) }

        // Builds and the activity feed are limited per project, so a busy project cannot push out the others.
        var entries: [(Date, OverviewNow.Entry)] = []
        for project in projects {
            let pid = try project.requireID()
            let builds = try await BuildArtifact.query(on: db).join(TodoTask.self, on: \BuildArtifact.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID == pid).sort(\.$createdAt, .descending).limit(Self.buildLimit).all()
            let events = try await ActivityEvent.query(on: db).join(TodoTask.self, on: \ActivityEvent.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID == pid).sort(\.$createdAt, .descending).limit(Self.activityLimit).all()
            let eventBuilds = Dictionary(uniqueKeysWithValues: try await BuildArtifact.query(on: db)
                .filter(\.$id ~~ events.filter { Self.buildEventKinds.contains($0.kind) }.compactMap(\.subjectID)).all().compactMap { b in b.id.map { ($0, b) } })
            for b in builds { touch(pid, b.createdAt) }
            for e in events { touch(pid, e.createdAt) }
            let runningTasks = runningByProject[pid] ?? [], sessions = sessionsByProject[pid] ?? [], jobs = jobsByProject[pid] ?? []
            let questions = questionsByProject[pid] ?? [], reviews = reviewsByProject[pid] ?? []
            guard !(runningTasks.isEmpty && sessions.isEmpty && jobs.isEmpty && builds.isEmpty && questions.isEmpty && reviews.isEmpty && events.isEmpty) else { continue }
            let last = activityAt[pid] ?? .distantPast
            entries.append((last, OverviewNow.Entry(
                projectID: pid, projectName: project.name, lastActivityAt: iso(last == .distantPast ? clock : last),
                runningTasks: runningTasks, sessions: sessions, agentJobs: jobs,
                builds: try builds.map { OverviewNow.Build(id: try $0.requireID(), taskID: $0.taskID, buildID: $0.buildID, label: $0.label, platform: $0.platform, createdAt: iso($0.createdAt ?? clock), commit: $0.commit ?? Self.commit(from: $0.buildID), status: $0.status) },
                openQuestions: questions, pendingReviews: reviews,
                recentActivity: try events.map { e in
                    let b = Self.buildEventKinds.contains(e.kind) ? e.subjectID.flatMap { eventBuilds[$0] } : nil
                    return OverviewNow.Event(taskID: e.taskID, taskTitle: try e.joined(TodoTask.self).title, kind: e.kind, actorType: "\(e.actorType)", createdAt: iso(e.createdAt ?? clock),
                        label: b?.label, platform: b?.platform, status: b?.status)
                })))
        }
        return OverviewNow(serverTime: iso(clock), now: block, projects: entries.sorted { $0.0 > $1.0 }.map(\.1))
    }
}
