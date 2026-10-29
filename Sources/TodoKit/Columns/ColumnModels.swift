import Fluent
import Vapor

/// A board column of exactly one project (ADR 0011). Columns are never inherited by sub-projects.
final class ProjectColumn: Model, @unchecked Sendable {
    static let schema = "project_columns"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "name") var name: String
    @OptionalField(key: "color") var color: String?
    /// Moving a task into this column completes it; moving it out of a completed state reopens it.
    @Field(key: "is_done") var isDone: Bool
    /// Dense 0-based order inside the project (renumbered under the sharing-graph lock).
    @Field(key: "position") var position: Int
    @Field(key: "version") var version: Int
    init() {}
    init(projectID: UUID, name: String, color: String?, isDone: Bool, position: Int) {
        self.projectID = projectID; self.name = name; self.color = color; self.isDone = isDone
        self.position = position; self.version = 1
    }
}

struct ColumnDTO: Content, Equatable {
    let id: UUID
    let projectID: UUID
    let name: String
    let color: String?
    let isDone: Bool
    let position: Int
    let version: Int
    init(_ c: ProjectColumn) throws {
        id = try c.requireID(); projectID = c.projectID; name = c.name; color = c.color
        isDone = c.isDone; position = c.position; version = c.version
    }
}

struct CreateColumnRequest: Content {
    let name: String
    let color: String?
    let isDone: Bool?
    /// 0-based insert position, default end.
    let index: Int?
}

struct UpdateColumnRequest: Content {
    let version: Int
    let name: String?
    /// `#RRGGBB`; empty string removes the colour.
    let color: String?
    let isDone: Bool?
    let index: Int?
}

struct ColumnTemplateRequest: Content {
    /// `"status"` (Offen / In Arbeit / Erledigt) or the UUID of a readable project whose columns are copied.
    let source: String
}

struct MoveTaskRequest: Content {
    let version: Int
    /// Target column of the task's own project; `null` = "Ohne Spalte".
    let columnID: UUID?
    /// 0-based position in the target column, default end.
    let index: Int?
}

struct BoardColumn: Content {
    /// `nil` for the virtual status columns of a project without own columns.
    let id: UUID?
    /// Status key for virtual columns (`open|in_progress|in_review|done`), otherwise `nil`.
    let key: String?
    let name: String
    let color: String?
    let isDone: Bool
    let position: Int
    let version: Int?
    let tasks: [TaskDTO]
}

struct BoardResponse: Content {
    let projectID: UUID
    /// `status`: project has no own columns, tasks are grouped by status. `columns`: own columns.
    let mode: String
    let columns: [BoardColumn]
    /// Tasks without a column (only in `columns` mode; empty in `status` mode).
    let unassigned: [TaskDTO]
}

struct CreateProjectColumns: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ProjectColumn.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("color", .string)
            .field("is_done", .bool, .required)
            .field("position", .int, .required)
            .field("version", .int, .required)
            .create()
        // No foreign key on tasks.column_id: the service reassigns tasks before a column is deleted, under the
        // sharing-graph lock. This keeps the ALTER portable between SQLite and MariaDB.
        // One ALTER per column: SQLite cannot add several columns in a single statement.
        try await db.schema(TodoTask.schema).field("column_id", .uuid).update()
        try await db.schema(TodoTask.schema).field("board_position", .int, .required, .sql(.default(0))).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ProjectColumn.schema).delete()
    }
}
