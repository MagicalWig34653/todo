import Fluent
import Vapor

struct MailPayload: Codable, Sendable, Equatable {
    var token: String?
    var code: String?
    /// Expiry of the token or code shown in the text (unix seconds).
    var until: Int?
}

enum MailKind {
    static let verifyEmail = "verify_email"
    static let recoveryCode = "recovery_code"
    static let test = "test"
}

/// Enqueueing and the address confirmation rules. Nothing here talks to a mail server.
struct MailService: Sendable {
    static let verificationLifetime: TimeInterval = 24 * 3600
    static let maxAttempts = 6

    let db: any Database
    let settings: AppSettings

    static func backoff(attempt: Int) -> TimeInterval { min(3600, 30 * pow(2, Double(max(0, attempt - 1)))) }

    /// Inserts a pending row unless the dedupe key is already known; returns whether it was new.
    @discardableResult
    func enqueue(kind: String, to recipient: String, userID: UUID?, payload: MailPayload, dedupeKey: String, expiresAt: Date, now: Date = Date()) async throws -> Bool {
        if try await MailOutbox.query(on: db).filter(\.$dedupeKey == dedupeKey).count() > 0 { return false }
        let row = MailOutbox()
        row.userID = userID; row.recipient = recipient; row.kind = kind; row.dedupeKey = dedupeKey
        row.payload = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        row.state = "pending"; row.attempts = 0; row.nextAttemptAt = now; row.expiresAt = expiresAt
        do { try await row.save(on: db) } catch {
            // Lost a race on the unique key: counts as already enqueued.
            if try await MailOutbox.query(on: db).filter(\.$dedupeKey == dedupeKey).count() > 0 { return false }
            throw error
        }
        return true
    }

    func confirmedEmail(of userID: UUID) async throws -> UserEmail? {
        try await UserEmail.query(on: db).filter(\.$userID == userID).first()
    }

    // MARK: Status

    func status(for userID: UUID) async throws -> EmailStatusDTO {
        let confirmed = try await confirmedEmail(of: userID)
        let pending = try await EmailVerification.query(on: db).filter(\.$userID == userID).filter(\.$expiresAt > Date()).first()
        let last = try await MailOutbox.query(on: db).filter(\.$userID == userID).filter(\.$kind != MailKind.recoveryCode)
            .sort(\.$createdAt, .descending).first()
        return EmailStatusDTO(
            email: confirmed?.email, verifiedAt: confirmed?.verifiedAt, pending: pending?.email, pendingExpiresAt: pending?.expiresAt,
            mailEnabled: settings.mail.enabled,
            lastMail: last.map { LastMailDTO(kind: $0.kind, state: $0.state, error: $0.lastError, at: $0.sentAt ?? $0.createdAt) })
    }

    // MARK: Double opt-in

    /// Starts the confirmation. The caller always answers the same way: an address that already belongs to another
    /// account (or to this one) produces no mail and no different response, so nobody can probe for registered addresses.
    func requestVerification(userID: UUID, address: String, now: Date = Date()) async throws -> EmailRequestedDTO {
        let expires = now.addingTimeInterval(Self.verificationLifetime)
        let taken = try await UserEmail.query(on: db).filter(\.$email == address).filter(\.$userID != userID).count() > 0
        let own = try await confirmedEmail(of: userID)?.email == address
        guard !taken, !own else { return EmailRequestedDTO(status: "verification_sent", expiresAt: expires) }
        let token = AuthSupport.randomToken()
        let digest = AuthSupport.hash(token)
        try await db.transaction { tx in
            try await lockRow(table: User.schema, id: userID, on: tx)
            try await EmailVerification.query(on: tx).filter(\.$userID == userID).delete()
            let row = EmailVerification()
            row.userID = userID; row.email = address; row.tokenHash = digest; row.expiresAt = expires
            try await row.save(on: tx)
        }
        try await enqueue(kind: MailKind.verifyEmail, to: address, userID: userID,
                          payload: MailPayload(token: token, code: nil, until: Int(expires.timeIntervalSince1970)),
                          dedupeKey: "verify:" + digest.prefix(32), expiresAt: expires, now: now)
        return EmailRequestedDTO(status: "verification_sent", expiresAt: expires)
    }

    /// Single-use confirmation. Every failure (unknown, used, expired, address meanwhile taken) is the same error.
    func confirm(token: String, now: Date = Date()) async throws {
        let fail = Abort(.badRequest, reason: "confirmation_failed")
        guard let found = try await EmailVerification.query(on: db).filter(\.$tokenHash == AuthSupport.hash(token)).first() else { throw fail }
        do {
            try await db.transaction { tx in
                try await lockRow(table: User.schema, id: found.userID, on: tx)
                guard let v = try await EmailVerification.find(found.id, on: tx), v.expiresAt > now else { throw fail }
                if try await UserEmail.query(on: tx).filter(\.$email == v.email).filter(\.$userID != v.userID).count() > 0 { throw fail }
                let row = try await UserEmail.query(on: tx).filter(\.$userID == v.userID).first() ?? UserEmail()
                row.userID = v.userID; row.email = v.email; row.verifiedAt = now
                try await row.save(on: tx)
                try await v.delete(on: tx)
            }
        } catch let abort as Abort where abort.reason == "confirmation_failed" {
            throw fail
        }
    }

    func remove(userID: UUID) async throws {
        try await db.transaction { tx in
            try await lockRow(table: User.schema, id: userID, on: tx)
            try await UserEmail.query(on: tx).filter(\.$userID == userID).delete()
            try await EmailVerification.query(on: tx).filter(\.$userID == userID).delete()
        }
    }

    // MARK: Recovery code

    enum RecoveryMail: String, Sendable { case queued, noVerifiedEmail = "no_verified_email", mailDisabled = "mail_disabled" }

    /// Queues the one-time recovery code for the confirmed address of the account (ADR 0010 / 0024).
    func queueRecoveryCode(userID: UUID, code: String, expiresAt: Date) async throws -> RecoveryMail {
        guard settings.mail.enabled else { return .mailDisabled }
        guard let address = try await confirmedEmail(of: userID) else { return .noVerifiedEmail }
        try await enqueue(kind: MailKind.recoveryCode, to: address.email, userID: userID,
                          payload: MailPayload(token: nil, code: code, until: Int(expiresAt.timeIntervalSince1970)),
                          dedupeKey: "recovery:" + AuthSupport.hash(code).prefix(32), expiresAt: expiresAt)
        return .queued
    }
}
