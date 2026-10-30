import Fluent
import Vapor

// MARK: - Models (ADR 0014)

/// Per-task workflow metadata (one lazily created row per task; `id` = task id).
final class TaskWorkflow: Model, @unchecked Sendable {
    static let schema = "task_workflow"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    /// `task` | `feature`
    @Field(key: "kind") var kind: String
    @OptionalField(key: "parent_task_id") var parentTaskID: UUID?
    @OptionalField(key: "blocked_reason") var blockedReason: String?
    @OptionalField(key: "claimed_by_type") var claimedByType: String?
    @OptionalField(key: "claimed_by_id") var claimedByID: UUID?
    @OptionalField(key: "claimed_label") var claimedLabel: String?
    @OptionalField(key: "claimed_at") var claimedAt: Date?
    init() {}
    init(taskID: UUID) { id = taskID; kind = "task" }
}

final class TaskQuestion: Model, @unchecked Sendable {
    static let schema = "task_questions"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "asked_by_type") var askedByType: ActivityActorType
    @Field(key: "asked_by_id") var askedByID: UUID
    @OptionalField(key: "asked_by_label") var askedByLabel: String?
    @Field(key: "prompt") var prompt: String
    @Field(key: "options") var options: [String]
    @Field(key: "blocking") var blocking: Bool
    /// `open` | `answered` | `withdrawn`
    @Field(key: "state") var state: String
    @OptionalField(key: "answer") var answer: String?
    @OptionalField(key: "answered_by") var answeredBy: UUID?
    /// `rest` | `mcp` | `runner`
    @OptionalField(key: "answered_via") var answeredVia: String?
    @OptionalField(key: "answered_at") var answeredAt: Date?
    @OptionalField(key: "agent_question_id") var agentQuestionID: UUID?
    @OptionalField(key: "idempotency_key") var idempotencyKey: String?
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

final class TaskReview: Model, @unchecked Sendable {
    static let schema = "task_reviews"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    /// `pending` | `accepted` | `changes_requested` | `withdrawn`
    @Field(key: "state") var state: String
    @Field(key: "requested_by_type") var requestedByType: ActivityActorType
    @Field(key: "requested_by_id") var requestedByID: UUID
    @OptionalField(key: "requested_by_label") var requestedByLabel: String?
    @OptionalField(key: "reviewer_id") var reviewerID: UUID?
    @Field(key: "summary") var summary: String
    @OptionalField(key: "decided_by") var decidedBy: UUID?
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "decision_note") var decisionNote: String?
    @OptionalField(key: "agent_job_id") var agentJobID: UUID?
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

final class TaskProgressNote: Model, @unchecked Sendable {
    static let schema = "task_progress_notes"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "actor_label") var actorLabel: String?
    @Field(key: "note") var note: String
    @OptionalField(key: "percent") var percent: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

final class ProjectAgentBrief: Model, @unchecked Sendable {
    static let schema = "project_agent_briefs"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "text") var text: String
    @Field(key: "version") var version: Int
    @OptionalField(key: "updated_by") var updatedBy: UUID?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(projectID: UUID) { id = projectID; text = ""; version = 0 }
}

final class BuildArtifact: Model, @unchecked Sendable {
    static let schema = "build_artifacts"
    @ID(key: .id) var id: UUID?
    @Field(key: "attachment_id") var attachmentID: UUID
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "build_id") var buildID: String
    @OptionalField(key: "label") var label: String?
    @OptionalField(key: "platform") var platform: String?
    @Field(key: "created_by_type") var createdByType: ActivityActorType
    @Field(key: "created_by_id") var createdByID: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

struct CreateCommandCenter: AsyncMigration {
    func prepare(on db: any Database) async throws {
        let text = DatabaseSchema.DataType.sql(raw: "TEXT")
        try await db.schema(TaskWorkflow.schema)
            .field("id", .uuid, .identifier(auto: false), .references("tasks", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("parent_task_id", .uuid, .references("tasks", "id", onDelete: .setNull))
            .field("blocked_reason", text)
            .field("claimed_by_type", .string).field("claimed_by_id", .uuid)
            .field("claimed_label", .string).field("claimed_at", .datetime)
            .create()
        try await db.schema(TaskQuestion.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("asked_by_type", .string, .required).field("asked_by_id", .uuid, .required)
            .field("asked_by_label", .string)
            .field("prompt", text, .required).field("options", .json, .required)
            .field("blocking", .bool, .required).field("state", .string, .required)
            .field("answer", text).field("answered_by", .uuid).field("answered_via", .string)
            .field("answered_at", .datetime).field("agent_question_id", .uuid)
            .field("idempotency_key", .string).field("version", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "task_id", "idempotency_key")
            .create()
        try await db.schema(TaskReview.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("state", .string, .required)
            .field("requested_by_type", .string, .required).field("requested_by_id", .uuid, .required)
            .field("requested_by_label", .string).field("reviewer_id", .uuid)
            .field("summary", text, .required)
            .field("decided_by", .uuid).field("decided_at", .datetime).field("decision_note", text)
            .field("agent_job_id", .uuid).field("version", .int, .required).field("created_at", .datetime)
            .create()
        try await db.schema(TaskProgressNote.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("actor_type", .string, .required).field("actor_id", .uuid, .required)
            .field("actor_label", .string).field("note", text, .required).field("percent", .int)
            .field("created_at", .datetime)
            .create()
        try await db.schema(ProjectAgentBrief.schema)
            .field("id", .uuid, .identifier(auto: false), .references("projects", "id", onDelete: .cascade))
            .field("text", .sql(raw: "MEDIUMTEXT"), .required).field("version", .int, .required)
            .field("updated_by", .uuid).field("updated_at", .datetime)
            .create()
        try await db.schema(BuildArtifact.schema).id()
            .field("attachment_id", .uuid, .required).field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("build_id", .string, .required).field("label", .string).field("platform", .string)
            .field("created_by_type", .string, .required).field("created_by_id", .uuid, .required)
            .field("created_at", .datetime)
            .unique(on: "attachment_id")
            .create()
    }
    func revert(on db: any Database) async throws {
        for table in [BuildArtifact.schema, ProjectAgentBrief.schema, TaskProgressNote.schema, TaskReview.schema, TaskQuestion.schema, TaskWorkflow.schema] {
            try await db.schema(table).delete()
        }
    }
}

// MARK: - DTOs

struct QuestionDTO: Content {
    let id: UUID
    let taskID: UUID
    var taskTitle: String?
    var projectID: UUID?
    var projectName: String?
    let askedByType: ActivityActorType
    let askedByID: UUID
    let askedByLabel: String?
    var askedByName: String?
    let prompt: String
    let options: [String]
    let blocking: Bool
    let state: String
    let answer: String?
    let answeredBy: UUID?
    let answeredVia: String?
    let answeredAt: Date?
    let createdAt: Date?
    /// Set when the question belongs to a runner job (mirror of `agent_questions`).
    let agentQuestionID: UUID?
    let version: Int
    init(_ q: TaskQuestion) throws {
        id = try q.requireID(); taskID = q.taskID; askedByType = q.askedByType; askedByID = q.askedByID
        askedByLabel = q.askedByLabel; prompt = q.prompt; options = q.options; blocking = q.blocking; state = q.state
        answer = q.answer; answeredBy = q.answeredBy; answeredVia = q.answeredVia; answeredAt = q.answeredAt
        createdAt = q.createdAt; agentQuestionID = q.agentQuestionID; version = q.version
    }
}

struct ReviewDTO: Content {
    let id: UUID
    let taskID: UUID
    var taskTitle: String?
    var projectID: UUID?
    var projectName: String?
    let state: String
    let requestedByType: ActivityActorType
    let requestedByID: UUID
    let requestedByLabel: String?
    let reviewerID: UUID?
    let summary: String
    let decidedBy: UUID?
    let decidedAt: Date?
    let decisionNote: String?
    let agentJobID: UUID?
    let createdAt: Date?
    let version: Int
    init(_ r: TaskReview) throws {
        id = try r.requireID(); taskID = r.taskID; state = r.state; requestedByType = r.requestedByType
        requestedByID = r.requestedByID; requestedByLabel = r.requestedByLabel; reviewerID = r.reviewerID
        summary = r.summary; decidedBy = r.decidedBy; decidedAt = r.decidedAt; decisionNote = r.decisionNote
        agentJobID = r.agentJobID; createdAt = r.createdAt; version = r.version
    }
}

struct ProgressNoteDTO: Content {
    let id: UUID
    let taskID: UUID
    let actorType: ActivityActorType
    let actorID: UUID
    let actorLabel: String?
    let note: String
    let percent: Int?
    let createdAt: Date?
    init(_ n: TaskProgressNote) throws {
        id = try n.requireID(); taskID = n.taskID; actorType = n.actorType; actorID = n.actorID
        actorLabel = n.actorLabel; note = n.note; percent = n.percent; createdAt = n.createdAt
    }
}

struct BuildArtifactDTO: Content {
    let id: UUID
    let attachmentID: UUID
    let taskID: UUID
    let buildID: String
    let label: String?
    let platform: String?
    let filename: String
    let mediaType: String
    let size: Int
    /// Authenticated image endpoint (session cookie / bearer), valid for images only.
    let previewURL: String
    let createdAt: Date?
}

struct AgentBriefDTO: Content {
    let projectID: UUID
    let text: String
    /// 0 = never written.
    let version: Int
    let updatedAt: Date?
}

struct ProgressDTO: Content {
    /// 0...100
    let percent: Int
    /// `status` | `subtasks` | `criteria` | `agent` | `none`
    let source: String
    let subtasksDone: Int
    let subtasksTotal: Int
    let criteriaDone: Int
    let criteriaTotal: Int
}

struct WorkflowDTO: Content {
    let taskID: UUID
    let kind: String
    let isFeature: Bool
    let parentTaskID: UUID?
    let blockedReason: String?
    let claimedByType: String?
    let claimedByID: UUID?
    let claimedLabel: String?
    let claimedAt: Date?
}

struct TaskContextDTO: Content {
    let task: TaskDTO
    let projectID: UUID
    let workflow: WorkflowDTO
    let progress: ProgressDTO
    let progressNotes: [ProgressNoteDTO]
    let criteria: [CriterionDTO]
    let subtasks: [TaskDTO]
    let comments: [CommentDTO]
    let questions: [QuestionDTO]
    let review: ReviewDTO?
    let builds: [BuildArtifactDTO]
}

// MARK: - Requests

struct ClaimTaskRequest: Content { let agentName: String?; let takeOver: Bool? }
struct ProgressRequest: Content { let note: String; let percent: Int? }
struct AskQuestionRequest: Content {
    let prompt: String
    let options: [String]?
    let blocking: Bool?
    let agentName: String?
    let idempotencyKey: String?
}
struct AnswerQuestionRequest: Content { let answer: String }
struct RequestReviewRequest: Content { let summary: String; let reviewerID: UUID?; let agentName: String? }
struct ReviewDecisionRequest: Content { let decision: String; let note: String? }
struct StructureRequest: Content {
    let kind: String?
    /// `null` removes the parent; absent leaves it unchanged.
    let parentTaskID: UUID??
    /// `null`/empty clears; absent leaves unchanged.
    let blockedReason: String??
    init(kind: String?, parentTaskID: UUID??, blockedReason: String??) {
        self.kind = kind; self.parentTaskID = parentTaskID; self.blockedReason = blockedReason
    }
    private enum CodingKeys: String, CodingKey { case kind, parentTaskID, blockedReason }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        parentTaskID = c.contains(.parentTaskID) ? .some(try c.decodeIfPresent(UUID.self, forKey: .parentTaskID)) : nil
        blockedReason = c.contains(.blockedReason) ? .some(try c.decodeIfPresent(String.self, forKey: .blockedReason)) : nil
    }
}
struct AgentBriefRequest: Content { let text: String; let version: Int }
struct RegisterBuildRequest: Content {
    let attachmentID: UUID
    let buildID: String
    let label: String?
    let platform: String?
}
