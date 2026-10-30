import Fluent
import SQLKit

/// Additive. Adds the per-row store marker and the chunk table; existing rows were written to S3
/// (the only store before this migration), so the column default is `s3`.
struct AddAttachmentBlobStorage: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Attachment.schema)
            .field("storage", .string, .required, .sql(.default("s3")))
            .update()
        try await db.schema(AttachmentBlob.schema).id()
            .field("attachment_id", .uuid, .required, .references(Attachment.schema, "id", onDelete: .cascade))
            .field("chunk_index", .int, .required)
            // LONGBLOB on MariaDB; SQLite treats it as BLOB. Rows are at most AttachmentLimits.chunkBytes.
            .field("bytes", .sql(unsafeRaw: "LONGBLOB"), .required)
            .unique(on: "attachment_id", "chunk_index")
            .create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(AttachmentBlob.schema).delete()
        if let sql = db as? any SQLDatabase, sql.dialect.name != "sqlite" {
            try await db.schema(Attachment.schema).deleteField("storage").update()
        }
    }
}
