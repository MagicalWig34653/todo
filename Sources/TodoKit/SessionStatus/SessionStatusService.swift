import Fluent
import Vapor

struct SessionStatusDTO: Content, Equatable {
    let projectID: UUID
    let sessionName: String
    let activity: String
    let updatedAt: String
}

/// One business path for REST and MCP. Writing needs the edit role on the project (like `post_progress`);
/// `allowedProjects` narrows an OAuth grant. Every rights failure is a 404. Texts are user data: never logged.
struct SessionStatusService: Sendable {
    static let maxActivity = 300
    static let maxName = 100
    /// At most one write per (account, project, session name) in this window.
    static let minInterval: TimeInterval = 10
    /// Junk-name guard: sessions per account and project.
    static let maxSessionsPerProject = 20

    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil

    @discardableResult
    func report(projectID: UUID, sessionName rawName: String, activity rawActivity: String) async throws -> SessionStatusDTO {
        guard let name = try LiveSessionService.clean(rawName, max: Self.maxName, reason: "invalid_session"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Abort(.badRequest, reason: "invalid_session") }
        guard let cleaned = try LiveSessionService.clean(rawActivity, max: Self.maxActivity, reason: "invalid_activity") else { throw Abort(.badRequest, reason: "invalid_activity") }
        let flat = SecretFilter.redact(cleaned).text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let activity = flat.count > Self.maxActivity ? String(flat.prefix(Self.maxActivity - 1)) + "…" : flat
        let sessionName = SecretFilter.redact(name).text

        if let allowedProjects, !allowedProjects.contains(projectID) { throw Abort(.notFound) }
        _ = try await ProjectAccess(user: user, db: db).project(projectID, role: .edit)
        let uid = try user.requireID()

        func existing() async throws -> SessionStatus? {
            try await SessionStatus.query(on: db).filter(\.$userID == uid).filter(\.$projectID == projectID).filter(\.$sessionName == sessionName).first()
        }
        let now = ChannelService.now()
        let row: SessionStatus
        if let found = try await existing() {
            guard now.timeIntervalSince(found.updatedAt) >= Self.minInterval else { throw Self.rateLimited }
            row = found
        } else {
            guard try await SessionStatus.query(on: db).filter(\.$userID == uid).filter(\.$projectID == projectID).count() < Self.maxSessionsPerProject else {
                throw Abort(.tooManyRequests, reason: "too_many_sessions")
            }
            row = SessionStatus(userID: uid, projectID: projectID, sessionName: sessionName, activity: activity, updatedAt: now)
        }
        row.activity = activity; row.updatedAt = now
        do { try await row.save(on: db) }
        catch {
            // A parallel first report won the unique key: that one counts as this window's write.
            if try await existing() != nil { throw Self.rateLimited }
            throw error
        }
        return SessionStatusDTO(projectID: projectID, sessionName: sessionName, activity: activity, updatedAt: LiveSessionService.iso(now))
    }

    private static var rateLimited: Abort { Abort(.tooManyRequests, headers: ["Retry-After": "10"], reason: "rate_limited") }
}

struct SessionStatusController: RouteCollection {
    struct Body: Content { let sessionName: String; let activity: String }

    func boot(routes: any RoutesBuilder) throws {
        routes.put("v1", "projects", ":id", "session-status", use: put)
        routes.get("v1", "overview", "now", use: overview)
    }

    @Sendable func put(_ req: Request) async throws -> SessionStatusDTO {
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.notFound) }
        let body = try req.content.decode(Body.self)
        return try await SessionStatusService(user: user, db: req.db).report(projectID: id, sessionName: body.sessionName, activity: body.activity)
    }

    @Sendable func overview(_ req: Request) async throws -> OverviewNow {
        let user = try await req.requireUser()
        return try await OverviewNowService(user: user, db: req.db).now()
    }
}
