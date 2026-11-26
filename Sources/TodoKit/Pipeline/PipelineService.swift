import Fluent
import Vapor

/// Rules of the card pipeline; REST and MCP call these methods. Writes run in `mutate` (sharing graph and task row lock).
extension WorkflowService {
    func pipeline(_ taskID: UUID) async throws -> PipelineDTO {
        let task = try await readableTask(taskID)
        return try await Self.pipelineDTO(taskID, projectID: task.projectID, viewer: user, on: db)
    }

    /// A new text is a new version that needs a new approval; the work steps start over.
    func setPlan(_ taskID: UUID, _ request: SetPlanRequest, actor: WorkflowActor) async throws -> PipelineDTO {
        guard let body = try Self.pipelineText(request.body, max: PipelineLimits.maxPlan, reason: "invalid_plan") else {
            throw Abort(.badRequest, reason: "invalid_plan")
        }
        let label = try Self.pipelineLabel(request.agentName, actor: actor)
        let user = self.user
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let existing = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first()
            // A retry of the write that is still waiting for its decision changes nothing, whatever version it expected.
            let settings = try await PipelineSettingsStore.values(task.projectID, on: tx)
            let autoApprove = !settings.enabled(.approval)
            // Without an approval step the text that is still waiting is not a retry: writing it again approves it.
            let unchanged = autoApprove
                ? existing?.state == PlanState.approved && existing?.decidedByType == Self.systemDecider
                : existing?.state == PlanState.proposed
            if let existing, existing.body == body, unchanged {
                return try await Self.pipelineDTO(id, projectID: task.projectID, viewer: user, on: tx)
            }
            if let expected = request.expectedVersion, expected != (existing?.version ?? 0) {
                throw Abort(.conflict, reason: "plan_changed")
            }
            let plan = try await Self.writePlan(task, body: body, existing: existing, settings: settings, label: label, actor: actor, on: tx)
            // Only a person with the start right accepts a plan by writing it (and only when no approval is needed).
            let mayStart = actor.type == .person ? try await PipelineExecution.canStart(user, projectID: task.projectID, on: tx) : false
            if let execution = try await PipelineExecution.find(id, on: tx), execution.isActive {
                if mayStart, plan.state == PlanState.approved {
                    execution.acceptedPlanVersion = plan.version; execution.updatedAt = Date()
                    try await execution.save(on: tx)
                }
                try await PipelineExecution.advance(id, ExecutionTrigger(actor: actor, mayStart: mayStart), on: tx)
            }
            return try await Self.pipelineDTO(id, projectID: task.projectID, viewer: user, on: tx)
        }
    }

    /// A new plan version: the row, the reset work steps, the planner and approval steps, audit and activity. Caller holds
    /// the task row lock.
    static func writePlan(_ task: TodoTask, body: String, existing: TaskPlan?, settings: PipelineSettingsValues, label: String?,
                          actor: WorkflowActor, on tx: any Database) async throws -> TaskPlan {
        let id = try task.requireID()
        let autoApprove = !settings.enabled(.approval)
        let now = Date()
        let plan = existing ?? TaskPlan()
        plan.taskID = id; plan.version = (existing?.version ?? 0) + 1; plan.body = body; plan.state = PlanState.proposed
        plan.authorType = actor.type; plan.authorID = actor.id; plan.authorLabel = label; plan.writtenAt = now
        plan.decidedAt = nil; plan.decidedByType = nil; plan.decidedByID = nil; plan.decidedByLabel = nil; plan.decisionComment = nil
        // Without an approval step a written plan is approved at once, by the system and without a name.
        if autoApprove {
            plan.state = PlanState.approved; plan.decidedAt = now; plan.decidedByType = Self.systemDecider
        }
        try await plan.save(on: tx)
        let work: [PipelineStepName] = [.developer, .validation, .tester, .review]
        try await TaskPipelineStep.query(on: tx).filter(\.$taskID == id).filter(\.$step ~~ work.map(\.rawValue)).delete()
        try await Self.saveStep(id, .planner, state: PipelineStepState.done, note: nil, planVersion: plan.version, label: label, actor: actor, at: now, on: tx)
        try await Self.saveStep(id, .approval, state: autoApprove ? PipelineStepState.skipped : PipelineStepState.waiting, note: nil,
            planVersion: plan.version, label: label, actor: actor, at: now, on: tx)
        let event = try await Self.audit(id, action: "plan_written", planVersion: plan.version, label: label, actor: actor, at: now, on: tx)
        // The activity points to the audit entry: it knows the version and the comment of that very moment (the plan row
        // only knows the current ones).
        try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "plan.written", subjectID: event.id, on: tx)
        return plan
    }

    /// Persons decide; a connection only under the brain mandate and never on its own plan (same order of refusals as
    /// `decideReview`). The task status and its column stay as they are.
    func decidePlan(_ taskID: UUID, _ request: PlanDecisionRequest, quote: String? = nil, actor: WorkflowActor) async throws -> PipelineDTO {
        guard ["approve", "request_changes"].contains(request.decision) else { throw Abort(.badRequest, reason: "invalid_decision") }
        let approve = request.decision == "approve"
        let comment = try Self.pipelineText(request.comment, max: PipelineLimits.maxComment, reason: "invalid_comment")
        if !approve, comment == nil { throw Abort(.badRequest, reason: "comment_required") }
        guard let version = request.version else { throw Abort(.badRequest, reason: "invalid_version") }
        let label = try Self.pipelineLabel(nil, actor: actor)
        let user = self.user
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            guard let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first() else {
                throw Abort(.conflict, reason: "no_plan")
            }
            if actor.type == .integration, plan.authorType == .integration,
               try await OAuthGrant.isSameRequester(plan.authorID, as: actor.id, on: tx) {
                throw Abort(.forbidden, reason: "cannot_decide_own_plan")
            }
            let authority = try await brainAuthority(for: actor, projectID: task.projectID, quote: quote, on: tx)
            guard plan.version == version else { throw Abort(.conflict, reason: "plan_changed") }
            guard plan.state == PlanState.proposed else { throw Abort(.conflict, reason: "plan_not_pending") }
            let now = Date()
            plan.state = approve ? PlanState.approved : PlanState.changesRequested
            plan.decidedAt = now; plan.decidedByType = actor.type.rawValue; plan.decidedByID = actor.id
            plan.decidedByLabel = label; plan.decisionComment = comment
            try await plan.save(on: tx)
            try await Self.saveStep(id, .approval, state: approve ? PipelineStepState.done : PipelineStepState.changesRequested,
                note: comment, planVersion: plan.version, label: label, actor: actor, at: now, on: tx)
            if !approve {
                try await Self.saveStep(id, .planner, state: PipelineStepState.pending, note: nil, planVersion: plan.version, label: label, actor: actor, at: now, on: tx)
            }
            let event = try await Self.audit(id, action: approve ? "plan_approved" : "plan_changes_requested", planVersion: plan.version,
                note: comment, label: label, actor: actor, at: now, on: tx)
            let kind = approve ? "plan.approved" : "plan.changes_requested"
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: kind, subjectID: event.id, on: tx)
            if let authority {
                try await recordBrainDecision(authority, kind: kind, task: task, subjectID: try plan.requireID(), note: comment, actor: actor, on: tx)
            }
            if let execution = try await PipelineExecution.find(id, on: tx), execution.isActive {
                // The start right accepts a plan: the person, or (approval only) a connection under their brain mandate.
                var mayStart = actor.type == .person || (approve && authority != nil)
                if mayStart { mayStart = try await PipelineExecution.canStart(user, projectID: task.projectID, on: tx) }
                if mayStart, approve {
                    execution.acceptedPlanVersion = plan.version; execution.updatedAt = Date()
                    try await execution.save(on: tx)
                }
                try await PipelineExecution.advance(id, ExecutionTrigger(actor: actor, mayStart: mayStart), on: tx)
            }
            return try await Self.pipelineDTO(id, projectID: task.projectID, viewer: user, on: tx)
        }
    }

    func setPipelineStep(_ taskID: UUID, step rawStep: String, _ request: SetPipelineStepRequest, actor: WorkflowActor) async throws -> PipelineDTO {
        guard let step = PipelineStepName(rawValue: rawStep) else { throw Abort(.badRequest, reason: "invalid_step") }
        guard step != .approval else { throw Abort(.conflict, reason: "step_managed") }
        let state = request.state
        guard PipelineStepState.settable.contains(state) else { throw Abort(.badRequest, reason: "invalid_state") }
        // The planner is finished by writing the plan, nothing else.
        if step == .planner, state == PipelineStepState.done || state == PipelineStepState.skipped {
            throw Abort(.conflict, reason: "step_managed")
        }
        let note = try Self.pipelineText(request.note, max: PipelineLimits.maxNote, reason: "invalid_note")
        let label = try Self.pipelineLabel(request.agentName, actor: actor)
        let expected = try Self.expectedPlanVersion(request.planVersion)
        let user = self.user
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first()
            // An agent that works on an older plan must not overwrite the steps of a newer one.
            if let expected, expected != plan?.version { throw Abort(.conflict, reason: "plan_changed") }
            let settings = try await PipelineSettingsStore.values(task.projectID, on: tx)
            guard settings.effectivelyEnabled(step) else { throw Abort(.conflict, reason: "step_disabled") }
            // With the planner off no plan is needed, so there is no gate either.
            if step != .planner, state != PipelineStepState.pending, settings.enabled(.planner), plan?.state != PlanState.approved {
                throw Abort(.conflict, reason: "plan_not_approved")
            }
            let current = try await TaskPipelineStep.query(on: tx).filter(\.$taskID == id).filter(\.$step == step.rawValue).first()
            if (current?.state ?? PipelineStepState.pending) == state, current?.note == note {
                return try await Self.pipelineDTO(id, projectID: task.projectID, viewer: user, on: tx)
            }
            let now = Date()
            let row = try await Self.saveStep(id, step, state: state, note: note, planVersion: plan?.version, label: label, actor: actor, at: now, on: tx)
            try await Self.audit(id, action: "step_changed", planVersion: plan?.version, step: step.rawValue, state: state,
                note: note, label: label, actor: actor, at: now, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "pipeline.step", subjectID: row.id, on: tx)
            return try await Self.pipelineDTO(id, projectID: task.projectID, viewer: user, on: tx)
        }
    }

    /// Back from `failed` to `pending` for this one step, as a counted fix round (`step_retried`). Nothing is started.
    func retryPipelineStep(_ taskID: UUID, step rawStep: String, _ request: RetryPipelineStepRequest, actor: WorkflowActor) async throws -> PipelineDTO {
        guard let step = PipelineStepName(rawValue: rawStep) else { throw Abort(.badRequest, reason: "invalid_step") }
        guard step != .approval else { throw Abort(.conflict, reason: "step_managed") }
        let note = try Self.pipelineText(request.note, max: PipelineLimits.maxNote, reason: "invalid_note")
        let label = try Self.pipelineLabel(request.agentName, actor: actor)
        let expected = try Self.expectedPlanVersion(request.planVersion)
        let user = self.user
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first()
            if let expected, expected != plan?.version { throw Abort(.conflict, reason: "plan_changed") }
            let settings = try await PipelineSettingsStore.values(task.projectID, on: tx)
            guard settings.effectivelyEnabled(step) else { throw Abort(.conflict, reason: "step_disabled") }
            let current = try await TaskPipelineStep.query(on: tx).filter(\.$taskID == id).filter(\.$step == step.rawValue).first()
            guard current?.state == PipelineStepState.failed else { throw Abort(.conflict, reason: "step_not_failed") }
            if step != .planner, settings.enabled(.planner), plan?.state != PlanState.approved {
                throw Abort(.conflict, reason: "plan_not_approved")
            }
            let used = try await Self.fixRoundsUsed(id, planVersion: plan?.version, on: tx)
            guard used < settings.maxFixRounds else { throw Abort(.conflict, reason: "fix_rounds_exhausted") }
            let now = Date()
            let row = try await Self.saveStep(id, step, state: PipelineStepState.pending, note: note, planVersion: plan?.version,
                label: label, actor: actor, at: now, on: tx)
            try await Self.audit(id, action: "step_retried", planVersion: plan?.version, step: step.rawValue, state: PipelineStepState.pending,
                note: note, label: label, actor: actor, at: now, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "pipeline.step", subjectID: row.id, on: tx)
            // A retry queues work only for a person with the start right; otherwise the execution waits for them.
            let mayStart = actor.type == .person ? try await PipelineExecution.canStart(user, projectID: task.projectID, on: tx) : false
            try await PipelineExecution.advance(id, ExecutionTrigger(actor: actor, mayStart: mayStart), on: tx)
            return try await Self.pipelineDTO(id, projectID: task.projectID, viewer: user, on: tx)
        }
    }

    // MARK: Helpers

    /// Free text of an agent or person: line breaks and tabs belong to it, other control characters do not; secrets are
    /// masked before storing. Empty after trimming is nil.
    static func pipelineText(_ raw: String?, max: Int, reason: String) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        // Characters are not bytes: stacked combining marks must not overflow the TEXT columns of MariaDB (65 535 bytes).
        let maxBytes = max > PipelineLimits.maxComment ? 262_144 : 60_000
        func fits(_ text: String) -> Bool { text.count <= max && text.utf8.count <= maxBytes }
        guard fits(value), !value.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && !"\n\r\t".unicodeScalars.contains($0)
        }) else { throw Abort(.badRequest, reason: reason) }
        // The mask and compatibility folding lengthen text, so the limits are checked again on what gets stored. Refused
        // rather than cut: nobody should approve a plan that silently lost its end.
        let masked = SecretFilter.redactLong(value)
        guard fits(masked) else { throw Abort(.badRequest, reason: reason) }
        return masked
    }

    /// Names are cut instead: at most `maxLabel` characters, and no more code points than VARCHAR(255) of MariaDB holds.
    private static func fittingLabel(_ name: String) -> String {
        var result = "", scalars = 0
        for character in name.prefix(PipelineLimits.maxLabel) {
            scalars += character.unicodeScalars.count
            if scalars > PipelineLimits.maxLabelScalars { break }
            result.append(character)
        }
        return result
    }

    /// The stored name: `agentName`, else the connection's name. A person without `agentName` gets none, because a copy
    /// of the account name would outlive the account; `pipelineDTO` reads it from the account.
    private static func pipelineLabel(_ agentName: String?, actor: WorkflowActor) throws -> String? {
        if let name = try Self.optionalLabel(agentName, reason: "invalid_agent_name") {
            let masked = SecretFilter.redact(name).text
            // The label of decisions under the brain mandate is written by the server only. Checked after the filter too,
            // which folds look-alike characters.
            let reserved = CommentService.reservedLabelPrefix.lowercased()
            guard ![name, masked].contains(where: { $0.lowercased().hasPrefix(reserved) }) else {
                throw Abort(.badRequest, reason: "invalid_agent_name")
            }
            return fittingLabel(masked)
        }
        return actor.label.map(fittingLabel)
    }

    /// Caller holds the task row lock.
    @discardableResult
    static func saveStep(_ taskID: UUID, _ step: PipelineStepName, state: String, note: String?, planVersion: Int?, label: String?,
                                 actor: WorkflowActor, at now: Date, on db: any Database) async throws -> TaskPipelineStep {
        let row = try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).filter(\.$step == step.rawValue).first()
            ?? TaskPipelineStep()
        row.taskID = taskID; row.step = step.rawValue; row.state = state; row.note = note; row.planVersion = planVersion
        row.actorType = actor.type; row.actorID = actor.id; row.actorLabel = label; row.updatedAt = now
        try await row.save(on: db)
        return row
    }

    /// Caller holds the task row lock, which serialises the sequence numbers.
    @discardableResult
    static func audit(_ taskID: UUID, action: String, planVersion: Int?, step: String? = nil, state: String? = nil,
                              note: String? = nil, label: String?, actor: WorkflowActor, at now: Date, on db: any Database) async throws -> TaskPipelineEvent {
        let last = try await TaskPipelineEvent.query(on: db).filter(\.$taskID == taskID).sort(\.$sequence, .descending).first()?.sequence ?? 0
        let e = TaskPipelineEvent()
        e.taskID = taskID; e.sequence = last + 1; e.action = action; e.planVersion = planVersion; e.step = step; e.state = state
        e.note = note; e.actorType = actor.type; e.actorID = actor.id; e.actorLabel = label; e.createdAt = now
        try await e.save(on: db)
        return e
    }

    /// `decidedByType` of a plan that was approved without a person (the project has no approval step).
    static let systemDecider = "system"

    /// Optional `planVersion` of a request: at least 1.
    private static func expectedPlanVersion(_ raw: Int?) throws -> Int? {
        guard let raw else { return nil }
        guard raw >= 1 else { throw Abort(.badRequest, reason: "invalid_plan_version") }
        return raw
    }

    /// Fix rounds of the current plan version: how often a failed step was retried since that plan was written.
    static func fixRoundsUsed(_ taskID: UUID, planVersion: Int?, on db: any Database) async throws -> Int {
        let query = TaskPipelineEvent.query(on: db).filter(\.$taskID == taskID).filter(\.$action == "step_retried")
        if let planVersion { return try await query.filter(\.$planVersion == planVersion).count() }
        return try await query.filter(\.$planVersion == .null).count()
    }

    static func pipelineDTO(_ taskID: UUID, projectID: UUID, viewer: User, on db: any Database) async throws -> PipelineDTO {
        let settings = try await PipelineSettingsStore.values(projectID, on: db)
        let plan = try await TaskPlan.query(on: db).filter(\.$taskID == taskID).first()
        let rows = try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).all()
        let byStep = Dictionary(rows.map { ($0.step, $0) }, uniquingKeysWith: { first, _ in first })
        let events = try await TaskPipelineEvent.query(on: db).filter(\.$taskID == taskID).sort(\.$sequence, .descending)
            .limit(PipelineLimits.maxEvents).all()

        // Persons without a stored name are looked up once for the whole answer; a deleted account has none.
        var persons = rows.filter { $0.actorType == .person }.map(\.actorID) + events.filter { $0.actorType == .person }.map(\.actorID)
        if let plan {
            if plan.authorType == .person { persons.append(plan.authorID) }
            if plan.decidedByType == ActivityActorType.person.rawValue, let id = plan.decidedByID { persons.append(id) }
        }
        let names = try await displayNames(persons, on: db)
        func label(_ stored: String?, _ type: ActivityActorType?, _ id: UUID?) -> String? {
            if let stored { return stored }
            guard type == .person, let id else { return nil }
            return names[id].map(fittingLabel)
        }

        let planDTO = plan.map { p in
            PlanDTO(p, authorLabel: label(p.authorLabel, p.authorType, p.authorID),
                decidedByLabel: label(p.decidedByLabel, p.decidedByType.flatMap(ActivityActorType.init(rawValue:)), p.decidedByID))
        }
        // A switched off step shows as `skipped` unless it has a stored state; the stored state itself is never touched.
        let steps = PipelineStepName.allCases.map { name -> PipelineStepDTO in
            let row = byStep[name.rawValue]
            let enabled = settings.effectivelyEnabled(name)
            let role = PipelineRoleName.of(name).map { settings.roles[$0.rawValue] ?? PipelineRoleValue() }
            return PipelineStepDTO(step: name.rawValue, state: row?.state ?? (enabled ? PipelineStepState.pending : PipelineStepState.skipped),
                note: row?.note, actorLabel: label(row?.actorLabel, row?.actorType, row?.actorID), updatedAt: row?.updatedAt,
                enabled: enabled, planVersion: row?.planVersion, role: role)
        }
        let used = try await fixRoundsUsed(taskID, planVersion: plan?.version, on: db)
        return PipelineDTO(taskID: taskID, plan: planDTO, steps: steps,
            events: try events.map { try PipelineEventDTO($0, actorLabel: label($0.actorLabel, $0.actorType, $0.actorID)) },
            settings: PipelineSettingsSummaryDTO(settings), fixRounds: FixRoundsDTO(used: used, max: settings.maxFixRounds),
            waitingApproval: plan?.state == PlanState.proposed && settings.enabled(.approval),
            execution: try await PipelineExecution.dto(taskID, viewer: viewer, on: db))
    }
}
