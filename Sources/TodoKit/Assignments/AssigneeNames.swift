import Fluent
import Vapor

/// A card, question or review as sent to a client, which can carry the display name of its stored assignee.
protocol NamesAssignee {
    var assigneeID: UUID? { get }
    var assigneeName: String? { get set }
    /// The card the item hangs on (a card: itself).
    var cardID: UUID { get }
    /// Nil where the answer does not carry the project; it is then looked up through the card.
    var cardProjectID: UUID? { get }
}

extension TaskDTO: NamesAssignee {
    var cardID: UUID { id }
    var cardProjectID: UUID? { projectID }
}

extension QuestionDTO: NamesAssignee {
    var cardID: UUID { taskID }
    var cardProjectID: UUID? { projectID }
}

extension ReviewDTO: NamesAssignee {
    var cardID: UUID { taskID }
    var cardProjectID: UUID? { projectID }
}

/// Fills `assigneeName` for the REST answers (card E9300901). The caller must already have checked that the reader may see
/// the items; the name appears only while the assignee still sees the project (`ResponsibilityResolver`). One instance per
/// answer: accounts and projects are read once, however many items name them.
struct AssigneeNames {
    private let db: any Database
    private let resolver: ResponsibilityResolver

    init(db: any Database) {
        self.db = db
        resolver = ResponsibilityResolver(db: db)
    }

    func fill<T: NamesAssignee>(_ items: [T]) async throws -> [T] {
        let unknown = Set(items.filter { $0.assigneeID != nil && $0.cardProjectID == nil }.map(\.cardID))
        var projects: [UUID: UUID] = [:]
        if !unknown.isEmpty {
            for task in try await TodoTask.query(on: db).filter(\.$id ~~ Array(unknown)).all() { projects[try task.requireID()] = task.projectID }
        }
        try await resolver.load(projects: Set(items.filter { $0.assigneeID != nil }.compactMap { $0.cardProjectID ?? projects[$0.cardID] }))
        var result = items
        for index in result.indices {
            guard result[index].assigneeID != nil, let project = result[index].cardProjectID ?? projects[result[index].cardID] else { continue }
            result[index].assigneeName = try await resolver.visibleName(of: result[index].assigneeID, projectID: project)
        }
        return result
    }

    func fill<T: NamesAssignee>(_ item: T) async throws -> T { try await fill([item])[0] }

    func fill(_ context: TaskContextDTO) async throws -> TaskContextDTO {
        var result = context
        result.task = try await fill(context.task)
        result.subtasks = try await fill(context.subtasks)
        result.questions = try await fill(context.questions)
        if let review = context.review { result.review = try await fill(review) }
        return result
    }
}
