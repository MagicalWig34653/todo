import Fluent
import Vapor

private struct LabelWrite: Content {
    let name: String
    let version: Int?
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

    private func name(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw Abort(.badRequest) }
        return value
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
        let label = DiscoveryLabel(ownerID: try service.user.requireID(), name: try name(body.name))
        try await label.save(on: req.db)
        return try await DiscoveryLabelDTO(label).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateLabel(_ req: Request) async throws -> DiscoveryLabelDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(LabelWrite.self)
        let labelID = try id(req)
        return try await req.db.transaction { db in
            try await lockRow(table: DiscoveryLabel.schema, id: labelID, on: db)
            let label = try await DiscoveryService(user: user, db: db).label(labelID)
            guard body.version == label.version else { throw Abort(.conflict, reason: "version_conflict") }
            label.name = try name(body.name)
            label.version += 1
            try await label.save(on: db)
            return try DiscoveryLabelDTO(label)
        }
    }

    @Sendable func deleteLabel(_ req: Request) async throws -> HTTPStatus {
        let service = try await service(req)
        try await service.label(id(req)).delete(on: req.db)
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
        let user = try await req.requireUser()
        let taskID = try id(req)
        let labelID = try id(req, "labelID")
        return try await req.db.transaction { db in
            // Serialize repeated PUTs on the label; the unique pair also protects the database.
            try await lockRow(table: DiscoveryLabel.schema, id: labelID, on: db)
            let service = DiscoveryService(user: user, db: db)
            _ = try await service.label(labelID)
            _ = try await service.task(taskID)
            let existing = try await DiscoveryTaskLabel.query(on: db)
                .filter(\.$taskID == taskID).filter(\.$labelID == labelID).first()
            if attach, existing == nil {
                try await DiscoveryTaskLabel(taskID: taskID, labelID: labelID).save(on: db)
            } else if !attach, let existing { try await existing.delete(on: db) }
            return .noContent
        }
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
        try await service.validate(body.criteria)
        let filter = try DiscoverySavedFilter(ownerID: service.user.requireID(), name: name(body.name), criteria: body.criteria)
        try await filter.save(on: req.db)
        return try await DiscoveryFilterDTO(filter).encodeResponse(status: .created, for: req)
    }

    @Sendable func updateFilter(_ req: Request) async throws -> DiscoveryFilterDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(FilterWrite.self)
        let filterID = try id(req)
        return try await req.db.transaction { db in
            try await lockRow(table: DiscoverySavedFilter.schema, id: filterID, on: db)
            let service = DiscoveryService(user: user, db: db)
            let filter = try await service.savedFilter(filterID)
            guard body.version == filter.version else { throw Abort(.conflict, reason: "version_conflict") }
            try await service.validate(body.criteria)
            filter.name = try name(body.name)
            filter.criteria = String(decoding: try JSONEncoder().encode(body.criteria), as: UTF8.self)
            filter.version += 1
            try await filter.save(on: db)
            return try DiscoveryFilterDTO(filter)
        }
    }

    @Sendable func deleteFilter(_ req: Request) async throws -> HTTPStatus {
        let service = try await service(req)
        try await service.savedFilter(id(req)).delete(on: req.db)
        return .noContent
    }

    @Sendable func filterResults(_ req: Request) async throws -> DiscoveryPage<DiscoveryHit> {
        let service = try await service(req)
        let filter = try await service.savedFilter(id(req))
        let dto = try DiscoveryFilterDTO(filter)
        return try await service.search(dto.criteria, page: req.query.decode(DiscoveryPagination.self))
    }
}
