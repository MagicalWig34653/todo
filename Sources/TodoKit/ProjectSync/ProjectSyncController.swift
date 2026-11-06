import Fluent
import Vapor

/// REST access to the repository binding of a project (the PWA and apps show and configure the sync state).
struct ProjectSyncController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("projects", ":id", "sync", use: get)
        v1.put("projects", ":id", "sync", use: put)
        v1.get("projects", ":id", "bindings", use: bindings)
        v1.delete("projects", ":id", "bindings", use: unbind)
        v1.get("projects", "by-repository", use: byRepository)
    }

    private func service(_ req: Request) async throws -> ProjectSyncService {
        ProjectSyncService(user: try await req.requireUser(), db: req.db)
    }
    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    /// Flat fields of the stalest binding plus `bindings`; `?repository=` selects one binding (409 not_bound).
    @Sendable func get(_ req: Request) async throws -> ProjectSyncDTO {
        try await service(req).status(id(req), repository: req.query[String.self, at: "repository"])
    }

    @Sendable func bindings(_ req: Request) async throws -> [ProjectSyncDTO] { try await service(req).listBindings(id(req)) }

    /// Removes one binding and its history (edit right).
    @Sendable func unbind(_ req: Request) async throws -> ProjectSyncDTO {
        guard let repository = req.query[String.self, at: "repository"] else { throw Abort(.badRequest, reason: "invalid_repository") }
        return try await service(req).unbind(id(req), repository: repository)
    }

    /// Adds a repository binding (history is never reset) and/or changes the staleness threshold.
    @Sendable func put(_ req: Request) async throws -> ProjectSyncDTO {
        struct Body: Content { let repository: String?; let staleAfterDays: Int? }
        let body = try req.content.decode(Body.self)
        return try await service(req).bind(id(req), repository: body.repository, staleAfterDays: body.staleAfterDays)
    }

    @Sendable func byRepository(_ req: Request) async throws -> RepositoryLookupDTO {
        guard let repository = req.query[String.self, at: "repository"] else { throw Abort(.badRequest, reason: "invalid_repository") }
        return try await service(req).find(repository: repository)
    }
}
