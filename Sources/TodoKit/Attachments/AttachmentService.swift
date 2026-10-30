import Fluent
import Vapor

struct BeginAttachment: Content {
    let taskID: UUID
    let filename: String
    let role: String
    let mediaType: String
    let size: Int
    let checksum: String
}
struct UploadCapability: Content {
    let attachmentID: UUID
    let uploadURL: String
    let token: String
    let expiresAt: Date
}

struct AttachmentService: Sendable {
    static let lifetime: TimeInterval = 900
    let maxBytes: Int
    /// Where new uploads go. Existing rows are read from the store recorded on the row.
    let writeKind: AttachmentStorageKind
    /// Test seam: replaces the store for a kind (for example an in-memory stand-in for S3).
    private let overrides: [AttachmentStorageKind: any AttachmentStore]

    init(settings: AppSettings) {
        self.init(writeKind: settings.attachmentStorage, maxBytes: settings.attachmentMaxBytes)
    }
    init(writeKind: AttachmentStorageKind = .database, maxBytes: Int = AttachmentLimits.defaultMaxBytes,
         overrides: [AttachmentStorageKind: any AttachmentStore] = [:]) {
        self.writeKind = writeKind; self.maxBytes = maxBytes; self.overrides = overrides
    }

    /// S3 is resolved lazily from S3_* so a database-only deployment never needs it.
    func store(_ kind: AttachmentStorageKind) throws -> any AttachmentStore {
        if let custom = overrides[kind] { return custom }
        switch kind {
        case .database: return DatabaseStore()
        case .s3: return try S3Store.fromEnvironment(maxBytes: maxBytes)
        }
    }
    func store(for a: Attachment) throws -> any AttachmentStore {
        guard let kind = AttachmentStorageKind(rawValue: a.storage) else { throw Abort(.badGateway, reason: "attachment_storage_failed") }
        return try store(kind)
    }

    static func mediaType(_ data: Data) -> String? {
        let b = Array(data.prefix(12))
        if b.starts(with: [137,80,78,71,13,10,26,10]) { return "image/png" }
        if b.starts(with: [255,216,255]) { return "image/jpeg" }
        if b.count >= 12, b.prefix(4) == Array("RIFF".utf8)[...], b[8..<12] == Array("WEBP".utf8)[...] { return "image/webp" }
        if b.starts(with: Array("%PDF-".utf8)) { return "application/pdf" }
        return nil
    }

    /// Reading needs `.read`; creating, uploading, completing and aborting need `.edit`.
    static func authorize(_ a: Attachment, user: User, db: any Database, role: ProjectRole = .read) async throws {
        _ = try await ProjectAccess(user: user, db: db).task(a.taskID, role: role)
    }

    func begin(_ input: BeginAttachment, user: User, db: any Database) async throws -> UploadCapability {
        guard input.size > 0, input.size <= maxBytes,
              ["reference", "progress", "result"].contains(input.role),
              ["image/png", "image/jpeg", "image/webp", "application/pdf"].contains(input.mediaType),
              input.checksum.count == 64, input.checksum.allSatisfy({ "0123456789abcdef".contains($0) }),
              !input.filename.isEmpty, input.filename.utf8.count <= 200,
              !input.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !input.filename.contains("/"), !input.filename.contains("\\")
        else { throw Abort(.badRequest, reason: "invalid_attachment") }
        _ = try store(writeKind)  // 503 attachment_storage_unconfigured before any row exists
        let a = Attachment()
        a.id = UUID(); a.storage = writeKind.rawValue; a.taskID = input.taskID; a.ownerID = try user.requireID()
        a.filename = input.filename; a.role = input.role; a.mediaType = input.mediaType
        a.size = input.size; a.checksum = input.checksum; a.status = "pending"
        a.objectKey = "attachments/\(try a.requireID().uuidString.lowercased())"
        let token = AuthSupport.randomToken()
        let session = UploadSession()
        session.attachmentID = try a.requireID(); session.tokenHash = AuthSupport.hash(token)
        session.expiresAt = Date().addingTimeInterval(Self.lifetime); session.uploaded = false
        try await db.transaction { db in
            try await Self.authorize(a, user: user, db: db, role: .edit)
            try await a.create(on: db); try await session.create(on: db)
        }
        return UploadCapability(attachmentID: try a.requireID(), uploadURL: "/v1/attachments/\(try a.requireID())/upload", token: token, expiresAt: session.expiresAt)
    }

    func validate(_ data: Data, for a: Attachment) throws {
        guard data.count == a.size, data.count <= maxBytes else { throw Abort(.unprocessableEntity, reason: "attachment_size_mismatch") }
        guard Self.mediaType(data) == a.mediaType else { throw Abort(.unsupportedMediaType, reason: "attachment_media_mismatch") }
        guard AttachmentChecksum.sha256(data) == a.checksum else { throw Abort(.unprocessableEntity, reason: "attachment_checksum_mismatch") }
    }

    /// Lock order is always attachment then upload session. Storage I/O finishes before releasing the lock;
    /// for the database store the blob rows commit in the same transaction as the session flag.
    func upload(_ id: UUID, token: String, data: Data, db: any Database) async throws {
        try await db.transaction { db in
            try await lockRow(table: Attachment.schema, id: id, on: db)
            guard let a = try await Attachment.find(id, on: db), a.status == "pending",
                  let session = try await UploadSession.query(on: db).filter(\.$attachmentID == id).first(),
                  session.expiresAt > Date(), !session.uploaded,
                  AuthSupport.constantTimeEquals(session.tokenHash, AuthSupport.hash(token)),
                  let user = try await User.find(a.ownerID, on: db)
            else { throw Abort(.notFound) }
            try await Self.authorize(a, user: user, db: db, role: .edit)
            try validate(data, for: a)
            try await store(for: a).put(key: a.objectKey, data: data, db: db)
            try await Self.authorize(a, user: user, db: db, role: .edit)
            session.uploaded = true
            try await session.update(on: db)
        }
    }

    func complete(_ id: UUID, user: User, db: any Database) async throws -> AttachmentDTO {
        try await db.transaction { db in
            try await lockRow(table: Attachment.schema, id: id, on: db)
            guard let a = try await Attachment.find(id, on: db) else { throw Abort(.notFound) }
            try await Self.authorize(a, user: user, db: db, role: .edit)
            if a.status == "complete" { return try AttachmentDTO(a) }
            guard let session = try await UploadSession.query(on: db).filter(\.$attachmentID == id).first(),
                  session.expiresAt > Date(), session.uploaded else { throw Abort(.conflict, reason: "upload_incomplete_or_expired") }
            try validate(try await store(for: a).get(key: a.objectKey, db: db), for: a)
            try await Self.authorize(a, user: user, db: db, role: .edit)
            a.status = "complete"
            try await a.update(on: db)
            try await session.delete(on: db)
            return try AttachmentDTO(a)
        }
    }

    func abort(_ id: UUID, user: User, db: any Database) async throws {
        try await db.transaction { db in
            try await lockRow(table: Attachment.schema, id: id, on: db)
            guard let a = try await Attachment.find(id, on: db) else { throw Abort(.notFound) }
            try await Self.authorize(a, user: user, db: db, role: .edit)
            guard a.status == "pending" else { throw Abort(.conflict) }
            try await store(for: a).delete(key: a.objectKey, db: db)
            try await a.delete(on: db)
        }
    }

    /// Also removes objects orphaned by task/account deletion; failures retain metadata for retry.
    /// A failure for one attachment (for example an unconfigured S3) does not stop the others; the first
    /// error is rethrown after the sweep.
    @discardableResult func cleanup(db: any Database, now: Date = Date()) async throws -> Int {
        var removed = 0
        var firstError: (any Error)?
        for a in try await Attachment.query(on: db).all() {
            let id = try a.requireID()
            do {
                let didRemove = try await db.transaction { db -> Bool in
                    try await lockRow(table: Attachment.schema, id: id, on: db)
                    guard let current = try await Attachment.find(id, on: db) else { return false }
                    let session = try await UploadSession.query(on: db).filter(\.$attachmentID == id).first()
                    let task = try await TodoTask.find(current.taskID, on: db)
                    guard task == nil || (current.status == "pending" && (session == nil || session!.expiresAt <= now)) else { return false }
                    try await store(for: current).delete(key: current.objectKey, db: db)
                    try await current.delete(on: db)
                    return true
                }
                if didRemove { removed += 1 }
            } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        return removed
    }
}
