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
    /// The one person the question is for (ADR 0043).
    @OptionalField(key: "assignee_id") var assigneeID: UUID?
    /// Set when the question was handed to somebody after it was asked.
    @OptionalField(key: "assigned_at") var assignedAt: Date?
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
    /// The review's assignee (ADR 0043): while set (and able to decide), only this person or a manager decides.
    @OptionalField(key: "reviewer_id") var reviewerID: UUID?
    /// Set when the review was handed to somebody after it was requested.
    @OptionalField(key: "assigned_at") var assignedAt: Date?
    @Field(key: "summary") var summary: String
    @OptionalField(key: "decided_by") var decidedBy: UUID?
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "decision_note") var decisionNote: String?
    @OptionalField(key: "agent_job_id") var agentJobID: UUID?
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// Undo snapshot written when a person decides (nil for old rows and runner-backed reviews).
    @OptionalField(key: "undo_status") var undoStatus: String?
    @OptionalField(key: "undo_column_id") var undoColumnID: UUID?
    @OptionalField(key: "undo_task_version") var undoTaskVersion: Int?
    /// Offered variants as JSON text (`[ReviewVariantDTO]`, 2-4 entries); nil = a review without a choice.
    @OptionalField(key: "variants") var variantsJSON: String?
    /// Variant picked when the review was accepted; only set on `accepted` reviews with variants.
    @OptionalField(key: "chosen_variant_id") var chosenVariantID: String?
    init() {}

    /// Asked for by this integration itself. Runner-backed reviews belong to their job and are nobody's "own".
    func isOwnRequest(of type: ActivityActorType, _ id: UUID) -> Bool {
        type == .integration && agentJobID == nil && requestedByType == .integration && requestedByID == id
    }
}

/// One option of a review with variants (card 1D9C8B0C). `attachmentID` points at an attachment (image) of the same task.
struct ReviewVariantDTO: Content, Equatable {
    let id: String
    let label: String
    let description: String?
    let attachmentID: UUID?
}

/// Request shape of a variant; `attachmentID` stays a string so that a malformed one is reported as
/// `invalid_variant_attachment` (422) instead of a generic decoding error.
struct ReviewVariantInput: Content {
    let id: String
    let label: String
    let description: String?
    let attachmentID: String?
}

extension TaskReview {
    var variants: [ReviewVariantDTO]? {
        get {
            guard let json = variantsJSON, let list = try? JSONDecoder().decode([ReviewVariantDTO].self, from: Data(json.utf8)), !list.isEmpty else { return nil }
            return list
        }
        set {
            guard let newValue, !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else { variantsJSON = nil; return }
            variantsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    /// "Variante B gewählt: Label" for an accepted review with a choice; the one-letter id is shown upper case.
    var chosenVariantLine: String? {
        guard let chosenVariantID, let variant = variants?.first(where: { $0.id == chosenVariantID }) else { return nil }
        let name = chosenVariantID.count == 1 ? chosenVariantID.uppercased() : chosenVariantID
        return "Variante \(name) gewählt: \(variant.label)"
    }

    /// Text of the decision for activity views: the choice (if any) plus the note, else the note, else nil.
    var decisionText: String? {
        guard let line = chosenVariantLine else { return decisionNote }
        return decisionNote.map { "\(line) – \($0)" } ?? line
    }
}

/// Additive migration for review variants (card 1D9C8B0C): both columns are nullable, old rows stay reviews without a choice.
struct AddReviewVariants: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskReview.schema).field("variants", .sql(raw: "TEXT")).update()
        try await db.schema(TaskReview.schema).field("chosen_variant_id", .string).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(TaskReview.schema).deleteField("chosen_variant_id").update()
        try await db.schema(TaskReview.schema).deleteField("variants").update()
    }
}

/// Migration for the review undo window (ADR 0020): previous task state and the task version right after the decision.
struct AddReviewUndo: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskReview.schema).field("undo_status", .string).update()
        try await db.schema(TaskReview.schema).field("undo_column_id", .uuid).update()
        try await db.schema(TaskReview.schema).field("undo_task_version", .int).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(TaskReview.schema).deleteField("undo_status").update()
        try await db.schema(TaskReview.schema).deleteField("undo_column_id").update()
        try await db.schema(TaskReview.schema).deleteField("undo_task_version").update()
    }
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
    /// building | succeeded | failed; nil = never reported.
    @OptionalField(key: "status") var status: String?
    /// Explicit commit hash (7-40 lowercase hex); nil = derive from buildID where it looks like one.
    @OptionalField(key: "commit") var commit: String?
    init() {}
}

/// Additive: optional build status and commit. One ALTER per column (SQLite cannot add several at once).
struct AddBuildStatusCommit: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(BuildArtifact.schema).field("status", .string).update()
        try await db.schema(BuildArtifact.schema).field("commit", .string).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(BuildArtifact.schema).deleteField("commit").update()
        try await db.schema(BuildArtifact.schema).deleteField("status").update()
    }
}

/// Removes subtask links that cross a project boundary (children moved to another project before moves unlinked them).
/// Reads additionally ignore such links, so this only cleans up stored data.
struct ClearCrossProjectSubtaskLinks: AsyncMigration {
    func prepare(on db: any Database) async throws {
        let links = try await TaskWorkflow.query(on: db).filter(\.$parentTaskID != nil).all()
        guard !links.isEmpty else { return }
        var projectOf: [UUID: UUID] = [:]
        let ids = Array(Set(links.compactMap(\.id) + links.compactMap(\.parentTaskID)))
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 400, ids.count)]); index += 400
            for task in try await TodoTask.query(on: db).field(\.$id).field(\.$projectID).filter(\.$id ~~ chunk).all() { projectOf[task.id!] = task.projectID }
        }
        for link in links {
            guard let id = link.id, let parent = link.parentTaskID else { continue }
            if projectOf[id] == nil || projectOf[id] != projectOf[parent] { link.parentTaskID = nil; try await link.save(on: db) }
        }
    }
    func revert(on db: any Database) async throws {}
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
    /// The person the question is for (ADR 0043); omitted when nobody is named.
    let assigneeID: UUID?
    init(_ q: TaskQuestion) throws {
        assigneeID = q.assigneeID
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
    /// Same person as `reviewerID`, under the name all assignable objects share (ADR 0043).
    let assigneeID: UUID?
    let summary: String
    let decidedBy: UUID?
    let decidedAt: Date?
    let decisionNote: String?
    let agentJobID: UUID?
    let createdAt: Date?
    let version: Int
    /// End of the undo window for a fresh person decision; nil when not undoable by time or kind.
    let undoUntil: Date?
    /// Derived, only set by review lists: a comment of the mandated brain connection hangs on this review (see `ReviewBrain`, ADR 0032).
    var brainRecommended: Bool? = nil
    /// Offered variants (2-4); absent for a review without a choice.
    let variants: [ReviewVariantDTO]?
    /// Variant picked on acceptance; absent otherwise.
    let chosenVariantID: String?
    init(_ r: TaskReview) throws {
        variants = r.variants; chosenVariantID = r.chosenVariantID
        id = try r.requireID(); taskID = r.taskID; state = r.state; requestedByType = r.requestedByType
        requestedByID = r.requestedByID; requestedByLabel = r.requestedByLabel; reviewerID = r.reviewerID; assigneeID = r.reviewerID
        summary = r.summary; decidedBy = r.decidedBy; decidedAt = r.decidedAt; decisionNote = r.decisionNote
        agentJobID = r.agentJobID; createdAt = r.createdAt; version = r.version
        if r.state != "pending", r.agentJobID == nil, r.undoStatus != nil || r.undoTaskVersion != nil, let at = r.decidedAt {
            let until = at.addingTimeInterval(WorkflowLimits.reviewUndoWindow)
            undoUntil = until > Date() ? until : nil
        } else { undoUntil = nil }
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
    /// building | succeeded | failed; absent when never reported.
    let status: String?
    /// Explicit commit, else the buildID when it looks like a commit hash; absent otherwise.
    let commit: String?
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
    /// True for an in-progress claim without a sign of life for more than 24 hours (flag only, never released automatically).
    var orphaned: Bool = false
    /// Newest sign of life (progress, comment, activity, runner event, claim time); only set while the task is claimed.
    var lastSignOfLifeAt: Date? = nil
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
    /// The one person the question is for; must be able to answer in the project.
    var assigneeID: UUID? = nil
}
/// `freeText: true` answers a question that has options with the person's own text (additive; omitted = one of the options).
struct AnswerQuestionRequest: Content { let answer: String; let freeText: Bool? }
struct RequestReviewRequest: Content {
    let summary: String
    let reviewerID: UUID?
    let agentName: String?
    /// Optional 2-4 variants to choose from (card 1D9C8B0C).
    var variants: [ReviewVariantInput]? = nil
    /// The one person who is to decide; same field as `reviewerID` (ADR 0043).
    var assigneeID: UUID? = nil
}
struct ReviewDecisionRequest: Content {
    let decision: String
    let note: String?
    /// Required when accepting a review with variants; refused otherwise.
    var variantID: String? = nil
}
struct ReviewBatchRequest: Content {
    struct Item: Content { let reviewID: String }
    let decisions: [Item]
    let decision: String
    let note: String?
}
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
    let status: String?
    let commit: String?
    init(attachmentID: UUID, buildID: String, label: String? = nil, platform: String? = nil, status: String? = nil, commit: String? = nil) {
        self.attachmentID = attachmentID; self.buildID = buildID; self.label = label; self.platform = platform
        self.status = status; self.commit = commit
    }
}
