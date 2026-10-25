import Fluent
import FluentSQL
import SQLKit

struct CreateAgentSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("runner_devices").id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .restrict))
            .field("label", .sql(.text), .required)
            .field("token_hash", .string)
            .field("revoked_at", .datetime)
            .unique(on: "token_hash")
            .create()
        try await db.schema("runner_pairings").id()
            .field("device_id", .uuid, .required, .references("runner_devices", "id", onDelete: .restrict))
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .unique(on: "code_hash")
            .create()
        try await db.schema("project_runner_bindings").id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .restrict))
            .field("device_id", .uuid, .required, .references("runner_devices", "id", onDelete: .restrict))
            .field("repository_key", .string, .required)
            .field("label", .sql(.text), .required)
            .create()
        try await db.schema("agent_jobs").id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .restrict))
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .restrict))
            .field("binding_id", .uuid, .required, .references("project_runner_bindings", "id", onDelete: .restrict))
            .field("requested_by", .uuid, .required, .references("users", "id", onDelete: .restrict))
            .field("previous_job_id", .uuid, .references("agent_jobs", "id", onDelete: .restrict))
            .field("task_revision", .int, .required)
            .field("mode", .sql(.text), .required)
            .field("scope", .sql(.text), .required)
            .field("state", .string, .required)
            .field("progress", .sql(.text), .required)
            .field("result", .sql(.text))
            .create()
        try await db.schema("agent_runs").id()
            .field("job_id", .uuid, .required, .references("agent_jobs", "id", onDelete: .restrict))
            .field("binding_id", .uuid, .required, .references("project_runner_bindings", "id", onDelete: .restrict))
            .field("device_id", .uuid, .required, .references("runner_devices", "id", onDelete: .restrict))
            .field("generation", .int, .required)
            .field("lease_until", .datetime, .required)
            .field("ended_at", .datetime)
            .unique(on: "job_id")
            .create()
        try await db.schema("agent_checkpoints").id()
            .field("run_id", .uuid, .required, .references("agent_runs", "id", onDelete: .restrict))
            .field("context_revision", .int, .required)
            .field("session_reference", .sql(.text), .required)
            .field("next_step", .sql(.text), .required)
            .unique(on: "run_id")
            .create()
        try await db.schema("agent_questions").id()
            .field("job_id", .uuid, .required, .references("agent_jobs", "id", onDelete: .restrict))
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .restrict))
            .field("prompt", .sql(.text), .required)
            .field("options", .json, .required)
            .create()
        try await db.schema("agent_answers").id()
            .field("question_id", .uuid, .required, .references("agent_questions", "id", onDelete: .restrict))
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .restrict))
            .field("value", .sql(.text), .required)
            .unique(on: "question_id")
            .create()
        try await db.schema("agent_events").id()
            .field("job_id", .uuid, .required, .references("agent_jobs", "id", onDelete: .restrict))
            .field("run_id", .uuid, .references("agent_runs", "id", onDelete: .restrict))
            .field("kind", .sql(.text), .required)
            .field("detail", .sql(.text), .required)
            .field("created_at", .datetime, .required)
            .create()
        if let sql = db as? any SQLDatabase {
            for statement in [
                "CREATE INDEX agent_binding_repository ON project_runner_bindings (device_id, repository_key)",
                "CREATE INDEX agent_run_slot ON agent_runs (binding_id, ended_at)",
                "CREATE INDEX agent_job_queue ON agent_jobs (binding_id, state)",
                "CREATE INDEX agent_question_job ON agent_questions (job_id)",
                "CREATE INDEX agent_event_job ON agent_events (job_id, created_at)"
            ] {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
        }
    }
    func revert(on db: any Database) async throws {
        for table in ["agent_events", "agent_answers", "agent_questions", "agent_checkpoints", "agent_runs", "agent_jobs", "project_runner_bindings", "runner_pairings", "runner_devices"] {
            try await db.schema(table).delete()
        }
    }
}
