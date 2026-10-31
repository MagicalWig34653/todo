import Fluent
import Vapor

private struct CommentBody: Content { let body: String; let version: Int? }
private struct VersionBody: Content { let version: Int }
private struct FavoriteBody: Content { let index: Int? }

/// Per-account project state (order, favourites, display preferences), project comments and the activity feed.
/// ADR 0012. Contract: `contracts/project-state.yaml`.
struct ProjectStateController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.put("projects", ":id", "position", use: position)
        v1.get("projects", ":id", "comments", use: comments)
        v1.post("projects", ":id", "comments", use: createComment)
        v1.patch("projects", ":id", "comments", ":commentID", use: editComment)
        v1.delete("projects", ":id", "comments", ":commentID", use: deleteComment)
        v1.get("me", "favorites", use: favorites)
        v1.put("me", "favorites", ":projectID", use: setFavorite)
        v1.delete("me", "favorites", ":projectID", use: removeFavorite)
        v1.get("me", "project-prefs", use: allPrefs)
        v1.get("me", "project-prefs", ":projectID", use: prefs)
        v1.patch("me", "project-prefs", ":projectID", use: updatePrefs)
        v1.get("activity", use: activity)
    }

    private func param(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    private func service(_ req: Request, on db: (any Database)? = nil) async throws -> ProjectStateService {
        ProjectStateService(user: try await req.requireUser(), db: db ?? req.db)
    }

    // MARK: Order

    @Sendable func position(_ req: Request) async throws -> ProjectDTO {
        let user = try await req.requireUser(), id = try param(req, "id")
        let body = try req.content.decode(ProjectPositionRequest.self)
        return try await req.db.transaction { db in try await ProjectStateService(user: user, db: db).position(id, body) }
    }

    // MARK: Comments

    @Sendable func comments(_ req: Request) async throws -> [ProjectCommentDTO] {
        try await ProjectCommentService(user: req.requireUser(), db: req.db).list(param(req, "id"))
    }

    @Sendable func createComment(_ req: Request) async throws -> Response {
        let user = try await req.requireUser(), id = try param(req, "id")
        let input = try req.content.decode(CommentBody.self)
        let keys = req.headers["Idempotency-Key"]
        guard keys.count <= 1 else { throw Abort(.badRequest, reason: "invalid_idempotency_key") }
        let dto = try await ProjectCommentService(user: user, db: req.db).create(id, body: input.body, idempotencyKey: keys.first)
        return try await dto.encodeResponse(status: .created, for: req)
    }

    @Sendable func editComment(_ req: Request) async throws -> ProjectCommentDTO {
        let user = try await req.requireUser()
        let input = try req.content.decode(CommentBody.self)
        guard let version = input.version else { throw Abort(.badRequest, reason: "version_required") }
        return try await ProjectCommentService(user: user, db: req.db)
            .edit(param(req, "id"), commentID: param(req, "commentID"), body: input.body, version: version)
    }

    @Sendable func deleteComment(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        let input = try req.content.decode(VersionBody.self)
        try await ProjectCommentService(user: user, db: req.db)
            .delete(param(req, "id"), commentID: param(req, "commentID"), version: input.version)
        return .noContent
    }

    // MARK: Favourites

    @Sendable func favorites(_ req: Request) async throws -> FavoritesResponse {
        FavoritesResponse(items: try await service(req).favorites())
    }

    @Sendable func setFavorite(_ req: Request) async throws -> FavoritesResponse {
        let user = try await req.requireUser(), id = try param(req, "projectID")
        let index: Int?
        if let buffer = req.body.data, buffer.readableBytes > 0 { index = try req.content.decode(FavoriteBody.self).index } else { index = nil }
        let items = try await req.db.transaction { db in try await ProjectStateService(user: user, db: db).setFavorite(id, index: index) }
        return FavoritesResponse(items: items)
    }

    @Sendable func removeFavorite(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser(), id = try param(req, "projectID")
        try await req.db.transaction { db in try await ProjectStateService(user: user, db: db).removeFavorite(id) }
        return .noContent
    }

    // MARK: Display preferences

    @Sendable func allPrefs(_ req: Request) async throws -> ProjectPrefsList {
        try await service(req).allPrefs(includeDefaults: req.query[Bool.self, at: "includeDefaults"] ?? false)
    }

    @Sendable func prefs(_ req: Request) async throws -> ProjectPrefsDTO {
        try await service(req).prefs(param(req, "projectID"))
    }

    @Sendable func updatePrefs(_ req: Request) async throws -> ProjectPrefsDTO {
        let user = try await req.requireUser(), id = try param(req, "projectID")
        guard let buffer = req.body.data, buffer.readableBytes <= 1024 else { throw Abort(.badRequest, reason: "invalid_project_prefs") }
        let change: ProjectPrefsChange
        do { change = try JSONDecoder().decode(ProjectPrefsChange.self, from: Data(buffer.readableBytesView)) }
        catch is DecodingError { throw Abort(.badRequest, reason: "invalid_project_prefs") }
        return try await req.db.transaction { db in try await ProjectStateService(user: user, db: db).updatePrefs(id, change) }
    }

    // MARK: Activity

    @Sendable func activity(_ req: Request) async throws -> ActivityFeedPage {
        let user = try await req.requireUser()
        var projectID: UUID?
        if let raw = req.query[String.self, at: "projectID"] {
            guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_project") }
            projectID = id
        }
        var limit: Int?
        if let raw = req.query[String.self, at: "limit"] {
            guard let value = Int(raw) else { throw Abort(.badRequest, reason: "invalid_limit") }
            limit = value
        }
        return try await ActivityFeedService(user: user, db: req.db)
            .page(projectID: projectID, limit: limit, before: req.query[String.self, at: "before"])
    }
}

func configureProjectState(_ app: Application) {
    app.migrations.add(CreateProjectState())
    app.migrations.add(AddProjectUserStateMode())
}
