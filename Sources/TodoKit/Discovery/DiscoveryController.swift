import Fluent
import Vapor

private struct LabelWrite: Content {
    let name: String
    let version: Int?
    let color: String?
}

private struct FilterWrite: Content {
    let name: String
    let criteria: DiscoveryCriteria
    let version: Int?
}

struct DiscoveryController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("search", use: search)
        v1.get("labels", use: listLabels)
        v1.post("labels", use: createLabel)
        v1.patch("labels", ":id", use: updateLabel)
        v1.delete("labels", ":id", use: deleteLabel)
        v1.get("tasks", ":id", "labels", use: taskLabels)
        v1.put("tasks", ":id", "labels", ":labelID", use: attachLabel)
        v1.delete("tasks", ":id", "labels", ":labelID", use: detachLabel)
        v1.get("filters", use: listFilters)
        v1.post("filters", use: createFilter)
        v1.patch("filters", ":id", use: updateFilter)
        v1.delete("filters", ":id", use: deleteFilter)
        v1.get("filters", ":id", "results", use: filterResults)
    }

    private func service(_ req: Request) async throws -> DiscoveryService {
        DiscoveryService(user: try await req.requireUser(), db: req.db)
    }

    private func id(_ req: Request, _ key: String = "id") throws -> UUID {
        guard let id = req.parameters.get(key, as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    @Sendable func search(_ req: Request) async throws -> DiscoveryPage<DiscoveryHit> {
        try await service(req).search(req.query.decode(DiscoveryCriteria.self), page: req.query.decode(DiscoveryPagination.self))
    }

    @Sendable func listLabels(_ req: Request) async throws -> DiscoveryPage<DiscoveryLabelDTO> {
        let service = try await service(req)
        return try await labels(service, req: req, taskID: nil)
    }

    private func labels(_ service: DiscoveryService, req: Request, taskID: UUID?) async throws -> DiscoveryPage<DiscoveryLabelDTO> {
        let ownerID = try service.user.requireID()
        let page = try req.query.decode(DiscoveryPagination.self)
        let size = try page.size()
        let scope = taskID.map { "labels:\($0)" } ?? "labels"
        let criteria = DiscoveryCriteria()
        let cursor = try DiscoveryCursor.decode(page.cursor, ownerID: ownerID, scope: scope, criteria: criteria)
        guard cursor.map({ $0.kind == "label" }) ?? true else { throw Abort(.badRequest) }
        let query = DiscoveryLabel.query(on: service.db).filter(\.$ownerID == ownerID)
        if let cursor { query.filter(\.$id > cursor.id) }
        if let taskID {
            let links = try await DiscoveryTaskLabel.query(on: service.db).filter(\.$taskID == taskID).all()
            query.filter(\.$id ~~ links.map(\.labelID))
        }
        let all = try await query.sort(\.$id).range(0..<(size + 1)).all()
        let items = try all.prefix(size).map(DiscoveryLabelDTO.init)
        let next = try all.count > size ? items.last.map {
            try DiscoveryCursor(ownerID: ownerID, scope: scope, criteria: criteria, kind: "label", id: $0.id).encoded()
        } : nil
        return DiscoveryPage(items: items, nextCursor: next)
    }

    @Sendable func createLabel(_ req: Request) async throws -> Response {
        let service = try await service(req)
        let body = try req.content.decode(LabelWrite.self)
        return try await service.createLabel(name: body.name, color: body.color).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateLabel(_ req: Request) async throws -> DiscoveryLabelDTO {
        let service = try await service(req)
        let body = try req.content.decode(LabelWrite.self)
        guard let version = body.version else { throw Abort(.conflict, reason: "version_conflict") }
        return try await service.updateLabel(id(req), version: version, name: body.name, color: body.color)
    }

    @Sendable func deleteLabel(_ req: Request) async throws -> HTTPStatus {
        try await service(req).deleteLabel(id(req))
        return .noContent
    }

    @Sendable func taskLabels(_ req: Request) async throws -> DiscoveryPage<DiscoveryLabelDTO> {
        let service = try await service(req)
        let taskID = try id(req)
        _ = try await service.task(taskID)
        return try await labels(service, req: req, taskID: taskID)
    }

    @Sendable func attachLabel(_ req: Request) async throws -> HTTPStatus {
        try await changeLink(req, attach: true)
    }

    @Sendable func detachLabel(_ req: Request) async throws -> HTTPStatus {
        try await changeLink(req, attach: false)
    }

    private func changeLink(_ req: Request, attach: Bool) async throws -> HTTPStatus {
        let service = try await service(req)
        try await service.setLabels(taskID: id(req), labelIDs: [id(req, "labelID")], replacing: false, attach: attach)
        return .noContent
    }

    @Sendable func listFilters(_ req: Request) async throws -> DiscoveryPage<DiscoveryFilterDTO> {
        let service = try await service(req)
        let ownerID = try service.user.requireID()
        let page = try req.query.decode(DiscoveryPagination.self)
        let size = try page.size()
        let criteria = DiscoveryCriteria()
        let cursor = try DiscoveryCursor.decode(page.cursor, ownerID: ownerID, scope: "filters", criteria: criteria)
        guard cursor.map({ $0.kind == "filter" }) ?? true else { throw Abort(.badRequest) }
        let query = DiscoverySavedFilter.query(on: req.db).filter(\.$ownerID == ownerID)
        if let cursor { query.filter(\.$id > cursor.id) }
        let all = try await query.sort(\.$id).range(0..<(size + 1)).all()
        let items = try all.prefix(size).map(DiscoveryFilterDTO.init)
        let next = try all.count > size ? items.last.map {
            try DiscoveryCursor(ownerID: ownerID, scope: "filters", criteria: criteria, kind: "filter", id: $0.id).encoded()
        } : nil
        return DiscoveryPage(items: items, nextCursor: next)
    }

    @Sendable func createFilter(_ req: Request) async throws -> Response {
        let service = try await service(req)
        let body = try req.content.decode(FilterWrite.self)
        return try await service.createFilter(name: body.name, criteria: body.criteria).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateFilter(_ req: Request) async throws -> DiscoveryFilterDTO {
        let service = try await service(req)
        let body = try req.content.decode(FilterWrite.self)
        guard let version = body.version else { throw Abort(.conflict, reason: "version_conflict") }
        return try await service.updateFilter(id(req), version: version, name: body.name, criteria: body.criteria)
    }

    @Sendable func deleteFilter(_ req: Request) async throws -> HTTPStatus {
        try await service(req).deleteFilter(id(req))
        return .noContent
    }

    @Sendable func filterResults(_ req: Request) async throws -> DiscoveryPage<DiscoveryHit> {
        let service = try await service(req)
        let filter = try await service.savedFilter(id(req))
        let dto = try DiscoveryFilterDTO(filter)
        return try await service.search(dto.criteria, page: req.query.decode(DiscoveryPagination.self))
    }
}
