import Fluent

struct CreateAttachmentSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Attachment.schema).id()
            .field("task_id", .uuid, .required)
            .field("owner_id", .uuid, .required)
            .field("filename", .string, .required)
            .field("role", .string, .required)
            .field("media_type", .string, .required)
            .field("size", .int, .required)
            .field("checksum", .string, .required)
            .field("status", .string, .required)
            .field("object_key", .string, .required)
            .unique(on: "object_key").create()
        try await db.schema(UploadSession.schema).id()
            .field("attachment_id", .uuid, .required, .references(Attachment.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("uploaded", .bool, .required)
            .unique(on: "attachment_id").unique(on: "token_hash").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(UploadSession.schema).delete()
        try await db.schema(Attachment.schema).delete()
    }
}
