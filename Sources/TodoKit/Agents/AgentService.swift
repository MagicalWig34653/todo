import Fluent
import Vapor

extension ProjectAccess {
    /// Agent execution is an independent capability; edit access must never imply it.
    func startAgent(in projectID: UUID) async throws -> Project {
        let project = try await project(projectID)
        guard project.ownerID == user.id else { throw Abort(.forbidden) }
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
    init(_ job: AgentJob) throws {
        id = try job.requireID(); taskID = job.taskID; projectID = job.projectID
        bindingID = job.bindingID; requestedBy = job.requestedBy; taskRevision = job.taskRevision
        previousJobID = job.previousJobID
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

    /// The device row serializes claims across bindings referring to the same local repository.
    /// An expired run keeps its slot until a runner explicitly confirms that the process stopped.
    static func claim(jobID: UUID, deviceID: UUID, on database: any Database) async throws -> AgentRunDTO {
        try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: db)
            guard let device = try await RunnerDevice.find(deviceID, on: db), device.revokedAt == nil,
                  let job = try await AgentJob.find(jobID, on: db),
                  let binding = try await ProjectRunnerBinding.find(job.bindingID, on: db) else { throw Abort(.notFound) }
            try await authorized(binding, device: device, on: db)
            guard job.state == "queued" else { throw Abort(.conflict, reason: "job_not_queued") }
            let bindings = try await ProjectRunnerBinding.query(on: db).filter(\.$deviceID == deviceID)
                .filter(\.$repositoryKey == binding.repositoryKey).all()
            let ids = try bindings.map { try $0.requireID() }
            guard try await AgentRun.query(on: db).filter(\.$bindingID ~~ ids).filter(\.$endedAt == nil).count() == 0 else {
                throw Abort(.conflict, reason: "repository_busy_reconcile_first")
            }
            guard let task = try await TodoTask.find(job.taskID, on: db), task.projectID == job.projectID,
                  task.ownerID == device.ownerID, task.version == job.taskRevision else { throw Abort(.conflict, reason: "task_revision_changed") }
            let run = try AgentRun(jobID: jobID, bindingID: binding.requireID(), deviceID: deviceID,
                               generation: 1, leaseUntil: Date().addingTimeInterval(leaseDuration), endedAt: nil)
            try await run.save(on: db)
            job.state = "claimed"
            try await job.save(on: db)
            try await event(job, run: run, kind: "claimed", on: db)
            try await appendLockedActivity(taskID: job.taskID, actorType: .run, actorID: run.requireID(), kind: "agent.claimed", subjectID: job.id, on: db)
            return try await AgentRunDTO(run, job: job, on: db)
        }
    }

    static func command(runID: UUID, deviceID: UUID, action: String, body: AgentRunCommand, on database: any Database) async throws -> AgentRunDTO {
        try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: db)
            guard let device = try await RunnerDevice.find(deviceID, on: db), device.revokedAt == nil,
                  let run = try await AgentRun.find(runID, on: db), run.deviceID == deviceID,
                  let job = try await AgentJob.find(run.jobID, on: db),
                  let binding = try await ProjectRunnerBinding.find(run.bindingID, on: db) else { throw Abort(.notFound) }
            try await authorized(binding, device: device, on: db)
            guard let task = try await TodoTask.find(job.taskID, on: db), task.projectID == job.projectID,
                  task.ownerID == device.ownerID else { throw Abort(.notFound) }
            guard run.generation == body.generation else { throw Abort(.conflict, reason: "stale_generation") }
            guard run.endedAt == nil else { throw Abort(.gone, reason: "run_ended") }
            if action == "reconcile" {
                guard ["alive", "paused", "stopped"].contains(body.observation ?? "") else { throw Abort(.badRequest) }
                if body.observation == "stopped" {
                    run.endedAt = Date()
                    if job.state != "cancelled" { job.state = "failed" }
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
                    try await AgentQuestion(jobID: job.requireID(), taskID: job.taskID, prompt: text(prompt), options: options).save(on: db)
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
                    job.state = "awaiting_review"
                    run.endedAt = Date()
                case "stop", "fail":
                    job.state = action == "stop" ? "cancelled" : "failed"
                    run.endedAt = Date()
                default: throw Abort(.notFound)
                }
            }
            try await run.save(on: db)
            try await job.save(on: db)
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

    static func release(_ body: ReleaseJobRequest, user: User, on database: any Database) async throws -> AgentJobDTO {
        guard ["clarify", "implement"].contains(body.mode) else { throw Abort(.badRequest) }
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
            let job = try AgentJob(taskID: body.taskID, projectID: binding.projectID, bindingID: body.bindingID,
                requestedBy: user.requireID(), previousJobID: body.previousJobID, taskRevision: body.taskRevision, mode: body.mode,
                scope: AgentService.text(body.scope), state: "queued", progress: "", result: nil)
            job.id = body.id
            do {
                try await job.create(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(.conflict, reason: "release_id_conflict")
            }
            try await AgentService.event(job, kind: "released", on: db)
            try await appendLockedActivity(taskID: job.taskID, actorType: .person, actorID: user.requireID(), kind: "agent.released", subjectID: job.id, on: db)
            return try AgentJobDTO(job)
        }
    }

    static func humanTransition(jobID: UUID, decision: String, user: User, on database: any Database) async throws -> AgentJobDTO {
        guard ["stop", "accept", "request_changes"].contains(decision) else { throw Abort(.badRequest) }
        let initial = try await humanJob(jobID, user: user, on: database)
        guard let binding = try await ProjectRunnerBinding.find(initial.bindingID, on: database) else { throw Abort(.notFound) }
        return try await database.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: binding.deviceID, on: db)
            let job = try await humanJob(jobID, user: user, on: db)
            if decision == "stop" {
                guard ["queued", "claimed", "running", "waiting_for_answer"].contains(job.state) else { throw Abort(.conflict) }
                job.state = "cancelled"
                // Keep the slot occupied until local termination is confirmed by reconciliation.
                for run in try await AgentRun.query(on: db).filter(\.$jobID == jobID).filter(\.$endedAt == nil).all() {
                    run.generation += 1; run.leaseUntil = Date()
                    try await run.save(on: db)
                }
            } else {
                guard job.state == "awaiting_review" else { throw Abort(.conflict) }
                job.state = decision == "accept" ? "succeeded" : "failed"
            }
            try await job.save(on: db)
            try await AgentService.event(job, kind: decision, detail: try user.requireID().uuidString, on: db)
            try await appendLockedActivity(taskID: job.taskID, actorType: .person, actorID: user.requireID(), kind: "agent.\(decision)", subjectID: job.id, on: db)
            return try AgentJobDTO(job)
        }
    }

    static func answer(questionID: UUID, value: String, user: User, on database: any Database) async throws -> AgentDetail {
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
                if !question.options.isEmpty, !question.options.contains(value) { throw Abort(.badRequest, reason: "invalid_answer_option") }
                try await AgentAnswer(questionID: questionID, authorID: user.requireID(), value: AgentService.text(value)).save(on: db)
                try await AgentService.event(job, kind: "answered", detail: questionID.uuidString, on: db)
                try await appendLockedActivity(taskID: job.taskID, actorType: .person, actorID: user.requireID(), kind: "agent.answered", subjectID: questionID, on: db)
            }
            return try await AgentDetail(job, on: db)
        }
    }
}
