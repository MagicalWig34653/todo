import Fluent
import Vapor

extension ProjectAccess {
    /// Agent execution is an independent capability; edit access must never imply it. It belongs to the *current*
    /// owner (ProjectSharing owner, or the admin of the owning team), never to the creator field of the project.
    func startAgent(in projectID: UUID) async throws -> Project {
        let project = try await project(projectID)
        guard try await SharingAccess(user: user, db: db).visibility(project).canTransferOwnership else { throw Abort(.forbidden) }
        return project
    }
}

struct AgentCheckpointInput: Content {
    let contextRevision: Int
    let sessionReference: String
    let nextStep: String
}

struct AgentResult: Content {
    let summary: String
    let references: [String]
    let checks: [String]
    let limitations: [String]
}

struct AgentRunCommand: Content {
    let generation: Int
    let progress: String?
    let checkpoint: AgentCheckpointInput?
    let prompt: String?
    let options: [String]?
    let result: AgentResult?
    /// Pipeline jobs only (submit): `passed` or `failed`, and the plan of a passed planner step.
    var outcome: String? = nil
    var plan: String? = nil
    /// Reconciliation is an observation by the local runner, never an instruction to restart.
    let observation: String?
}

struct AgentJobDTO: Content {
    let id: UUID
    let taskID: UUID
    let projectID: UUID
    let bindingID: UUID
    let requestedBy: UUID
    let taskRevision: Int
    let previousJobID: UUID?
    let mode: String
    let scope: String
    let state: String
    let progress: String
    let result: AgentResult?
    /// Present only on jobs of a pipeline execution.
    let pipelineStep: String?
    let pipelineExecutionID: UUID?
    init(_ job: AgentJob) throws {
        id = try job.requireID(); taskID = job.taskID; projectID = job.projectID
        bindingID = job.bindingID; requestedBy = job.requestedBy; taskRevision = job.taskRevision
        previousJobID = job.previousJobID
        pipelineStep = job.pipelineStep; pipelineExecutionID = job.pipelineExecutionID
        mode = job.mode; scope = job.scope; state = job.state; progress = job.progress
        result = try job.result.map { try JSONDecoder().decode(AgentResult.self, from: Data($0.utf8)) }
    }
}

struct AgentRunDTO: Content {
    let id: UUID
    let job: AgentJobDTO
    let generation: Int
    let leaseUntil: Date
    let endedAt: Date?
    let checkpoint: AgentCheckpointInput?
    init(_ run: AgentRun, job: AgentJob, on db: any Database) async throws {
        id = try run.requireID(); self.job = try AgentJobDTO(job)
        generation = run.generation; leaseUntil = run.leaseUntil; endedAt = run.endedAt
        let saved = try await AgentCheckpoint.query(on: db).filter(\.$runID == id).first()
        checkpoint = saved.map { .init(contextRevision: $0.contextRevision, sessionReference: $0.sessionReference, nextStep: $0.nextStep) }
    }
}

struct AgentService {
    static let leaseDuration: TimeInterval = 90

    /// Called inside the ownership-transfer transaction (after the new owner is stored). Runner capabilities of anyone who
    /// no longer owns the project end now: their open jobs are cancelled and their runs fenced (the repository slot stays
    /// occupied until the runner confirms termination, like a human stop), and bindings nothing refers to are removed.
    /// Bindings with history stay as inert rows: every later use re-checks the current owner.
    static func revokeRunnerAccess(projectID: UUID, on db: any Database) async throws {
        guard let project = try await Project.find(projectID, on: db) else { return }
        let bindings = try await ProjectRunnerBinding.query(on: db).filter(\.$projectID == projectID).all()
        for binding in bindings {
            let bindingID = try binding.requireID()
            if let device = try await RunnerDevice.find(binding.deviceID, on: db), let owner = try await User.find(device.ownerID, on: db),
               try await SharingAccess(user: owner, db: db).visibility(project).canTransferOwnership { continue }
            let jobs = try await AgentJob.query(on: db).filter(\.$bindingID == bindingID).all()
            for job in jobs where ["queued", "claimed", "running", "waiting_for_answer"].contains(job.state) {
                job.state = "cancelled"
                try await WorkflowMirror.runnerWithdrawn(jobID: job.requireID(), on: db)
                for run in try await AgentRun.query(on: db).filter(\.$jobID == job.requireID()).filter(\.$endedAt == nil).all() {
                    run.generation += 1; run.leaseUntil = Date()
                    try await run.save(on: db)
                }
                try await job.save(on: db)
                try await event(job, kind: "owner_changed", on: db)
            }
            try await PipelineExecution.stopAll(bindingIDs: [bindingID], on: db)
            if jobs.isEmpty, try await AgentRun.query(on: db).filter(\.$bindingID == bindingID).count() == 0 { try await binding.delete(on: db) }
        }
    }

    static func text(_ value: String, max: Int = 4000) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= max else {
            throw Abort(.badRequest, reason: "invalid_agent_text")
        }
        return value
    }

    static func event(_ job: AgentJob, run: AgentRun? = nil, kind: String, detail: String = "", on db: any Database) async throws {
        try await AgentEvent(jobID: job.requireID(), runID: run?.id, kind: kind, detail: detail, createdAt: Date()).save(on: db)
    }

    static func authorized(_ binding: ProjectRunnerBinding, device: RunnerDevice, on db: any Database) async throws {
        guard binding.deviceID == device.id, device.revokedAt == nil,
              let user = try await User.find(device.ownerID, on: db) else { throw Abort(.notFound) }
        _ = try await ProjectAccess(user: user, db: db).startAgent(in: binding.projectID)
    }

    /// Non-throwing variant for runner lists: bindings of projects the device owner may no longer start agents in
    /// (for example after an ownership transfer) are left out instead of failing the whole list.
    static func isAuthorized(_ binding: ProjectRunnerBinding, device: RunnerDevice, on db: any Database) async throws -> Bool {
        do { try await authorized(binding, device: device, on: db); return true }
        catch let e as Abort where e.status == .notFound || e.status == .forbidden { return false }
    }

    /// The device row serializes claims across bindings referring to the same local repository.
    /// An expired run keeps its slot until a runner explicitly confirms that the process stopped.
    /// `pipeline` is true when the runner asked with `?pipeline=1`; only such a runner may take a pipeline job.
    static func claim(jobID: UUID, deviceID: UUID, pipeline: Bool = false, on database: any Database) async throws -> AgentRunDTO {
        // Read outside the transaction: the task lock has to come before the first consistent read.
        let pipelineTask = try await AgentJob.find(jobID, on: database).flatMap { $0.pipelineExecutionID == nil ? nil : $0.taskID }
        let outcome: ClaimOutcome = try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: db)
            if let pipelineTask { try await lockRow(table: TodoTask.schema, id: pipelineTask, on: db) }
            guard let device = try await RunnerDevice.find(deviceID, on: db), device.revokedAt == nil,
                  let job = try await AgentJob.find(jobID, on: db),
                  let binding = try await ProjectRunnerBinding.find(job.bindingID, on: db) else { throw Abort(.notFound) }
            try await authorized(binding, device: device, on: db)
            guard job.state == "queued" else { throw Abort(.conflict, reason: "job_not_queued") }
            if job.pipelineExecutionID != nil, !pipeline { throw Abort(.conflict, reason: "pipeline_runner_required") }
            let bindings = try await ProjectRunnerBinding.query(on: db).filter(\.$deviceID == deviceID)
                .filter(\.$repositoryKey == binding.repositoryKey).all()
            let ids = try bindings.map { try $0.requireID() }
            guard try await AgentRun.query(on: db).filter(\.$bindingID ~~ ids).filter(\.$endedAt == nil).count() == 0 else {
                throw Abort(.conflict, reason: "repository_busy_reconcile_first")
            }
            guard let task = try await TodoTask.find(job.taskID, on: db), task.projectID == job.projectID else {
                throw Abort(.conflict, reason: "task_revision_changed")
            }
            if job.pipelineExecutionID != nil {
                // The card content counts, not its revision. A refused job is cancelled, so the transaction commits.
                if let reason = try await PipelineExecution.refuseClaim(job, task: task, on: db) { return .refused(reason) }
                job.taskRevision = task.version
            } else {
                guard task.version == job.taskRevision else { throw Abort(.conflict, reason: "task_revision_changed") }
            }
            let run = try AgentRun(jobID: jobID, bindingID: binding.requireID(), deviceID: deviceID,
                               generation: 1, leaseUntil: Date().addingTimeInterval(leaseDuration), endedAt: nil)
            try await run.save(on: db)
            job.state = "claimed"
            job.progress = ""
            try await job.save(on: db)
            try await event(job, run: run, kind: "claimed", on: db)
            try await appendLockedActivity(taskID: job.taskID, actorType: .run, actorID: run.requireID(), kind: "agent.claimed", subjectID: job.id, on: db)
            if let step = job.pipelineStep.flatMap(PipelineStepName.init(rawValue:)) {
                try await PipelineExecution.changeStep(job.taskID, step, state: PipelineStepState.running, note: nil,
                    actor: PipelineExecution.runActor(run.requireID()), on: db)
            }
            return .claimed(try await AgentRunDTO(run, job: job, on: db))
        }
        switch outcome {
        case .claimed(let run): return run
        case .refused(let reason): throw Abort(.conflict, reason: reason)
        }
    }

    private enum ClaimOutcome: Sendable {
        case claimed(AgentRunDTO)
        case refused(String)
    }

    /// A waiting job the runner cannot take right now (for example the budget brake): the reason becomes its progress.
    static func hold(jobID: UUID, deviceID: UUID, reason: String, on database: any Database) async throws -> AgentJobDTO {
        let value = SecretFilter.redact(try text(reason, max: PipelineExecution.maxHold)).text
        return try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: db)
            guard let device = try await RunnerDevice.find(deviceID, on: db), device.revokedAt == nil,
                  let job = try await AgentJob.find(jobID, on: db),
                  let binding = try await ProjectRunnerBinding.find(job.bindingID, on: db) else { throw Abort(.notFound) }
            try await authorized(binding, device: device, on: db)
            guard job.state == "queued" else { throw Abort(.conflict, reason: "job_not_queued") }
            if job.progress != value {
                job.progress = value
                try await job.save(on: db)
                try await event(job, kind: "held", detail: value, on: db)
            }
            return try AgentJobDTO(job)
        }
    }

    static func command(runID: UUID, deviceID: UUID, action: String, body: AgentRunCommand, on database: any Database) async throws -> AgentRunDTO {
        var pipelineTask: UUID?
        if let initial = try await AgentRun.find(runID, on: database), initial.deviceID == deviceID,
           let job = try await AgentJob.find(initial.jobID, on: database), job.pipelineExecutionID != nil { pipelineTask = job.taskID }
        let lockedTask = pipelineTask
        return try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: db)
            if let lockedTask { try await lockRow(table: TodoTask.schema, id: lockedTask, on: db) }
            guard let device = try await RunnerDevice.find(deviceID, on: db), device.revokedAt == nil,
                  let run = try await AgentRun.find(runID, on: db), run.deviceID == deviceID,
                  let job = try await AgentJob.find(run.jobID, on: db),
                  let binding = try await ProjectRunnerBinding.find(run.bindingID, on: db) else { throw Abort(.notFound) }
            if action == "reconcile", body.observation == "stopped" {
                // Confirming that the process ended needs no project right: after an ownership transfer the former owner's
                // device must still be able to free the repository slot. Only the device's own run is touched.
                guard binding.deviceID == device.id else { throw Abort(.notFound) }
            } else {
                try await authorized(binding, device: device, on: db)
            }
            guard let task = try await TodoTask.find(job.taskID, on: db), task.projectID == job.projectID else { throw Abort(.notFound) }
            guard run.generation == body.generation else { throw Abort(.conflict, reason: "stale_generation") }
            guard run.endedAt == nil else { throw Abort(.gone, reason: "run_ended") }
            // What the pipeline has to do once the job is saved.
            var afterwards: (@Sendable () async throws -> Void)?
            let isPipeline = job.pipelineExecutionID != nil
            if action == "reconcile" {
                guard ["alive", "paused", "stopped"].contains(body.observation ?? "") else { throw Abort(.badRequest) }
                if body.observation == "stopped" {
                    run.endedAt = Date()
                    let wasOpen = PipelineExecution.openJobStates.contains(job.state)
                    if job.state != "cancelled" { job.state = "failed" }
                    try await WorkflowMirror.runnerWithdrawn(jobID: job.requireID(), on: db)
                    if isPipeline, wasOpen { afterwards = { try await PipelineExecution.failed(job, runID: runID, on: db) } }
                } else {
                    guard job.state != "cancelled" else { throw Abort(.gone, reason: "stop_local_process") }
                    if body.observation == "paused" {
                        guard job.state == "waiting_for_answer",
                              try await AgentCheckpoint.query(on: db).filter(\.$runID == runID).first() != nil else {
                            throw Abort(.conflict, reason: "no_durable_question_pause")
                        }
                    }
                    run.leaseUntil = Date().addingTimeInterval(leaseDuration)
                }
                run.generation += 1
            } else {
                guard run.leaseUntil > Date(), job.state != "cancelled" else { throw Abort(.gone, reason: "lease_lost_reconcile_first") }
                switch action {
                case "heartbeat":
                    run.leaseUntil = Date().addingTimeInterval(leaseDuration)
                case "progress":
                    guard ["claimed", "running"].contains(job.state), let progress = body.progress else { throw Abort(.conflict) }
                    job.progress = try text(progress)
                    job.state = "running"
                case "checkpoint":
                    guard let input = body.checkpoint, input.contextRevision >= job.taskRevision else { throw Abort(.badRequest) }
                    let saved = try await AgentCheckpoint.query(on: db).filter(\.$runID == runID).first()
                    if let saved, input.contextRevision < saved.contextRevision { throw Abort(.conflict, reason: "context_revision_regressed") }
                    let checkpoint = saved ?? AgentCheckpoint(runID: runID, contextRevision: input.contextRevision,
                        sessionReference: "", nextStep: "")
                    checkpoint.contextRevision = input.contextRevision
                    checkpoint.sessionReference = try text(input.sessionReference, max: 200)
                    checkpoint.nextStep = try text(input.nextStep)
                    try await checkpoint.save(on: db)
                case "question":
                    guard ["claimed", "running"].contains(job.state), let prompt = body.prompt else { throw Abort(.conflict) }
                    let options = body.options ?? []
                    guard options.count <= 20 else { throw Abort(.badRequest) }
                    for option in options { _ = try text(option, max: 500) }
                    let asked = try AgentQuestion(jobID: job.requireID(), taskID: job.taskID, prompt: text(prompt), options: options)
                    try await asked.save(on: db)
                    try await WorkflowMirror.runnerAsked(asked, runID: runID, on: db)
                    job.state = "waiting_for_answer"
                case "resume":
                    guard job.state == "waiting_for_answer" else { throw Abort(.conflict) }
                    let questions = try await AgentQuestion.query(on: db).filter(\.$jobID == run.jobID).all()
                    for question in questions {
                        guard try await AgentAnswer.query(on: db).filter(\.$questionID == question.requireID()).first() != nil else {
                            throw Abort(.conflict, reason: "answer_required")
                        }
                    }
                    job.state = "running"
                case "submit":
                    guard ["claimed", "running"].contains(job.state), let result = body.result else { throw Abort(.conflict) }
                    _ = try text(result.summary)
                    guard result.references.count + result.checks.count + result.limitations.count <= 100 else { throw Abort(.badRequest) }
                    for value in result.references + result.checks + result.limitations { _ = try text(value) }
                    job.result = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                    run.endedAt = Date()
                    if isPipeline {
                        let submission = try PipelineExecution.Submission(step: job.pipelineStep, outcome: body.outcome, plan: body.plan,
                            summary: result.summary)
                        let trigger = try await PipelineExecution.submitted(job, runID: runID, submission, on: db)
                        let taskID = job.taskID
                        afterwards = { try await PipelineExecution.advance(taskID, trigger, on: db) }
                    } else {
                        try await WorkflowMirror.runnerSubmitted(job: job, runID: runID, summary: result.summary, on: db)
                        job.state = "awaiting_review"
                    }
                case "stop", "fail":
                    job.state = action == "stop" ? "cancelled" : "failed"
                    run.endedAt = Date()
                    try await WorkflowMirror.runnerWithdrawn(jobID: job.requireID(), on: db)
                    if isPipeline {
                        if action == "fail" {
                            afterwards = { try await PipelineExecution.failed(job, runID: runID, on: db) }
                        } else {
                            afterwards = {
                                guard let execution = try await PipelineExecution.active(of: job, on: db) else { return }
                                try await PipelineExecution.stop(execution, actor: PipelineExecution.runActor(runID), on: db)
                            }
                        }
                    }
                default: throw Abort(.notFound)
                }
            }
            try await run.save(on: db)
            try await job.save(on: db)
            try await afterwards?()
            // Heartbeats and replaceable progress do not create a permanent log stream.
            if !["heartbeat", "progress"].contains(action) {
                try await event(job, run: run, kind: action, detail: body.observation ?? "", on: db)
                // Task timeline: only milestones a person cares about, not checkpoints or reconciliation.
                if ["question", "resume", "submit", "stop", "fail"].contains(action) {
                    try await appendLockedActivity(taskID: job.taskID, actorType: .run, actorID: run.requireID(), kind: "agent.\(action)", subjectID: job.id, on: db)
                }
            }
            return try await AgentRunDTO(run, job: job, on: db)
        }
    }
}

// Human and integration entry points share these capability and transition checks.
extension AgentService {
    static func humanJob(_ id: UUID, user: User, on db: any Database) async throws -> AgentJob {
        guard let job = try await AgentJob.find(id, on: db) else { throw Abort(.notFound) }
        let access = ProjectAccess(user: user, db: db)
        _ = try await access.startAgent(in: job.projectID)
        let task = try await access.task(job.taskID)
        guard task.projectID == job.projectID else { throw Abort(.notFound) }
        return job
    }

    /// `origin == .scheduler` is the guard (ADR 0033): it needs the connection (`integrationGrant`), the account switch,
    /// the card's one-time permission, a card that is not done and not blocked. A retry with the same `body.id` returns
    /// the existing job before any of that is evaluated (the permission is consumed by the first start).
    static func release(_ body: ReleaseJobRequest, user: User, origin: ReleaseOrigin = .manual, integrationGrant: UUID? = nil,
                        on database: any Database) async throws -> AgentJobDTO {
        guard ["clarify", "implement"].contains(body.mode) else { throw Abort(.badRequest) }
        guard origin == .manual || integrationGrant != nil else { throw Abort(.forbidden, reason: "scheduler_requires_connection") }
        guard let initialBinding = try await ProjectRunnerBinding.find(body.bindingID, on: database) else { throw Abort(.notFound) }
        return try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: initialBinding.deviceID, on: db)
            guard let binding = try await ProjectRunnerBinding.find(body.bindingID, on: db) else { throw Abort(.notFound) }
            let access = ProjectAccess(user: user, db: db)
            _ = try await access.startAgent(in: binding.projectID)
            let task = try await access.task(body.taskID)
            guard task.projectID == binding.projectID else { throw Abort(.notFound) }
            guard let device = try await RunnerDevice.find(binding.deviceID, on: db), device.ownerID == user.id,
                  device.revokedAt == nil else { throw Abort(.notFound) }
            if let existing = try await AgentJob.find(body.id, on: db) {
                guard existing.requestedBy == user.id, existing.taskID == body.taskID, existing.bindingID == body.bindingID,
                      existing.previousJobID == body.previousJobID, existing.taskRevision == body.taskRevision, existing.mode == body.mode, existing.scope == body.scope else {
                    throw Abort(.conflict, reason: "release_id_conflict")
                }
                return try AgentJobDTO(existing)
            }
            if let previousID = body.previousJobID {
                let previous = try await humanJob(previousID, user: user, on: db)
                guard previous.taskID == body.taskID, ["succeeded", "failed", "cancelled"].contains(previous.state) else {
                    throw Abort(.conflict, reason: "invalid_previous_job")
                }
            }
            guard task.version == body.taskRevision else { throw Abort(.conflict, reason: "task_revision_changed") }
            // Serialize with revocation and enabling of the card permission (device lock is always taken first).
            try await lockRow(table: TodoTask.schema, id: body.taskID, on: db)
            let planning = try await TaskPlanning.find(body.taskID, on: db)
            if origin == .scheduler {
                guard try await AutoStartService.accountAllowed(userID: user.requireID(), on: db) else {
                    throw Abort(.forbidden, reason: "auto_start_disabled_for_account")
                }
                guard let planning, planning.autoStart, planning.plannedAt != nil, !planning.plannedAllDay else {
                    throw Abort(.conflict, reason: "auto_start_not_enabled")
                }
                guard task.status != "done" else { throw Abort(.conflict, reason: "task_done") }
                guard try await !PlanningService(user: user, db: db).blocked(body.taskID) else { throw Abort(.conflict, reason: "task_blocked") }
            }
            let job = try AgentJob(taskID: body.taskID, projectID: binding.projectID, bindingID: body.bindingID,
                requestedBy: user.requireID(), previousJobID: body.previousJobID, taskRevision: body.taskRevision, mode: body.mode,
                scope: AgentService.text(body.scope), state: "queued", progress: "", result: nil)
            job.id = body.id
            do {
                try await job.create(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(.conflict, reason: "release_id_conflict")
            }
            let now = Date()
            var detail = ""
            if origin == .scheduler, let plannedAt = planning?.plannedAt {
                let delay = max(0, Int(now.timeIntervalSince(plannedAt) / 60))
                let catchup = now.timeIntervalSince(plannedAt) > AutoStartService.catchupSeconds
                let object: [String: Any] = ["origin": origin.rawValue, "catchup": catchup, "delayMinutes": delay,
                                             "plannedAt": ISO8601DateFormatter().string(from: plannedAt)]
                detail = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            }
            try await AgentService.event(job, kind: "released", detail: detail, on: db)
            // Hand-over consumes the one-time permission, whoever started. Only the guard sets the automatic start time.
            if let planning, planning.autoStart {
                planning.autoStart = false
                if origin == .scheduler { planning.autoStartedAt = now }
                try await planning.save(on: db)
            }
            try await appendLockedActivity(taskID: job.taskID, actorType: integrationGrant == nil ? .person : .integration,
                actorID: integrationGrant ?? user.requireID(), kind: "agent.released", subjectID: job.id, on: db)
            return try AgentJobDTO(job)
        }
    }

    static func humanTransition(jobID: UUID, decision: String, user: User, on database: any Database) async throws -> AgentJobDTO {
        guard ["stop", "accept", "request_changes"].contains(decision) else { throw Abort(.badRequest) }
        let initial = try await humanJob(jobID, user: user, on: database)
        guard let binding = try await ProjectRunnerBinding.find(initial.bindingID, on: database) else { throw Abort(.notFound) }
        let pipelineTask = initial.pipelineExecutionID == nil ? nil : initial.taskID
        return try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: binding.deviceID, on: db)
            if let pipelineTask { try await lockRow(table: TodoTask.schema, id: pipelineTask, on: db) }
            let job = try await humanJob(jobID, user: user, on: db)
            if decision == "stop" {
                guard ["queued", "claimed", "running", "waiting_for_answer"].contains(job.state) else { throw Abort(.conflict) }
                job.state = "cancelled"
                try await WorkflowMirror.runnerWithdrawn(jobID: jobID, on: db)
                // Keep the slot occupied until local termination is confirmed by reconciliation.
                for run in try await AgentRun.query(on: db).filter(\.$jobID == jobID).filter(\.$endedAt == nil).all() {
                    run.generation += 1; run.leaseUntil = Date()
                    try await run.save(on: db)
                }
            } else {
                guard job.state == "awaiting_review" else { throw Abort(.conflict) }
                job.state = decision == "accept" ? "succeeded" : "failed"
                try await WorkflowMirror.runnerDecided(job: job, accepted: decision == "accept", user: user, on: db)
            }
            try await job.save(on: db)
            if decision == "stop", let execution = try await PipelineExecution.active(of: job, on: db) {
                try await PipelineExecution.stop(execution, actor: .person(user), on: db)
            }
            try await AgentService.event(job, kind: decision, detail: try user.requireID().uuidString, on: db)
            try await appendLockedActivity(taskID: job.taskID, actorType: .person, actorID: user.requireID(), kind: "agent.\(decision)", subjectID: job.id, on: db)
            return try AgentJobDTO(job)
        }
    }

    static func answer(questionID: UUID, value: String, user: User, freeText: Bool = false, on database: any Database) async throws -> AgentDetail {
        guard let question = try await AgentQuestion.find(questionID, on: database) else { throw Abort(.notFound) }
        let initial = try await humanJob(question.jobID, user: user, on: database)
        guard let binding = try await ProjectRunnerBinding.find(initial.bindingID, on: database) else { throw Abort(.notFound) }
        return try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: binding.deviceID, on: db)
            let job = try await humanJob(question.jobID, user: user, on: db)
            if let existing = try await AgentAnswer.query(on: db).filter(\.$questionID == questionID).first() {
                guard existing.value == value, existing.authorID == user.id else { throw Abort(.conflict, reason: "answer_already_given") }
            } else {
                guard job.state == "waiting_for_answer" else { throw Abort(.conflict) }
                if !freeText, !question.options.isEmpty, !question.options.contains(value) { throw Abort(.badRequest, reason: "invalid_answer_option") }
                try await AgentAnswer(questionID: questionID, authorID: user.requireID(), value: AgentService.text(value)).save(on: db)
                try await WorkflowMirror.runnerAnswered(agentQuestionID: questionID, value: value, userID: user.requireID(), on: db)
                try await AgentService.event(job, kind: "answered", detail: questionID.uuidString, on: db)
                try await appendLockedActivity(taskID: job.taskID, actorType: .person, actorID: user.requireID(), kind: "agent.answered", subjectID: questionID, on: db)
            }
            return try await AgentDetail(job, on: db)
        }
    }
}
