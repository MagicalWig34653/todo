import Fluent
import Vapor

final class DiscoveryLabel: Model, @unchecked Sendable {
    static let schema = "discovery_labels"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "name") var name: String
    @Field(key: "version") var version: Int
    init() {}
    init(ownerID: UUID, name: String) {
        self.ownerID = ownerID
        self.name = name
        self.version = 1
    }
}

final class DiscoveryTaskLabel: Model, @unchecked Sendable {
    static let schema = "discovery_task_labels"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "label_id") var labelID: UUID
    init() {}
    init(taskID: UUID, labelID: UUID) {
        self.taskID = taskID
        self.labelID = labelID
    }
}

final class DiscoverySavedFilter: Model, @unchecked Sendable {
    static let schema = "discovery_saved_filters"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "name") var name: String
    @Field(key: "criteria") var criteria: String
    @Field(key: "version") var version: Int
    init() {}
    init(ownerID: UUID, name: String, criteria: DiscoveryCriteria) throws {
        self.ownerID = ownerID
        self.name = name
        self.criteria = String(decoding: try JSONEncoder().encode(criteria), as: UTF8.self)
        self.version = 1
    }
}

struct DiscoveryCriteria: Content, Equatable {
    var q: String?
    var projectID: UUID?
    var labelID: UUID?
    var status: String?

    func validated() throws -> Self {
        guard (q?.count ?? 0) <= 500, status.map(TaskStatus.all.contains) ?? true else {
            throw Abort(.badRequest)
        }
        return self
    }
}

struct DiscoveryLabelDTO: Content {
    let id: UUID
    let name: String
    let version: Int
    init(_ label: DiscoveryLabel) throws {
        id = try label.requireID()
        name = label.name
        version = label.version
    }
}

struct DiscoveryFilterDTO: Content {
    let id: UUID
    let name: String
    let criteria: DiscoveryCriteria
    let version: Int
    init(_ filter: DiscoverySavedFilter) throws {
        id = try filter.requireID()
        name = filter.name
        criteria = try JSONDecoder().decode(DiscoveryCriteria.self, from: Data(filter.criteria.utf8))
        version = filter.version
    }
}

struct DiscoveryPage<Item: Content>: Content {
    let items: [Item]
    let nextCursor: String?
}

struct DiscoveryHit: Content {
    let kind: String
    let id: UUID
    let project: ProjectDTO
    let task: TaskDTO?
}
