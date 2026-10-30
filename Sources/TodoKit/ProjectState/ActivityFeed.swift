import Fluent
import Vapor

struct ActivityFeedItem: Content {
    let id: UUID
    /// `task` (event of `activity_events`) or `project` (event of `project_activity_events`).
    let source: String
    let projectID: UUID
    let projectName: String
    let taskID: UUID?
    let taskTitle: String?
    let sequence: Int
    let actorType: ActivityActorType
    let actorID: UUID
    var actorName: String?
    let kind: String
    let subjectID: UUID?
    let createdAt: Date?
}

struct ActivityFeedPage: Content {
    let items: [ActivityFeedItem]
    /// Pass as `before` to get the next (older) page; absent on the last page.
    let nextCursor: String?
}

/// Aggregated, permission-checked activity across task events (including comments and agent flows, which are
/// recorded as task events) and project events. Newest first; pages by an opaque `(createdAt, id)` cursor.
struct ActivityFeedService: Sendable {
    static let defaultLimit = 50
    static let maxLimit = 100

    let user: User
    let db: any Database

    private struct Cursor { let time: Double; let id: String }

    private static func parse(_ raw: String?) throws -> Cursor? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let time = Double(parts[0]), time.isFinite, let id = UUID(uuidString: String(parts[1])) else {
            throw Abort(.badRequest, reason: "invalid_cursor")
        }
        return Cursor(time: time, id: id.uuidString)
    }

    private struct Row {
        let item: ActivityFeedItem
        var key: (Double, String) { (item.createdAt?.timeIntervalSince1970 ?? 0, item.id.uuidString) }
    }

    func page(projectID: UUID?, limit rawLimit: Int?, before: String?) async throws -> ActivityFeedPage {
        let limit = rawLimit ?? Self.defaultLimit
        guard (1...Self.maxLimit).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        let cursor = try Self.parse(before)
        let access = ProjectAccess(user: user, db: db)
        var projects: [UUID: Project] = [:]
        if let projectID {
            projects[projectID] = try await access.project(projectID, role: .read)
        } else {
            for project in try await access.visibleProjects() { projects[try project.requireID()] = project }
        }
        guard !projects.isEmpty else { return ActivityFeedPage(items: [], nextCursor: nil) }
        let ids = Array(projects.keys)
        // SQLite stores dates as raw doubles but reads them back rounded to microseconds, so the cursor date can
        // differ from the stored value by up to 0.5 microseconds. Compare with a 1 microsecond tolerance, otherwise
        // the last item of a page may be repeated on the next one.
        let tolerance: TimeInterval = 1e-6
        let cursorDate = cursor.map { Date(timeIntervalSince1970: $0.time - tolerance) }
        let cursorUpper = cursor.map { Date(timeIntervalSince1970: $0.time + tolerance) }

        var rows: [Row] = []
        var taskQuery = ActivityEvent.query(on: db)
            .join(TodoTask.self, on: \ActivityEvent.$taskID == \TodoTask.$id)
            .filter(TodoTask.self, \.$projectID ~~ ids)
        if let cursor, let cursorDate, let cursorUpper {
            let cursorID = UUID(uuidString: cursor.id)!
            taskQuery = taskQuery.group(.or) { or in
                or.filter(ActivityEvent.self, \.$createdAt < cursorDate)
                or.group(.and) { and in
                    and.filter(ActivityEvent.self, \.$createdAt >= cursorDate)
                    and.filter(ActivityEvent.self, \.$createdAt <= cursorUpper)
                    and.filter(ActivityEvent.self, \.$id < cursorID)
                }
            }
        }
        let taskEvents = try await taskQuery.sort(ActivityEvent.self, \.$createdAt, .descending)
            .sort(ActivityEvent.self, \.$id, .descending).limit(limit + 1).all()
        for event in taskEvents {
            let task = try event.joined(TodoTask.self)
            let project = projects[task.projectID]
            rows.append(Row(item: ActivityFeedItem(
                id: try event.requireID(), source: "task", projectID: task.projectID, projectName: project?.name ?? "",
                taskID: task.id, taskTitle: task.title, sequence: event.sequence, actorType: event.actorType,
                actorID: event.actorID, actorName: nil, kind: event.kind, subjectID: event.subjectID,
                createdAt: event.createdAt)))
        }

        var projectQuery = ProjectActivityEvent.query(on: db).filter(\.$projectID ~~ ids)
        if let cursor, let cursorDate, let cursorUpper {
            let cursorID = UUID(uuidString: cursor.id)!
            projectQuery = projectQuery.group(.or) { or in
                or.filter(\.$createdAt < cursorDate)
                or.group(.and) { and in
                    and.filter(\.$createdAt >= cursorDate)
                    and.filter(\.$createdAt <= cursorUpper)
                    and.filter(\.$id < cursorID)
                }
            }
        }
        for event in try await projectQuery.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit + 1).all() {
            rows.append(Row(item: ActivityFeedItem(
                id: try event.requireID(), source: "project", projectID: event.projectID,
                projectName: projects[event.projectID]?.name ?? "", taskID: nil, taskTitle: nil, sequence: event.sequence,
                actorType: event.actorType, actorID: event.actorID, actorName: nil, kind: event.kind,
                subjectID: event.subjectID, createdAt: event.createdAt)))
        }

        rows.sort { a, b in a.key.0 != b.key.0 ? a.key.0 > b.key.0 : a.key.1 > b.key.1 }
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        let names = try await displayNames(pageRows.filter { $0.item.actorType == .person }.map(\.item.actorID), on: db)
        let items = pageRows.map { row -> ActivityFeedItem in
            var item = row.item
            if item.actorType == .person { item.actorName = names[item.actorID] }
            return item
        }
        let next = hasMore ? items.last.map { "\($0.createdAt?.timeIntervalSince1970 ?? 0):\($0.id.uuidString)" } : nil
        return ActivityFeedPage(items: items, nextCursor: next)
    }
}
