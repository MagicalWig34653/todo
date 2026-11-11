import Fluent
import FluentSQL

/// Additive indexes for the hot read paths (command center, feed, task lists, sharing graph).
/// SQLite does not index foreign keys on its own; on MariaDB an index with the same leading columns replaces the
/// implicit foreign key index, so nothing is duplicated there. `IF NOT EXISTS` keeps the migration repeatable.
struct AddPerformanceIndexes: AsyncMigration {
    /// (index name, table, columns)
    static let indexes: [(name: String, table: String, columns: String)] = [
        ("perf_tasks_project", "tasks", "project_id"),
        ("perf_projects_owner", "projects", "owner_id"),
        ("perf_projects_parent", "projects", "parent_id"),
        ("perf_comments_task", "comments", "task_id"),
        ("perf_criteria_task", "acceptance_criteria", "task_id"),
        ("perf_questions_task", "task_questions", "task_id, state"),
        ("perf_reviews_task", "task_reviews", "task_id, state"),
        ("perf_notes_task", "task_progress_notes", "task_id, created_at"),
        ("perf_activity_created", "activity_events", "created_at"),
        ("perf_workflow_parent", "task_workflow", "parent_task_id"),
        ("perf_memberships_user", "sharing_memberships", "user_id, accepted"),
        ("perf_sharing_owner", "sharing_projects", "owner_type, owner_id"),
        ("perf_grants_principal", "sharing_grants", "principal_type, principal_id"),
        ("perf_task_labels_label", "discovery_task_labels", "label_id"),
        ("perf_labels_owner", "discovery_labels", "owner_id"),
    ]

    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for index in Self.indexes {
            try await sql.raw("CREATE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.table) (\(unsafeRaw: index.columns))").run()
        }
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for index in Self.indexes {
            if sql.dialect.name == "sqlite" {
                try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
            } else {
                try await sql.raw("DROP INDEX \(unsafeRaw: index.name) ON \(unsafeRaw: index.table)").run()
            }
        }
    }
}

/// Serves the "newest row per task" subqueries of `ClaimLiveness` (orphaned claims): `activity_events` and `comments`
/// had no index that ends in `created_at` per task. Runner events (`agent_event_job`) and progress notes
/// (`perf_notes_task`) already have one. Separate migration because `AddPerformanceIndexes` has already run in production.
struct AddSignOfLifeIndexes: AsyncMigration {
    static let indexes: [(name: String, table: String, columns: String)] = [
        ("perf_activity_task_created", "activity_events", "task_id, created_at"),
        ("perf_comments_task_created", "comments", "task_id, created_at"),
    ]

    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for index in Self.indexes {
            try await sql.raw("CREATE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.table) (\(unsafeRaw: index.columns))").run()
        }
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for index in Self.indexes {
            if sql.dialect.name == "sqlite" {
                try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
            } else {
                try await sql.raw("DROP INDEX \(unsafeRaw: index.name) ON \(unsafeRaw: index.table)").run()
            }
        }
    }
}
