import Fluent
import FluentSQL

/// ADR 0043, additive: the card's responsible person. Registered before the sync backfill, which reads tasks through the
/// model (like `CreateProjectColumns`). No foreign key: account deletion clears assignments through the models, so that
/// other clients receive the change.
struct AddTaskAssignee: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TodoTask.schema).field("assignee_id", .uuid).update()
        try await AssignmentIndex.tasks.create(on: db)
    }
    func revert(on db: any Database) async throws {
        try await AssignmentIndex.tasks.drop(on: db)
        try await db.schema(TodoTask.schema).deleteField("assignee_id").update()
    }
}

/// ADR 0043, additive: the person a question is for, and when a question or review was handed to somebody else later
/// (the new person is then notified although the item itself is older). Reviews keep `reviewer_id` as their assignee.
/// One ALTER per column (SQLite cannot add several at once).
struct AddQuestionAndReviewAssignment: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskQuestion.schema).field("assignee_id", .uuid).update()
        try await db.schema(TaskQuestion.schema).field("assigned_at", .datetime).update()
        try await db.schema(TaskReview.schema).field("assigned_at", .datetime).update()
        try await AssignmentIndex.questions.create(on: db)
        try await AssignmentIndex.reviews.create(on: db)
    }
    func revert(on db: any Database) async throws {
        try await AssignmentIndex.reviews.drop(on: db)
        try await AssignmentIndex.questions.drop(on: db)
        try await db.schema(TaskReview.schema).deleteField("assigned_at").update()
        try await db.schema(TaskQuestion.schema).deleteField("assigned_at").update()
        try await db.schema(TaskQuestion.schema).deleteField("assignee_id").update()
    }
}

/// Indexes behind "for me". `IF NOT EXISTS` keeps the migrations repeatable.
struct AssignmentIndex: Sendable {
    let name: String, table: String, column: String
    static let tasks = AssignmentIndex(name: "assign_tasks_assignee", table: "tasks", column: "assignee_id")
    static let questions = AssignmentIndex(name: "assign_questions_assignee", table: "task_questions", column: "assignee_id")
    static let reviews = AssignmentIndex(name: "assign_reviews_reviewer", table: "task_reviews", column: "reviewer_id")

    func create(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS \(unsafeRaw: name) ON \(unsafeRaw: table) (\(unsafeRaw: column))").run()
    }
    func drop(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        if sql.dialect.name == "sqlite" {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: name)").run()
        } else {
            try await sql.raw("DROP INDEX \(unsafeRaw: name) ON \(unsafeRaw: table)").run()
        }
    }
}
