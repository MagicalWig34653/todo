import Fluent
import Vapor

/// `App attachments migrate-storage --from s3 --to database [--dry-run] [--delete-source]`
struct AttachmentsCommandGroup: AsyncCommandGroup {
    let help = "Attachment storage administration."
    let commands: [String: any AnyAsyncCommand] = ["migrate-storage": MigrateAttachmentStorageCommand()]
    var defaultCommand: (any AnyAsyncCommand)? { nil }
}

struct MigrateStorageReport: Equatable, Sendable {
    var migrated = 0
    var skipped = 0
    var failed: [UUID] = []
}

extension AttachmentService {
    /// Copies complete attachments from one store to the other. Idempotent and resumable: rows already on the
    /// target are not selected, a half-copied target is overwritten, and the source is only removed on request
    /// after the row has been switched. Each attachment is verified (size, media type, SHA-256) on the way.
    func migrateStorage(from: AttachmentStorageKind, to: AttachmentStorageKind, dryRun: Bool = false,
                        deleteSource: Bool = false, db: any Database) async throws -> MigrateStorageReport {
        guard from != to else { throw Abort(.badRequest, reason: "same_storage") }
        let source = try store(from), target = try store(to)
        var report = MigrateStorageReport()
        let ids = try await Attachment.query(on: db).filter(\.$storage == from.rawValue).filter(\.$status == "complete")
            .field(\.$id).all().map { try $0.requireID() }
        for id in ids {
            if dryRun { report.migrated += 1; continue }
            do {
                let switched = try await db.transaction { db -> Attachment? in
                    try await lockRow(table: Attachment.schema, id: id, on: db)
                    guard let a = try await Attachment.find(id, on: db), a.storage == from.rawValue, a.status == "complete" else { return nil }
                    // Rows of deleted tasks are left to `cleanup-uploads`; copying them would only resurrect data.
                    guard try await TodoTask.find(a.taskID, on: db) != nil else { return nil }
                    let data = try await source.get(key: a.objectKey, db: db)
                    try validate(data, for: a)
                    try await target.put(key: a.objectKey, data: data, db: db)
                    a.storage = to.rawValue
                    try await a.update(on: db)
                    return a
                }
                guard let switched else { report.skipped += 1; continue }
                report.migrated += 1
                if deleteSource { try await source.delete(key: switched.objectKey, db: db) }
            } catch { report.failed.append(id) }
        }
        return report
    }
}

struct MigrateAttachmentStorageCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "from", help: "Source store: database or s3") var from: String?
        @Option(name: "to", help: "Target store: database or s3") var to: String?
        @Flag(name: "dry-run", help: "Only count what would be copied") var dryRun: Bool
        @Flag(name: "delete-source", help: "Delete source bytes after each attachment was switched") var deleteSource: Bool
    }
    let help = "Copy attachment bytes between the database and S3 (idempotent, verified by SHA-256)."

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let from = signature.from.flatMap(AttachmentStorageKind.init(rawValue:)),
              let to = signature.to.flatMap(AttachmentStorageKind.init(rawValue:)), from != to else {
            throw Abort(.badRequest, reason: "Usage: attachments migrate-storage --from s3|database --to database|s3")
        }
        let app = context.application
        let report = try await AttachmentService(settings: app.settings)
            .migrateStorage(from: from, to: to, dryRun: signature.dryRun, deleteSource: signature.deleteSource, db: app.db)
        context.console.print("\(signature.dryRun ? "Would migrate" : "Migrated") \(report.migrated), skipped \(report.skipped), failed \(report.failed.count).")
        for id in report.failed { context.console.error("failed: \(id)") }
        if !report.failed.isEmpty { throw Abort(.internalServerError, reason: "\(report.failed.count) attachments failed; rerun to retry") }
    }
}
