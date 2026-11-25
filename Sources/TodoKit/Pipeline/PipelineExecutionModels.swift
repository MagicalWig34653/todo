import Fluent
import Vapor

// Pipeline stage 3 (card F5DD1C00, docs/PLAN-PIPELINE-STUFE-3.md): the runner executes the steps of a card.

enum ExecutionState {
    static let running = "running", waitingApproval = "waiting_approval", blocked = "blocked", paused = "paused"
    static let completed = "completed", stopped = "stopped"
    static let active = [running, waitingApproval, blocked, paused]
}

enum ExecutionReason {
    static let planNeedsOwner = "plan_needs_owner", taskChanged = "task_changed", continueRequired = "continue_required"
    static let stepFailed = "step_failed", fixRoundsExhausted = "fix_rounds_exhausted"
}

/// One row per card; a new start replaces an ended execution. The id comes from the client (idempotency).
final class TaskPipelineExecution: Model, @unchecked Sendable {
    static let schema = "task_pipeline_executions"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "binding_id") var bindingID: UUID
    @Field(key: "requested_by") var requestedBy: UUID
    @Field(key: "state") var state: String
    @OptionalField(key: "reason") var reason: String?
    @OptionalField(key: "step") var step: String?
    /// SHA-256 of title and description at the start or at the last continuation.
    @Field(key: "content_hash") var contentHash: String
    /// Plan version the person with the start right accepted; no other plan text reaches a work step.
    @OptionalField(key: "accepted_plan_version") var acceptedPlanVersion: Int?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
    var isActive: Bool { ExecutionState.active.contains(state) }
}

extension TaskPipelineExecution: LiveTaskScoped { var liveTaskID: UUID? { taskID } }

/// Additive. No foreign key to accounts or bindings (a binding without history may be removed). `pipeline_plan_version` is
/// the plan version at the moment a job was queued, so that a result or a claim for an older plan is recognised.
struct CreatePipelineExecution: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskPipelineExecution.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required).field("binding_id", .uuid, .required).field("requested_by", .uuid, .required)
            .field("state", .string, .required).field("reason", .string).field("step", .string)
            .field("content_hash", .string, .required).field("accepted_plan_version", .int)
            .field("created_at", .datetime, .required).field("updated_at", .datetime, .required)
            .unique(on: "task_id", name: "uq_task_pipeline_executions_task")
            .create()
        // One column per statement: SQLite cannot add several at once.
        try await db.schema(AgentJob.schema).field("pipeline_execution_id", .uuid).update()
        try await db.schema(AgentJob.schema).field("pipeline_step", .string).update()
        try await db.schema(AgentJob.schema).field("pipeline_plan_version", .int).update()
        try await db.schema(RunnerDevice.schema).field("pipeline_seen_at", .datetime).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(RunnerDevice.schema).deleteField("pipeline_seen_at").update()
        for column in ["pipeline_plan_version", "pipeline_step", "pipeline_execution_id"] {
            try await db.schema(AgentJob.schema).deleteField(.string(column)).update()
        }
        try await db.schema(TaskPipelineExecution.schema).delete()
    }
}
