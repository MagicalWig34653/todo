import Fluent
import Vapor

final class Attachment: Model, @unchecked Sendable {
    static let schema = "attachments"
    @ID(key: .id) var id: UUID?
    // Deliberately retained after task deletion so cleanup can still delete the object.
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "filename") var filename: String
    @Field(key: "role") var role: String
    @Field(key: "media_type") var mediaType: String
    @Field(key: "size") var size: Int
    @Field(key: "checksum") var checksum: String
    @Field(key: "status") var status: String
    @Field(key: "object_key") var objectKey: String
    /// `AttachmentStorageKind` raw value; legacy rows (created before the column existed) are `s3`.
    @Field(key: "storage") var storage: String
    init() { storage = AttachmentStorageKind.database.rawValue }
}

/// One chunk of an attachment stored in the database. Kept apart from `attachments` so that metadata
/// queries never touch blob pages.
final class AttachmentBlob: Model, @unchecked Sendable {
    static let schema = "attachment_blobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "attachment_id") var attachmentID: UUID
    @Field(key: "chunk_index") var chunkIndex: Int
    @Field(key: "bytes") var bytes: Data
    init() {}
}

final class UploadSession: Model, @unchecked Sendable {
    static let schema = "attachment_upload_sessions"
    @ID(key: .id) var id: UUID?
    @Field(key: "attachment_id") var attachmentID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "uploaded") var uploaded: Bool
    init() {}
}

struct AttachmentDTO: Content {
    let id: UUID
    let taskID: UUID
    let filename: String
    let role: String
    let mediaType: String
    let size: Int
    let checksum: String
    let status: String
    init(_ a: Attachment) throws {
        id = try a.requireID(); taskID = a.taskID; filename = a.filename
        role = a.role; mediaType = a.mediaType; size = a.size
        checksum = a.checksum; status = a.status
    }
}
