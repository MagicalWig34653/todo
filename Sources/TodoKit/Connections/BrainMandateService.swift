import Fluent
import Vapor

struct BrainMandateDTO: Content {
    let grantID: UUID
    let grantName: String?
    let projectIDs: [UUID]
    /// False when revoked or when the connection's grant itself was revoked (the mandate is then void).
    let active: Bool
    let createdAt: Date
    let updatedAt: Date
    let revokedAt: Date?
    let lastUsedAt: Date?
}

/// One entry per connection that holds (or held) a mandate, most recently changed first; `[]` without any.
struct BrainMandateResponse: Content {
    let mandates: [BrainMandateDTO]
}

struct BrainMandateRequest: Content {
    let grantID: UUID
    let projectIDs: [UUID]
}

struct BrainAuditDTO: Content {
    let id: UUID
    let kind: String
    /// nil for `connection.*` kinds (no card involved).
    let taskID: UUID?
    let projectID: UUID
    /// Review or question id; for `connection.*` kinds the id of the connection whose project list changed.
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
        id = try a.requireID(); kind = a.kind; taskID = nil; projectID = a.projectID; subjectID = a.targetGrantID
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
    private static func dto(_ m: BrainMandate, db: any Database) async throws -> BrainMandateDTO {
        let grant = try await OAuthGrant.find(m.grantID, on: db)
        var client: String?
        if let grant { client = try await OAuthClient.find(grant.clientID, on: db)?.name }
        return BrainMandateDTO(grantID: m.grantID, grantName: grant.map { ConnectionNames.display($0, clientName: client) },
            projectIDs: m.projects, active: m.revokedAt == nil && grant?.revoked == false,
            createdAt: m.createdAt, updatedAt: m.updatedAt, revokedAt: m.revokedAt, lastUsedAt: grant?.lastUsedAt)
    }

    static func list(userID: UUID, db: any Database) async throws -> [BrainMandateDTO] {
        let rows = try await BrainMandate.query(on: db).filter(\.$userID == userID).sort(\.$updatedAt, .descending).sort(\.$id, .descending).all()
        var out: [BrainMandateDTO] = []
        for m in rows { out.append(try await dto(m, db: db)) }
        return out
    }

    /// Gives (or overwrites) the mandate of one connection; the person's other mandates stay as they are. The grant must be the
    /// person's own and not revoked; every project must be readable by the person now.
    static func grant(_ request: BrainMandateRequest, user: User, db: any Database) async throws -> BrainMandateDTO {
        let userID = try user.requireID()
        let projects = Array(Set(request.projectIDs))
        guard !projects.isEmpty, projects.count <= BrainMandateLimits.maxProjects else { throw Abort(.badRequest, reason: "invalid_projects") }
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
            let now = Date()
            let sorted = projects.sorted { $0.uuidString < $1.uuidString }
            if let m = existing {
                m.projects = sorted; m.revokedAt = nil; m.updatedAt = now
                try await m.save(on: tx)
                return m
            }
            let m = BrainMandate(userID: userID, grantID: request.grantID, projects: sorted, now: now)
            try await m.save(on: tx)
            return m
        }
        return try await dto(saved, db: db)
    }

    /// Revokes the mandate of one connection; idempotent, nothing leaks about foreign or unknown grants. Takes effect for the
    /// next decision (decisions re-read the mandate under lock).
    static func revoke(grantID: UUID, user: User, db: any Database) async throws {
        let userID = try user.requireID()
        try await db.transaction { tx in
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
