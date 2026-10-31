import Fluent
import SQLKit
import Vapor

struct HealthResponse: Content {
    let status: String
}

public func routes(_ app: Application) throws {
    try app.register(collection: OAuthController())
    try app.register(collection: AuthController())
    try registerIdentity(app)
    try registerPreferences(app)
    try app.register(collection: PlanningController())
    try app.register(collection: CollaborationController())

    try app.register(collection: PlanningExtController())

    try app.register(collection: DiscoveryController())
    try app.register(collection: SharingController())
    try app.register(collection: DirectoryController())
    try app.register(collection: AgentController())
    try app.register(collection: AttachmentController(maxBytes: app.settings.attachmentMaxBytes))
    try app.register(collection: ColumnController())
    try app.register(collection: SyncController())
    try app.register(collection: ProjectStateController())
    try app.register(collection: CommandCenterController())
    try app.register(collection: ProjectSyncController())
    // Apple app-site-association for passkeys in native apps: public, no redirect, JSON.
    for path in [[".well-known", "apple-app-site-association"], ["apple-app-site-association"]] {
        app.get(path.map { PathComponent(stringLiteral: $0) }) { req async throws -> Response in
            let ids = req.application.settings.appleAppIDs
            guard !ids.isEmpty else { throw Abort(.notFound) }
            let body = try JSONSerialization.data(
                withJSONObject: ["webcredentials": ["apps": ids]], options: [.sortedKeys])
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: body))
        }
    }
    // Liveness: process is up. No dependencies checked.
    app.get("health", "live") { _ in HealthResponse(status: "ok") }

    // Readiness: database reachable, so a replica may receive traffic.
    app.get("health", "ready") { req async throws -> HealthResponse in
        do {
            if let sql = req.db as? any SQLDatabase {
                _ = try await sql.raw("SELECT 1").all()
            }
            return HealthResponse(status: "ok")
        } catch {
            throw Abort(.serviceUnavailable, reason: "database unavailable")
        }
    }
    // Last: the PWA only answers what no real route handled (see WebRootMiddleware).
    app.registerWebRoot()
}
