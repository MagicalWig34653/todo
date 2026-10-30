import Fluent
import Vapor

struct StructureColumn: Content {
    let id: UUID
    let name: String
    let color: String?
    let isDone: Bool
    let position: Int
    /// Workflow role recognised from the name (`backlog|ready|working|question|review|done`) or null.
    let role: String?
}

struct StructureProject: Content {
    let id: UUID
    let name: String
    let description: String?
    let color: String?
    let parentID: UUID?
    let version: Int
    /// Visible ancestors, root first.
    let path: [String]
}

struct TemplateStatus: Content {
    let name: String
    /// True when every role of the standard template has a matching column.
    let complete: Bool
    let missingRoles: [String]
}

struct StructureCounts: Content {
    let open: Int
    let inProgress: Int
    let inReview: Int
    let done: Int
    let features: Int
    let openQuestions: Int
    let pendingReviews: Int
}

struct ProjectStructureDTO: Content {
    let project: StructureProject
    /// The user-edited rules for agents of this project (empty text and version 0 if never written).
    let brief: AgentBriefDTO
    /// `columns` (own columns) or `status` (virtual status columns).
    let columnMode: String
    let columns: [StructureColumn]
    let template: TemplateStatus
    let counts: StructureCounts
    let manualVersion: String
    /// Always-valid rules; the brief adds project-specific ones.
    let rules: [String]
}

extension WorkflowService {
    static let standardRules = [
        "Read the project brief first; its rules override your defaults.",
        "Claim a task before working on it (claim_task) and post progress notes (post_progress) while you work.",
        "Never guess a decision that belongs to the user: ask_question with options and wait for the answer.",
        "When the work is finished, attach build screenshots if the brief asks for them and call request_review; do not mark your own work done.",
        "Keep the standard column names so cards move automatically; do not rename or delete columns without being asked.",
        "Use idempotency keys when retrying writes.",
    ]

    func structure(_ projectID: UUID) async throws -> ProjectStructureDTO {
        let project = try await self.project(projectID)
        var path: [String] = []
        var cursor = project.parentID
        var seen: Set<UUID> = [projectID]
        while let id = cursor, seen.insert(id).inserted, let parent = try? await access.project(id, role: .read) {
            if let allowedProjects, !allowedProjects.contains(id) { break }
            path.insert(parent.name, at: 0)
            cursor = parent.parentID
        }
        let columns = try await ColumnService(user: user, db: db).columns(of: projectID)
        let roles = columns.map { ColumnRole.of($0) }
        let dtoColumns = try columns.enumerated().map { (i, c) in
            StructureColumn(id: try c.requireID(), name: c.name, color: c.color, isDone: c.isDone, position: c.position, role: roles[i]?.rawValue)
        }
        let missing = ColumnRole.template.map(\.role).filter { role in !roles.contains(role) }.map(\.rawValue)
        let tasks = try await TodoTask.query(on: db).filter(\.$projectID == projectID).all()
        let ids = try tasks.map { try $0.requireID() }
        func n(_ status: String) -> Int { tasks.filter { $0.status == status }.count }
        var features = 0, questions = 0, reviews = 0
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 400, ids.count)])
            index += 400
            let rows = try await TaskWorkflow.query(on: db).filter(\.$id ~~ chunk).all()
            let parents = Set(rows.compactMap(\.parentTaskID))
            features += rows.filter { $0.kind == "feature" || parents.contains($0.id!) }.count
            questions += try await TaskQuestion.query(on: db).filter(\.$taskID ~~ chunk).filter(\.$state == "open").count()
            reviews += try await TaskReview.query(on: db).filter(\.$taskID ~~ chunk).filter(\.$state == "pending").count()
        }
        return ProjectStructureDTO(
            project: StructureProject(id: projectID, name: project.name, description: project.details, color: project.color,
                parentID: project.parentID, version: project.version, path: path),
            brief: try await Self.briefDTO(projectID, on: db),
            columnMode: columns.isEmpty ? "status" : "columns", columns: dtoColumns,
            template: TemplateStatus(name: "agent_workflow", complete: missing.isEmpty, missingRoles: missing),
            counts: StructureCounts(open: n("open"), inProgress: n("in_progress"), inReview: n("in_review"), done: n("done"),
                features: features, openQuestions: questions, pendingReviews: reviews),
            manualVersion: AgentManual.version, rules: Self.standardRules)
    }
}
