import Fluent
import Vapor

// Pipeline per card, stage 1 (card 74EC341D, contracts/pipeline.yaml): the current plan of a task, its approval, the state
// of six fixed steps and an audit trail. Nothing here changes the task, its column or the sync formats, and nothing runs.

/// Fixed order of the steps; the raw value is the wire name.
enum PipelineStepName: String, CaseIterable, Sendable {
    case planner, approval, developer, validation, tester, review
}

enum PipelineStepState {
    static let pending = "pending", running = "running", waiting = "waiting", changesRequested = "changes_requested"
    static let done = "done", failed = "failed", skipped = "skipped"
    /// What a caller may set; `waiting` and `changes_requested` follow from writing and deciding a plan.
    static let settable = [pending, running, done, failed, skipped]
}

enum PlanState {
    static let proposed = "proposed", approved = "approved", changesRequested = "changes_requested"
}

enum PipelineLimits {
    static let maxPlan = 20_000
    static let maxComment = 4000
    static let maxNote = 2000
    static let maxEvents = 50
    static let maxLabel = 100
    static let maxLabelScalars = 255
}

// MARK: - Models

/// The current plan of a task (one row per task); earlier versions survive only as audit entries.
final class TaskPlan: Model, @unchecked Sendable {
    static let schema = "task_plans"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "version") var version: Int
    @Field(key: "body") var body: String
    /// `proposed` | `approved` | `changes_requested`
    @Field(key: "state") var state: String
    @Field(key: "author_type") var authorType: ActivityActorType
    @Field(key: "author_id") var authorID: UUID
    @OptionalField(key: "author_label") var authorLabel: String?
    @Field(key: "written_at") var writtenAt: Date
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "decided_by_type") var decidedByType: String?
    @OptionalField(key: "decided_by_id") var decidedByID: UUID?
    @OptionalField(key: "decided_by_label") var decidedByLabel: String?
    @OptionalField(key: "decision_comment") var decisionComment: String?
    init() {}
}

/// Only steps that differ from the default (`pending`, nothing else) need a row.
final class TaskPipelineStep: Model, @unchecked Sendable {
    static let schema = "task_pipeline_steps"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "step") var step: String
    @Field(key: "state") var state: String
    @OptionalField(key: "note") var note: String?
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "actor_label") var actorLabel: String?
    @Field(key: "updated_at") var updatedAt: Date
    /// Plan version the stored state refers to (stage 2); nil on rows of stage 1.
    @OptionalField(key: "plan_version") var planVersion: Int?
    init() {}
}

/// Audit trail; `sequence` orders the entries of a task independently of timestamp precision.
final class TaskPipelineEvent: Model, @unchecked Sendable {
    static let schema = "task_pipeline_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "sequence") var sequence: Int
    /// `plan_written` | `plan_approved` | `plan_changes_requested` | `step_changed` | `step_retried`
    @Field(key: "action") var action: String
    @OptionalField(key: "plan_version") var planVersion: Int?
    @OptionalField(key: "step") var step: String?
    @OptionalField(key: "state") var state: String?
    @OptionalField(key: "note") var note: String?
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "actor_label") var actorLabel: String?
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

// Hint rows for live refresh and MCP `wait_for_events`.
extension TaskPlan: LiveTaskScoped { var liveTaskID: UUID? { taskID } }
extension TaskPipelineStep: LiveTaskScoped { var liveTaskID: UUID? { taskID } }

// MARK: - Migration

/// Additive: three new tables, removed with their task (and so with their project). No foreign key to accounts, like the
/// other agent texts on a card (progress notes, reviews): they stay with a surviving card when an account is deleted.
/// The label columns never hold a person's account name (it is read from the account, so it ends with it).
struct CreateTaskPipeline: AsyncMigration {
    func prepare(on db: any Database) async throws {
        // `.sql(raw:)` because `.sql(.text)` becomes VARCHAR(255) on MariaDB; a plan of 20 000 characters can exceed TEXT.
        let text = DatabaseSchema.DataType.sql(raw: "TEXT")
        try await db.schema(TaskPlan.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("version", .int, .required)
            .field("body", .sql(raw: "MEDIUMTEXT"), .required)
            .field("state", .string, .required)
            .field("author_type", .string, .required).field("author_id", .uuid, .required).field("author_label", .string)
            .field("written_at", .datetime, .required)
            .field("decided_at", .datetime).field("decided_by_type", .string).field("decided_by_id", .uuid)
            .field("decided_by_label", .string).field("decision_comment", text)
            .unique(on: "task_id", name: "uq_task_plans_task")
            .create()
        try await db.schema(TaskPipelineStep.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("step", .string, .required).field("state", .string, .required).field("note", text)
            .field("actor_type", .string, .required).field("actor_id", .uuid, .required).field("actor_label", .string)
            .field("updated_at", .datetime, .required)
            .unique(on: "task_id", "step", name: "uq_task_pipeline_steps_step")
            .create()
        try await db.schema(TaskPipelineEvent.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("sequence", .int, .required).field("action", .string, .required)
            .field("plan_version", .int).field("step", .string).field("state", .string).field("note", text)
            .field("actor_type", .string, .required).field("actor_id", .uuid, .required).field("actor_label", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "task_id", "sequence", name: "uq_task_pipeline_events_sequence")
            .create()
    }
    func revert(on db: any Database) async throws {
        for table in [TaskPipelineEvent.schema, TaskPipelineStep.schema, TaskPlan.schema] { try await db.schema(table).delete() }
    }
}

func configurePipeline(_ app: Application) {
    app.migrations.add(CreateTaskPipeline())
    app.migrations.add(CreateProjectPipelineSettings())
    app.migrations.add(AddPlanVersionToPipelineSteps())
}

// MARK: - DTOs

/// Actor types are lower case on this surface (like the live view).
private func wireType(_ type: ActivityActorType) -> String { type.rawValue.lowercased() }

struct PlanDTO: Content {
    let version: Int
    let body: String
    let state: String
    let authorType: String
    let authorLabel: String?
    let writtenAt: Date
    let decidedAt: Date?
    let decidedByLabel: String?
    let decisionComment: String?
    /// `person` | `integration` | `system` (a plan approved without a person because the project has no approval step); absent while undecided.
    let decidedByType: String?
    init(_ p: TaskPlan, authorLabel: String?, decidedByLabel: String?) {
        version = p.version; body = p.body; state = p.state; authorType = wireType(p.authorType); self.authorLabel = authorLabel
        writtenAt = p.writtenAt; decidedAt = p.decidedAt; self.decidedByLabel = decidedByLabel; decisionComment = p.decisionComment
        decidedByType = p.decidedByType?.lowercased()
    }
}

struct PipelineStepDTO: Content {
    let step: String
    let state: String
    let note: String?
    let actorLabel: String?
    let updatedAt: Date?
    /// Stage 2: false when the project switched the step off (the shown `state` is then `skipped` or the stored one).
    var enabled: Bool = true
    /// Plan version the state refers to; absent for `pending` without a row and for rows of stage 1.
    var planVersion: Int? = nil
    /// Model and effort of the role of this step (planner, developer, tester, review only).
    var role: PipelineRoleValue? = nil
}

struct FixRoundsDTO: Content {
    let used: Int
    let max: Int
    let remaining: Int
    init(used: Int, max: Int) { self.used = used; self.max = max; remaining = Swift.max(0, max - used) }
}

struct PipelineEventDTO: Content {
    let id: UUID
    let action: String
    let planVersion: Int?
    let step: String?
    let state: String?
    let note: String?
    let actorType: String
    let actorLabel: String?
    let createdAt: Date
    init(_ e: TaskPipelineEvent, actorLabel: String?) throws {
        id = try e.requireID(); action = e.action; planVersion = e.planVersion; step = e.step; state = e.state; note = e.note
        actorType = wireType(e.actorType); self.actorLabel = actorLabel; createdAt = e.createdAt
    }
}

struct PipelineDTO: Content {
    let taskID: UUID
    let plan: PlanDTO?
    /// Always all six steps in their fixed order.
    let steps: [PipelineStepDTO]
    /// Newest first, at most `PipelineLimits.maxEvents`.
    let events: [PipelineEventDTO]
    /// Effective project settings (stage 2).
    let settings: PipelineSettingsSummaryDTO
    /// Retries of the current plan version against the maximum.
    let fixRounds: FixRoundsDTO
    /// The plan is `proposed` and the project has an approval step.
    let waitingApproval: Bool
}

struct SetPlanRequest: Content {
    let body: String
    var expectedVersion: Int? = nil
    var agentName: String? = nil
}

struct PlanDecisionRequest: Content {
    /// `approve` | `request_changes`
    let decision: String
    /// The plan version the caller looked at (required).
    var version: Int? = nil
    var comment: String? = nil
}

struct SetPipelineStepRequest: Content {
    let state: String
    var note: String? = nil
    var agentName: String? = nil
    /// Stage 2, optional: the plan version the caller works on (409 `plan_changed` if it is not the current one).
    var planVersion: Int? = nil
}

struct RetryPipelineStepRequest: Content {
    var planVersion: Int? = nil
    var note: String? = nil
    var agentName: String? = nil
}
