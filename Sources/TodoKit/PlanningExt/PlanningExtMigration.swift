import Fluent

struct CreatePlanningExtension: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TaskPlanning.schema)
            .field("id", .uuid, .identifier(auto: false), .references("tasks", "id", onDelete: .cascade))
            .field("due_at", .datetime).field("planned_at", .datetime)
            .field("priority", .int, .required).field("position", .int, .required)
            .field("recurrence", .json).field("reminders", .json, .required).create()
        try await db.schema(PlanningDependency.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("prerequisite_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .unique(on: "task_id", "prerequisite_id").create()
        try await db.schema(PlanningMilestone.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("title", .string, .required).field("due_at", .datetime).create()
        try await db.schema(PlanningMilestoneTask.schema).id()
            .field("milestone_id", .uuid, .required, .references(PlanningMilestone.schema, "id", onDelete: .cascade))
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .unique(on: "milestone_id", "task_id").create()
        try await db.schema(PlanningOccurrence.schema)
            .field("id", .uuid, .identifier(auto: false), .references("tasks", "id", onDelete: .cascade))
            .field("next_task_id", .uuid, .references("tasks", "id", onDelete: .setNull)).create()
    }
    func revert(on db: any Database) async throws {
        for table in [PlanningOccurrence.schema, PlanningMilestoneTask.schema, PlanningMilestone.schema,
                      PlanningDependency.schema, TaskPlanning.schema] { try await db.schema(table).delete() }
    }
}
