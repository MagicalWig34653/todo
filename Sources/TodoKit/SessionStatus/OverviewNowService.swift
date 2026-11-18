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
    struct Build: Content { let taskID: UUID; let buildID: String; let label: String?; let platform: String?; let createdAt: String
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
    let serverTime: String
    /// Most recently active project first; projects without anything to show are left out.
    let projects: [Entry]
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

    /// 7-40 lowercase hex characters: abbreviated or full commit hash.
    static func commit(from buildID: String) -> String? {
        (7...40).contains(buildID.utf8.count) && buildID.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) ? buildID : nil
    }

    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil

    func now() async throws -> OverviewNow {
        let clock = Date()
        var projects = try await ProjectAccess(user: user, db: db).visibleProjects()
        if let allowedProjects { projects = projects.filter { allowedProjects.contains($0.id ?? UUID()) } }
        let ids = try projects.map { try $0.requireID() }
        guard !ids.isEmpty else { return OverviewNow(serverTime: LiveSessionService.iso(clock), projects: []) }
        let iso = LiveSessionService.iso

        // Running cards with worker and last progress note.
        let running = try await TodoTask.query(on: db).filter(\.$projectID ~~ ids).filter(\.$status == "in_progress").sort(\.$updatedAt, .descending).limit(300).all()
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
        for task in running {
            let id = try task.requireID(), wf = workflows[id], note = lastNote[id]
            let since = wf?.claimedAt ?? task.updatedAt ?? clock
            touch(task.projectID, note?.createdAt ?? task.updatedAt)
            runningByProject[task.projectID, default: []].append(OverviewNow.RunningTask(
                taskID: id, title: task.title, worker: wf?.claimedLabel ?? wf?.claimedByType,
                lastProgress: note.flatMap { n in n.createdAt.map { OverviewNow.Progress(note: n.note, at: iso($0)) } },
                ageSeconds: max(0, Int(clock.timeIntervalSince(since))), percent: lastPercent[id]))
        }

        // Heartbeats: orphaned after 30 minutes, hidden after 24 hours.
        var sessionsByProject: [UUID: [OverviewNow.Session]] = [:]
        let visibleSince = clock.addingTimeInterval(-Self.hiddenAfter)
        for s in try await SessionStatus.query(on: db).filter(\.$projectID ~~ ids).filter(\.$updatedAt > visibleSince).sort(\.$updatedAt, .descending).limit(500).all() {
            touch(s.projectID, s.updatedAt)
            let age = max(0, Int(clock.timeIntervalSince(s.updatedAt)))
            sessionsByProject[s.projectID, default: []].append(OverviewNow.Session(
                sessionName: s.sessionName, activity: s.activity, updatedAt: iso(s.updatedAt), ageSeconds: age, orphaned: Double(age) > Self.orphanedAfter))
        }

        var jobsByProject: [UUID: [OverviewNow.Job]] = [:]
        for job in try await AgentJob.query(on: db).filter(\.$projectID ~~ ids).filter(\.$state ~~ Self.activeJobStates).limit(300).all() {
            jobsByProject[job.projectID, default: []].append(OverviewNow.Job(
                jobID: try job.requireID(), taskID: job.taskID, state: job.state, mode: job.mode, progress: String(job.progress.prefix(200))))
        }

        var questionsByProject: [UUID: [OverviewNow.Open]] = [:]
        for q in try await TaskQuestion.query(on: db).join(TodoTask.self, on: \TaskQuestion.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids).filter(\.$state == "open").sort(\.$createdAt, .descending).limit(200).all() {
            let task = try q.joined(TodoTask.self)
            touch(task.projectID, q.createdAt)
            questionsByProject[task.projectID, default: []].append(OverviewNow.Open(
                id: try q.requireID(), taskID: q.taskID, taskTitle: task.title, text: String(q.prompt.prefix(200)), createdAt: iso(q.createdAt ?? clock)))
        }
        var reviewsByProject: [UUID: [OverviewNow.Open]] = [:]
        for r in try await TaskReview.query(on: db).join(TodoTask.self, on: \TaskReview.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids).filter(\.$state == "pending").sort(\.$createdAt, .descending).limit(200).all() {
            let task = try r.joined(TodoTask.self)
            touch(task.projectID, r.createdAt)
            reviewsByProject[task.projectID, default: []].append(OverviewNow.Open(
                id: try r.requireID(), taskID: r.taskID, taskTitle: task.title, text: String(r.summary.prefix(200)), createdAt: iso(r.createdAt ?? clock)))
        }

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
                builds: try builds.map { OverviewNow.Build(taskID: $0.taskID, buildID: $0.buildID, label: $0.label, platform: $0.platform, createdAt: iso($0.createdAt ?? clock), commit: $0.commit ?? Self.commit(from: $0.buildID), status: $0.status) },
                openQuestions: questions, pendingReviews: reviews,
                recentActivity: try events.map { e in
                    let b = Self.buildEventKinds.contains(e.kind) ? e.subjectID.flatMap { eventBuilds[$0] } : nil
                    return OverviewNow.Event(taskID: e.taskID, taskTitle: try e.joined(TodoTask.self).title, kind: e.kind, actorType: "\(e.actorType)", createdAt: iso(e.createdAt ?? clock),
                        label: b?.label, platform: b?.platform, status: b?.status)
                })))
        }
        return OverviewNow(serverTime: iso(clock), projects: entries.sorted { $0.0 > $1.0 }.map(\.1))
    }
}
