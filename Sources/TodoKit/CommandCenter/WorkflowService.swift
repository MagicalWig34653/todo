import Crypto
import Fluent
import Vapor

/// Who performs a workflow action. REST = person, MCP = integration (OAuth grant), runner = run.
struct WorkflowActor: Sendable {
    let type: ActivityActorType
    let id: UUID
    let label: String?
    /// `rest` | `mcp` | `runner`
    let via: String
    static func person(_ user: User) throws -> WorkflowActor { WorkflowActor(type: .person, id: try user.requireID(), label: nil, via: "rest") }
    static func integration(grantID: UUID, label: String?) -> WorkflowActor {
        WorkflowActor(type: .integration, id: grantID, label: label, via: "mcp")
    }
}

/// Column roles recognised by name (ADR 0014). A project without a matching column simply skips the move.
enum ColumnRole: String, CaseIterable, Sendable {
    case backlog, ready, working, question, review, done

    static let aliases: [ColumnRole: [String]] = [
        .backlog: ["backlog"],
        .ready: ["bereit", "ready", "to do", "todo", "offen", "open"],
        .working: ["in arbeit", "in progress", "doing", "läuft", "laeuft", "wip"],
        .question: ["frage offen", "fragen", "question", "questions", "open question", "open questions", "rückfrage", "rückfragen"],
        .review: ["review", "in review", "in prüfung", "prüfung", "pruefung", "zur prüfung"],
    ]

    static func normalize(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func of(_ column: ProjectColumn) -> ColumnRole? {
        let name = normalize(column.name)
        for (role, names) in aliases where names.contains(name) { return role }
        return column.isDone ? .done : nil
    }

    /// The standard "agent_workflow" template (also the German UI names).
    static let template: [(name: String, role: ColumnRole)] = [
        ("Backlog", .backlog), ("Bereit", .ready), ("In Arbeit", .working),
        ("Frage offen", .question), ("Review", .review), ("Erledigt", .done),
    ]
}

enum WorkflowLimits {
    static let maxText = 4000
    static let maxBrief = 20_000
    static let inlineAttachmentBytes = 5 * 1024 * 1024
}

/// Business rules for questions, progress, reviews, builds, briefs and claims. REST and MCP use the same
/// methods; `allowedProjects` narrows an OAuth grant to its project list (404 outside, like every MCP tool).
struct WorkflowService: Sendable {
    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil
    var attachments: (@Sendable () throws -> AttachmentService)? = nil

    var access: ProjectAccess { ProjectAccess(user: user, db: db) }

    func checkScope(_ projectID: UUID) throws {
        if let allowedProjects, !allowedProjects.contains(projectID) { throw Abort(.notFound) }
    }

    /// Visible project, readable by the user and inside the grant.
    func project(_ id: UUID, role: ProjectRole = .read) async throws -> Project {
        try checkScope(id)
        return try await access.project(id, role: role)
    }

    func readableTask(_ id: UUID, role: ProjectRole = .read) async throws -> TodoTask {
        let task = try await access.task(id, role: role)
        try checkScope(task.projectID)
        return task
    }

    /// Lock order: sharing graph, then the task row, then reads. Rights are checked on the locked state.
    func mutate<T: Sendable>(_ taskID: UUID, role: ProjectRole,
                             _ body: @escaping @Sendable (TodoTask, any Database) async throws -> T) async throws -> T {
        let user = self.user, allowed = allowedProjects
        return try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: TodoTask.schema, id: taskID, on: tx)
            let task = try await ProjectAccess(user: user, db: tx).task(taskID, role: role)
            if let allowed, !allowed.contains(task.projectID) { throw Abort(.notFound) }
            return try await body(task, tx)
        }
    }

    // MARK: Text helpers

    static func text(_ raw: String, max: Int = WorkflowLimits.maxText, reason: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= max else { throw Abort(.badRequest, reason: reason) }
        return value
    }

    static func optionalLabel(_ raw: String?, max: Int = 100, reason: String) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.count <= max, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }

    // MARK: Task state helpers (caller holds the sharing graph and task row locks)

    static func workflow(_ taskID: UUID, on db: any Database) async throws -> TaskWorkflow {
        try await TaskWorkflow.find(taskID, on: db) ?? TaskWorkflow(taskID: taskID)
    }

    /// Moves the task into the first column with `role`, if the project has one. Does not save the task.
    static func place(_ task: TodoTask, role: ColumnRole, on db: any Database) async throws {
        let columns = try await ProjectColumn.query(on: db).filter(\.$projectID == task.projectID).sort(\.$position).sort(\.$id).all()
        guard let target = columns.first(where: { ColumnRole.of($0) == role }), task.columnID != target.id else { return }
        let taskID = try task.requireID()
        task.columnID = target.id
        task.boardPosition = try await TodoTask.query(on: db).filter(\.$projectID == task.projectID)
            .filter(\.$columnID == target.requireID()).filter(\.$id != taskID).count()
    }

    /// Sets the status like PATCH does (column reconciliation, activity). Saving and recurrence happen in `commit`.
    static func applyStatus(_ task: TodoTask, _ status: String, actor: WorkflowActor, on db: any Database) async throws {
        guard task.status != status else { return }
        guard TaskStatus.all.contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
        task.status = status
        try await ColumnService.reconcile(task, on: db)
        try await appendActivity(taskID: task.requireID(), actorType: actor.type, actorID: actor.id,
            kind: "task.status_changed", subjectID: nil, on: db)
    }

    static func commit(_ task: TodoTask, owner: User, on db: any Database) async throws {
        task.version += 1
        try await task.save(on: db)
        if task.status == "done", let planning = try await TaskPlanning.find(task.requireID(), on: db) {
            try await PlanningService(user: owner, db: db).spawnNext(task, planning: planning)
        }
    }

    // MARK: Claim / release

    func claim(_ taskID: UUID, agentName: String?, takeOver: Bool, actor: WorkflowActor) async throws -> TaskContextDTO {
        let label = try Self.optionalLabel(agentName, reason: "invalid_agent_name") ?? actor.label
        let owner = user
        try await mutate(taskID, role: .edit) { task, tx in
            guard task.status != "done" else { throw Abort(.conflict, reason: "task_done") }
            let id = try task.requireID()
            let wf = try await Self.workflow(id, on: tx)
            if let current = wf.claimedByID, !(current == actor.id && (wf.claimedLabel ?? "") == (label ?? "")), !takeOver {
                throw Abort(.conflict, reason: "already_claimed")
            }
            wf.claimedByType = actor.type.rawValue; wf.claimedByID = actor.id; wf.claimedLabel = label; wf.claimedAt = Date()
            try await wf.save(on: tx)
            try await Self.applyStatus(task, "in_progress", actor: actor, on: tx)
            try await Self.place(task, role: .working, on: tx)
            try await Self.commit(task, owner: owner, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "task.claimed", subjectID: nil, on: tx)
        }
        return try await context(taskID)
    }

    func release(_ taskID: UUID, force: Bool, actor: WorkflowActor) async throws -> TaskContextDTO {
        let owner = user
        try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            guard let wf = try await TaskWorkflow.find(id, on: tx), let current = wf.claimedByID else { return }
            if !(current == actor.id) && !force { throw Abort(.conflict, reason: "claimed_by_other") }
            wf.claimedByType = nil; wf.claimedByID = nil; wf.claimedLabel = nil; wf.claimedAt = nil
            try await wf.save(on: tx)
            if task.status == "in_progress" {
                try await Self.applyStatus(task, "open", actor: actor, on: tx)
                try await Self.place(task, role: .ready, on: tx)
                try await Self.commit(task, owner: owner, on: tx)
            }
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "task.released", subjectID: nil, on: tx)
        }
        return try await context(taskID)
    }

    // MARK: Progress

    func postProgress(_ taskID: UUID, note: String, percent: Int?, label: String?, actor: WorkflowActor) async throws -> ProgressNoteDTO {
        let text = try Self.text(note, reason: "invalid_note")
        if let percent, !(0...100).contains(percent) { throw Abort(.badRequest, reason: "invalid_percent") }
        let label = try Self.optionalLabel(label, reason: "invalid_agent_name") ?? actor.label
        return try await mutate(taskID, role: .edit) { task, tx in
            let n = TaskProgressNote()
            n.taskID = try task.requireID(); n.actorType = actor.type; n.actorID = actor.id; n.actorLabel = label
            n.note = text; n.percent = percent
            try await n.save(on: tx)
            try await appendActivity(taskID: n.taskID, actorType: actor.type, actorID: actor.id, kind: "progress.posted", subjectID: n.id, on: tx)
            return try ProgressNoteDTO(n)
        }
    }

    // MARK: Structure (feature, subtasks, blocked)

    func setStructure(_ taskID: UUID, _ body: StructureRequest, actor: WorkflowActor) async throws -> WorkflowDTO {
        if let kind = body.kind, !["task", "feature"].contains(kind) { throw Abort(.badRequest, reason: "invalid_kind") }
        let blocked: String?? = try {
            guard let raw = body.blockedReason else { return nil }
            if let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                guard value.count <= 1000 else { throw Abort(.badRequest, reason: "invalid_blocked_reason") }
                return .some(value)
            }
            return .some(nil)
        }()
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let wf = try await Self.workflow(id, on: tx)
            if let kind = body.kind { wf.kind = kind }
            if let parent = body.parentTaskID {
                if let parentID = parent {
                    guard parentID != id else { throw Abort(.unprocessableEntity, reason: "invalid_parent") }
                    guard let p = try await TodoTask.find(parentID, on: tx), p.projectID == task.projectID else {
                        throw Abort(.unprocessableEntity, reason: "parent_must_share_project")
                    }
                    if try await TaskWorkflow.find(parentID, on: tx)?.parentTaskID != nil { throw Abort(.unprocessableEntity, reason: "subtask_depth_exceeded") }
                    if try await TaskWorkflow.query(on: tx).filter(\.$parentTaskID == id).count() > 0 {
                        throw Abort(.unprocessableEntity, reason: "subtask_depth_exceeded")
                    }
                    wf.parentTaskID = parentID
                } else { wf.parentTaskID = nil }
            }
            if let blocked {
                let before = wf.blockedReason
                wf.blockedReason = blocked
                if before != blocked {
                    try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id,
                        kind: blocked == nil ? "task.unblocked" : "task.blocked", subjectID: nil, on: tx)
                }
            }
            try await wf.save(on: tx)
            return Self.dto(wf)
        }
    }

    static func dto(_ wf: TaskWorkflow, hasChildren: Bool = false) -> WorkflowDTO {
        WorkflowDTO(taskID: wf.id!, kind: wf.kind, isFeature: wf.kind == "feature" || hasChildren, parentTaskID: wf.parentTaskID,
            blockedReason: wf.blockedReason, claimedByType: wf.claimedByType, claimedByID: wf.claimedByID,
            claimedLabel: wf.claimedLabel, claimedAt: wf.claimedAt)
    }

    // MARK: Criteria

    func addCriterion(_ taskID: UUID, text raw: String, actor: WorkflowActor) async throws -> CriterionDTO {
        let value = try Self.text(raw, max: 2000, reason: "invalid_text")
        return try await mutate(taskID, role: .edit) { task, tx in
            let c = AcceptanceCriterion(taskID: try task.requireID(), text: value)
            try await c.save(on: tx)
            try await appendActivity(taskID: c.taskID, actorType: actor.type, actorID: actor.id, kind: "criterion.created", subjectID: c.id, on: tx)
            return try CriterionDTO(c)
        }
    }

    func setCriterion(_ id: UUID, completed: Bool, actor: WorkflowActor) async throws -> CriterionDTO {
        guard let existing = try await AcceptanceCriterion.find(id, on: db) else { throw Abort(.notFound) }
        return try await mutate(existing.taskID, role: .edit) { _, tx in
            guard let c = try await AcceptanceCriterion.find(id, on: tx) else { throw Abort(.notFound) }
            if c.completed != completed {
                c.completed = completed; c.version += 1
                try await c.save(on: tx)
                try await appendActivity(taskID: c.taskID, actorType: actor.type, actorID: actor.id, kind: "criterion.updated", subjectID: c.id, on: tx)
            }
            return try CriterionDTO(c)
        }
    }

    // MARK: Questions

    func ask(_ taskID: UUID, _ body: AskQuestionRequest, actor: WorkflowActor) async throws -> QuestionDTO {
        let prompt = try Self.text(body.prompt, reason: "invalid_prompt")
        let options = try (body.options ?? []).map { try Self.text($0, max: 500, reason: "invalid_option") }
        guard options.count <= 20, Set(options).count == options.count else { throw Abort(.badRequest, reason: "invalid_option") }
        let hash = try CommentService.keyHash(body.idempotencyKey)
        let blocking = body.blocking ?? true
        let label = try Self.optionalLabel(body.agentName, reason: "invalid_agent_name") ?? actor.label
        let owner = user
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            if let hash, let saved = try await TaskQuestion.query(on: tx).filter(\.$taskID == id).filter(\.$idempotencyKey == hash).first() {
                guard saved.prompt == prompt else { throw Abort(.conflict, reason: "idempotency_conflict") }
                return try QuestionDTO(saved)
            }
            let q = TaskQuestion()
            q.taskID = id; q.askedByType = actor.type; q.askedByID = actor.id; q.askedByLabel = label
            q.prompt = prompt; q.options = options; q.blocking = blocking; q.state = "open"; q.idempotencyKey = hash; q.version = 1
            try await q.save(on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "question.asked", subjectID: q.id, on: tx)
            if blocking, task.status != "done" {
                let before = task.columnID
                try await Self.place(task, role: .question, on: tx)
                if task.columnID != before { try await Self.commit(task, owner: owner, on: tx) }
            }
            return try QuestionDTO(q)
        }
    }

    /// Answer a question. Runner-backed questions delegate to `AgentService.answer` (same rules as the runner flow).
    func answer(_ questionID: UUID, value raw: String, actor: WorkflowActor) async throws -> QuestionDTO {
        guard let initial = try await TaskQuestion.find(questionID, on: db) else { throw Abort(.notFound) }
        _ = try await readableTask(initial.taskID, role: .comment)
        let value = try Self.text(raw, reason: "invalid_answer")
        if let agentQuestionID = initial.agentQuestionID {
            _ = try await AgentService.answer(questionID: agentQuestionID, value: value, user: user, on: db)
            guard let fresh = try await TaskQuestion.find(questionID, on: db) else { throw Abort(.notFound) }
            return try QuestionDTO(fresh)
        }
        let owner = user, userID = try user.requireID()
        return try await mutate(initial.taskID, role: .comment) { task, tx in
            guard let q = try await TaskQuestion.find(questionID, on: tx) else { throw Abort(.notFound) }
            if q.state == "answered" {
                guard q.answer == value, q.answeredBy == userID else { throw Abort(.conflict, reason: "question_already_answered") }
                return try QuestionDTO(q)
            }
            guard q.state == "open" else { throw Abort(.conflict, reason: "question_not_open") }
            if actor.type == .integration, q.askedByType == .integration, q.askedByID == actor.id {
                throw Abort(.forbidden, reason: "cannot_answer_own_question")
            }
            if !q.options.isEmpty, !q.options.contains(value) { throw Abort(.badRequest, reason: "invalid_answer_option") }
            q.state = "answered"; q.answer = value; q.answeredBy = userID; q.answeredVia = actor.via; q.answeredAt = Date(); q.version += 1
            try await q.save(on: tx)
            try await appendActivity(taskID: q.taskID, actorType: actor.type, actorID: actor.id, kind: "question.answered", subjectID: q.id, on: tx)
            let stillOpen = try await TaskQuestion.query(on: tx).filter(\.$taskID == q.taskID).filter(\.$state == "open")
                .filter(\.$blocking == true).count()
            if stillOpen == 0, task.status == "in_progress" {
                let before = task.columnID
                try await Self.place(task, role: .working, on: tx)
                if task.columnID != before { try await Self.commit(task, owner: owner, on: tx) }
            }
            return try QuestionDTO(q)
        }
    }

    func question(_ id: UUID) async throws -> QuestionDTO {
        guard let q = try await TaskQuestion.find(id, on: db) else { throw Abort(.notFound) }
        let task = try await readableTask(q.taskID)
        var dto = try QuestionDTO(q)
        dto.taskTitle = task.title; dto.projectID = task.projectID
        return dto
    }

    /// Questions of the visible (and granted) projects, newest first.
    func questions(projectID: UUID?, taskID: UUID?, state: String, includeSubprojects: Bool = true, limit: Int = 100) async throws -> [QuestionDTO] {
        guard ["open", "answered", "all"].contains(state), (1...200).contains(limit) else { throw Abort(.badRequest, reason: "invalid_filter") }
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: includeSubprojects, allowed: allowedProjects)
        var tasks = TodoTask.query(on: db).filter(\.$projectID ~~ scope.projectIDs)
        if let taskID { tasks = tasks.filter(\.$id == taskID) }
        let taskRows = try await tasks.all()
        guard !taskRows.isEmpty else { return [] }
        let byTask = Dictionary(uniqueKeysWithValues: try taskRows.map { (try $0.requireID(), $0) })
        var q = TaskQuestion.query(on: db).filter(\.$taskID ~~ Array(byTask.keys))
        if state != "all" { q = q.filter(\.$state == state) }
        let rows = try await q.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit).all()
        let names = try await displayNames(rows.compactMap { $0.askedByType == .person ? $0.askedByID : nil }, on: db)
        return try rows.map { row in
            var dto = try QuestionDTO(row)
            let task = byTask[row.taskID]
            dto.taskTitle = task?.title; dto.projectID = task?.projectID
            dto.projectName = task.flatMap { scope.projects[$0.projectID]?.name }
            if row.askedByType == .person { dto.askedByName = names[row.askedByID] }
            return dto
        }
    }

    // MARK: Reviews

    func requestReview(_ taskID: UUID, _ body: RequestReviewRequest, actor: WorkflowActor) async throws -> ReviewDTO {
        let summary = try Self.text(body.summary, reason: "invalid_summary")
        let label = try Self.optionalLabel(body.agentName, reason: "invalid_agent_name") ?? actor.label
        let owner = user
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            guard task.status != "done" else { throw Abort(.conflict, reason: "task_done") }
            if let reviewerID = body.reviewerID {
                guard let reviewer = try await User.find(reviewerID, on: tx),
                      (try? await ProjectAccess(user: reviewer, db: tx).project(task.projectID, role: .read)) != nil else {
                    throw Abort(.badRequest, reason: "invalid_reviewer")
                }
            }
            if let pending = try await TaskReview.query(on: tx).filter(\.$taskID == id).filter(\.$state == "pending").first() {
                guard pending.agentJobID == nil, pending.requestedByID == actor.id else { throw Abort(.conflict, reason: "review_already_pending") }
                pending.summary = summary; pending.reviewerID = body.reviewerID; pending.version += 1
                try await pending.save(on: tx)
                return try ReviewDTO(pending)
            }
            let r = TaskReview()
            r.taskID = id; r.state = "pending"; r.requestedByType = actor.type; r.requestedByID = actor.id
            r.requestedByLabel = label; r.reviewerID = body.reviewerID; r.summary = summary; r.version = 1
            try await r.save(on: tx)
            try await Self.applyStatus(task, "in_review", actor: actor, on: tx)
            try await Self.place(task, role: .review, on: tx)
            try await Self.commit(task, owner: owner, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "review.requested", subjectID: r.id, on: tx)
            return try ReviewDTO(r)
        }
    }

    func decideReview(_ taskID: UUID, decision: String, note rawNote: String?, actor: WorkflowActor) async throws -> ReviewDTO {
        guard ["accept", "request_changes"].contains(decision) else { throw Abort(.badRequest, reason: "invalid_decision") }
        let note = try Self.optionalLabel(rawNote, max: WorkflowLimits.maxText, reason: "invalid_note")
        _ = try await readableTask(taskID, role: .edit)
        // Runner-backed review: the job transition (owner capability, job state) is authoritative.
        if let linked = try await TaskReview.query(on: db).filter(\.$taskID == taskID).filter(\.$state == "pending")
            .filter(\.$agentJobID != .null).first(), let jobID = linked.agentJobID {
            _ = try await AgentService.humanTransition(jobID: jobID, decision: decision, user: user, on: db)
            if let note {
                _ = try await CommentService.create(taskID: taskID, user: user, body: note, idempotencyKey: nil,
                    actor: (actor.type, actor.id), scope: { [allowedProjects] t in
                        if let allowedProjects, !allowedProjects.contains(t.projectID) { throw Abort(.notFound) }
                    }, on: db)
            }
            guard let fresh = try await TaskReview.find(linked.requireID(), on: db) else { throw Abort(.notFound) }
            return try ReviewDTO(fresh)
        }
        let owner = user, userID = try user.requireID()
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            guard let r = try await TaskReview.query(on: tx).filter(\.$taskID == id).filter(\.$state == "pending").first() else {
                throw Abort(.conflict, reason: "no_pending_review")
            }
            if actor.type == .integration, r.requestedByType == .integration, r.requestedByID == actor.id {
                throw Abort(.forbidden, reason: "cannot_decide_own_review")
            }
            if let reviewer = r.reviewerID, reviewer != userID {
                do { _ = try await ProjectAccess(user: owner, db: tx).project(task.projectID, role: .manage) }
                catch { throw Abort(.forbidden, reason: "not_the_reviewer") }
            }
            r.state = decision == "accept" ? "accepted" : "changes_requested"
            r.decidedBy = userID; r.decidedAt = Date(); r.decisionNote = note; r.version += 1
            try await r.save(on: tx)
            if decision == "accept" {
                try await Self.applyStatus(task, "done", actor: actor, on: tx)
            } else {
                try await Self.applyStatus(task, "in_progress", actor: actor, on: tx)
                try await Self.place(task, role: .working, on: tx)
            }
            try await Self.commit(task, owner: owner, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id,
                kind: decision == "accept" ? "review.accepted" : "review.changes_requested", subjectID: r.id, on: tx)
            return try ReviewDTO(r)
        }
    }

    func reviews(projectID: UUID?, state: String, includeSubprojects: Bool = true, limit: Int = 100) async throws -> [ReviewDTO] {
        guard ["pending", "all"].contains(state) || ["accepted", "changes_requested", "withdrawn"].contains(state),
              (1...200).contains(limit) else { throw Abort(.badRequest, reason: "invalid_filter") }
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: includeSubprojects, allowed: allowedProjects)
        let tasks = try await TodoTask.query(on: db).filter(\.$projectID ~~ scope.projectIDs).all()
        guard !tasks.isEmpty else { return [] }
        let byTask = Dictionary(uniqueKeysWithValues: try tasks.map { (try $0.requireID(), $0) })
        var q = TaskReview.query(on: db).filter(\.$taskID ~~ Array(byTask.keys))
        if state != "all" { q = q.filter(\.$state == state) }
        return try await q.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit).all().map { row in
            var dto = try ReviewDTO(row)
            let task = byTask[row.taskID]
            dto.taskTitle = task?.title; dto.projectID = task?.projectID
            dto.projectName = task.flatMap { scope.projects[$0.projectID]?.name }
            return dto
        }
    }

    // MARK: Builds (screenshots) via the existing attachment service

    static func cleanBuild(buildID: String, label: String?, platform: String?) throws -> (String, String?, String?) {
        let id = try optionalLabel(buildID, max: 100, reason: "invalid_build_id")
        guard let id else { throw Abort(.badRequest, reason: "invalid_build_id") }
        return (id, try optionalLabel(label, max: 200, reason: "invalid_label"), try optionalLabel(platform, max: 50, reason: "invalid_platform"))
    }

    private func attachmentService() throws -> AttachmentService {
        guard let attachments else { throw Abort(.serviceUnavailable, reason: "attachments_unavailable") }
        return try attachments()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func beginBuild(taskID: UUID, filename: String, mediaType: String, size: Int, checksum: String,
                    buildID: String, label: String?, platform: String?, actor: WorkflowActor) async throws -> (UploadCapability, BuildArtifact) {
        let (build, label, platform) = try Self.cleanBuild(buildID: buildID, label: label, platform: platform)
        _ = try await readableTask(taskID, role: .edit)
        let capability = try await attachmentService().begin(
            BeginAttachment(taskID: taskID, filename: filename, role: "result", mediaType: mediaType, size: size, checksum: checksum),
            user: user, db: db)
        let artifact = BuildArtifact()
        artifact.attachmentID = capability.attachmentID; artifact.taskID = taskID; artifact.buildID = build
        artifact.label = label; artifact.platform = platform; artifact.createdByType = actor.type; artifact.createdByID = actor.id
        try await artifact.save(on: db)
        return (capability, artifact)
    }

    func completeBuild(attachmentID: UUID, actor: WorkflowActor) async throws -> BuildArtifactDTO {
        guard let artifact = try await BuildArtifact.query(on: db).filter(\.$attachmentID == attachmentID).first() else { throw Abort(.notFound) }
        _ = try await readableTask(artifact.taskID, role: .edit)
        let dto = try await attachmentService().complete(attachmentID, user: user, db: db)
        return try await announceBuild(artifact, attachment: dto, actor: actor)
    }

    /// Registers an already completed attachment as a build artifact (human uploads through the normal flow).
    func registerBuild(_ body: RegisterBuildRequest, actor: WorkflowActor) async throws -> BuildArtifactDTO {
        let (build, label, platform) = try Self.cleanBuild(buildID: body.buildID, label: body.label, platform: body.platform)
        guard let attachment = try await Attachment.find(body.attachmentID, on: db), attachment.status == "complete" else { throw Abort(.notFound) }
        _ = try await readableTask(attachment.taskID, role: .edit)
        if let existing = try await BuildArtifact.query(on: db).filter(\.$attachmentID == body.attachmentID).first() {
            return Self.buildDTO(existing, attachment: try AttachmentDTO(attachment))
        }
        let artifact = BuildArtifact()
        artifact.attachmentID = body.attachmentID; artifact.taskID = attachment.taskID; artifact.buildID = build
        artifact.label = label; artifact.platform = platform; artifact.createdByType = actor.type; artifact.createdByID = actor.id
        do { try await artifact.save(on: db) }
        catch let error as any DatabaseError where error.isConstraintFailure {
            guard let existing = try await BuildArtifact.query(on: db).filter(\.$attachmentID == body.attachmentID).first() else { throw Abort(.conflict, reason: "build_register_conflict") }
            return Self.buildDTO(existing, attachment: try AttachmentDTO(attachment))
        }
        return try await announceBuild(artifact, attachment: try AttachmentDTO(attachment), actor: actor)
    }

    private func announceBuild(_ artifact: BuildArtifact, attachment: AttachmentDTO, actor: WorkflowActor) async throws -> BuildArtifactDTO {
        let artifactID = try artifact.requireID()
        try await mutate(artifact.taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let announced = try await ActivityEvent.query(on: tx).filter(\.$taskID == id).filter(\.$kind == "build.added")
                .filter(\.$subjectID == artifactID).count()
            if announced == 0 {
                try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "build.added", subjectID: artifactID, on: tx)
            }
        }
        return Self.buildDTO(artifact, attachment: attachment)
    }

    static func buildDTO(_ a: BuildArtifact, attachment: AttachmentDTO) -> BuildArtifactDTO {
        BuildArtifactDTO(id: a.id!, attachmentID: a.attachmentID, taskID: a.taskID, buildID: a.buildID, label: a.label,
            platform: a.platform, filename: attachment.filename, mediaType: attachment.mediaType, size: attachment.size,
            previewURL: "/v1/attachments/\(a.attachmentID.uuidString)/preview", createdAt: a.createdAt)
    }


    /// Inline upload for small screenshots: begin, upload, complete in one call.
    func addInline(taskID: UUID, filename: String, mediaType: String, base64: String, buildID: String,
                   label: String?, platform: String?, actor: WorkflowActor) async throws -> BuildArtifactDTO {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), !data.isEmpty else {
            throw Abort(.badRequest, reason: "invalid_base64")
        }
        guard data.count <= WorkflowLimits.inlineAttachmentBytes else { throw Abort(.payloadTooLarge, reason: "inline_attachment_too_large") }
        let (capability, _) = try await beginBuild(taskID: taskID, filename: filename, mediaType: mediaType, size: data.count,
            checksum: Self.sha256(data), buildID: buildID, label: label, platform: platform, actor: actor)
        let service = try attachmentService()
        do {
            try await service.upload(capability.attachmentID, token: capability.token, data: data, db: db)
        } catch {
            try? await service.abort(capability.attachmentID, user: user, db: db)
            try? await BuildArtifact.query(on: db).filter(\.$attachmentID == capability.attachmentID).delete()
            throw error
        }
        return try await completeBuild(attachmentID: capability.attachmentID, actor: actor)
    }

    /// Completed build artifacts of the given tasks, newest first.
    static func builds(of taskIDs: [UUID], on db: any Database, limitPerTask: Int? = nil) async throws -> [UUID: [BuildArtifactDTO]] {
        guard !taskIDs.isEmpty else { return [:] }
        let artifacts = try await BuildArtifact.query(on: db).filter(\.$taskID ~~ taskIDs).sort(\.$createdAt, .descending).sort(\.$id, .descending).all()
        guard !artifacts.isEmpty else { return [:] }
        let attachments = Dictionary(uniqueKeysWithValues: try await Attachment.query(on: db)
            .filter(\.$id ~~ artifacts.map(\.attachmentID)).filter(\.$status == "complete").all().map { (try $0.requireID(), $0) })
        var result: [UUID: [BuildArtifactDTO]] = [:]
        for artifact in artifacts {
            guard let attachment = attachments[artifact.attachmentID] else { continue }
            result[artifact.taskID, default: []].append(buildDTO(artifact, attachment: try AttachmentDTO(attachment)))
        }
        return result
    }

    func builds(taskID: UUID) async throws -> [BuildArtifactDTO] {
        _ = try await readableTask(taskID)
        return try await Self.builds(of: [taskID], on: db)[taskID] ?? []
    }

    // MARK: Agent brief

    func brief(_ projectID: UUID) async throws -> AgentBriefDTO {
        _ = try await project(projectID)
        return try await Self.briefDTO(projectID, on: db)
    }

    static func briefDTO(_ projectID: UUID, on db: any Database) async throws -> AgentBriefDTO {
        let row = try await ProjectAgentBrief.find(projectID, on: db)
        return AgentBriefDTO(projectID: projectID, text: row?.text ?? "", version: row?.version ?? 0, updatedAt: row?.updatedAt)
    }

    func putBrief(_ projectID: UUID, _ body: AgentBriefRequest) async throws -> AgentBriefDTO {
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= WorkflowLimits.maxBrief, body.version >= 0 else { throw Abort(.badRequest, reason: "invalid_brief") }
        let user = self.user, allowed = allowedProjects
        return try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            if let allowed, !allowed.contains(projectID) { throw Abort(.notFound) }
            _ = try await ProjectAccess(user: user, db: tx).project(projectID, role: .manage)
            let row = try await ProjectAgentBrief.find(projectID, on: tx) ?? ProjectAgentBrief(projectID: projectID)
            guard row.version == body.version else { throw Abort(.conflict, reason: "version_conflict") }
            row.text = text; row.version += 1; row.updatedBy = try user.requireID()
            try await row.save(on: tx)
            return AgentBriefDTO(projectID: projectID, text: row.text, version: row.version, updatedAt: row.updatedAt)
        }
    }

    // MARK: Progress rollup and context

    func context(_ taskID: UUID) async throws -> TaskContextDTO {
        let task = try await readableTask(taskID)
        let id = try task.requireID()
        let wf = try await TaskWorkflow.find(id, on: db)
        let children = try await Self.children(of: [id], on: db)[id] ?? []
        let criteria = try await AcceptanceCriterion.query(on: db).filter(\.$taskID == id).sort(\.$id).all()
        let notes = try await TaskProgressNote.query(on: db).filter(\.$taskID == id).sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(20).all()
        let progress = ProgressCalc.compute(task: task, children: children, criteria: criteria, latestPercent: notes.first(where: { $0.percent != nil })?.percent)
        let comments = try await TaskComment.query(on: db).filter(\.$taskID == id).sort(\.$id).all()
        let names = try await displayNames(comments.map(\.authorID), on: db)
        let questions = try await TaskQuestion.query(on: db).filter(\.$taskID == id).sort(\.$createdAt).sort(\.$id).all()
        let review = try await TaskReview.query(on: db).filter(\.$taskID == id).sort(\.$createdAt, .descending).sort(\.$id, .descending).first()
        let wfDTO = Self.dto(wf ?? TaskWorkflow(taskID: id), hasChildren: !children.isEmpty)
        return TaskContextDTO(task: try TaskDTO(task), projectID: task.projectID, workflow: wfDTO, progress: progress,
            progressNotes: try notes.map(ProgressNoteDTO.init), criteria: try criteria.map(CriterionDTO.init),
            subtasks: try children.map(TaskDTO.init),
            comments: try comments.map { var c = try CommentDTO($0); c.authorName = names[$0.authorID]; return c },
            questions: try questions.map(QuestionDTO.init), review: try review.map(ReviewDTO.init),
            builds: try await Self.builds(of: [id], on: db)[id] ?? [])
    }

    /// Children (subtasks) per parent id.
    static func children(of parents: [UUID], on db: any Database) async throws -> [UUID: [TodoTask]] {
        guard !parents.isEmpty else { return [:] }
        let links = try await TaskWorkflow.query(on: db).filter(\.$parentTaskID ~~ parents).all()
        guard !links.isEmpty else { return [:] }
        let tasks = try await TodoTask.query(on: db).filter(\.$id ~~ links.map { $0.id! }).sort(\.$createdAt).sort(\.$id).all()
        var result: [UUID: [TodoTask]] = [:]
        let parentOf = Dictionary(uniqueKeysWithValues: links.map { ($0.id!, $0.parentTaskID!) })
        for task in tasks { if let p = parentOf[task.id!] { result[p, default: []].append(task) } }
        return result
    }
}

enum ProgressCalc {
    static func compute(task: TodoTask, children: [TodoTask], criteria: [AcceptanceCriterion], latestPercent: Int?) -> ProgressDTO {
        let subDone = children.filter { $0.status == "done" }.count
        let critDone = criteria.filter(\.completed).count
        func dto(_ percent: Int, _ source: String) -> ProgressDTO {
            ProgressDTO(percent: max(0, min(100, percent)), source: source, subtasksDone: subDone, subtasksTotal: children.count,
                criteriaDone: critDone, criteriaTotal: criteria.count)
        }
        if task.status == "done" { return dto(100, "status") }
        if !children.isEmpty { return dto(Int((Double(subDone) / Double(children.count) * 100).rounded()), "subtasks") }
        if !criteria.isEmpty { return dto(Int((Double(critDone) / Double(criteria.count) * 100).rounded()), "criteria") }
        if let latestPercent { return dto(latestPercent, "agent") }
        return dto(0, "none")
    }
}

// MARK: - Mirrors for the runner flow (called inside AgentService transactions; caller holds its locks)

enum WorkflowMirror {
    static func runnerAsked(_ question: AgentQuestion, runID: UUID, on db: any Database) async throws {
        let q = TaskQuestion()
        q.taskID = question.taskID; q.askedByType = .run; q.askedByID = runID; q.askedByLabel = "Runner"
        q.prompt = question.prompt; q.options = question.options; q.blocking = true; q.state = "open"
        q.agentQuestionID = try question.requireID(); q.version = 1
        try await q.save(on: db)
    }

    static func runnerAnswered(agentQuestionID: UUID, value: String, userID: UUID, on db: any Database) async throws {
        guard let q = try await TaskQuestion.query(on: db).filter(\.$agentQuestionID == agentQuestionID).first(), q.state == "open" else { return }
        q.state = "answered"; q.answer = value; q.answeredBy = userID; q.answeredVia = "runner"; q.answeredAt = Date(); q.version += 1
        try await q.save(on: db)
    }

    /// Job ended without an answer: open mirrors become withdrawn.
    static func runnerWithdrawn(jobID: UUID, on db: any Database) async throws {
        let ids = try await AgentQuestion.query(on: db).filter(\.$jobID == jobID).all().map { try $0.requireID() }
        guard !ids.isEmpty else { return }
        for q in try await TaskQuestion.query(on: db).filter(\.$agentQuestionID ~~ ids).filter(\.$state == "open").all() {
            q.state = "withdrawn"; q.version += 1
            try await q.save(on: db)
            try await appendLockedActivity(taskID: q.taskID, actorType: .run, actorID: q.askedByID, kind: "question.withdrawn", subjectID: q.id, on: db)
        }
        for r in try await TaskReview.query(on: db).filter(\.$agentJobID == jobID).filter(\.$state == "pending").all() {
            r.state = "withdrawn"; r.version += 1
            try await r.save(on: db)
        }
    }

    static func runnerSubmitted(job: AgentJob, runID: UUID, summary: String, on db: any Database) async throws {
        let r = TaskReview()
        r.taskID = job.taskID; r.state = "pending"; r.requestedByType = .run; r.requestedByID = runID; r.requestedByLabel = "Runner"
        r.summary = summary; r.agentJobID = try job.requireID(); r.version = 1
        try await r.save(on: db)
    }

    /// Human decision on a runner job. Like the runner flow itself it leaves the task status to the person.
    static func runnerDecided(job: AgentJob, accepted: Bool, user: User, on db: any Database) async throws {
        let jobID = try job.requireID()
        for r in try await TaskReview.query(on: db).filter(\.$agentJobID == jobID).filter(\.$state == "pending").all() {
            r.state = accepted ? "accepted" : "changes_requested"; r.decidedBy = user.id; r.decidedAt = Date(); r.version += 1
            try await r.save(on: db)
        }
    }
}
