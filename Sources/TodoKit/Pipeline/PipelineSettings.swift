import Fluent
import Vapor

// Pipeline stage 2 (card B926E7D8, docs/PLAN-PIPELINE-STUFE-2.md): per-project settings of the card pipeline. Status and
// settings only; nothing here starts anything (the runner is stage 3).

/// Roles that carry a model and an effort; each belongs to one step (`validation` runs without an agent, `approval` is a person).
enum PipelineRoleName: String, CaseIterable, Sendable {
    case planner, developer, tester, reviewer

    var step: PipelineStepName {
        switch self {
        case .planner: return .planner
        case .developer: return .developer
        case .tester: return .tester
        case .reviewer: return .review
        }
    }
    static func of(_ step: PipelineStepName) -> PipelineRoleName? { allCases.first { $0.step == step } }
}

enum PipelineSettingsLimits {
    static let defaultMaxFixRounds = 3
    static let maxFixRoundsCeiling = 10
    static let maxModel = 100
    static let historyLimit = 20
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static let maxSummary = 2000
}

/// Model and effort of one role; both missing = default of the runner. Nil fields are not written to JSON.
struct PipelineRoleValue: Content, Equatable, Sendable {
    var model: String? = nil
    var effort: String? = nil
}

/// The effective settings of a project (defaults without a row).
struct PipelineSettingsValues: Equatable, Sendable {
    var steps: [String: Bool]
    var roles: [String: PipelineRoleValue]
    var maxFixRounds: Int
    var notifyOnWaitingApproval: Bool
    var revision: Int = 0

    static var defaults: PipelineSettingsValues {
        PipelineSettingsValues(steps: Dictionary(uniqueKeysWithValues: PipelineStepName.allCases.map { ($0.rawValue, true) }),
            roles: Dictionary(uniqueKeysWithValues: PipelineRoleName.allCases.map { ($0.rawValue, PipelineRoleValue()) }),
            maxFixRounds: PipelineSettingsLimits.defaultMaxFixRounds, notifyOnWaitingApproval: true)
    }

    func enabled(_ step: PipelineStepName) -> Bool { steps[step.rawValue] ?? true }

    /// What the card shows: with the planner off nobody approves anything, so `approval` is off with it.
    func effectivelyEnabled(_ step: PipelineStepName) -> Bool {
        step == .approval ? enabled(.approval) && enabled(.planner) : enabled(step)
    }

    /// A proposed plan is announced (feed, command center, push) only when somebody is meant to approve it.
    var announcesWaitingPlans: Bool { enabled(.approval) && notifyOnWaitingApproval }

    /// Same settings, whatever the revision.
    func sameContent(as other: PipelineSettingsValues) -> Bool {
        steps == other.steps && roles == other.roles && maxFixRounds == other.maxFixRounds
            && notifyOnWaitingApproval == other.notifyOnWaitingApproval
    }
}

// MARK: - Models

/// One row per project, created by the first write. Gone with its project.
final class ProjectPipelineSettings: Model, @unchecked Sendable {
    static let schema = "project_pipeline_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "revision") var revision: Int
    @Field(key: "steps") var steps: [String: Bool]
    @Field(key: "roles") var roles: [String: PipelineRoleValue]
    @Field(key: "max_fix_rounds") var maxFixRounds: Int
    @Field(key: "notify_on_waiting_approval") var notifyOnWaitingApproval: Bool
    @Field(key: "updated_at") var updatedAt: Date
    @Field(key: "updated_by_type") var updatedByType: ActivityActorType
    @Field(key: "updated_by_id") var updatedByID: UUID
    /// Only the name a connection reported; a person's name is read from the account (it ends with it).
    @OptionalField(key: "updated_by_label") var updatedByLabel: String?
    init() {}

    var values: PipelineSettingsValues {
        var result = PipelineSettingsValues.defaults
        for (key, value) in steps where result.steps[key] != nil { result.steps[key] = value }
        for (key, value) in roles where result.roles[key] != nil { result.roles[key] = value }
        result.maxFixRounds = maxFixRounds; result.notifyOnWaitingApproval = notifyOnWaitingApproval; result.revision = revision
        return result
    }
}

/// Audit trail of the settings of a project; `sequence` orders the entries independently of timestamp precision.
final class ProjectPipelineSettingsEvent: Model, @unchecked Sendable {
    static let schema = "project_pipeline_settings_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "sequence") var sequence: Int
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "actor_label") var actorLabel: String?
    @Field(key: "summary") var summary: String
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

/// Additive: two new tables, removed with their project. No foreign key to accounts (see `CreateTaskPipeline`).
struct CreateProjectPipelineSettings: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ProjectPipelineSettings.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("revision", .int, .required)
            .field("steps", .json, .required).field("roles", .json, .required)
            .field("max_fix_rounds", .int, .required).field("notify_on_waiting_approval", .bool, .required)
            .field("updated_at", .datetime, .required)
            .field("updated_by_type", .string, .required).field("updated_by_id", .uuid, .required).field("updated_by_label", .string)
            .unique(on: "project_id", name: "uq_project_pipeline_settings_project")
            .create()
        try await db.schema(ProjectPipelineSettingsEvent.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("sequence", .int, .required)
            .field("actor_type", .string, .required).field("actor_id", .uuid, .required).field("actor_label", .string)
            .field("summary", .sql(raw: "TEXT"), .required)
            .field("created_at", .datetime, .required)
            .unique(on: "project_id", "sequence", name: "uq_project_pipeline_settings_events_sequence")
            .create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ProjectPipelineSettingsEvent.schema).delete()
        try await db.schema(ProjectPipelineSettings.schema).delete()
    }
}

/// Plan version a stored step state refers to. Nullable: rows of stage 1 stay valid without a value.
struct AddPlanVersionToPipelineSteps: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskPipelineStep.schema).field("plan_version", .int).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(TaskPipelineStep.schema).deleteField("plan_version").update()
    }
}

// MARK: - Reading

enum PipelineSettingsStore {
    static func values(_ projectID: UUID, on db: any Database) async throws -> PipelineSettingsValues {
        try await ProjectPipelineSettings.query(on: db).filter(\.$projectID == projectID).first()?.values ?? .defaults
    }

    /// One query for several projects; projects without a row get the defaults.
    static func values(for projectIDs: [UUID], on db: any Database) async throws -> [UUID: PipelineSettingsValues] {
        var result = Dictionary(projectIDs.map { ($0, PipelineSettingsValues.defaults) }, uniquingKeysWith: { first, _ in first })
        let unique = Array(Set(projectIDs))
        var index = 0
        while index < unique.count {
            let end = min(index + 400, unique.count)
            for row in try await ProjectPipelineSettings.query(on: db).filter(\.$projectID ~~ Array(unique[index..<end])).all() {
                result[row.projectID] = row.values
            }
            index = end
        }
        return result
    }

    /// Plans in state `proposed` among `taskIDs` that somebody is meant to approve (the project has `approval` on and notifies).
    /// The pairs carry the task's project so that callers do not load it twice.
    static func waitingPlans(taskIDs: [UUID], projectOf: [UUID: UUID], on db: any Database) async throws -> [TaskPlan] {
        guard !taskIDs.isEmpty else { return [] }
        var plans: [TaskPlan] = []
        var index = 0
        while index < taskIDs.count {
            let end = min(index + 400, taskIDs.count)
            plans += try await TaskPlan.query(on: db).filter(\.$taskID ~~ Array(taskIDs[index..<end])).filter(\.$state == PlanState.proposed).all()
            index = end
        }
        let settings = try await values(for: Array(Set(plans.compactMap { projectOf[$0.taskID] })), on: db)
        return plans.filter { plan in projectOf[plan.taskID].flatMap { settings[$0] }?.announcesWaitingPlans ?? false }
    }

    static func dto(_ projectID: UUID, on db: any Database) async throws -> PipelineSettingsDTO {
        let row = try await ProjectPipelineSettings.query(on: db).filter(\.$projectID == projectID).first()
        let events = try await ProjectPipelineSettingsEvent.query(on: db).filter(\.$projectID == projectID)
            .sort(\.$sequence, .descending).limit(PipelineSettingsLimits.historyLimit).all()
        var persons = events.filter { $0.actorType == .person }.map(\.actorID)
        if let row, row.updatedByType == .person { persons.append(row.updatedByID) }
        let names = try await displayNames(persons, on: db)
        func label(_ stored: String?, _ type: ActivityActorType, _ id: UUID) -> String? {
            stored ?? (type == .person ? names[id].map { String($0.prefix(PipelineLimits.maxLabel)) } : nil)
        }
        let values = row?.values ?? .defaults
        return PipelineSettingsDTO(projectID: projectID, revision: values.revision, steps: values.steps, roles: values.roles,
            maxFixRounds: values.maxFixRounds, notifyOnWaitingApproval: values.notifyOnWaitingApproval,
            updatedAt: row?.updatedAt, updatedByLabel: row.flatMap { label($0.updatedByLabel, $0.updatedByType, $0.updatedByID) },
            history: try events.map { e in
                PipelineSettingsEventDTO(id: try e.requireID(), actorType: e.actorType.rawValue.lowercased(),
                    actorLabel: label(e.actorLabel, e.actorType, e.actorID), summary: e.summary, createdAt: e.createdAt)
            })
    }
}

// MARK: - DTOs

struct PipelineSettingsEventDTO: Content {
    let id: UUID
    let actorType: String
    let actorLabel: String?
    let summary: String
    let createdAt: Date
}

struct PipelineSettingsDTO: Content {
    let projectID: UUID
    let revision: Int
    let steps: [String: Bool]
    let roles: [String: PipelineRoleValue]
    let maxFixRounds: Int
    let notifyOnWaitingApproval: Bool
    let updatedAt: Date?
    let updatedByLabel: String?
    /// The latest `PipelineSettingsLimits.historyLimit` changes, newest first.
    let history: [PipelineSettingsEventDTO]
}

/// The settings as part of a card's pipeline (without history).
struct PipelineSettingsSummaryDTO: Content {
    let revision: Int
    let steps: [String: Bool]
    let roles: [String: PipelineRoleValue]
    let maxFixRounds: Int
    let notifyOnWaitingApproval: Bool
    init(_ v: PipelineSettingsValues) {
        revision = v.revision; steps = v.steps; roles = v.roles; maxFixRounds = v.maxFixRounds; notifyOnWaitingApproval = v.notifyOnWaitingApproval
    }
}

// MARK: - Partial update

/// A validated partial update; shared by REST and MCP (both hand over the JSON object they received).
struct PipelineSettingsPatch: Equatable, Sendable {
    enum Change: Equatable, Sendable { case set(String), clear }

    var revision: Int
    var steps: [String: Bool] = [:]
    /// role name -> `model` | `effort` -> change
    var roles: [String: [String: Change]] = [:]
    var maxFixRounds: Int? = nil
    var notifyOnWaitingApproval: Bool? = nil

    private static var invalid: Abort { Abort(.badRequest, reason: "invalid_pipeline_settings") }

    private static func whole(_ value: JSONValue?) -> Int? {
        guard let value, case .number(let n) = value, n.isFinite, n == n.rounded(), abs(n) < 1e9 else { return nil }
        return Int(n)
    }

    static func parse(_ raw: JSONValue) throws -> PipelineSettingsPatch {
        guard case .object(let object) = raw,
              Set(object.keys).isSubset(of: ["revision", "steps", "roles", "maxFixRounds", "notifyOnWaitingApproval"]),
              let revision = whole(object["revision"]), revision >= 0 else { throw invalid }
        var patch = PipelineSettingsPatch(revision: revision)
        if let value = object["steps"] {
            guard case .object(let steps) = value, Set(steps.keys).isSubset(of: Set(PipelineStepName.allCases.map(\.rawValue))) else { throw invalid }
            for (key, flag) in steps {
                guard case .bool(let on) = flag else { throw invalid }
                patch.steps[key] = on
            }
        }
        if let value = object["roles"] {
            guard case .object(let roles) = value, Set(roles.keys).isSubset(of: Set(PipelineRoleName.allCases.map(\.rawValue))) else { throw invalid }
            for (name, fields) in roles {
                guard case .object(let fields) = fields, Set(fields.keys).isSubset(of: ["model", "effort"]) else { throw invalid }
                var changes: [String: Change] = [:]
                if let model = fields["model"] { changes["model"] = try parseModel(model) }
                if let effort = fields["effort"] { changes["effort"] = try parseEffort(effort) }
                if !changes.isEmpty { patch.roles[name] = changes }
            }
        }
        if let value = object["maxFixRounds"] {
            guard let n = whole(value), (0...PipelineSettingsLimits.maxFixRoundsCeiling).contains(n) else { throw invalid }
            patch.maxFixRounds = n
        }
        if let value = object["notifyOnWaitingApproval"] {
            guard case .bool(let on) = value else { throw invalid }
            patch.notifyOnWaitingApproval = on
        }
        guard !patch.steps.isEmpty || !patch.roles.isEmpty || patch.maxFixRounds != nil || patch.notifyOnWaitingApproval != nil else { throw invalid }
        return patch
    }

    /// Free but narrow: letters, digits and `._:/-` only, so that a model name can never carry text or secrets.
    private static func parseModel(_ value: JSONValue) throws -> Change {
        if case .null = value { return .clear }
        guard case .string(let raw) = value else { throw Abort(.badRequest, reason: "invalid_model") }
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")
        guard !model.isEmpty, model.count <= PipelineSettingsLimits.maxModel, model.allSatisfy({ allowed.contains($0) }) else {
            throw Abort(.badRequest, reason: "invalid_model")
        }
        return .set(model)
    }

    private static func parseEffort(_ value: JSONValue) throws -> Change {
        if case .null = value { return .clear }
        guard case .string(let effort) = value, PipelineSettingsLimits.efforts.contains(effort) else { throw Abort(.badRequest, reason: "invalid_effort") }
        return .set(effort)
    }

    func applying(to current: PipelineSettingsValues) -> PipelineSettingsValues {
        var next = current
        for (key, on) in steps { next.steps[key] = on }
        for (name, changes) in roles {
            var role = next.roles[name] ?? PipelineRoleValue()
            if let change = changes["model"] { role.model = { if case .set(let v) = change { return v }; return nil }() }
            if let change = changes["effort"] { role.effort = { if case .set(let v) = change { return v }; return nil }() }
            next.roles[name] = role
        }
        if let maxFixRounds { next.maxFixRounds = maxFixRounds }
        if let notifyOnWaitingApproval { next.notifyOnWaitingApproval = notifyOnWaitingApproval }
        return next
    }

    /// Short text of what really changed, e.g. `steps.tester aus; roles.developer.model sonnet`.
    static func summary(from old: PipelineSettingsValues, to new: PipelineSettingsValues) -> String {
        var parts: [String] = []
        for step in PipelineStepName.allCases where old.enabled(step) != new.enabled(step) {
            parts.append("steps.\(step.rawValue) \(new.enabled(step) ? "an" : "aus")")
        }
        for role in PipelineRoleName.allCases {
            let before = old.roles[role.rawValue] ?? PipelineRoleValue(), after = new.roles[role.rawValue] ?? PipelineRoleValue()
            if before.model != after.model { parts.append("roles.\(role.rawValue).model \(after.model ?? "Standard")") }
            if before.effort != after.effort { parts.append("roles.\(role.rawValue).effort \(after.effort ?? "Standard")") }
        }
        if old.maxFixRounds != new.maxFixRounds { parts.append("maxFixRounds \(new.maxFixRounds)") }
        if old.notifyOnWaitingApproval != new.notifyOnWaitingApproval { parts.append("notifyOnWaitingApproval \(new.notifyOnWaitingApproval ? "an" : "aus")") }
        return String(parts.joined(separator: "; ").prefix(PipelineSettingsLimits.maxSummary))
    }
}

// MARK: - Service

extension WorkflowService {
    func pipelineSettings(_ projectID: UUID) async throws -> PipelineSettingsDTO {
        _ = try await project(projectID)
        return try await PipelineSettingsStore.dto(projectID, on: db)
    }

    /// `manage` on the project. A connection also needs the brain mandate for this project and the person's quote (like
    /// `decide_plan`); the decision is entered in the mandate log with kind `pipeline.settings`. The same content changes
    /// nothing (neither revision nor history), whatever revision the repetition carries.
    func updatePipelineSettings(_ projectID: UUID, _ raw: JSONValue, quote: String? = nil, actor: WorkflowActor) async throws -> PipelineSettingsDTO {
        let patch = try PipelineSettingsPatch.parse(raw)
        let user = self.user, allowed = allowedProjects
        return try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: Project.schema, id: projectID, on: tx)
            if let allowed, !allowed.contains(projectID) { throw Abort(.notFound) }
            _ = try await ProjectAccess(user: user, db: tx).project(projectID, role: .manage)
            let authority = try await brainAuthority(for: actor, projectID: projectID, quote: quote, on: tx)
            let existing = try await ProjectPipelineSettings.query(on: tx).filter(\.$projectID == projectID).first()
            let current = existing?.values ?? .defaults
            let next = patch.applying(to: current)
            if next.sameContent(as: current) { return try await PipelineSettingsStore.dto(projectID, on: tx) }
            guard patch.revision == current.revision else { throw Abort(.conflict, reason: "revision_conflict") }

            let now = Date()
            let label = actor.type == .person ? nil : actor.label.map { String($0.prefix(PipelineLimits.maxLabel)) }
            let row = existing ?? ProjectPipelineSettings()
            row.projectID = projectID; row.revision = current.revision + 1
            row.steps = next.steps; row.roles = next.roles; row.maxFixRounds = next.maxFixRounds
            row.notifyOnWaitingApproval = next.notifyOnWaitingApproval
            row.updatedAt = now; row.updatedByType = actor.type; row.updatedByID = actor.id; row.updatedByLabel = label
            try await row.save(on: tx)

            let last = try await ProjectPipelineSettingsEvent.query(on: tx).filter(\.$projectID == projectID)
                .sort(\.$sequence, .descending).first()?.sequence ?? 0
            let event = ProjectPipelineSettingsEvent()
            event.projectID = projectID; event.sequence = last + 1; event.actorType = actor.type; event.actorID = actor.id
            event.actorLabel = label; event.summary = PipelineSettingsPatch.summary(from: current, to: next); event.createdAt = now
            try await event.save(on: tx)

            if let authority {
                // `brain_decision_audits` is about a card (task_id NOT NULL); the mandate log of project-level changes is the
                // table of the connection changes (card E71B0FF1), which has no card either.
                let audit = BrainConnectionAudit()
                audit.mandateID = authority.mandateID; audit.userID = try user.requireID(); audit.grantID = authority.grantID
                audit.targetGrantID = authority.grantID; audit.kind = "pipeline.settings"; audit.projectID = projectID
                audit.quote = authority.quote; audit.createdAt = now
                try await audit.save(on: tx)
            }
            return try await PipelineSettingsStore.dto(projectID, on: tx)
        }
    }
}
