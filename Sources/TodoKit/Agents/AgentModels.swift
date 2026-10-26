import Fluent
import Vapor

final class RunnerDevice: Model, @unchecked Sendable {
    static let schema = "runner_devices"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "label") var label: String
    @OptionalField(key: "token_hash") var tokenHash: String?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    init() {}
    init(ownerID: UUID, label: String, tokenHash: String?, revokedAt: Date?) {
        self.ownerID = ownerID
        self.label = label
        self.tokenHash = tokenHash
        self.revokedAt = revokedAt
    }
}

final class RunnerPairing: Model, @unchecked Sendable {
    static let schema = "runner_pairings"
    @ID(key: .id) var id: UUID?
    @Field(key: "device_id") var deviceID: UUID
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "used_at") var usedAt: Date?
    init() {}
    init(deviceID: UUID, codeHash: String, expiresAt: Date, usedAt: Date?) {
        self.deviceID = deviceID
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }
}

final class ProjectRunnerBinding: Model, @unchecked Sendable {
    static let schema = "project_runner_bindings"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "device_id") var deviceID: UUID
    @Field(key: "repository_key") var repositoryKey: String
    @Field(key: "label") var label: String
    init() {}
    init(projectID: UUID, deviceID: UUID, repositoryKey: String, label: String) {
        self.projectID = projectID
        self.deviceID = deviceID
        self.repositoryKey = repositoryKey
        self.label = label
    }
}

final class AgentJob: Model, @unchecked Sendable {
    static let schema = "agent_jobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "binding_id") var bindingID: UUID
    @Field(key: "requested_by") var requestedBy: UUID
    @OptionalField(key: "previous_job_id") var previousJobID: UUID?
    @Field(key: "task_revision") var taskRevision: Int
    @Field(key: "mode") var mode: String
    @Field(key: "scope") var scope: String
    @Field(key: "state") var state: String
    @Field(key: "progress") var progress: String
    @OptionalField(key: "result") var result: String?
    init() {}
    init(taskID: UUID, projectID: UUID, bindingID: UUID, requestedBy: UUID, previousJobID: UUID? = nil, taskRevision: Int, mode: String, scope: String, state: String, progress: String, result: String?) {
        self.taskID = taskID
        self.projectID = projectID
        self.bindingID = bindingID
        self.requestedBy = requestedBy
        self.previousJobID = previousJobID
        self.taskRevision = taskRevision
        self.mode = mode
        self.scope = scope
        self.state = state
        self.progress = progress
        self.result = result
    }
}

final class AgentRun: Model, @unchecked Sendable {
    static let schema = "agent_runs"
    @ID(key: .id) var id: UUID?
    @Field(key: "job_id") var jobID: UUID
    @Field(key: "binding_id") var bindingID: UUID
    @Field(key: "device_id") var deviceID: UUID
    @Field(key: "generation") var generation: Int
    @Field(key: "lease_until") var leaseUntil: Date
    @OptionalField(key: "ended_at") var endedAt: Date?
    init() {}
    init(jobID: UUID, bindingID: UUID, deviceID: UUID, generation: Int, leaseUntil: Date, endedAt: Date?) {
        self.jobID = jobID
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.generation = generation
        self.leaseUntil = leaseUntil
        self.endedAt = endedAt
    }
}

final class AgentCheckpoint: Model, @unchecked Sendable {
    static let schema = "agent_checkpoints"
    @ID(key: .id) var id: UUID?
    @Field(key: "run_id") var runID: UUID
    @Field(key: "context_revision") var contextRevision: Int
    @Field(key: "session_reference") var sessionReference: String
    @Field(key: "next_step") var nextStep: String
    init() {}
    init(runID: UUID, contextRevision: Int, sessionReference: String, nextStep: String) {
        self.runID = runID
        self.contextRevision = contextRevision
        self.sessionReference = sessionReference
        self.nextStep = nextStep
    }
}

final class AgentQuestion: Model, @unchecked Sendable {
    static let schema = "agent_questions"
    @ID(key: .id) var id: UUID?
    @Field(key: "job_id") var jobID: UUID
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "prompt") var prompt: String
    @Field(key: "options") var options: [String]
    init() {}
    init(jobID: UUID, taskID: UUID, prompt: String, options: [String]) {
        self.jobID = jobID
        self.taskID = taskID
        self.prompt = prompt
        self.options = options
    }
}

final class AgentAnswer: Model, @unchecked Sendable {
    static let schema = "agent_answers"
    @ID(key: .id) var id: UUID?
    @Field(key: "question_id") var questionID: UUID
    @Field(key: "author_id") var authorID: UUID
    @Field(key: "value") var value: String
    init() {}
    init(questionID: UUID, authorID: UUID, value: String) {
        self.questionID = questionID
        self.authorID = authorID
        self.value = value
    }
}

final class AgentEvent: Model, @unchecked Sendable {
    static let schema = "agent_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "job_id") var jobID: UUID
    @OptionalField(key: "run_id") var runID: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "detail") var detail: String
    @Field(key: "created_at") var createdAt: Date
    init() {}
    init(jobID: UUID, runID: UUID?, kind: String, detail: String, createdAt: Date) {
        self.jobID = jobID
        self.runID = runID
        self.kind = kind
        self.detail = detail
        self.createdAt = createdAt
    }
}
