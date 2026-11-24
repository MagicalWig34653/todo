import Fluent
import Vapor

/// Retention of voice audio (ADR 0030 step 7, decision by Lino 13.11.2026). Transcripts stay in the channel history;
/// only the audio goes, and the message then no longer points to it.
enum VoiceRetention {
    /// Recording of the person: deleted right after processing (`VoiceService.result`), at the latest after this time.
    static let inputLifetime: TimeInterval = 24 * 3600
    /// Reply audio of the brain.
    static let replyLifetime: TimeInterval = 7 * 24 * 3600

    /// Idempotent and safe on every replica (each message is re-read under its row lock). Returns the number of removed
    /// recordings. `now` is a parameter so that tests move time instead of waiting.
    @discardableResult
    static func sweep(db: any Database, service: AttachmentService = AttachmentService(), now: Date = Date()) async throws -> Int {
        var removed = 0
        // Recordings of ended jobs on S3 are only marked `deleted` (the job layer has no storage settings): remove the object now.
        let marked = try await Attachment.query(on: db).filter(\.$taskID == Attachment.noTask).filter(\.$role == "voice")
            .filter(\.$status == "deleted").field(\.$id).all()
        for a in marked {
            if try await remove(try a.requireID(), service: service, db: db) { removed += 1 }
        }
        for (kind, lifetime) in [("voice_in", inputLifetime), ("voice_out", replyLifetime)] {
            let cutoff = now.addingTimeInterval(-lifetime)
            let due = try await ChannelMessage.query(on: db).filter(\.$kind == kind).filter(\.$attachmentID != nil)
                .filter(\.$createdAt < cutoff).field(\.$id).all()
            for m in due {
                let id = try m.requireID()
                let didRemove = try await db.transaction { tx -> Bool in
                    try await lockRow(table: ChannelMessage.schema, id: id, on: tx)
                    guard let message = try await ChannelMessage.find(id, on: tx), let attachmentID = message.attachmentID,
                          message.createdAt < cutoff else { return false }
                    // A recording that a job still needs is ended by the job's own 10 minute expiry, never by the sweep.
                    if kind == "voice_in", let job = try await VoiceJob.query(on: tx).filter(\.$messageID == id).first(), !job.isEnded {
                        return false
                    }
                    try await remove(attachmentID, service: service, db: tx)
                    message.attachmentID = nil
                    try await message.save(on: tx)
                    return true
                }
                if didRemove { removed += 1 }
            }
        }
        return removed
    }

    /// Deletes the object and the row. A storage failure (S3 down) leaves the row marked `deleted`: the next sweep retries,
    /// and nothing can be downloaded in the meantime. Returns false when the row is already gone.
    @discardableResult
    private static func remove(_ id: UUID, service: AttachmentService, db: any Database) async throws -> Bool {
        guard let a = try await Attachment.find(id, on: db) else { return false }
        if a.storage == AttachmentStorageKind.database.rawValue {
            try await DatabaseStore().delete(key: a.objectKey, db: db)
            try await a.delete(on: db)
            return true
        }
        do {
            try await service.store(for: a).delete(key: a.objectKey, db: db)
            try await a.delete(on: db)
            return true
        } catch {
            a.status = "deleted"
            try await a.update(on: db)
            return false
        }
    }
}
