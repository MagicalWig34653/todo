import Fluent
import Vapor

/// Rules of the card pipeline; REST and MCP call these methods. Writes run in `mutate` (sharing graph and task row lock).
extension WorkflowService {
    func pipeline(_ taskID: UUID) async throws -> PipelineDTO {
        _ = try await readableTask(taskID)
        return try await Self.pipelineDTO(taskID, on: db)
    }

    /// A new text is a new version that needs a new approval; the work steps start over.
    func setPlan(_ taskID: UUID, _ request: SetPlanRequest, actor: WorkflowActor) async throws -> PipelineDTO {
        guard let body = try Self.pipelineText(request.body, max: PipelineLimits.maxPlan, reason: "invalid_plan") else {
            throw Abort(.badRequest, reason: "invalid_plan")
        }
        let label = try pipelineLabel(request.agentName, actor: actor)
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let existing = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first()
            // A retry of the write that is still waiting for its decision changes nothing, whatever version it expected.
            if let existing, existing.state == PlanState.proposed, existing.body == body {
                return try await Self.pipelineDTO(id, on: tx)
            }
            if let expected = request.expectedVersion, expected != (existing?.version ?? 0) {
                throw Abort(.conflict, reason: "plan_changed")
            }
            let now = Date()
            let plan = existing ?? TaskPlan()
            plan.taskID = id; plan.version = (existing?.version ?? 0) + 1; plan.body = body; plan.state = PlanState.proposed
            plan.authorType = actor.type; plan.authorID = actor.id; plan.authorLabel = label; plan.writtenAt = now
            plan.decidedAt = nil; plan.decidedByType = nil; plan.decidedByID = nil; plan.decidedByLabel = nil; plan.decisionComment = nil
            try await plan.save(on: tx)
            let work: [PipelineStepName] = [.developer, .validation, .tester, .review]
            try await TaskPipelineStep.query(on: tx).filter(\.$taskID == id).filter(\.$step ~~ work.map(\.rawValue)).delete()
            try await Self.saveStep(id, .planner, state: PipelineStepState.done, note: nil, label: label, actor: actor, at: now, on: tx)
            try await Self.saveStep(id, .approval, state: PipelineStepState.waiting, note: nil, label: label, actor: actor, at: now, on: tx)
            try await Self.audit(id, action: "plan_written", planVersion: plan.version, label: label, actor: actor, at: now, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "plan.written", subjectID: plan.id, on: tx)
            return try await Self.pipelineDTO(id, on: tx)
        }
    }

    /// Persons decide; a connection only under the brain mandate and never on its own plan (same order of refusals as
    /// `decideReview`). The task status and its column stay as they are.
    func decidePlan(_ taskID: UUID, _ request: PlanDecisionRequest, quote: String? = nil, actor: WorkflowActor) async throws -> PipelineDTO {
        guard ["approve", "request_changes"].contains(request.decision) else { throw Abort(.badRequest, reason: "invalid_decision") }
        let approve = request.decision == "approve"
        let comment = try Self.pipelineText(request.comment, max: PipelineLimits.maxComment, reason: "invalid_comment")
        if !approve, comment == nil { throw Abort(.badRequest, reason: "comment_required") }
        guard let version = request.version else { throw Abort(.badRequest, reason: "invalid_version") }
        let label = try pipelineLabel(nil, actor: actor)
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            guard let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first() else {
                throw Abort(.conflict, reason: "no_plan")
            }
            if actor.type == .integration, plan.authorType == .integration, plan.authorID == actor.id {
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
                note: comment, label: label, actor: actor, at: now, on: tx)
            if !approve {
                try await Self.saveStep(id, .planner, state: PipelineStepState.pending, note: nil, label: label, actor: actor, at: now, on: tx)
            }
            try await Self.audit(id, action: approve ? "plan_approved" : "plan_changes_requested", planVersion: plan.version,
                note: comment, label: label, actor: actor, at: now, on: tx)
            let kind = approve ? "plan.approved" : "plan.changes_requested"
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: kind, subjectID: plan.id, on: tx)
            if let authority {
                try await recordBrainDecision(authority, kind: kind, task: task, subjectID: try plan.requireID(), note: comment, actor: actor, on: tx)
            }
            return try await Self.pipelineDTO(id, on: tx)
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
        let label = try pipelineLabel(request.agentName, actor: actor)
        return try await mutate(taskID, role: .edit) { task, tx in
            let id = try task.requireID()
            let plan = try await TaskPlan.query(on: tx).filter(\.$taskID == id).first()
            if step != .planner, state != PipelineStepState.pending, plan?.state != PlanState.approved {
                throw Abort(.conflict, reason: "plan_not_approved")
            }
            let current = try await TaskPipelineStep.query(on: tx).filter(\.$taskID == id).filter(\.$step == step.rawValue).first()
            if (current?.state ?? PipelineStepState.pending) == state, current?.note == note {
                return try await Self.pipelineDTO(id, on: tx)
            }
            let now = Date()
            let row = try await Self.saveStep(id, step, state: state, note: note, label: label, actor: actor, at: now, on: tx)
            try await Self.audit(id, action: "step_changed", planVersion: plan?.version, step: step.rawValue, state: state,
                note: note, label: label, actor: actor, at: now, on: tx)
            try await appendActivity(taskID: id, actorType: actor.type, actorID: actor.id, kind: "pipeline.step", subjectID: row.id, on: tx)
            return try await Self.pipelineDTO(id, on: tx)
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

    /// `agentName`, else the connection's name, else (persons) the account's display name.
    private func pipelineLabel(_ agentName: String?, actor: WorkflowActor) throws -> String? {
        if let name = try Self.optionalLabel(agentName, reason: "invalid_agent_name") {
            let masked = SecretFilter.redact(name).text
            // The label of decisions under the brain mandate is written by the server only. Checked after the filter too,
            // which folds look-alike characters.
            let reserved = CommentService.reservedLabelPrefix.lowercased()
            guard ![name, masked].contains(where: { $0.lowercased().hasPrefix(reserved) }) else {
                throw Abort(.badRequest, reason: "invalid_agent_name")
            }
            return Self.fittingLabel(masked)
        }
        let fallback = actor.label ?? (actor.type == .person ? user.displayName : nil)
        return fallback.map(Self.fittingLabel)
    }

    /// Caller holds the task row lock.
    @discardableResult
    private static func saveStep(_ taskID: UUID, _ step: PipelineStepName, state: String, note: String?, label: String?,
                                 actor: WorkflowActor, at now: Date, on db: any Database) async throws -> TaskPipelineStep {
        let row = try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).filter(\.$step == step.rawValue).first()
            ?? TaskPipelineStep()
        row.taskID = taskID; row.step = step.rawValue; row.state = state; row.note = note
        row.actorType = actor.type; row.actorID = actor.id; row.actorLabel = label; row.updatedAt = now
        try await row.save(on: db)
        return row
    }

    /// Caller holds the task row lock, which serialises the sequence numbers.
    private static func audit(_ taskID: UUID, action: String, planVersion: Int?, step: String? = nil, state: String? = nil,
                              note: String? = nil, label: String?, actor: WorkflowActor, at now: Date, on db: any Database) async throws {
        let last = try await TaskPipelineEvent.query(on: db).filter(\.$taskID == taskID).sort(\.$sequence, .descending).first()?.sequence ?? 0
        let e = TaskPipelineEvent()
        e.taskID = taskID; e.sequence = last + 1; e.action = action; e.planVersion = planVersion; e.step = step; e.state = state
        e.note = note; e.actorType = actor.type; e.actorID = actor.id; e.actorLabel = label; e.createdAt = now
        try await e.save(on: db)
    }

    private static func pipelineDTO(_ taskID: UUID, on db: any Database) async throws -> PipelineDTO {
        let plan = try await TaskPlan.query(on: db).filter(\.$taskID == taskID).first()
        let rows = try await TaskPipelineStep.query(on: db).filter(\.$taskID == taskID).all()
        let byStep = Dictionary(rows.map { ($0.step, $0) }, uniquingKeysWith: { first, _ in first })
        let steps = PipelineStepName.allCases.map { name -> PipelineStepDTO in
            let row = byStep[name.rawValue]
            return PipelineStepDTO(step: name.rawValue, state: row?.state ?? PipelineStepState.pending, note: row?.note,
                actorLabel: row?.actorLabel, updatedAt: row?.updatedAt)
        }
        let events = try await TaskPipelineEvent.query(on: db).filter(\.$taskID == taskID).sort(\.$sequence, .descending)
            .limit(PipelineLimits.maxEvents).all()
        return PipelineDTO(taskID: taskID, plan: plan.map(PlanDTO.init), steps: steps, events: try events.map(PipelineEventDTO.init))
    }
}
