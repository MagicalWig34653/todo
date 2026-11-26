import Fluent
import Vapor

struct BrainMandateDTO: Content {
    let grantID: UUID
    let grantName: String?
    /// What the mandate covers now (ADR 0037: explicit projects plus the rule, cut with the read right).
    let projectIDs: [UUID]
    /// The explicitly chosen projects.
    let explicitProjectIDs: [UUID]
    /// The rule (groups, "all owned except"); absent = only the explicit projects.
    let selection: SelectionDTO?
    /// False when revoked or when the connection's grant itself was revoked (the mandate is then void).
    let active: Bool
    let createdAt: Date
    let updatedAt: Date
    let revokedAt: Date?
    let lastUsedAt: Date?
    /// ADR 0036: why the connection was revoked (`person`, `replay`, `superseded`, `account_locked`); absent otherwise.
    let grantRevokedReason: String?
    /// ADR 0036: set when this connection took the mandate over from an earlier one after a new sign-in.
    let takenOver: BrainTakeoverDTO?
}

struct BrainTakeoverDTO: Content {
    let fromGrantID: UUID
    let fromName: String
    let at: Date
}

/// One entry per connection that holds (or held) a mandate, most recently changed first; `[]` without any.
struct BrainMandateResponse: Content {
    let mandates: [BrainMandateDTO]
}

struct BrainMandateRequest: Content {
    let grantID: UUID
    let projectIDs: [UUID]
    /// ADR 0037: optional rule; absent replaces an existing rule by the plain list (older clients).
    var selection: SelectionInput?
}

struct BrainAuditDTO: Content {
    let id: UUID
    let kind: String
    /// nil for `connection.*` kinds (no card involved).
    let taskID: UUID?
    let projectID: UUID
    /// Review or question id; for `connection.*` kinds the id of the connection whose project list changed; for `pipeline.settings` the project.
    let subjectID: UUID
    /// The deciding or acting connection.
    let grantID: UUID
    let quote: String
    let note: String?
    let createdAt: Date?
    init(_ a: BrainDecisionAudit) throws {
        id = try a.requireID(); kind = a.kind; taskID = a.taskID; projectID = a.projectID; subjectID = a.subjectID
        grantID = a.grantID; quote = a.quote; note = a.note; createdAt = a.createdAt
    }
    init(_ a: BrainConnectionAudit) throws {
        // `pipeline.settings` (card B926E7D8) changes a project, not another connection: its subject is the project.
        id = try a.requireID(); kind = a.kind; taskID = nil; projectID = a.projectID
        subjectID = a.kind == "pipeline.settings" ? a.projectID : a.targetGrantID
        grantID = a.grantID; quote = a.quote; note = nil; createdAt = a.createdAt
    }
}

struct BrainAuditResponse: Content { let items: [BrainAuditDTO] }

enum BrainMandateLimits {
    static let maxProjects = 200
    static let maxQuote = 2000
    static let auditLimit = 200
}

/// ADR 0032 and addendum 23.11.2026: one mandate per connection (grant). The mandate is managed by the person only (REST with a
/// session); agents may only read it.
enum BrainMandateService {
    private static func dto(_ m: BrainMandate, resolver: inout ProjectSelectionResolver, db: any Database) async throws -> BrainMandateDTO {
        let grant = try await OAuthGrant.find(m.grantID, on: db)
        var client: String?
        if let grant { client = try await OAuthClient.find(grant.clientID, on: db)?.name }
        var takenOver: BrainTakeoverDTO?
        if let grant, let from = grant.predecessors?.last, let at = grant.takenOverAt, let old = try await OAuthGrant.find(from, on: db) {
            let oldClient = try await OAuthClient.find(old.clientID, on: db)?.name
            takenOver = BrainTakeoverDTO(fromGrantID: from, fromName: ConnectionNames.display(old, clientName: oldClient), at: at)
        }
        let rule = try await resolver.rule(of: m.requireID())
        return BrainMandateDTO(grantID: m.grantID, grantName: grant.map { ConnectionNames.display($0, clientName: client) },
            projectIDs: try await resolver.resolve(explicit: m.explicitProjects, rule: rule), explicitProjectIDs: m.explicitProjects,
            selection: SelectionDTO(explicit: m.explicitProjects, rule: rule), active: m.revokedAt == nil && grant?.revoked == false,
            createdAt: m.createdAt, updatedAt: m.updatedAt, revokedAt: m.revokedAt, lastUsedAt: grant?.lastUsedAt,
            grantRevokedReason: grant?.revoked == true ? grant?.revokedReason : nil, takenOver: takenOver)
    }

    static func list(userID: UUID, db: any Database) async throws -> [BrainMandateDTO] {
        let rows = try await BrainMandate.query(on: db).filter(\.$userID == userID).sort(\.$updatedAt, .descending).sort(\.$id, .descending).all()
        var out: [BrainMandateDTO] = []
        var resolver = ProjectSelectionResolver(userID: userID, db: db)
        for m in rows { out.append(try await dto(m, resolver: &resolver, db: db)) }
        return out
    }

    /// Gives (or overwrites) the mandate of one connection; the person's other mandates stay as they are. The grant must be the
    /// person's own and not revoked; every project must be readable by the person now.
    static func grant(_ request: BrainMandateRequest, user: User, db: any Database) async throws -> BrainMandateDTO {
        let userID = try user.requireID()
        let projects = Array(Set(request.projectIDs))
        guard projects.count <= BrainMandateLimits.maxProjects else { throw Abort(.badRequest, reason: "invalid_projects") }
        let saved: BrainMandate = try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: User.schema, id: userID, on: tx)
            // Same order as the decision check: mandate row first, then the grant row.
            let existing = try await BrainMandate.query(on: tx).filter(\.$userID == userID).filter(\.$grantID == request.grantID).first()
            if let id = existing?.id { try await lockRow(table: BrainMandate.schema, id: id, on: tx) }
            try await lockRow(table: OAuthGrant.schema, id: request.grantID, on: tx)
            guard let g = try await OAuthGrant.find(request.grantID, on: tx), g.userID == userID else { throw Abort(.notFound) }
            guard !g.revoked else { throw Abort(.conflict, reason: "grant_revoked") }
            let access = ProjectAccess(user: user, db: tx)
            for id in projects { _ = try await access.project(id) }
            // ADR 0037: an optional rule (own groups only); a mandate must name something (projects, a group or "all").
            let resolver = ProjectSelectionResolver(userID: userID, db: tx, locking: true)
            let rule = try await resolver.validate(request.selection)
            guard SelectionRule.namesSomething(projects, rule) else { throw Abort(.badRequest, reason: "invalid_projects") }
            let now = Date()
            let sorted = projects.sorted { $0.uuidString < $1.uuidString }
            let m = existing ?? BrainMandate(userID: userID, grantID: request.grantID, projects: sorted, now: now)
            m.explicitProjects = sorted; m.revokedAt = nil; m.updatedAt = now
            try await m.save(on: tx)
            try await resolver.store(rule, of: m.requireID())
            return m
        }
        var resolver = ProjectSelectionResolver(userID: userID, db: db)
        return try await dto(saved, resolver: &resolver, db: db)
    }

    /// Revokes the mandate of one connection; idempotent, nothing leaks about foreign or unknown grants. Takes effect for the
    /// next decision (decisions re-read the mandate under lock).
    static func revoke(grantID: UUID, user: User, db: any Database) async throws {
        let userID = try user.requireID()
        try await db.transaction { tx in
            // Same order as group changes (ADR 0037), so the two cannot deadlock.
            try await lockSharingGraph(on: tx)
            try await lockRow(table: User.schema, id: userID, on: tx)
            guard let m = try await BrainMandate.query(on: tx).filter(\.$userID == userID).filter(\.$grantID == grantID).first(), m.revokedAt == nil else { return }
            m.revokedAt = Date(); m.updatedAt = m.revokedAt!
            try await m.save(on: tx)
        }
    }

    /// Revokes every active mandate of the person at once.
    static func revokeAll(user: User, db: any Database) async throws {
        let userID = try user.requireID()
        try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: User.schema, id: userID, on: tx)
            let now = Date()
            for m in try await BrainMandate.query(on: tx).filter(\.$userID == userID).filter(\.$revokedAt == .null).all() {
                m.revokedAt = now; m.updatedAt = now
                try await m.save(on: tx)
            }
        }
    }

    static func audit(userID: UUID, db: any Database) async throws -> BrainAuditResponse {
        let decisions = try await BrainDecisionAudit.query(on: db).filter(\.$userID == userID)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(BrainMandateLimits.auditLimit).all()
        let changes = try await BrainConnectionAudit.query(on: db).filter(\.$userID == userID)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(BrainMandateLimits.auditLimit).all()
        // Both tables are cut at the limit first, so the merged newest entries are complete.
        let items = try (decisions.map(BrainAuditDTO.init) + changes.map(BrainAuditDTO.init))
            .sorted { ($0.createdAt ?? .distantPast, $0.id.uuidString) > ($1.createdAt ?? .distantPast, $1.id.uuidString) }
        return BrainAuditResponse(items: Array(items.prefix(BrainMandateLimits.auditLimit)))
    }
}

struct BrainMandateController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let m = routes.grouped("v1", "settings", "brain-mandate")
        m.get(use: get)
        m.put(use: put)
        m.delete(use: removeAll)
        m.delete(":grantID", use: remove)
        m.get("audit", use: audit)
    }
    @Sendable func get(_ req: Request) async throws -> BrainMandateResponse {
        BrainMandateResponse(mandates: try await BrainMandateService.list(userID: req.requireUser().requireID(), db: req.db))
    }
    @Sendable func put(_ req: Request) async throws -> BrainMandateDTO {
        let user = try await req.requireUser()
        return try await BrainMandateService.grant(req.content.decode(BrainMandateRequest.self), user: user, db: req.db)
    }
    /// Without an ID: revoke every mandate. With the grant ID: only that connection's.
    @Sendable func removeAll(_ req: Request) async throws -> HTTPStatus {
        try await BrainMandateService.revokeAll(user: req.requireUser(), db: req.db)
        return .noContent
    }
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        guard let id = req.parameters.get("grantID", as: UUID.self) else { throw Abort(.badRequest, reason: "invalid_grant") }
        try await BrainMandateService.revoke(grantID: id, user: user, db: req.db)
        return .noContent
    }
    @Sendable func audit(_ req: Request) async throws -> BrainAuditResponse {
        try await BrainMandateService.audit(userID: req.requireUser().requireID(), db: req.db)
    }
}
