import Fluent
import Vapor

struct FeedController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1").get("feed", use: feed)
    }

    @Sendable func feed(_ req: Request) async throws -> FeedResponse {
        let user = try await req.requireUser()
        var projectID: UUID?
        if let raw = req.query[String.self, at: "projectID"] {
            guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_projectID") }
            projectID = id
        }
        var limit: Int?
        if let raw = req.query[String.self, at: "limit"] {
            guard let value = Int(raw) else { throw Abort(.badRequest, reason: "invalid_limit") }
            limit = value
        }
        return try await FeedService(user: user, db: req.db).feed(projectID: projectID, mode: req.query[String.self, at: "mode"],
            cursor: req.query[String.self, at: "cursor"], limit: limit)
    }
}
