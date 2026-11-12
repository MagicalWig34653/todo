import Fluent
import Vapor

// MARK: - Model

/// Decision journal: a decision an agent took on its own (often overnight), with reasoning, the criterion it was
/// measured by and a pointer to roll it back. The person reviews decisions in the morning instead of code.
final class TaskDecision: Model, @unchecked Sendable {
    static let schema = "task_decisions"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "decision") var decision: String
    @Field(key: "rationale") var rationale: String
    @Field(key: "criterion") var criterion: String
    /// Commit hash or branch that undoes or contains the decision; nil when nothing was changed in code.
    @OptionalField(key: "rollback_ref") var rollbackRef: String?
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "actor_label") var actorLabel: String?
    /// `open` | `ok` | `rolled_back`
    @Field(key: "state") var state: String
    /// Reason of the person; required for `rolled_back` and then retrievable as precedent.
    @OptionalField(key: "review_note") var reviewNote: String?
    @OptionalField(key: "reviewed_by") var reviewedBy: UUID?
    @OptionalField(key: "reviewed_at") var reviewedAt: Date?
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

struct CreateTaskDecisions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        let text = DatabaseSchema.DataType.sql(raw: "TEXT")
        try await db.schema(TaskDecision.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("decision", text, .required).field("rationale", text, .required).field("criterion", text, .required)
            .field("rollback_ref", .string)
            .field("actor_type", .string, .required).field("actor_id", .uuid, .required).field("actor_label", .string)
            .field("state", .string, .required)
            .field("review_note", text).field("reviewed_by", .uuid).field("reviewed_at", .datetime)
            .field("version", .int, .required).field("created_at", .datetime)
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(TaskDecision.schema).delete() }
}

// MARK: - DTOs

struct DecisionDTO: Content, Equatable {
    let id: UUID
    let taskID: UUID
    var taskTitle: String?
    var projectID: UUID?
    var projectName: String?
    let decision: String
    let rationale: String
    let criterion: String
    let rollbackRef: String?
    let actorType: ActivityActorType
    let actorLabel: String?
    /// `open` | `ok` | `rolled_back`
    let state: String
    let reviewNote: String?
    let reviewedAt: Date?
    let createdAt: Date?
    let version: Int
    init(_ d: TaskDecision) throws {
        id = try d.requireID(); taskID = d.taskID; decision = d.decision; rationale = d.rationale; criterion = d.criterion
        rollbackRef = d.rollbackRef; actorType = d.actorType; actorLabel = d.actorLabel; state = d.state
        reviewNote = d.reviewNote; reviewedAt = d.reviewedAt; createdAt = d.createdAt; version = d.version
    }
}

struct RecordDecisionRequest: Content {
    let decision: String
    let rationale: String
    let criterion: String
    let rollbackRef: String?
    let agentName: String?
}

struct DecisionVerdictRequest: Content {
    /// `ok` | `rollback`
    let verdict: String
    let note: String?
}

// MARK: - Service

extension WorkflowService {
    static let decisionTextLimit = 2000

    /// Commit hash, branch or tag name: no spaces, no shell or URL metacharacters.
    static func rollbackRef(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-@+")
        guard value.count <= 200, value.unicodeScalars.allSatisfy(allowed.contains), !value.hasPrefix("-") else {
            throw Abort(.badRequest, reason: "invalid_rollback_ref")
        }
        return value
    }

    func recordDecision(_ taskID: UUID, _ body: RecordDecisionRequest, actor: WorkflowActor) async throws -> DecisionDTO {
        let decision = try Self.text(body.decision, max: Self.decisionTextLimit, reason: "invalid_decision")
        let rationale = try Self.text(body.rationale, max: Self.decisionTextLimit, reason: "invalid_rationale")
        let criterion = try Self.text(body.criterion, max: Self.decisionTextLimit, reason: "invalid_criterion")
        let ref = try Self.rollbackRef(body.rollbackRef)
        let label = try Self.optionalLabel(body.agentName, reason: "invalid_agent_name") ?? actor.label
        return try await mutate(taskID, role: .edit) { task, tx in
            let d = TaskDecision()
            d.taskID = try task.requireID(); d.decision = decision; d.rationale = rationale; d.criterion = criterion
            d.rollbackRef = ref; d.actorType = actor.type; d.actorID = actor.id; d.actorLabel = label
            d.state = "open"; d.version = 1
            try await d.save(on: tx)
            return try DecisionDTO(d)
        }
    }

    /// Journal of the readable scope, newest first. `query` matches decision, rationale, criterion and review note
    /// (case-insensitive); with `state=rolled_back` that is the precedent search.
    func decisions(projectID: UUID?, taskID: UUID?, since: Date?, state: String, query: String?, limit: Int = 50) async throws -> [DecisionDTO] {
        guard ["open", "ok", "rolled_back", "all"].contains(state), (1...200).contains(limit) else { throw Abort(.badRequest, reason: "invalid_filter") }
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: true, allowed: allowedProjects)
        var tasks = TodoTask.query(on: db).filter(\.$projectID ~~ scope.projectIDs)
        if let taskID { tasks = tasks.filter(\.$id == taskID) }
        let taskRows = try await tasks.all()
        guard !taskRows.isEmpty else { return [] }
        let byTask = Dictionary(uniqueKeysWithValues: try taskRows.map { (try $0.requireID(), $0) })
        var q = TaskDecision.query(on: db).filter(\.$taskID ~~ Array(byTask.keys))
        if state != "all" { q = q.filter(\.$state == state) }
        if let since { q = q.filter(\.$createdAt >= since) }
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = try await q.sort(\.$createdAt, .descending).sort(\.$id, .descending).all()
        let matching = rows.filter { row in
            guard let needle, !needle.isEmpty else { return true }
            return [row.decision, row.rationale, row.criterion, row.reviewNote ?? ""].contains { $0.lowercased().contains(needle) }
        }
        return try matching.prefix(limit).map { row in
            var dto = try DecisionDTO(row)
            let task = byTask[row.taskID]
            dto.taskTitle = task?.title; dto.projectID = task?.projectID
            dto.projectName = task.flatMap { scope.projects[$0.projectID]?.name }
            return dto
        }
    }

    /// The person marks a decision `ok` or takes it back (`rollback`, with a reason that stays retrievable as precedent).
    /// An agent connection may review too (on behalf of the person steering it) but never its own decision.
    func reviewDecision(_ decisionID: UUID, _ body: DecisionVerdictRequest, actor: WorkflowActor) async throws -> DecisionDTO {
        guard ["ok", "rollback"].contains(body.verdict) else { throw Abort(.badRequest, reason: "invalid_verdict") }
        let note = try Self.optionalLabel(body.note, max: WorkflowLimits.maxText, reason: "invalid_note")
        if body.verdict == "rollback", note == nil { throw Abort(.badRequest, reason: "note_required") }
        guard let existing = try await TaskDecision.find(decisionID, on: db) else { throw Abort(.notFound) }
        let userID = try user.requireID()
        return try await mutate(existing.taskID, role: .edit) { _, tx in
            guard let d = try await TaskDecision.find(decisionID, on: tx) else { throw Abort(.notFound) }
            if actor.type == .integration, d.actorType == .integration, d.actorID == actor.id {
                throw Abort(.forbidden, reason: "cannot_review_own_decision")
            }
            d.state = body.verdict == "ok" ? "ok" : "rolled_back"
            d.reviewNote = note; d.reviewedBy = userID; d.reviewedAt = Date(); d.version += 1
            try await d.save(on: tx)
            return try DecisionDTO(d)
        }
    }
}
