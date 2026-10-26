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
    try app.register(collection: PlanningController())
    try app.register(collection: CollaborationController())

    try app.register(collection: PlanningExtController())

    try app.register(collection: DiscoveryController())
    try app.register(collection: SharingController())
    try app.register(collection: AgentController())
    try app.register(collection: AttachmentController())
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
}
