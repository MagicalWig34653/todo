import Fluent
import Vapor

// MARK: - Scope

/// Projects an aggregate may look at: visible to the user, inside the OAuth grant (if any), optionally narrowed to
/// one project and its visible sub-projects.
struct CommandCenterScope: Sendable {
    let projects: [UUID: Project]
    var projectIDs: [UUID] { Array(projects.keys) }

    static func resolve(user: User, db: any Database, projectID: UUID?, includeSubprojects: Bool, allowed: Set<UUID>?) async throws -> CommandCenterScope {
        var visible = try await ProjectAccess(user: user, db: db).visibleProjects()
        if let allowed { visible = visible.filter { allowed.contains($0.id ?? UUID()) } }
        let byID = Dictionary(uniqueKeysWithValues: try visible.map { (try $0.requireID(), $0) })
        guard let projectID else { return CommandCenterScope(projects: byID) }
        guard byID[projectID] != nil else { throw Abort(.notFound) }
        guard includeSubprojects else { return CommandCenterScope(projects: [projectID: byID[projectID]!]) }
        var included: Set<UUID> = [projectID]
        var changed = true
        while changed {
            changed = false
            for (id, project) in byID where !included.contains(id) {
                if let parent = project.parentID, included.contains(parent) { included.insert(id); changed = true }
            }
        }
        return CommandCenterScope(projects: byID.filter { included.contains($0.key) })
    }
}

// MARK: - DTOs

struct LaneInfo {
    static let order: [(key: String, title: String)] = [
        ("running", "Läuft"), ("question", "Frage offen"), ("review", "Review fällig"),
        ("ready", "Bereit"), ("blocked", "Blockiert"), ("done", "Erledigt kürzlich"),
    ]
    static let keys = Set(order.map(\.key))
}

struct QuestionBrief: Content {
    let id: UUID
    let prompt: String
    let options: [String]
    let blocking: Bool
    let askedByType: ActivityActorType
    let askedByLabel: String?
    let createdAt: Date?
}

struct ReviewBrief: Content {
    let id: UUID
    let summary: String
    let requestedByType: ActivityActorType
    let requestedByLabel: String?
    let reviewerID: UUID?
    let agentJobID: UUID?
    let createdAt: Date?
}

struct CardTask: Content {
    let id: UUID
    let title: String
    let status: String
    let version: Int
    let columnID: UUID?
    let columnName: String?
    let createdAt: Date?
    let updatedAt: Date?
}

struct CardProject: Content {
    let id: UUID
    let name: String
    let color: String?
    let parentID: UUID?
}

struct CardAgent: Content {
    let claimedLabel: String?
    let claimedAt: Date?
    let jobID: UUID?
    let jobState: String?
    let jobProgress: String?
    let runID: UUID?
    let checkpointNextStep: String?
}

struct CardUpdate: Content {
    /// `note` | `checkpoint` | `job_progress`
    let kind: String
    let text: String
    let at: Date?
    let actorLabel: String?
}

struct SubtaskBrief: Content {
    let id: UUID
    let title: String
    let status: String
    let lane: String
    let progressPercent: Int
}

struct CommandCard: Content {
    let task: CardTask
    let project: CardProject
    let kind: String
    let isFeature: Bool
    let parentTaskID: UUID?
    let lane: String
    let progress: ProgressDTO
    let agent: CardAgent?
    let openQuestionCount: Int
    let questions: [QuestionBrief]
    let pendingReview: ReviewBrief?
    let blockedReason: String?
    let blockedBy: [UUID]
    let latestUpdate: CardUpdate?
    let builds: [BuildArtifactDTO]
    let buildCount: Int
    let nextDue: Date?
    let priority: Int
    let subtasks: [SubtaskBrief]
}

struct LaneDTO: Content {
    let key: String
    let title: String
    /// Total cards in the lane before `laneLimit` truncation.
    let count: Int
    let truncated: Bool
    let cards: [CommandCard]
}

struct SummaryDTO: Content {
    let running: Int
    let question: Int
    let review: Int
    let ready: Int
    let blocked: Int
    let done: Int
    let backlog: Int
    let openQuestions: Int
    let pendingReviews: Int
    let features: Int
    let activeAgents: Int
}

struct UpdateItem: Content {
    let id: UUID
    let taskID: UUID
    let taskTitle: String
    let projectID: UUID
    let projectName: String
    let kind: String
    let actorType: ActivityActorType
    let actorID: UUID
    var actorName: String?
    let subjectID: UUID?
    /// Resolved note / question / answer / review summary / build label; absent for plain state changes.
    var text: String?
    let createdAt: Date?
}

struct BuildGroup: Content {
    let buildID: String
    let label: String?
    let platform: String?
    let taskIDs: [UUID]
    let createdAt: Date?
    let items: [BuildArtifactDTO]
}

struct CommandCenterResponse: Content {
    let generatedAt: Date
    let scope: String
    let projectID: UUID?
    let view: String
    let summary: SummaryDTO
    /// Kanban view only.
    let lanes: [LaneDTO]?
    /// List view only: flat, filtered, sorted, paged.
    let items: [CommandCard]?
    let total: Int?
    let updates: [UpdateItem]
    let builds: [BuildGroup]
}

struct CommandCenterQuery: Sendable {
    var projectID: UUID?
    var includeSubprojects = true
    var view = "kanban"
    var doneWithinDays = 7
    var laneLimit = 50
    var updatesLimit = 20
    var lanes: Set<String>? = nil
    var kind: String? = nil
    var hasQuestion: Bool? = nil
    var includeSubtasks = false
    var sort = "attention"
    var limit = 50
    var offset = 0

    init(projectID: UUID? = nil) { self.projectID = projectID }

    /// Parses query-string style values; `scope=project` requires a project.
    init(scope: String?, projectID: String?, raw: [String: String]) throws {
        let scope = scope ?? (projectID == nil ? "account" : "project")
        guard ["account", "project"].contains(scope) else { throw Abort(.badRequest, reason: "invalid_scope") }
        if let projectID {
            guard let id = UUID(uuidString: projectID) else { throw Abort(.badRequest, reason: "invalid_project") }
            self.projectID = id
        }
        if scope == "project", self.projectID == nil { throw Abort(.badRequest, reason: "project_required") }
        if scope == "account", self.projectID != nil { throw Abort(.badRequest, reason: "invalid_scope") }
        func bool(_ key: String) throws -> Bool? {
            guard let v = raw[key] else { return nil }
            guard v == "true" || v == "false" else { throw Abort(.badRequest, reason: "invalid_\(key)") }
            return v == "true"
        }
        func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let v = raw[key] else { return nil }
            guard let n = Int(v), range.contains(n) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
            return n
        }
        includeSubprojects = try bool("includeSubprojects") ?? true
        if let view = raw["view"] { guard ["kanban", "list"].contains(view) else { throw Abort(.badRequest, reason: "invalid_view") }; self.view = view }
        doneWithinDays = try int("doneWithinDays", 1...365) ?? 7
        laneLimit = try int("laneLimit", 1...200) ?? 50
        updatesLimit = try int("updatesLimit", 0...50) ?? 20
        limit = try int("limit", 1...200) ?? 50
        offset = try int("offset", 0...1_000_000) ?? 0
        includeSubtasks = try bool("includeSubtasks") ?? false
        hasQuestion = try bool("hasQuestion")
        if let lane = raw["lane"] {
            let set = Set(lane.split(separator: ",").map(String.init))
            guard !set.isEmpty, set.isSubset(of: LaneInfo.keys) else { throw Abort(.badRequest, reason: "invalid_lane") }
            lanes = set
        }
        if let kind = raw["kind"] { guard ["task", "feature"].contains(kind) else { throw Abort(.badRequest, reason: "invalid_kind") }; self.kind = kind }
        if let sort = raw["sort"] { guard ["attention", "updated", "due", "progress", "title"].contains(sort) else { throw Abort(.badRequest, reason: "invalid_sort") }; self.sort = sort }
    }
}

// MARK: - Service

struct CommandCenterService: Sendable {
    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil

    static let updateKinds = [
        "progress.posted", "question.asked", "question.answered", "question.withdrawn", "review.requested",
        "review.accepted", "review.changes_requested", "build.added", "task.claimed", "task.released", "task.blocked",
        "agent.released", "agent.claimed", "agent.question", "agent.answered", "agent.resume", "agent.submit",
        "agent.stop", "agent.fail", "agent.accept", "agent.request_changes",
    ]

    private static let urgency = ["question": 0, "review": 1, "running": 2, "blocked": 3, "ready": 4]

    /// Runs `fetch` over id chunks (keeps IN lists below database limits).
    private func batched<M>(_ ids: [UUID], _ fetch: ([UUID]) async throws -> [M]) async throws -> [M] {
        var result: [M] = []
        var index = 0
        while index < ids.count {
            let end = min(index + 400, ids.count)
            result += try await fetch(Array(ids[index..<end]))
            index = end
        }
        return result
    }

    private struct TaskState {
        var lane: String
        var role: ColumnRole?
        var questions: [TaskQuestion] = []
        var review: TaskReview?
        var blockedBy: [UUID] = []
        var wf: TaskWorkflow?
        var latestNote: TaskProgressNote?
        var criteria: [AcceptanceCriterion] = []
    }

    func build(_ q: CommandCenterQuery) async throws -> CommandCenterResponse {
        let now = Date()
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: q.projectID,
            includeSubprojects: q.includeSubprojects, allowed: allowedProjects)
        let projectIDs = scope.projectIDs
        let cutoff = now.addingTimeInterval(-Double(q.doneWithinDays) * 86_400)

        // Tasks: everything not done, plus recently finished ones.
        var loaded: [TodoTask] = projectIDs.isEmpty ? [] : try await TodoTask.query(on: db).filter(\.$projectID ~~ projectIDs)
            .group(.or) { or in
                or.filter(\.$status != "done")
                or.filter(\.$updatedAt >= cutoff)
            }.all()
        var workflows: [UUID: TaskWorkflow] = [:]
        for wf in try await batched(loaded.map { $0.id! }, { try await TaskWorkflow.query(on: db).filter(\.$id ~~ $0).all() }) {
            workflows[wf.id!] = wf
        }
        // Parents of loaded subtasks must be present even if they finished long ago.
        let missingParents = Set(workflows.values.compactMap(\.parentTaskID)).subtracting(loaded.map { $0.id! })
        if !missingParents.isEmpty {
            let parents = try await batched(Array(missingParents), { try await TodoTask.query(on: db).filter(\.$id ~~ $0).filter(\.$projectID ~~ projectIDs).all() })
            loaded += parents
            for wf in try await batched(parents.map { $0.id! }, { try await TaskWorkflow.query(on: db).filter(\.$id ~~ $0).all() }) { workflows[wf.id!] = wf }
        }
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id!, $0) })
        // All children of loaded features (including long finished ones) for progress.
        var childrenOf: [UUID: [TodoTask]] = [:]
        let linked = try await batched(Array(byID.keys), { try await TaskWorkflow.query(on: db).filter(\.$parentTaskID ~~ $0).all() })
        let childIDs = linked.compactMap(\.id)
        let childTasks = try await batched(childIDs, { try await TodoTask.query(on: db).filter(\.$id ~~ $0).all() })
        for wf in linked { workflows[wf.id!] = workflows[wf.id!] ?? wf }
        for child in childTasks { if let parent = workflows[child.id!]?.parentTaskID { childrenOf[parent, default: []].append(child) } }
        for key in childrenOf.keys { childrenOf[key]!.sort { ($0.createdAt ?? .distantPast, $0.id!.uuidString) < ($1.createdAt ?? .distantPast, $1.id!.uuidString) } }
        let allTaskIDs = Array(Set(byID.keys).union(childIDs))

        let questions = try await batched(allTaskIDs, { try await TaskQuestion.query(on: db).filter(\.$taskID ~~ $0).filter(\.$state == "open").sort(\.$createdAt).all() })
        let reviews = try await batched(allTaskIDs, { try await TaskReview.query(on: db).filter(\.$taskID ~~ $0).filter(\.$state == "pending").sort(\.$createdAt).all() })
        let noteCutoff = now.addingTimeInterval(-30 * 86_400)
        let notes = try await batched(allTaskIDs, { try await TaskProgressNote.query(on: db).filter(\.$taskID ~~ $0).filter(\.$createdAt >= noteCutoff)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).all() })
        let criteria = try await batched(Array(byID.keys), { try await AcceptanceCriterion.query(on: db).filter(\.$taskID ~~ $0).all() })
        let planning = Dictionary(uniqueKeysWithValues: try await batched(Array(byID.keys), { try await TaskPlanning.query(on: db).filter(\.$id ~~ $0).all() }).map { ($0.id!, $0) })
        let deps = try await batched(Array(byID.keys), { try await PlanningDependency.query(on: db).filter(\.$taskID ~~ $0).all() })
        let prerequisiteStatus = Dictionary(uniqueKeysWithValues: try await batched(Array(Set(deps.map(\.prerequisiteID))),
            { try await TodoTask.query(on: db).filter(\.$id ~~ $0).all() }).map { ($0.id!, $0.status) })
        let columns = projectIDs.isEmpty ? [] : try await ProjectColumn.query(on: db).filter(\.$projectID ~~ projectIDs).all()
        let columnByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id!, $0) })
        let builds = try await WorkflowService.builds(of: allTaskIDs, on: db)

        // Runner jobs: visible to the project owner only (like GET /v1/agents/jobs/:id).
        let ownedProjects = scope.projects.filter { $0.value.ownerID == user.id }.map(\.key)
        var activeJob: [UUID: AgentJob] = [:]
        var activeRun: [UUID: AgentRun] = [:]
        var checkpoint: [UUID: AgentCheckpoint] = [:]
        if !ownedProjects.isEmpty {
            let active = ["queued", "claimed", "running", "waiting_for_answer", "awaiting_review"]
            let jobs = try await batched(Array(byID.keys), { try await AgentJob.query(on: db).filter(\.$taskID ~~ $0).filter(\.$projectID ~~ ownedProjects).filter(\.$state ~~ active).all() })
            for job in jobs { activeJob[job.taskID] = job }
            let runs = try await batched(jobs.map { $0.id! }, { try await AgentRun.query(on: db).filter(\.$jobID ~~ $0).filter(\.$endedAt == .null).all() })
            for run in runs { activeRun[run.jobID] = run }
            for cp in try await batched(runs.map { $0.id! }, { try await AgentCheckpoint.query(on: db).filter(\.$runID ~~ $0).all() }) { checkpoint[cp.runID] = cp }
        }

        // Per-task state.
        var states: [UUID: TaskState] = [:]
        for task in loaded + childTasks.filter({ byID[$0.id!] == nil }) {
            let id = task.id!
            let role = task.columnID.flatMap { columnByID[$0] }.flatMap(ColumnRole.of)
            states[id] = TaskState(lane: "ready", role: role, wf: workflows[id])
        }
        for q in questions { states[q.taskID]?.questions.append(q) }
        for r in reviews where states[r.taskID]?.review == nil { states[r.taskID]?.review = r }
        for n in notes where states[n.taskID]?.latestNote == nil { states[n.taskID]?.latestNote = n }
        for c in criteria { states[c.taskID]?.criteria.append(c) }
        for dep in deps where (prerequisiteStatus[dep.prerequisiteID] ?? "done") != "done" { states[dep.taskID]?.blockedBy.append(dep.prerequisiteID) }
        func ownLane(_ task: TodoTask, _ s: TaskState) -> String {
            let id = task.id!
            if task.status == "done" { return "done" }
            if !s.questions.isEmpty { return "question" }
            if s.review != nil || task.status == "in_review" || s.role == .review { return "review" }
            if s.wf?.blockedReason != nil || !s.blockedBy.isEmpty { return "blocked" }
            if task.status == "in_progress" || s.wf?.claimedByID != nil || activeRun[activeJob[id]?.id ?? UUID()] != nil || s.role == .working { return "running" }
            if s.role == .backlog { return "backlog" }
            return "ready"
        }
        for task in loaded + childTasks.filter({ byID[$0.id!] == nil }) { states[task.id!]!.lane = ownLane(task, states[task.id!]!) }

        // Cards for top-level tasks (no parent); subtasks nested.
        var progressByTask: [UUID: ProgressDTO] = [:]
        func progress(_ task: TodoTask) -> ProgressDTO {
            let id = task.id!
            if let p = progressByTask[id] { return p }
            let s = states[id]
            let p = ProgressCalc.compute(task: task, children: childrenOf[id] ?? [], criteria: s?.criteria ?? [], latestPercent: s?.latestNote?.percent)
            progressByTask[id] = p; return p
        }
        func effectiveLane(_ task: TodoTask) -> String {
            let id = task.id!, own = states[id]!.lane
            guard let kids = childrenOf[id], !kids.isEmpty, own != "done" else { return own }
            let candidates = ([own] + kids.filter { $0.status != "done" }.map { states[$0.id!]?.lane ?? "ready" }).filter { $0 != "backlog" && $0 != "done" }
            if let best = candidates.min(by: { (Self.urgency[$0] ?? 9) < (Self.urgency[$1] ?? 9) }) { return best }
            return own == "backlog" ? (kids.allSatisfy { $0.status == "done" } ? "ready" : "backlog") : own
        }
        func card(_ task: TodoTask, lane: String) throws -> CommandCard {
            let id = task.id!, s = states[id]!
            let project = scope.projects[task.projectID]!
            let kids = childrenOf[id] ?? []
            let kidStates = kids.compactMap { states[$0.id!] }
            let allQuestions = (s.questions + kidStates.flatMap(\.questions)).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            let review = s.review ?? kidStates.compactMap(\.review).first
            let ownBuilds = (builds[id] ?? []) + kids.flatMap { builds[$0.id!] ?? [] }
            let sortedBuilds = ownBuilds.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            var agent: CardAgent?
            let job = activeJob[id]
            let run = job.flatMap { activeRun[$0.id!] }
            if s.wf?.claimedByID != nil || job != nil {
                agent = CardAgent(claimedLabel: s.wf?.claimedLabel, claimedAt: s.wf?.claimedAt, jobID: job?.id, jobState: job?.state,
                    jobProgress: job.flatMap { $0.progress.isEmpty ? nil : $0.progress }, runID: run?.id,
                    checkpointNextStep: run.flatMap { checkpoint[$0.id!]?.nextStep })
            }
            var update: CardUpdate?
            if let step = agent?.checkpointNextStep { update = CardUpdate(kind: "checkpoint", text: step, at: nil, actorLabel: s.wf?.claimedLabel) }
            else if let p = agent?.jobProgress { update = CardUpdate(kind: "job_progress", text: p, at: nil, actorLabel: s.wf?.claimedLabel) }
            else if let n = s.latestNote ?? kidStates.compactMap(\.latestNote).max(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                update = CardUpdate(kind: "note", text: n.note, at: n.createdAt, actorLabel: n.actorLabel)
            }
            let column = task.columnID.flatMap { columnByID[$0] }
            let due = planning[id]?.dueAt
            let kidDue = kids.compactMap { planning[$0.id!]?.dueAt }
            let kind = (s.wf?.kind == "feature" || !kids.isEmpty) ? "feature" : "task"
            return CommandCard(
                task: CardTask(id: id, title: task.title, status: task.status, version: task.version, columnID: task.columnID,
                    columnName: column?.name, createdAt: task.createdAt, updatedAt: task.updatedAt),
                project: CardProject(id: task.projectID, name: project.name, color: project.color, parentID: project.parentID),
                kind: kind, isFeature: kind == "feature", parentTaskID: s.wf?.parentTaskID, lane: lane, progress: progress(task), agent: agent,
                openQuestionCount: allQuestions.count,
                questions: try allQuestions.prefix(3).map { QuestionBrief(id: try $0.requireID(), prompt: $0.prompt, options: $0.options,
                    blocking: $0.blocking, askedByType: $0.askedByType, askedByLabel: $0.askedByLabel, createdAt: $0.createdAt) },
                pendingReview: try review.map { ReviewBrief(id: try $0.requireID(), summary: $0.summary, requestedByType: $0.requestedByType,
                    requestedByLabel: $0.requestedByLabel, reviewerID: $0.reviewerID, agentJobID: $0.agentJobID, createdAt: $0.createdAt) },
                blockedReason: s.wf?.blockedReason, blockedBy: s.blockedBy, latestUpdate: update,
                builds: Array(sortedBuilds.prefix(3)), buildCount: sortedBuilds.count,
                nextDue: ([due].compactMap { $0 } + kidDue).min(), priority: planning[id]?.priority ?? 0,
                subtasks: kids.map { SubtaskBrief(id: $0.id!, title: $0.title, status: $0.status, lane: states[$0.id!]?.lane ?? "ready", progressPercent: progress($0).percent) })
        }

        let tops = loaded.filter { workflows[$0.id!]?.parentTaskID == nil || byID[workflows[$0.id!]!.parentTaskID!] == nil }
        // Only tasks of the recent-done window may form done cards; a done parent with active children stays visible.
        var topCards: [CommandCard] = []
        var backlog = 0
        for task in tops {
            let lane = effectiveLane(task)
            if lane == "backlog" { backlog += 1; continue }
            topCards.append(try card(task, lane: lane))
        }
        var activeAgents = Set<String>()
        for c in topCards where c.lane == "running" {
            if let label = c.agent?.claimedLabel { activeAgents.insert(label) }
            else if let id = c.agent?.runID { activeAgents.insert(id.uuidString) }
        }
        func count(_ lane: String) -> Int { topCards.filter { $0.lane == lane }.count }
        let summary = SummaryDTO(running: count("running"), question: count("question"), review: count("review"), ready: count("ready"),
            blocked: count("blocked"), done: count("done"), backlog: backlog,
            openQuestions: questions.count, pendingReviews: reviews.count, features: topCards.filter { $0.isFeature && $0.lane != "done" }.count,
            activeAgents: activeAgents.count)

        let updates = q.updatesLimit == 0 ? [] : try await self.updates(scope: scope, limit: q.updatesLimit)
        let buildGroups = Self.groups(builds, limit: 10)

        func sorted(_ cards: [CommandCard], by sort: String, lane: String?) -> [CommandCard] {
            func updated(_ c: CommandCard) -> Date { c.latestUpdate?.at ?? c.task.updatedAt ?? c.task.createdAt ?? .distantPast }
            switch sort {
            case "title": return cards.sorted { $0.task.title.localizedCaseInsensitiveCompare($1.task.title) == .orderedAscending }
            case "updated": return cards.sorted { updated($0) > updated($1) }
            case "progress": return cards.sorted { $0.progress.percent > $1.progress.percent }
            case "due": return cards.sorted { ($0.nextDue ?? .distantFuture) < ($1.nextDue ?? .distantFuture) }
            default:
                return cards.sorted { a, b in
                    switch lane ?? a.lane {
                    case "question": return (a.questions.first?.createdAt ?? .distantFuture) < (b.questions.first?.createdAt ?? .distantFuture)
                    case "review": return (a.pendingReview?.createdAt ?? .distantFuture) < (b.pendingReview?.createdAt ?? .distantFuture)
                    case "ready":
                        if (a.nextDue ?? .distantFuture) != (b.nextDue ?? .distantFuture) { return (a.nextDue ?? .distantFuture) < (b.nextDue ?? .distantFuture) }
                        if a.priority != b.priority { return a.priority > b.priority }
                        return (a.task.createdAt ?? .distantPast) < (b.task.createdAt ?? .distantPast)
                    default: return updated(a) > updated(b)
                    }
                }
            }
        }

        if q.view == "list" {
            var pool = topCards
            if q.includeSubtasks {
                for parent in tops {
                    for kid in childrenOf[parent.id!] ?? [] where states[kid.id!]!.lane != "backlog" {
                        // Subtasks outside the done window are not listed as done cards.
                        if kid.status == "done", (kid.updatedAt ?? .distantPast) < cutoff { continue }
                        pool.append(try card(kid, lane: states[kid.id!]!.lane))
                    }
                }
            }
            if let lanes = q.lanes { pool = pool.filter { lanes.contains($0.lane) } }
            if let kind = q.kind { pool = pool.filter { $0.kind == kind } }
            if let has = q.hasQuestion { pool = pool.filter { ($0.openQuestionCount > 0) == has } }
            let ordered = sorted(pool, by: q.sort, lane: nil)
            let page = Array(ordered.dropFirst(q.offset).prefix(q.limit))
            return CommandCenterResponse(generatedAt: now, scope: q.projectID == nil ? "account" : "project", projectID: q.projectID,
                view: "list", summary: summary, lanes: nil, items: page, total: ordered.count, updates: updates, builds: buildGroups)
        }

        var lanes: [LaneDTO] = []
        for (key, title) in LaneInfo.order where q.lanes?.contains(key) ?? true {
            var cards = topCards.filter { $0.lane == key }
            if let kind = q.kind { cards = cards.filter { $0.kind == kind } }
            if let has = q.hasQuestion { cards = cards.filter { ($0.openQuestionCount > 0) == has } }
            let ordered = sorted(cards, by: q.sort, lane: key)
            lanes.append(LaneDTO(key: key, title: title, count: ordered.count, truncated: ordered.count > q.laneLimit,
                cards: Array(ordered.prefix(q.laneLimit))))
        }
        return CommandCenterResponse(generatedAt: now, scope: q.projectID == nil ? "account" : "project", projectID: q.projectID,
            view: "kanban", summary: summary, lanes: lanes, items: nil, total: nil, updates: updates, builds: buildGroups)
    }

    static func groups(_ builds: [UUID: [BuildArtifactDTO]], limit: Int) -> [BuildGroup] {
        var grouped: [String: [BuildArtifactDTO]] = [:]
        for item in builds.values.flatMap({ $0 }) { grouped[item.buildID, default: []].append(item) }
        let groups = grouped.map { (id, items) -> BuildGroup in
            let sorted = items.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            return BuildGroup(buildID: id, label: sorted.compactMap(\.label).first, platform: sorted.compactMap(\.platform).first,
                taskIDs: Array(Set(sorted.map(\.taskID))).sorted { $0.uuidString < $1.uuidString },
                createdAt: sorted.first?.createdAt, items: Array(sorted.prefix(6)))
        }
        return Array(groups.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(limit))
    }

    /// Latest agent/workflow events of the scope with resolved text.
    func updates(scope: CommandCenterScope, limit: Int) async throws -> [UpdateItem] {
        let ids = scope.projectIDs
        guard !ids.isEmpty else { return [] }
        let events = try await ActivityEvent.query(on: db)
            .join(TodoTask.self, on: \ActivityEvent.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids)
            .filter(ActivityEvent.self, \.$kind ~~ Self.updateKinds)
            .sort(ActivityEvent.self, \.$createdAt, .descending).sort(ActivityEvent.self, \.$id, .descending)
            .limit(limit).all()
        var subjects: [String: Set<UUID>] = [:]
        for e in events { if let s = e.subjectID { subjects[String(e.kind.split(separator: ".").first ?? ""), default: []].insert(s) } }
        let noteText = Dictionary(uniqueKeysWithValues: try await TaskProgressNote.query(on: db)
            .filter(\.$id ~~ Array(subjects["progress"] ?? [])).all().map { ($0.id!, $0.note) })
        let questionIDs = Array((subjects["question"] ?? []).union(subjects["agent"] ?? []))
        let questions = try await TaskQuestion.query(on: db).group(.or) { or in
            or.filter(\.$id ~~ questionIDs); or.filter(\.$agentQuestionID ~~ questionIDs)
        }.all()
        var questionByKey: [UUID: TaskQuestion] = [:]
        for q in questions { questionByKey[q.id!] = q; if let a = q.agentQuestionID { questionByKey[a] = q } }
        let reviews = Dictionary(uniqueKeysWithValues: try await TaskReview.query(on: db)
            .filter(\.$id ~~ Array(subjects["review"] ?? [])).all().map { ($0.id!, $0) })
        let artifacts = Dictionary(uniqueKeysWithValues: try await BuildArtifact.query(on: db)
            .filter(\.$id ~~ Array(subjects["build"] ?? [])).all().map { ($0.id!, $0) })
        let names = try await displayNames(events.filter { $0.actorType == .person }.map(\.actorID), on: db)
        return try events.map { e in
            let task = try e.joined(TodoTask.self)
            var text: String?
            if let s = e.subjectID {
                switch e.kind {
                case "progress.posted": text = noteText[s]
                case "question.asked", "question.withdrawn": text = questionByKey[s]?.prompt
                case "question.answered", "agent.answered": text = questionByKey[s]?.answer
                case "review.requested": text = reviews[s]?.summary
                case "review.accepted", "review.changes_requested": text = reviews[s]?.decisionNote ?? reviews[s]?.summary
                case "build.added": text = artifacts[s].map { $0.label ?? $0.buildID }
                default: break
                }
            }
            return UpdateItem(id: try e.requireID(), taskID: task.id!, taskTitle: task.title, projectID: task.projectID,
                projectName: scope.projects[task.projectID]?.name ?? "", kind: e.kind, actorType: e.actorType, actorID: e.actorID,
                actorName: e.actorType == .person ? names[e.actorID] : nil, subjectID: e.subjectID, text: text, createdAt: e.createdAt)
        }
    }
}
