import Crypto
import Fluent
import Vapor

/// What caused `advance`, and whether it may queue a job. Only the start right queues work: a person who may start agents,
/// the explicit start or continuation, or the execution itself after one of its jobs. Edit rights never do.
struct ExecutionTrigger: Sendable {
    let actor: WorkflowActor
    let mayStart: Bool
    /// A finished pipeline job: it never repeats a step that already ran for this plan version.
    var automatic = false
}

/// The execution of a card pipeline (docs/PLAN-PIPELINE-STUFE-3.md §2). `advance` is the only place that queues jobs.
/// Every method expects a transaction that holds the task row lock.
enum PipelineExecution {
    static let openJobStates = ["queued", "claimed", "running", "waiting_for_answer"]
    static let workSteps: [PipelineStepName] = [.developer, .validation, .tester, .review]
    static let failedNote = "Lauf abgebrochen oder fehlgeschlagen"
    static let runnerLabel = "Runner"
    static let maxHold = 200

    static func runActor(_ runID: UUID) -> WorkflowActor { WorkflowActor(type: .run, id: runID, label: runnerLabel, via: "runner") }

    /// Stops without a person behind them (lost access, revoked device, locked account).
    static func systemActor(_ id: UUID) -> WorkflowActor { WorkflowActor(type: .run, id: id, label: "System", via: "runner") }

    static func contentHash(_ task: TodoTask) -> String {
        SHA256.hash(data: Data("\(task.title)\u{0}\(task.details)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func find(_ taskID: UUID, on db: any Database) async throws -> TaskPipelineExecution? {
        try await TaskPipelineExecution.query(on: db).filter(\.$taskID == taskID).first()
    }

    /// The execution a job belongs to, as long as it still is the active one of its card.
    static func active(of job: AgentJob, on db: any Database) async throws -> TaskPipelineExecution? {
        guard let id = job.pipelineExecutionID, let execution = try await TaskPipelineExecution.find(id, on: db),
              execution.isActive, execution.taskID == job.taskID else { return nil }
        return execution
    }

    static func openJob(_ executionID: UUID, on db: any Database) async throws -> AgentJob? {
        try await AgentJob.query(on: db).filter(\.$pipelineExecutionID == executionID).filter(\.$state ~~ openJobStates).first()
    }

    static func canStart(_ user: User, projectID: UUID, on db: any Database) async throws -> Bool {
        do { _ = try await ProjectAccess(user: user, db: db).startAgent(in: projectID); return true }
        catch let error as Abort where error.status == .notFound || error.status == .forbidden { return false }
    }

    private static func stepRow(_ taskID: UUID, _ step: PipelineStepName, on db: any Database) async throws -> TaskPipelineStep? {
        try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).filter(\.$step == step.rawValue).first()
    }

    private static func plan(_ taskID: UUID, on db: any Database) async throws -> TaskPlan? {
        try await TaskPlan.query(on: db).filter(\.$taskID == taskID).first()
    }

    /// Saves only a real change.
    private static func set(_ execution: TaskPipelineExecution, _ state: String, reason: String? = nil, step: PipelineStepName?,
                            on db: any Database) async throws {
        if execution.state == state, execution.reason == reason, execution.step == step?.rawValue { return }
        execution.state = state; execution.reason = reason; execution.step = step?.rawValue; execution.updatedAt = Date()
        try await execution.save(on: db)
    }

    /// Audit entry of the card pipeline plus, for what a person or runner decides about the execution, the card activity.
    static func record(_ execution: TaskPipelineExecution, action: String, actor: WorkflowActor, activity: Bool, on db: any Database) async throws {
        let version = try await plan(execution.taskID, on: db)?.version
        let event = try await WorkflowService.audit(execution.taskID, action: action, planVersion: version, label: actor.label,
            actor: actor, at: Date(), on: db)
        if activity {
            try await appendActivity(taskID: execution.taskID, actorType: actor.type, actorID: actor.id, kind: "pipeline.execution",
                subjectID: event.id, on: db)
        }
    }

    /// A step change made by the execution (shown like any other step change, actor "Runner").
    static func changeStep(_ taskID: UUID, _ step: PipelineStepName, state: String, note: String?, actor: WorkflowActor,
                           on db: any Database) async throws {
        let version = try await plan(taskID, on: db)?.version
        let now = Date()
        let row = try await WorkflowService.saveStep(taskID, step, state: state, note: note, planVersion: version, label: actor.label,
            actor: actor, at: now, on: db)
        try await WorkflowService.audit(taskID, action: "step_changed", planVersion: version, step: step.rawValue, state: state,
            note: note, label: actor.label, actor: actor, at: now, on: db)
        try await appendActivity(taskID: taskID, actorType: actor.type, actorID: actor.id, kind: "pipeline.step", subjectID: row.id, on: db)
    }

    static func advance(_ taskID: UUID, _ trigger: ExecutionTrigger, on db: any Database) async throws {
        guard let execution = try await find(taskID, on: db), execution.isActive else { return }
        guard let task = try await TodoTask.find(taskID, on: db), task.projectID == execution.projectID else {
            return try await stop(execution, actor: trigger.actor, on: db)
        }
        let executionID = try execution.requireID()
        guard try await openJob(executionID, on: db) == nil else { return }
        let settings = try await PipelineSettingsStore.values(task.projectID, on: db)
        let plan = try await plan(taskID, on: db)
        let rows = try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).all()
        let states = Dictionary(rows.map { ($0.step, $0.state) }, uniquingKeysWith: { first, _ in first })
        func block(_ step: PipelineStepName) async throws {
            let used = try await WorkflowService.fixRoundsUsed(taskID, planVersion: plan?.version, on: db)
            try await set(execution, ExecutionState.blocked,
                reason: used >= settings.maxFixRounds ? ExecutionReason.fixRoundsExhausted : ExecutionReason.stepFailed, step: step, on: db)
        }
        if settings.enabled(.planner) {
            if states[PipelineStepName.planner.rawValue] == PipelineStepState.failed { return try await block(.planner) }
            if plan == nil || plan?.state == PlanState.changesRequested {
                return try await enqueue(.planner, execution: execution, task: task, planVersion: plan?.version, trigger: trigger, on: db)
            }
            if plan?.state == PlanState.proposed {
                return try await set(execution, ExecutionState.waitingApproval, step: .approval, on: db)
            }
        }
        for step in workSteps where settings.enabled(step) {
            let state = states[step.rawValue] ?? PipelineStepState.pending
            if state == PipelineStepState.done || state == PipelineStepState.skipped { continue }
            if state == PipelineStepState.failed { return try await block(step) }
            if settings.enabled(.planner), plan == nil || execution.acceptedPlanVersion != plan?.version {
                return try await set(execution, ExecutionState.paused, reason: ExecutionReason.planNeedsOwner, step: step, on: db)
            }
            if contentHash(task) != execution.contentHash {
                return try await set(execution, ExecutionState.paused, reason: ExecutionReason.taskChanged, step: step, on: db)
            }
            return try await enqueue(step, execution: execution, task: task, planVersion: plan?.version, trigger: trigger, on: db)
        }
        try await set(execution, ExecutionState.completed, step: nil, on: db)
        try await record(execution, action: "execution_completed", actor: trigger.actor, activity: false, on: db)
    }

    private static func enqueue(_ step: PipelineStepName, execution: TaskPipelineExecution, task: TodoTask, planVersion: Int?,
                                trigger: ExecutionTrigger, on db: any Database) async throws {
        let executionID = try execution.requireID(), taskID = try task.requireID()
        var allowed = trigger.mayStart
        if allowed, trigger.automatic {
            let earlier = try await AgentJob.query(on: db).filter(\.$pipelineExecutionID == executionID)
                .filter(\.$pipelineStep == step.rawValue).filter(\.$state ~~ ["succeeded", "failed", "awaiting_review"]).all()
            allowed = !earlier.contains { $0.pipelinePlanVersion == planVersion }
        }
        guard allowed else {
            return try await set(execution, ExecutionState.paused, reason: ExecutionReason.continueRequired, step: step, on: db)
        }
        // The right of the person who started it is checked again for every job.
        guard let binding = try await ProjectRunnerBinding.find(execution.bindingID, on: db), binding.projectID == task.projectID,
              let device = try await RunnerDevice.find(binding.deviceID, on: db), device.revokedAt == nil,
              device.ownerID == execution.requestedBy, let owner = try await User.find(execution.requestedBy, on: db),
              try await canStart(owner, projectID: task.projectID, on: db) else {
            return try await stop(execution, actor: trigger.actor, on: db)
        }
        let mode = step == .developer || step == .tester ? "implement" : "clarify"
        let job = AgentJob(taskID: taskID, projectID: task.projectID, bindingID: execution.bindingID, requestedBy: execution.requestedBy,
            taskRevision: task.version, mode: mode, scope: "Pipeline: \(step.rawValue)", state: "queued", progress: "", result: nil)
        job.id = UUID()
        job.pipelineExecutionID = executionID; job.pipelineStep = step.rawValue; job.pipelinePlanVersion = planVersion
        try await job.create(on: db)
        var object: [String: Any] = ["origin": "pipeline", "step": step.rawValue]
        if let planVersion { object["planVersion"] = planVersion }
        try await AgentService.event(job, kind: "released",
            detail: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), on: db)
        try await appendActivity(taskID: taskID, actorType: trigger.actor.type, actorID: trigger.actor.id, kind: "agent.released",
            subjectID: job.id, on: db)
        try await set(execution, ExecutionState.running, step: step, on: db)
    }

    /// Ends the execution: the open job is cancelled like a human stop (the repository slot stays until the runner confirms),
    /// a running step goes back to `pending` without counting a fix round.
    static func stop(_ execution: TaskPipelineExecution, actor: WorkflowActor, on db: any Database) async throws {
        guard execution.isActive else { return }
        let executionID = try execution.requireID()
        while let job = try await openJob(executionID, on: db) {
            let jobID = try job.requireID()
            job.state = "cancelled"
            try await job.save(on: db)
            try await WorkflowMirror.runnerWithdrawn(jobID: jobID, on: db)
            for run in try await AgentRun.query(on: db).filter(\.$jobID == jobID).filter(\.$endedAt == nil).all() {
                run.generation += 1; run.leaseUntil = Date()
                try await run.save(on: db)
            }
            try await AgentService.event(job, kind: "execution_stopped", on: db)
        }
        if let step = execution.step.flatMap(PipelineStepName.init(rawValue:)),
           try await stepRow(execution.taskID, step, on: db)?.state == PipelineStepState.running {
            try await changeStep(execution.taskID, step, state: PipelineStepState.pending, note: nil, actor: actor, on: db)
        }
        try await set(execution, ExecutionState.stopped, step: execution.step.flatMap(PipelineStepName.init(rawValue:)), on: db)
        try await record(execution, action: "execution_stopped", actor: actor, activity: true, on: db)
    }

    /// Stops every active execution matching the bindings (lost access, revoked device, locked account).
    static func stopAll(bindingIDs: [UUID], requestedBy: UUID? = nil, on db: any Database) async throws {
        var rows: [TaskPipelineExecution] = []
        if !bindingIDs.isEmpty {
            rows = try await TaskPipelineExecution.query(on: db).filter(\.$bindingID ~~ bindingIDs).filter(\.$state ~~ ExecutionState.active).all()
        }
        if let requestedBy {
            rows += try await TaskPipelineExecution.query(on: db).filter(\.$requestedBy == requestedBy).filter(\.$state ~~ ExecutionState.active).all()
        }
        var seen = Set<UUID>()
        for row in rows {
            let id = try row.requireID()
            guard seen.insert(id).inserted else { continue }
            try await lockRow(table: TodoTask.schema, id: row.taskID, on: db)
            try await stop(row, actor: systemActor(id), on: db)
        }
    }

    // MARK: Runner

    /// Checks a queued pipeline job before it is claimed. A refusal cancels the job (it can never run) and returns the
    /// reason; the caller commits and then answers 409.
    static func refuseClaim(_ job: AgentJob, task: TodoTask, on db: any Database) async throws -> String? {
        let taskID = try task.requireID()
        guard let execution = try await active(of: job, on: db), let step = job.pipelineStep.flatMap(PipelineStepName.init(rawValue:)) else {
            try await cancel(job, kind: "execution_stopped", on: db)
            return "job_not_queued"
        }
        let settings = try await PipelineSettingsStore.values(task.projectID, on: db)
        let plan = try await plan(taskID, on: db)
        var stale = false
        if step == .planner {
            stale = job.pipelinePlanVersion != plan?.version
        } else if settings.enabled(.planner) {
            stale = job.pipelinePlanVersion != plan?.version || execution.acceptedPlanVersion != plan?.version || plan?.state != PlanState.approved
        }
        if contentHash(task) != execution.contentHash {
            try await cancel(job, kind: "task_changed", on: db)
            try await set(execution, ExecutionState.paused, reason: ExecutionReason.taskChanged, step: step, on: db)
            return "task_changed"
        }
        if stale {
            try await cancel(job, kind: "plan_changed", on: db)
            let accepted = settings.enabled(.planner) && execution.acceptedPlanVersion == plan?.version
            try await advance(taskID, ExecutionTrigger(actor: systemActor(try execution.requireID()), mayStart: accepted), on: db)
            return "plan_changed"
        }
        return nil
    }

    private static func cancel(_ job: AgentJob, kind: String, on db: any Database) async throws {
        job.state = "cancelled"
        try await job.save(on: db)
        try await AgentService.event(job, kind: kind, on: db)
    }

    /// What a runner reports at the end of a pipeline job.
    struct Submission: Sendable {
        let passed: Bool
        let plan: String?
        let summary: String
        /// Validated before anything is written.
        init(step: String?, outcome: String?, plan: String?, summary: String) throws {
            guard let outcome, ["passed", "failed"].contains(outcome) else { throw Abort(.badRequest, reason: "outcome_required") }
            passed = outcome == "passed"
            if passed, step == PipelineStepName.planner.rawValue {
                guard let text = try WorkflowService.pipelineText(plan, max: PipelineLimits.maxPlan, reason: "plan_required") else {
                    throw Abort(.badRequest, reason: "plan_required")
                }
                self.plan = text
            } else { self.plan = nil }
            self.summary = summary
        }

        /// The summary as a step note: secrets masked, cut to the limits of a note.
        var note: String? {
            let controls = summary.unicodeScalars.filter { $0.properties.generalCategory != .control || "\n\r\t".unicodeScalars.contains($0) }
            var result = "", bytes = 0
            for character in SecretFilter.redactLong(String(String.UnicodeScalarView(controls)))
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(PipelineLimits.maxNote) {
                bytes += String(character).utf8.count
                if bytes > 60_000 { break }
                result.append(character)
            }
            return result.isEmpty ? nil : result
        }
    }

    /// Applies a submitted result: step (or plan), job state and review. The caller saves the job and then calls `advance`
    /// with the returned trigger.
    static func submitted(_ job: AgentJob, runID: UUID, _ submission: Submission, on db: any Database) async throws -> ExecutionTrigger {
        let actor = runActor(runID)
        let taskID = job.taskID
        job.state = submission.passed ? "succeeded" : "failed"
        guard let execution = try await active(of: job, on: db), let step = job.pipelineStep.flatMap(PipelineStepName.init(rawValue:)),
              let task = try await TodoTask.find(taskID, on: db) else { return ExecutionTrigger(actor: actor, mayStart: false) }
        let settings = try await PipelineSettingsStore.values(task.projectID, on: db)
        let current = try await plan(taskID, on: db)
        // The plan changed while the job ran: the result belongs to an older plan and counts for nothing.
        if current?.version != job.pipelinePlanVersion {
            job.state = "failed"
            return ExecutionTrigger(actor: actor, mayStart: settings.enabled(.planner) && execution.acceptedPlanVersion == current?.version,
                automatic: true)
        }
        if step == .planner, let text = submission.plan {
            let written = try await WorkflowService.writePlan(task, body: text, existing: current, settings: settings,
                label: runnerLabel, actor: actor, on: db)
            // Written by the planner of this execution: without an approval step it is accepted at once.
            if written.state == PlanState.approved {
                execution.acceptedPlanVersion = written.version; execution.updatedAt = Date()
                try await execution.save(on: db)
            }
            if let note = submission.note { try await changeStep(taskID, .planner, state: PipelineStepState.done, note: note, actor: actor, on: db) }
        } else {
            try await changeStep(taskID, step, state: submission.passed ? PipelineStepState.done : PipelineStepState.failed,
                note: submission.note, actor: actor, on: db)
            if submission.passed, step != .planner {
                let rows = try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).all()
                let finished = Set(rows.filter { [PipelineStepState.done, PipelineStepState.skipped].contains($0.state) }.map(\.step))
                if workSteps.allSatisfy({ !settings.enabled($0) || finished.contains($0.rawValue) }) {
                    job.state = "awaiting_review"
                    try await WorkflowMirror.runnerSubmitted(job: job, runID: runID, summary: submission.summary, on: db)
                }
            }
        }
        return ExecutionTrigger(actor: actor, mayStart: true, automatic: true)
    }

    /// The run failed or its process ended without a result: the step failed, the execution is blocked.
    static func failed(_ job: AgentJob, runID: UUID, on db: any Database) async throws {
        let actor = runActor(runID)
        guard let execution = try await active(of: job, on: db), let step = job.pipelineStep.flatMap(PipelineStepName.init(rawValue:)) else { return }
        let current = try await plan(job.taskID, on: db)
        if current?.version == job.pipelinePlanVersion {
            try await changeStep(job.taskID, step, state: PipelineStepState.failed, note: failedNote, actor: actor, on: db)
        }
        let accepted = execution.acceptedPlanVersion != nil && execution.acceptedPlanVersion == current?.version
        try await advance(job.taskID, ExecutionTrigger(actor: actor, mayStart: accepted, automatic: true), on: db)
    }

    /// Everything the runner needs beyond the job. Plan text only when it is the plan this job was queued for and, for a
    /// work step, the accepted one.
    static func runnerInfo(_ job: AgentJob, on db: any Database) async throws -> RunnerPipelineDTO? {
        guard let executionID = job.pipelineExecutionID, let step = job.pipelineStep.flatMap(PipelineStepName.init(rawValue:)) else { return nil }
        let execution = try await TaskPipelineExecution.find(executionID, on: db)
        let settings = try await PipelineSettingsStore.values(job.projectID, on: db)
        let plan = try await plan(job.taskID, on: db)
        var shown: TaskPlan?
        if let plan, plan.version == job.pipelinePlanVersion {
            if step == .planner { shown = plan }
            else if settings.enabled(.planner), plan.state == PlanState.approved, execution?.acceptedPlanVersion == plan.version { shown = plan }
        }
        let retries = TaskPipelineEvent.query(on: db).filter(\.$taskID == job.taskID).filter(\.$action == "step_retried")
            .filter(\.$step == step.rawValue)
        if let version = job.pipelinePlanVersion { retries.filter(\.$planVersion == version) } else { retries.filter(\.$planVersion == .null) }
        var feedback = try await retries.sort(\.$sequence, .descending).first()?.note
        if feedback == nil, step == .planner, shown?.state == PlanState.changesRequested { feedback = shown?.decisionComment }
        let role = PipelineRoleName.of(step).flatMap { settings.roles[$0.rawValue] }
        var session: String?
        if step == .planner || step == .developer {
            let jobs = try await AgentJob.query(on: db).filter(\.$pipelineExecutionID == executionID).filter(\.$bindingID == job.bindingID)
                .filter(\.$pipelineStep ~~ [PipelineStepName.planner.rawValue, PipelineStepName.developer.rawValue]).all()
            let jobIDs = try jobs.map { try $0.requireID() }
            // Newest claim first; the first run that left a checkpoint wins.
            let claims = try await AgentEvent.query(on: db).filter(\.$jobID ~~ jobIDs).filter(\.$kind == "claimed")
                .sort(\.$createdAt, .descending).all()
            for runID in claims.compactMap(\.runID) {
                if let saved = try await AgentCheckpoint.query(on: db).filter(\.$runID == runID).first() { session = saved.sessionReference; break }
            }
        }
        return RunnerPipelineDTO(step: step.rawValue, planBody: shown?.body, planVersion: shown?.version, feedback: feedback,
            model: role?.model, effort: role?.effort, resumeSessionReference: session)
    }

    // MARK: Wire

    static func dto(_ taskID: UUID, viewer: User, on db: any Database) async throws -> PipelineExecutionDTO? {
        guard let execution = try await find(taskID, on: db) else { return nil }
        let id = try execution.requireID()
        let binding = try await ProjectRunnerBinding.find(execution.bindingID, on: db)
        var device: RunnerDevice?
        if let binding { device = try await RunnerDevice.find(binding.deviceID, on: db) }
        var job = try await openJob(id, on: db)
        if job == nil, execution.state == ExecutionState.completed {
            job = try await AgentJob.query(on: db).filter(\.$pipelineExecutionID == id).filter(\.$state == "awaiting_review").first()
        }
        // The progress text of a runner is for those who may run agents.
        var progress: String?
        if let job, !job.progress.isEmpty, try await canStart(viewer, projectID: execution.projectID, on: db) {
            progress = SecretFilter.redact(job.progress).text
        }
        return PipelineExecutionDTO(id: id, state: execution.state, reason: execution.reason, step: execution.step,
            bindingID: execution.bindingID, bindingLabel: binding?.label ?? "", deviceLabel: device?.label ?? "",
            runnerSupportsPipeline: device?.pipelineSeenAt != nil, jobID: job?.id, jobState: job?.state, jobProgress: progress,
            createdAt: execution.createdAt, updatedAt: execution.updatedAt)
    }
}

struct PipelineExecutionDTO: Content {
    let id: UUID
    let state: String
    let reason: String?
    let step: String?
    let bindingID: UUID
    let bindingLabel: String
    let deviceLabel: String
    let runnerSupportsPipeline: Bool
    let jobID: UUID?
    let jobState: String?
    let jobProgress: String?
    let createdAt: Date
    let updatedAt: Date
}

struct RunnerPipelineDTO: Content {
    let step: String
    let planBody: String?
    let planVersion: Int?
    let feedback: String?
    let model: String?
    let effort: String?
    let resumeSessionReference: String?
}

struct StartExecutionRequest: Content {
    let id: UUID
    let bindingID: UUID
}

struct ContinueExecutionRequest: Content {
    var planVersion: Int? = nil
}

// MARK: - Person and integration entry points

extension WorkflowService {
    /// Device row first, then the task row: the same order as release, claim and the runner commands.
    private func locked<T: Sendable>(_ taskID: UUID, deviceID: UUID?,
                                     _ body: @escaping @Sendable (TodoTask, any Database) async throws -> T) async throws -> T {
        let user = self.user, allowed = allowedProjects
        return try await db.transaction { tx in
            if let deviceID { try await lockRow(table: RunnerDevice.schema, id: deviceID, on: tx) }
            try await lockRow(table: TodoTask.schema, id: taskID, on: tx)
            let access = ProjectAccess(user: user, db: tx)
            let task = try await access.task(taskID, role: .read)
            if let allowed, !allowed.contains(task.projectID) { throw Abort(.notFound) }
            _ = try await access.startAgent(in: task.projectID)
            return try await body(task, tx)
        }
    }

    private func executionDevice(_ taskID: UUID) async throws -> UUID? {
        guard let execution = try await PipelineExecution.find(taskID, on: db) else { return nil }
        return try await ProjectRunnerBinding.find(execution.bindingID, on: db)?.deviceID
    }

    /// Needs the start right and an own, paired device bound to the card's project. A retry with the same id returns the state.
    func startExecution(_ taskID: UUID, _ request: StartExecutionRequest, actor: WorkflowActor) async throws -> PipelineDTO {
        let deviceID = try await ProjectRunnerBinding.find(request.bindingID, on: db)?.deviceID
        let user = self.user
        return try await locked(taskID, deviceID: deviceID) { task, tx in
            let userID = try user.requireID()
            guard let binding = try await ProjectRunnerBinding.find(request.bindingID, on: tx), binding.projectID == task.projectID,
                  let device = try await RunnerDevice.find(binding.deviceID, on: tx), device.ownerID == userID,
                  device.revokedAt == nil else { throw Abort(.notFound) }
            if let existing = try await TaskPipelineExecution.find(request.id, on: tx) {
                guard existing.taskID == taskID, existing.bindingID == request.bindingID, existing.requestedBy == userID else {
                    throw Abort(.conflict, reason: "execution_id_conflict")
                }
                return try await Self.pipelineDTO(taskID, projectID: task.projectID, viewer: user, on: tx)
            }
            let current = try await PipelineExecution.find(taskID, on: tx)
            if current?.isActive == true { throw Abort(.conflict, reason: "execution_active") }
            let settings = try await PipelineSettingsStore.values(task.projectID, on: tx)
            let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == taskID).first()
            let rows = try await TaskPipelineStep.query(on: tx).filter(\.$taskID == taskID).all()
            let finished = Set(rows.filter { [PipelineStepState.done, PipelineStepState.skipped].contains($0.state) }.map(\.step))
            let planOpen = settings.enabled(.planner) && plan?.state != PlanState.approved
            if !planOpen, PipelineExecution.workSteps.allSatisfy({ !settings.enabled($0) || finished.contains($0.rawValue) }) {
                throw Abort(.conflict, reason: "nothing_to_run")
            }
            try await current?.delete(on: tx)
            let now = Date()
            let execution = TaskPipelineExecution()
            execution.id = request.id; execution.taskID = taskID; execution.projectID = task.projectID
            execution.bindingID = request.bindingID; execution.requestedBy = userID; execution.state = ExecutionState.running
            execution.contentHash = PipelineExecution.contentHash(task)
            execution.acceptedPlanVersion = plan?.state == PlanState.approved ? plan?.version : nil
            execution.createdAt = now; execution.updatedAt = now
            do { try await execution.create(on: tx) }
            catch let error as any DatabaseError where error.isConstraintFailure { throw Abort(.conflict, reason: "execution_id_conflict") }
            // Handing the card to a runner consumes the one-time automatic start, whoever started.
            if let planning = try await TaskPlanning.find(taskID, on: tx), planning.autoStart {
                planning.autoStart = false
                try await planning.save(on: tx)
            }
            try await PipelineExecution.record(execution, action: "execution_started", actor: actor, activity: true, on: tx)
            try await PipelineExecution.advance(taskID, ExecutionTrigger(actor: actor, mayStart: true), on: tx)
            return try await Self.pipelineDTO(taskID, projectID: task.projectID, viewer: user, on: tx)
        }
    }

    /// The person accepts the current plan (only the version they name) and the current card content.
    func continueExecution(_ taskID: UUID, _ request: ContinueExecutionRequest, actor: WorkflowActor) async throws -> PipelineDTO {
        let user = self.user
        return try await locked(taskID, deviceID: try await executionDevice(taskID)) { task, tx in
            guard let execution = try await PipelineExecution.find(taskID, on: tx), execution.isActive else {
                throw Abort(.conflict, reason: "no_execution")
            }
            let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == taskID).first()
            if let expected = request.planVersion, expected != plan?.version { throw Abort(.conflict, reason: "plan_changed") }
            if request.planVersion != nil, plan?.state == PlanState.approved { execution.acceptedPlanVersion = plan?.version }
            execution.contentHash = PipelineExecution.contentHash(task)
            execution.updatedAt = Date()
            try await execution.save(on: tx)
            try await PipelineExecution.record(execution, action: "execution_continued", actor: actor, activity: true, on: tx)
            try await PipelineExecution.advance(taskID, ExecutionTrigger(actor: actor, mayStart: true), on: tx)
            return try await Self.pipelineDTO(taskID, projectID: task.projectID, viewer: user, on: tx)
        }
    }

    func stopExecution(_ taskID: UUID, actor: WorkflowActor) async throws -> PipelineDTO {
        let user = self.user
        return try await locked(taskID, deviceID: try await executionDevice(taskID)) { task, tx in
            guard let execution = try await PipelineExecution.find(taskID, on: tx), execution.isActive else {
                throw Abort(.conflict, reason: "no_execution")
            }
            try await PipelineExecution.stop(execution, actor: actor, on: tx)
            return try await Self.pipelineDTO(taskID, projectID: task.projectID, viewer: user, on: tx)
        }
    }
}
