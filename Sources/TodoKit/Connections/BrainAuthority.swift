import Fluent
import Vapor

/// Proof that an agent decision is covered by the person's brain mandate (ADR 0032).
struct BrainAuthority: Sendable {
    let mandateID: UUID
    let grantID: UUID
    let quote: String
}

extension WorkflowService {
    /// nil for persons. For every other actor the check order of ADR 0032 applies (the own-request check comes before this
    /// one): no active mandate of this very connection -> `brain_mandate_required`; project not in the mandate ->
    /// `outside_brain_mandate`; no or oversized quote -> `quote_required` / `invalid_quote`. The mandate row is locked and
    /// re-read, so a concurrent revoke wins.
    func brainAuthority(for actor: WorkflowActor, projectID: UUID, quote rawQuote: String?, on tx: any Database) async throws -> BrainAuthority? {
        guard actor.type != .person else { return nil }
        let userID = try user.requireID()
        guard actor.type == .integration,
              let probe = try await BrainMandate.query(on: tx).filter(\.$userID == userID).filter(\.$grantID == actor.id).first(),
              let mandateID = probe.id else { throw Abort(.forbidden, reason: "brain_mandate_required") }
        try await lockRow(table: BrainMandate.schema, id: mandateID, on: tx)
        guard let mandate = try await BrainMandate.find(mandateID, on: tx), mandate.revokedAt == nil, mandate.grantID == actor.id,
              let grant = try await OAuthGrant.find(actor.id, on: tx), !grant.revoked, grant.userID == userID else {
            throw Abort(.forbidden, reason: "brain_mandate_required")
        }
        guard mandate.projects.contains(projectID) else { throw Abort(.forbidden, reason: "outside_brain_mandate") }
        let quote = (rawQuote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { throw Abort(.badRequest, reason: "quote_required") }
        guard quote.count <= BrainMandateLimits.maxQuote else { throw Abort(.badRequest, reason: "invalid_quote") }
        return BrainAuthority(mandateID: mandateID, grantID: actor.id, quote: quote)
    }

    /// Same checks in a short transaction of their own, for the runner-backed paths that delegate to `AgentService`.
    func brainAuthority(for actor: WorkflowActor, projectID: UUID, quote: String?) async throws -> BrainAuthority? {
        guard actor.type != .person else { return nil }
        return try await db.transaction { tx in try await brainAuthority(for: actor, projectID: projectID, quote: quote, on: tx) }
    }

    static func brainLabel(_ user: User) -> String { "Brain im Auftrag von \(String(user.displayName.prefix(60)))" }

    /// Audit row and chat comment in the caller's decision transaction (the caller holds the task row lock).
    func recordBrainDecision(_ authority: BrainAuthority, kind: String, task: TodoTask, subjectID: UUID, note: String?,
                             actor: WorkflowActor, on tx: any Database) async throws {
        let row = BrainDecisionAudit()
        row.mandateID = authority.mandateID; row.userID = try user.requireID(); row.grantID = authority.grantID
        row.kind = kind; row.taskID = try task.requireID(); row.projectID = task.projectID; row.subjectID = subjectID
        row.quote = authority.quote; row.note = note; row.createdAt = Date()
        try await row.save(on: tx)
        let target: CommentService.Target = kind.hasPrefix("question.") ? .init(questionID: subjectID) : .init(reviewID: subjectID)
        _ = try await CommentService.create(taskID: row.taskID, user: user,
            body: "Entscheidung von \(user.displayName) (Zitat): „\(authority.quote)“", idempotencyKey: nil,
            actor: (actor.type, actor.id), target: target, agentLabel: Self.brainLabel(user),
            scope: { [allowedProjects] t in
                if let allowedProjects, !allowedProjects.contains(t.projectID) { throw Abort(.notFound) }
            }, on: tx)
    }

    /// Runner-backed decisions: the job transition ran in its own transaction, audit and comment follow.
    func recordBrainDecisionAfterDelegation(_ authority: BrainAuthority, kind: String, taskID: UUID, subjectID: UUID, note: String?,
                                            actor: WorkflowActor) async throws {
        try await mutate(taskID, role: .comment) { task, tx in
            try await recordBrainDecision(authority, kind: kind, task: task, subjectID: subjectID, note: note, actor: actor, on: tx)
        }
    }
}
