import Fluent
import Vapor

/// Retention of voice audio (ADR 0030 step 7, decision by Lino 13.11.2026). Transcripts stay in the channel history.
enum VoiceRetention {
    /// Recording of the person: deleted right after processing, at the latest after this time.
    static let inputLifetime: TimeInterval = 24 * 3600
    /// Reply audio of the brain.
    static let replyLifetime: TimeInterval = 7 * 24 * 3600

    @discardableResult
    static func sweep(db: any Database, service: AttachmentService = AttachmentService(), now: Date = Date()) async throws -> Int { 0 }
}
