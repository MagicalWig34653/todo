import Fluent
import FluentSQL
import Vapor

/// Per-account state of one project (ADR 0012): sibling order, favourite flag/order and display preferences.
/// One row per (user, project); rows are created lazily. Everything here is private to the account.
final class ProjectUserState: Model, @unchecked Sendable {
    static let schema = "project_user_state"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "project_id") var projectID: UUID
    /// 0-based rank among the viewer's visible siblings; `nil` until the viewer reordered that sibling group.
    @OptionalField(key: "order_position") var orderPosition: Int?
    @Field(key: "is_favorite") var isFavorite: Bool
    /// Dense 0-based rank among the account's favourites (meaningful while `isFavorite`).
    @Field(key: "favorite_position") var favoritePosition: Int
    @Field(key: "view_mode") var view: String
    @Field(key: "sort_mode") var sortMode: String
    @Field(key: "grouping") var grouping: String
    @Field(key: "show_completed") var showCompleted: Bool
    /// `classic` | `management`; `nil` = never chosen, the effective mode is derived (see `ProjectStateService.defaultModes`).
    @OptionalField(key: "mode") var mode: String?
    /// Incremented on every write of favourite flag or display preferences (not on pure reordering); 0 = defaults.
    @Field(key: "revision") var revision: Int
    @Field(key: "updated_at") var updatedAt: Date
    init() {}

    static let views: Set<String> = ["list", "board"]
    static let sorts: Set<String> = ["manual", "title", "due", "priority"]
    static let groupings: Set<String> = ["none", "column", "priority", "due"]
    static let modes: Set<String> = ["classic", "management"]

    init(userID: UUID, projectID: UUID) {
        self.userID = userID; self.projectID = projectID
        orderPosition = nil; isFavorite = false; favoritePosition = 0
        view = "list"; sortMode = "manual"; grouping = "column"; showCompleted = true
        revision = 0; updatedAt = Date()
    }

    static func states(of user: User, on db: any Database) async throws -> [UUID: ProjectUserState] {
        let rows = try await ProjectUserState.query(on: db).filter(\.$userID == user.requireID()).all()
        return Dictionary(rows.map { ($0.projectID, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Comment on a project (not on a task). Same rules as task comments; `createdAt` is exposed.
final class ProjectComment: Model, @unchecked Sendable {
    static let schema = "project_comments"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "author_id") var authorID: UUID
    @Field(key: "body") var body: String
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(projectID: UUID, authorID: UUID, body: String) {
        self.projectID = projectID; self.authorID = authorID; self.body = body; version = 1
    }
}

final class ProjectCommentIdempotency: Model, @unchecked Sendable {
    static let schema = "project_comment_idempotency"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "key_hash") var keyHash: String
    @Field(key: "request_body") var requestBody: String
    @Field(key: "comment_id") var commentID: UUID
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

/// Project-level activity (comments on the project). Task-level events stay in `activity_events`.
final class ProjectActivityEvent: Model, @unchecked Sendable {
    static let schema = "project_activity_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "sequence") var sequence: Int
    @Field(key: "actor_type") var actorType: ActivityActorType
    @Field(key: "actor_id") var actorID: UUID
    @Field(key: "kind") var kind: String
    @OptionalField(key: "subject_id") var subjectID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

/// Additive: description/colour on projects. Registered before `CreateSyncSchema`, whose backfill reads projects
/// through the model (which already contains these columns).
struct AddProjectDetails: AsyncMigration {
    func prepare(on db: any Database) async throws {
        // One ALTER per column: SQLite cannot add several columns in one statement. TEXT, never VARCHAR(255).
        try await db.schema(Project.schema).field("description", .sql(unsafeRaw: "TEXT")).update()
        try await db.schema(Project.schema).field("color", .string).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(Project.schema).deleteField("color").update()
        try await db.schema(Project.schema).deleteField("description").update()
    }
}

/// Additive: per-account project mode (classic | management). NULL = derived default, so existing rows need no backfill.
struct AddProjectUserStateMode: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ProjectUserState.schema).field("mode", .string).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ProjectUserState.schema).deleteField("mode").update()
    }
}

struct CreateProjectState: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ProjectUserState.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("order_position", .int)
            .field("is_favorite", .bool, .required)
            .field("favorite_position", .int, .required)
            .field("view_mode", .string, .required)
            .field("sort_mode", .string, .required)
            .field("grouping", .string, .required)
            .field("show_completed", .bool, .required)
            .field("revision", .int, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "user_id", "project_id")
            .create()
        try await db.schema(ProjectComment.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references("users", "id"))
            .field("body", .sql(unsafeRaw: "TEXT"), .required)
            .field("version", .int, .required)
            .field("created_at", .datetime)
            .create()
        try await db.schema(ProjectCommentIdempotency.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("key_hash", .string, .required)
            .field("request_body", .sql(unsafeRaw: "TEXT"), .required)
            .field("comment_id", .uuid, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "project_id", "user_id", "key_hash")
            .create()
        try await db.schema(ProjectActivityEvent.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("sequence", .int, .required)
            .field("actor_type", .string, .required)
            .field("actor_id", .uuid, .required)
            .field("kind", .string, .required)
            .field("subject_id", .uuid)
            .field("created_at", .datetime)
            .unique(on: "project_id", "sequence")
            .create()
    }
    func revert(on db: any Database) async throws {
        for table in [ProjectActivityEvent.schema, ProjectCommentIdempotency.schema, ProjectComment.schema, ProjectUserState.schema] {
            try await db.schema(table).delete()
        }
    }
}
