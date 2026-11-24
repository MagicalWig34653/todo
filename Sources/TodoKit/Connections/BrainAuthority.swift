import Fluent
import FluentSQL
import SQLKit
import Vapor

/// Proof that an agent decision is covered by the person's brain mandate (ADR 0032).
struct BrainAuthority: Sendable {
    let mandateID: UUID
    let grantID: UUID
    let quote: String
    /// The projects of the mandate as read under lock (callers that change several projects need them).
    let mandateProjects: [UUID]
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

/// The mandate of exactly this connection, read under `FOR UPDATE` (one mandate per person and connection).
func lockedMandate(userID: UUID, grantID: UUID, on db: any Database) async throws -> BrainMandate? {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let lock = sql.dialect.name == "sqlite" ? "" : " FOR UPDATE"
    guard let row = try await sql.raw("SELECT * FROM \(ident: BrainMandate.schema) WHERE \(ident: "user_id") = \(bind: userID) AND \(ident: "grant_id") = \(bind: grantID) LIMIT 1\(unsafeRaw: lock)").first() else { return nil }
    return try row.decode(fluentModel: BrainMandate.self)
}

/// The check of ADR 0032 for one or several projects, shared by agent decisions (`WorkflowService.brainAuthority`) and by
/// `set_connection_projects` (addendum 24.11.2026). Order: no active mandate of this very connection ->
/// `brain_mandate_required`; a project not in the mandate -> `outside_brain_mandate`; no or oversized quote ->
/// `quote_required` / `invalid_quote`. Lock order: the mandate row, then the grant rows (the caller's and every one in
/// `alsoLocking`, in ascending id order so two calls in opposite directions cannot deadlock). All rows are read under
/// `FOR UPDATE`, so a concurrent revoke wins.
///
/// `afterLock` runs once the rows are locked and before the mandate itself is judged: it lets a caller reject problems of the
/// locked target grants first (they must not depend on whether a mandate exists).
func lockedBrainAuthority(userID: UUID, grantID: UUID, projectIDs: [UUID], quote rawQuote: String?, alsoLocking others: [UUID] = [],
                          afterLock: ([UUID: OAuthGrant]) throws -> Void = { _ in },
                          on tx: any Database) async throws -> (authority: BrainAuthority, grants: [UUID: OAuthGrant]) {
    let mandate = try await lockedMandate(userID: userID, grantID: grantID, on: tx)
    var locked: [UUID: OAuthGrant] = [:]
    for id in Set([grantID] + others).sorted(by: { $0.uuidString < $1.uuidString }) {
        if let g = try await lockedFirst(OAuthGrant.self, column: "id", equals: id, on: tx) { locked[id] = g }
    }
    try afterLock(locked)
    guard let mandate, let mandateID = mandate.id, mandate.revokedAt == nil,
          let own = locked[grantID], !own.revoked, own.userID == userID else {
        throw Abort(.forbidden, reason: "brain_mandate_required")
    }
    guard projectIDs.allSatisfy({ mandate.projects.contains($0) }) else { throw Abort(.forbidden, reason: "outside_brain_mandate") }
    let quote = (rawQuote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !quote.isEmpty else { throw Abort(.badRequest, reason: "quote_required") }
    guard quote.count <= BrainMandateLimits.maxQuote else { throw Abort(.badRequest, reason: "invalid_quote") }
    return (BrainAuthority(mandateID: mandateID, grantID: grantID, quote: quote, mandateProjects: mandate.projects), locked)
}

extension WorkflowService {
    /// nil for persons. For every other actor the check order of ADR 0032 applies (the own-request check comes before this
    /// one), see `lockedBrainAuthority`.
    func brainAuthority(for actor: WorkflowActor, projectID: UUID, quote rawQuote: String?, on tx: any Database) async throws -> BrainAuthority? {
        guard actor.type != .person else { return nil }
        guard actor.type == .integration else { throw Abort(.forbidden, reason: "brain_mandate_required") }
        return try await lockedBrainAuthority(userID: user.requireID(), grantID: actor.id, projectIDs: [projectID], quote: rawQuote, on: tx).authority
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
