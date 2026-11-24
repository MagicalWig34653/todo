import Fluent
import Vapor

/// Retention of voice audio (ADR 0030 step 7, decision by Lino 13.11.2026). Transcripts stay in the channel history;
/// only the audio goes, and the message then no longer points to it.
enum VoiceRetention {
    /// Recording of the person: deleted right after processing (`VoiceService.result`), at the latest after this time.
    static let inputLifetime: TimeInterval = 24 * 3600
    /// Reply audio of the brain.
    static let replyLifetime: TimeInterval = 7 * 24 * 3600
    /// Both kinds of audio for accounts with "keep audio" switched on (`BrainChannel.keepAudio`).
    static let keepLifetime: TimeInterval = 30 * 24 * 3600
    /// What the privacy settings show the person.
    static let shown = VoiceRetentionDTO(inputHours: Int(inputLifetime / 3600), replyDays: Int(replyLifetime / 86400), keepDays: Int(keepLifetime / 86400))

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
        // Accounts that keep their audio switch to the long limit; everyone else gets the short one per kind.
        let keepers = Set(try await BrainChannel.query(on: db).filter(\.$keepAudio == true).all().map(\.ownerID))
        let keepCutoff = now.addingTimeInterval(-keepLifetime)
        for (kind, lifetime) in [("voice_in", inputLifetime), ("voice_out", replyLifetime)] {
            let cutoff = now.addingTimeInterval(-lifetime)
            let due = try await ChannelMessage.query(on: db).filter(\.$kind == kind).filter(\.$attachmentID != nil)
                .filter(\.$createdAt < cutoff).all()
            for candidate in due {
                let id = try candidate.requireID()
                if keepers.contains(candidate.ownerID), candidate.createdAt >= keepCutoff { continue }
                let didRemove = try await db.transaction { tx -> Bool in
                    try await lockRow(table: ChannelMessage.schema, id: id, on: tx)
                    guard let message = try await ChannelMessage.find(id, on: tx), let attachmentID = message.attachmentID,
                          message.createdAt < cutoff else { return false }
                    // Re-read under the lock: switching keepAudio on after the scan must still protect the audio.
                    let keeps = try await BrainChannel.query(on: tx).filter(\.$ownerID == message.ownerID).filter(\.$keepAudio == true).count() > 0
                    if keeps, message.createdAt >= keepCutoff { return false }
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

    /// Anonymizing an account: the history (see `eraseHistory`) and the channel itself.
    static func eraseChannel(of owner: UUID, on db: any Database) async throws {
        try await eraseHistory(of: owner, on: db)
        try await BrainChannel.query(on: db).filter(\.$ownerID == owner).delete()
    }

    /// Channel messages, jobs and every voice recording and reply of the account (also unposted ones); the channel and its
    /// settings stay. Recordings in the database go with their bytes at once; an S3 object is marked `deleted` and removed
    /// by the next sweep (the account layer has no storage settings). Returns what was removed.
    @discardableResult
    static func eraseHistory(of owner: UUID, on db: any Database) async throws -> (messages: Int, audio: Int) {
        let messages = try await ChannelMessage.query(on: db).filter(\.$ownerID == owner).count()
        try await VoiceJob.query(on: db).filter(\.$ownerID == owner).delete()
        try await ChannelMessage.query(on: db).filter(\.$ownerID == owner).delete()
        var audio = 0
        // Rows already marked `deleted` wait for the sweep to remove their object; they are not counted again.
        for a in try await Attachment.query(on: db).filter(\.$ownerID == owner).filter(\.$taskID == Attachment.noTask).filter(\.$role == "voice").all() {
            let id = try a.requireID()
            if a.status != "deleted" { audio += 1 }
            try await UploadSession.query(on: db).filter(\.$attachmentID == id).delete()
            try await VoiceService.deleteAttachment(id, db: db)
        }
        return (messages, audio)
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
