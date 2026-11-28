import Fluent
import Vapor

/// What a person is responsible for. The kind decides which project role makes somebody assignable: a card may belong to
/// anyone who can see it, a question needs somebody who may answer, a review (or plan) somebody who may decide (ADR 0043).
enum AssignmentKind: String, CaseIterable, Sendable {
    case task, question, review

    var role: ProjectRole {
        switch self {
        case .task: return .read
        case .question: return .comment
        case .review: return .edit
        }
    }
}

/// Who a question, review, plan or reminder concerns.
enum Audience: Equatable, Sendable {
    /// Nobody is responsible: everybody with the needed right, as before responsibilities existed.
    case everyone
    case only(UUID)
    /// A named reviewer who lost the right: deciding stays with the project management, so only they are concerned.
    case managers
}

/// Effective responsibility, resolved on every read and again before sending: a stored assignee who lost access (or is
/// locked) has no effect, nothing has to be cleaned up when rights change. Results are cached for one run.
actor ResponsibilityResolver {
    private let db: any Database
    private var roles: [String: ProjectRole?] = [:]
    private var names: [UUID: String] = [:]

    init(db: any Database) { self.db = db }

    /// Effective role of an account in a project; nil for unknown, locked or without access.
    func role(of userID: UUID, projectID: UUID) async throws -> ProjectRole? {
        let key = "\(userID)|\(projectID)"
        if let cached = roles[key] { return cached }
        var result: ProjectRole?
        if let user = try await User.find(userID, on: db), !user.isLocked, let project = try await Project.find(projectID, on: db) {
            names[userID] = user.displayName
            result = try await SharingAccess(user: user, db: db).visibility(project).role
        }
        roles[key] = .some(result)
        return result
    }

    /// Display name of a stored assignee for whoever may read the item; nil once the account lost access to the project or
    /// is locked. Never a login name.
    func visibleName(of userID: UUID?, projectID: UUID) async throws -> String? {
        guard let userID, try await role(of: userID, projectID: projectID) != nil else { return nil }
        return names[userID]
    }

    func isAssignable(_ userID: UUID, to kind: AssignmentKind, projectID: UUID) async throws -> Bool {
        (try await role(of: userID, projectID: projectID)?.rank ?? -1) >= kind.role.rank
    }

    private func cardAssignee(_ task: TodoTask, for kind: AssignmentKind, author: UUID?) async throws -> UUID? {
        guard let id = task.assigneeID, id != author,
              try await isAssignable(id, to: kind, projectID: task.projectID) else { return nil }
        return id
    }

    /// Named on the question, else the card's person (not for the own question). Runner questions have their own rights
    /// and never inherit.
    func audience(of q: TaskQuestion, task: TodoTask) async throws -> Audience {
        if let id = q.assigneeID, try await isAssignable(id, to: .question, projectID: task.projectID) { return .only(id) }
        guard q.agentQuestionID == nil else { return .everyone }
        let author = q.askedByType == .person ? q.askedByID : nil
        return try await cardAssignee(task, for: .question, author: author).map(Audience.only) ?? .everyone
    }

    func audience(of r: TaskReview, task: TodoTask) async throws -> Audience {
        if let id = r.reviewerID {
            return try await isAssignable(id, to: .review, projectID: task.projectID) ? .only(id) : .managers
        }
        guard r.agentJobID == nil else { return .everyone }
        let author = r.requestedByType == .person ? r.requestedByID : nil
        return try await cardAssignee(task, for: .review, author: author).map(Audience.only) ?? .everyone
    }

    /// Waiting plans have no own assignee: the card's person, else everybody who may decide.
    func audience(of plan: TaskPlan, task: TodoTask) async throws -> Audience {
        let author = plan.authorType == .person ? plan.authorID : nil
        return try await cardAssignee(task, for: .review, author: author).map(Audience.only) ?? .everyone
    }

    /// Reminders belong to one account: the card's person, else the creator.
    func reminderRecipient(_ task: TodoTask) async throws -> UUID {
        try await cardAssignee(task, for: .task, author: nil) ?? task.ownerID
    }

    /// Whether an item with this audience concerns the account (which already has the needed right).
    func concerns(_ audience: Audience, userID: UUID, projectID: UUID) async throws -> Bool {
        switch audience {
        case .everyone: return true
        case .only(let id): return id == userID
        case .managers: return try await role(of: userID, projectID: projectID) == .manage
        }
    }
}
