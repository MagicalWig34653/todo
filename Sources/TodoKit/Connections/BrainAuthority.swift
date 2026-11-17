import Fluent
import FluentSQL
import SQLKit
import Vapor

/// Proof that an agent decision is covered by the person's brain mandate (ADR 0032).
struct BrainAuthority: Sendable {
    let mandateID: UUID
    let grantID: UUID
    let quote: String
}

/// Reads a row with `SELECT ... FOR UPDATE` and decodes the model from that very result. A plain read after `lockRow` would
/// still see the transaction's old snapshot on MariaDB (repeatable read) and could miss a concurrent revoke. SQLite (tests)
/// serialises writers and has no row locks, so a normal query is equivalent there.
func lockedFirst<M: Model>(_ type: M.Type, column: String, equals value: UUID, on db: any Database) async throws -> M? {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let lock = sql.dialect.name == "sqlite" ? "" : " FOR UPDATE"
    guard let row = try await sql.raw("SELECT * FROM \(ident: M.schema) WHERE \(ident: column) = \(bind: value) LIMIT 1\(unsafeRaw: lock)").first() else { return nil }
    return try row.decode(fluentModel: M.self)
}

extension WorkflowService {
    /// nil for persons. For every other actor the check order of ADR 0032 applies (the own-request check comes before this
    /// one): no active mandate of this very connection -> `brain_mandate_required`; project not in the mandate ->
    /// `outside_brain_mandate`; no or oversized quote -> `quote_required` / `invalid_quote`. The mandate row is locked and
    /// re-read, so a concurrent revoke wins.
    func brainAuthority(for actor: WorkflowActor, projectID: UUID, quote rawQuote: String?, on tx: any Database) async throws -> BrainAuthority? {
        guard actor.type != .person else { return nil }
        let userID = try user.requireID()
        // Lock order everywhere: mandate row, then grant row (see BrainMandateService.grant).
        guard actor.type == .integration,
              let mandate = try await lockedFirst(BrainMandate.self, column: "user_id", equals: userID, on: tx),
              let mandateID = mandate.id, mandate.revokedAt == nil, mandate.grantID == actor.id,
              let grant = try await lockedFirst(OAuthGrant.self, column: "id", equals: actor.id, on: tx),
              !grant.revoked, grant.userID == userID else {
            throw Abort(.forbidden, reason: "brain_mandate_required")
        }
        guard mandate.projects.contains(projectID) else { throw Abort(.forbidden, reason: "outside_brain_mandate") }
        let quote = (rawQuote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { throw Abort(.badRequest, reason: "quote_required") }
        guard quote.count <= BrainMandateLimits.maxQuote else { throw Abort(.badRequest, reason: "invalid_quote") }
        return BrainAuthority(mandateID: mandateID, grantID: actor.id, quote: quote)
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
            }, allowReservedLabel: true, on: tx)
    }
}
