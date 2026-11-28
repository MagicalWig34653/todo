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
/// locked) has no effect, nothing has to be cleaned up when rights change. Cached for one run: each account (with its teams)
/// and each project (with its sharing row and grants) is read once; the rule itself is `SharingSnapshot.visibility`.
actor ResponsibilityResolver {
    private struct Account {
        let name: String
        let teamIDs: Set<UUID>
        let admins: Set<UUID>
    }

    private let db: any Database
    /// A stored nil stands for an unknown or locked account.
    private var accounts: [UUID: Account?] = [:]
    /// Projects already asked for, found or not.
    private var loaded: Set<UUID> = []
    private var projects: [UUID: Project] = [:]
    private var sharing: [UUID: ProjectSharing] = [:]
    private var grants: [UUID: [ProjectGrant]] = [:]

    init(db: any Database) { self.db = db }

    /// Reads these projects and their ancestors with sharing rows and grants, one batch per tree level. Callers with many
    /// items pass all their projects first, so that the number of queries does not grow with the number of projects.
    func load(projects ids: Set<UUID>) async throws {
        var wanted = ids.subtracting(loaded)
        guard !wanted.isEmpty else { return }
        var asked = Set<UUID>()
        var rows: [Project] = [], sharingRows: [ProjectSharing] = [], grantRows: [ProjectGrant] = []
        while !wanted.isEmpty {
            asked.formUnion(wanted)
            var parents = Set<UUID>()
            let level = Array(wanted)
            for start in stride(from: 0, to: level.count, by: 500) {
                let chunk = Array(level[start..<min(start + 500, level.count)])
                let found = try await Project.query(on: db).filter(\.$id ~~ chunk).all()
                rows += found
                parents.formUnion(found.compactMap(\.parentID))
                sharingRows += try await ProjectSharing.query(on: db).filter(\.$projectID ~~ chunk).all()
                grantRows += try await ProjectGrant.query(on: db).filter(\.$projectID ~~ chunk).all()
            }
            wanted = parents.subtracting(asked).subtracting(loaded)
        }
        // Merged without suspension: a concurrent caller never sees a project without its ancestors or grants.
        for project in rows { projects[try project.requireID()] = project }
        for row in sharingRows { sharing[row.projectID] = row }
        grants.merge(Dictionary(grouping: grantRows, by: \.projectID)) { _, new in new }
        loaded.formUnion(asked)
    }

    private func account(_ userID: UUID) async throws -> Account? {
        if let known = accounts[userID] { return known }
        var result: Account?
        if let user = try await User.find(userID, on: db), !user.isLocked {
            let teams = try await SharingAccess(user: user, db: db).memberships()
            result = Account(name: user.displayName, teamIDs: Set(teams.map(\.teamID)), admins: Set(teams.filter(\.isAdmin).map(\.teamID)))
        }
        accounts[userID] = .some(result)
        return result
    }

    /// Effective role of an account in a project; nil for unknown, locked or without access.
    func role(of userID: UUID, projectID: UUID) async throws -> ProjectRole? {
        guard let account = try await account(userID) else { return nil }
        try await load(projects: [projectID])
        guard let project = projects[projectID] else { return nil }
        let snapshot = SharingSnapshot(uid: userID, teamIDs: account.teamIDs, admins: account.admins,
                                       projects: projects, sharing: sharing, grants: grants)
        return try snapshot.visibility(project).role
    }

    /// Display name of a stored assignee for whoever may read the item; nil once the account lost access to the project or
    /// is locked. Never a login name.
    func visibleName(of userID: UUID?, projectID: UUID) async throws -> String? {
        guard let userID, try await role(of: userID, projectID: projectID) != nil else { return nil }
        return try await account(userID)?.name
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
