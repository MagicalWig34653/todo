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

struct BrainMandateResponse: Content {
    let mandate: BrainMandateDTO?
    /// Always present, `null` without a mandate.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mandate, forKey: .mandate)
    }
}

struct BrainMandateRequest: Content {
    let grantID: UUID
    let projectIDs: [UUID]
}

struct BrainAuditDTO: Content {
    let id: UUID
    let kind: String
    let taskID: UUID
    let projectID: UUID
    let subjectID: UUID
    let grantID: UUID
    let quote: String
    let note: String?
    let createdAt: Date?
    init(_ a: BrainDecisionAudit) throws {
        id = try a.requireID(); kind = a.kind; taskID = a.taskID; projectID = a.projectID; subjectID = a.subjectID
        grantID = a.grantID; quote = a.quote; note = a.note; createdAt = a.createdAt
    }
}

struct BrainAuditResponse: Content { let items: [BrainAuditDTO] }

enum BrainMandateLimits {
    static let maxProjects = 200
    static let maxQuote = 2000
    static let auditLimit = 200
}

/// ADR 0032. The mandate is managed by the person only (REST with a session); agents may only read it.
enum BrainMandateService {
    static func current(userID: UUID, db: any Database) async throws -> BrainMandateDTO? {
        guard let m = try await BrainMandate.query(on: db).filter(\.$userID == userID).first() else { return nil }
        let grant = try await OAuthGrant.find(m.grantID, on: db)
        var client: String?
        if let grant { client = try await OAuthClient.find(grant.clientID, on: db)?.name }
        return BrainMandateDTO(grantID: m.grantID, grantName: grant.map { ConnectionNames.display($0, clientName: client) },
            projectIDs: m.projects, active: m.revokedAt == nil && grant?.revoked == false,
            createdAt: m.createdAt, updatedAt: m.updatedAt, revokedAt: m.revokedAt, lastUsedAt: grant?.lastUsedAt)
    }

    /// Gives (or overwrites) the person's single mandate. The grant must be the person's own and not revoked; every
    /// project must be readable by the person now.
    static func grant(_ request: BrainMandateRequest, user: User, db: any Database) async throws -> BrainMandateDTO {
        let userID = try user.requireID()
        let projects = Array(Set(request.projectIDs))
        guard !projects.isEmpty, projects.count <= BrainMandateLimits.maxProjects else { throw Abort(.badRequest, reason: "invalid_projects") }
        try await db.transaction { tx in
            try await lockSharingGraph(on: tx)
            try await lockRow(table: User.schema, id: userID, on: tx)
            // Same order as the decision check: mandate row first, then the grant row.
            if let existing = try await BrainMandate.query(on: tx).filter(\.$userID == userID).first(), let id = existing.id {
                try await lockRow(table: BrainMandate.schema, id: id, on: tx)
            }
            try await lockRow(table: OAuthGrant.schema, id: request.grantID, on: tx)
            guard let g = try await OAuthGrant.find(request.grantID, on: tx), g.userID == userID else { throw Abort(.notFound) }
            guard !g.revoked else { throw Abort(.conflict, reason: "grant_revoked") }
            let access = ProjectAccess(user: user, db: tx)
            for id in projects { _ = try await access.project(id) }
            let now = Date()
            if let m = try await BrainMandate.query(on: tx).filter(\.$userID == userID).first() {
                m.grantID = request.grantID; m.projects = projects.sorted { $0.uuidString < $1.uuidString }
                m.revokedAt = nil; m.updatedAt = now
                try await m.save(on: tx)
            } else {
                try await BrainMandate(userID: userID, grantID: request.grantID, projects: projects.sorted { $0.uuidString < $1.uuidString }, now: now).save(on: tx)
            }
        }
        guard let dto = try await current(userID: userID, db: db) else { throw Abort(.internalServerError) }
        return dto
    }

    /// Idempotent; takes effect for the next decision (decisions re-read the mandate under lock).
    static func revoke(user: User, db: any Database) async throws {
        let userID = try user.requireID()
        try await db.transaction { tx in
            try await lockRow(table: User.schema, id: userID, on: tx)
            guard let m = try await BrainMandate.query(on: tx).filter(\.$userID == userID).first(), m.revokedAt == nil else { return }
            m.revokedAt = Date(); m.updatedAt = m.revokedAt!
            try await m.save(on: tx)
        }
    }

    static func audit(userID: UUID, db: any Database) async throws -> BrainAuditResponse {
        let rows = try await BrainDecisionAudit.query(on: db).filter(\.$userID == userID)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(BrainMandateLimits.auditLimit).all()
        return BrainAuditResponse(items: try rows.map(BrainAuditDTO.init))
    }
}

struct BrainMandateController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let m = routes.grouped("v1", "settings", "brain-mandate")
        m.get(use: get)
        m.put(use: put)
        m.delete(use: remove)
        m.get("audit", use: audit)
    }
    @Sendable func get(_ req: Request) async throws -> BrainMandateResponse {
        BrainMandateResponse(mandate: try await BrainMandateService.current(userID: req.requireUser().requireID(), db: req.db))
    }
    @Sendable func put(_ req: Request) async throws -> BrainMandateDTO {
        let user = try await req.requireUser()
        return try await BrainMandateService.grant(req.content.decode(BrainMandateRequest.self), user: user, db: req.db)
    }
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        try await BrainMandateService.revoke(user: req.requireUser(), db: req.db)
        return .noContent
    }
    @Sendable func audit(_ req: Request) async throws -> BrainAuditResponse {
        try await BrainMandateService.audit(userID: req.requireUser().requireID(), db: req.db)
    }
}
