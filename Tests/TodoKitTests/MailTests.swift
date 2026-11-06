import Crypto
import Fluent
import NIOCore
import NIOPosix
import XCTVapor
@testable import TodoKit

/// Mail transport double: records messages and fails according to a script. No network is involved.
final class MockMail: MailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [MailMessage] = []
    private var _failures: [MailSendError] = []
    var sent: [MailMessage] { lock.withLock { _sent } }
    func failNext(_ errors: MailSendError...) { lock.withLock { _failures.append(contentsOf: errors) } }
    func send(_ message: MailMessage) async throws {
        let failure: MailSendError? = lock.withLock {
            if !_failures.isEmpty { return _failures.removeFirst() }
            _sent.append(message); return nil
        }
        if let failure { throw failure }
    }
}

final class MailTests: XCTestCase {
    struct Account { let id: UUID; let token: String }

    struct Fixture {
        let t: TestApp
        let mock: MockMail
        let user: Account
        let other: Account
        let admin: Account
        var worker: MailWorker { MailWorker(app: t.app, interval: 0) }
    }

    static func mailConfig(enabled: Bool = true) -> MailConfig {
        var c = MailConfig()
        c.enabled = enabled; c.host = "smtp.example.org"; c.from = "todolino@example.org"
        return c
    }

    static func account(_ t: TestApp, _ name: String, admin: Bool = false) async throws -> Account {
        let user = User(displayName: name, isAdmin: admin)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return Account(id: try user.requireID(), token: token)
    }

    func fixture(enabled: Bool = true) async throws -> Fixture {
        let t = try await TestApp.make()
        t.app.settings.mail = Self.mailConfig(enabled: enabled)
        t.app.settings.relyingPartyOrigin = "https://todo.example.org"
        let mock = MockMail()
        t.app.mailTransport = mock
        return Fixture(t: t, mock: mock, user: try await Self.account(t, "Anna"), other: try await Self.account(t, "Ben"),
                       admin: try await Self.account(t, "Root", admin: true))
    }

    /// Requests a confirmation, runs the worker and returns the token from the mailed link.
    @discardableResult
    func confirmAddress(_ f: Fixture, _ a: Account, _ address: String) async throws -> String {
        let before = f.mock.sent.count
        let r = try await f.t.json(.POST, "/v1/me/email", ["email": address], token: a.token)
        XCTAssertEqual(r.status, .accepted, "\(r.body ?? [:])")
        _ = try await f.worker.tick()
        let mail = try XCTUnwrap(f.mock.sent.dropFirst(before).first)
        let token = try XCTUnwrap(mail.text.range(of: "#token=").map { String(mail.text[$0.upperBound...].prefix { !$0.isWhitespace }) })
        let c = try await f.t.json(.POST, "/v1/email/confirm", ["token": token])
        XCTAssertEqual(c.status, .noContent)
        return token
    }

    // MARK: Configuration

    func testConfigDisabledByDefaultAndIgnoresIncompleteSettings() throws {
        XCTAssertFalse(try MailConfig.fromEnvironment(get: { _ in nil }).enabled)
        XCTAssertFalse(try MailConfig.fromEnvironment(get: { ["SMTP_HOST": "x"][$0] }).enabled)
    }

    func testConfigValidation() throws {
        func cfg(_ env: [String: String]) throws -> MailConfig { try MailConfig.fromEnvironment(get: { env[$0] }) }
        let base = ["MAIL_ENABLED": "true", "SMTP_HOST": "smtp.example.org", "MAIL_FROM": "todolino@example.org"]
        let ok = try cfg(base)
        XCTAssertTrue(ok.enabled); XCTAssertEqual(ok.port, 587); XCTAssertEqual(ok.security, .starttls); XCTAssertEqual(ok.fromName, "Todolino")
        XCTAssertEqual(try cfg(base.merging(["SMTP_SECURITY": "tls"]) { $1 }).port, 465)
        XCTAssertEqual(try cfg(base.merging(["SMTP_PORT": "2525"]) { $1 }).port, 2525)
        let bad: [[String: String]] = [
            base.filter { $0.key != "SMTP_HOST" }, base.filter { $0.key != "MAIL_FROM" },
            base.merging(["MAIL_FROM": "not-an-address"]) { $1 }, base.merging(["SMTP_PORT": "70000"]) { $1 },
            base.merging(["SMTP_SECURITY": "ssl"]) { $1 }, base.merging(["SMTP_USER": "u"]) { $1 },
            base.merging(["SMTP_PASSWORD": "p"]) { $1 }, base.merging(["MAIL_ENABLED": "yes"]) { $1 },
            base.merging(["SMTP_USER": "u", "SMTP_PASSWORD": "p", "SMTP_SECURITY": "none"]) { $1 },
            base.merging(["MAIL_FROM_NAME": "a\r\nBcc: x@y.z"]) { $1 },
        ]
        for env in bad { XCTAssertThrowsError(try cfg(env), "\(env)") }
        // Credentials over cleartext are fine for a loopback test server only.
        XCTAssertNoThrow(try cfg(base.merging(["SMTP_HOST": "127.0.0.1", "SMTP_USER": "u", "SMTP_PASSWORD": "p", "SMTP_SECURITY": "none"]) { $1 }))
    }

    func testConfigReadsPasswordFromSecretFileAndNeverPrintsIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("smtp-\(UUID())")
        try "s3cret-pw\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = ["MAIL_ENABLED": "true", "SMTP_HOST": "smtp.example.org", "MAIL_FROM": "a@example.org", "SMTP_USER": "u", "SMTP_PASSWORD_FILE": file.path]
        XCTAssertEqual(try MailConfig.fromEnvironment(get: { env[$0] }).password, "s3cret-pw")
        let missing = env.merging(["SMTP_PASSWORD_FILE": "/nonexistent/secret"]) { $1 }
        XCTAssertThrowsError(try MailConfig.fromEnvironment(get: { missing[$0] })) { XCTAssertFalse("\($0)".contains("nonexistent")) }
    }

    func testAddressNormalizationAndValidation() {
        XCTAssertEqual(MailAddress.normalize("  Anna.Muster@Example.ORG "), "anna.muster@example.org")
        for good in ["a@example.org", "a.b+tag@mail.example.org"] { XCTAssertTrue(MailAddress.isValid(good), good) }
        for bad in ["", "a@b", "a b@example.org", "a@example.org\r\nBcc: x@y.z", "<a@example.org>", "a@@example.org", ".a@example.org", "a..b@example.org", "ä@example.org"] {
            XCTAssertFalse(MailAddress.isValid(bad), bad)
        }
    }

    // MARK: Message format

    func testMessageFormatDotStuffingEncodingAndInjection() throws {
        let cfg = Self.mailConfig()
        let msg = MailMessage(to: "a@example.org", subject: "Prüfung ✓", text: "Hallo\n.Punkt am Anfang\nÜmläut=", html: "<p>x</p>")
        let data = try MailFormat.data(config: cfg, message: msg)
        XCTAssertTrue(data.hasSuffix("\r\n.\r\n"))
        XCTAssertTrue(data.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(data.contains("\r\n..Punkt am Anfang"), "leading dots are stuffed")
        XCTAssertTrue(data.contains("=C3=9Cml=C3=A4ut=3D"))
        XCTAssertTrue(data.contains("multipart/alternative"))
        XCTAssertTrue(data.contains("To: <a@example.org>"))
        XCTAssertThrowsError(try MailFormat.data(config: cfg, message: MailMessage(to: "a@example.org\r\nBcc: x@y.z", subject: "s", text: "", html: "")))
        XCTAssertThrowsError(try MailFormat.data(config: cfg, message: MailMessage(to: "a@example.org", subject: "s\r\nBcc: x@y.z", text: "", html: "")))
        for line in data.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 998) }
    }

    func testTemplatesContainNoTaskDataAndEscapeHTML() {
        let r = MailTemplates.recoveryCode(link: "https://x.example/recover#code=a<b", code: "a<b", expiresAt: Date())
        XCTAssertTrue(r.html.contains("a&lt;b"))
        XCTAssertFalse(r.html.contains("<img")); XCTAssertFalse(r.html.contains("http://"))
        XCTAssertTrue(r.text.contains("kein sicherer Kanal"))
    }

    // MARK: Confirmation flow

    func testStatusWithoutAddress() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let r = try await f.t.json(.GET, "/v1/me/email", token: f.user.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.body?["email"] as? String)
        XCTAssertEqual(r.body?["mailEnabled"] as? Bool, true)
        let anon = try await f.t.json(.GET, "/v1/me/email")
        XCTAssertEqual(anon.status, .unauthorized)
    }

    func testDoubleOptInFlow() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let r = try await f.t.json(.POST, "/v1/me/email", ["email": "  Anna@Example.org "], token: f.user.token)
        XCTAssertEqual(r.status, .accepted)
        XCTAssertEqual(r.body?["status"] as? String, "verification_sent")
        var s = try await f.t.json(.GET, "/v1/me/email", token: f.user.token)
        XCTAssertEqual(s.body?["pending"] as? String, "anna@example.org")
        XCTAssertNil(s.body?["email"] as? String, "unconfirmed addresses are not active")
        // No mail before the worker ran; a test mail is refused while nothing is confirmed.
        XCTAssertTrue(f.mock.sent.isEmpty)
        let early = try await f.t.json(.POST, "/v1/me/email/test", token: f.user.token)
        XCTAssertEqual(early.status, .conflict); XCTAssertEqual(early.body?["reason"] as? String, "no_verified_email")

        let report = try await f.worker.tick()
        XCTAssertEqual(report.sent, 1)
        let mail = try XCTUnwrap(f.mock.sent.first)
        XCTAssertEqual(mail.to, "anna@example.org")
        XCTAssertTrue(mail.text.contains("https://todo.example.org/confirm-email#token="))
        XCTAssertFalse(mail.text.contains("Anna"), "no display name or task data")
        let token = String(mail.text[mail.text.range(of: "#token=")!.upperBound...].prefix { !$0.isWhitespace })

        let bad = try await f.t.json(.POST, "/v1/email/confirm", ["token": "nope"])
        XCTAssertEqual(bad.status, .badRequest); XCTAssertEqual(bad.body?["reason"] as? String, "confirmation_failed")
        let ok = try await f.t.json(.POST, "/v1/email/confirm", ["token": token])
        XCTAssertEqual(ok.status, .noContent)
        let again = try await f.t.json(.POST, "/v1/email/confirm", ["token": token])
        XCTAssertEqual(again.status, .badRequest, "single use")
        s = try await f.t.json(.GET, "/v1/me/email", token: f.user.token)
        XCTAssertEqual(s.body?["email"] as? String, "anna@example.org")
        XCTAssertNil(s.body?["pending"] as? String)
        // The queued row no longer carries the token.
        let row = try await MailOutbox.query(on: f.t.app.db).first()
        XCTAssertEqual(row?.payload, "{}"); XCTAssertEqual(row?.state, "sent")
    }

    func testExpiredTokenIsRejected() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "anna@example.org"], token: f.user.token)
        _ = try await f.worker.tick()
        let mail = try XCTUnwrap(f.mock.sent.first)
        let token = String(mail.text[mail.text.range(of: "#token=")!.upperBound...].prefix { !$0.isWhitespace })
        let v = try await EmailVerification.query(on: f.t.app.db).first()
        v?.expiresAt = Date().addingTimeInterval(-1); try await v?.save(on: f.t.app.db)
        let r = try await f.t.json(.POST, "/v1/email/confirm", ["token": token])
        XCTAssertEqual(r.status, .badRequest)
        let n = try await UserEmail.query(on: f.t.app.db).count()
        XCTAssertEqual(n, 0)
    }

    func testNoAccountEnumerationAndNoMailToForeignAddress() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await confirmAddress(f, f.user, "shared@example.org")
        let before = f.mock.sent.count
        let taken = try await f.t.json(.POST, "/v1/me/email", ["email": "shared@example.org"], token: f.other.token)
        let fresh = try await f.t.json(.POST, "/v1/me/email", ["email": "fresh@example.org"], token: f.other.token)
        XCTAssertEqual(taken.status, fresh.status)
        XCTAssertEqual(Set(taken.body?.keys ?? [:].keys), Set(fresh.body?.keys ?? [:].keys))
        XCTAssertEqual(taken.body?["status"] as? String, fresh.body?["status"] as? String)
        _ = try await f.worker.tick()
        let recipients = f.mock.sent.dropFirst(before).map(\.to)
        XCTAssertEqual(recipients, ["fresh@example.org"], "the taken address receives nothing")
        let s = try await f.t.json(.GET, "/v1/me/email", token: f.other.token)
        XCTAssertEqual(s.body?["pending"] as? String, "fresh@example.org")
    }

    func testNewRequestSupersedesOldLink() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "one@example.org"], token: f.user.token)
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "two@example.org"], token: f.user.token)
        let report = try await f.worker.tick()
        XCTAssertEqual(report.sent, 1); XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(f.mock.sent.map(\.to), ["two@example.org"])
    }

    func testInvalidAddressDisabledServerAndRemoval() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let bad = try await f.t.json(.POST, "/v1/me/email", ["email": "no-at-sign"], token: f.user.token)
        XCTAssertEqual(bad.status, .badRequest); XCTAssertEqual(bad.body?["reason"] as? String, "invalid_email")
        try await confirmAddress(f, f.user, "anna@example.org")
        let del = try await f.t.json(.DELETE, "/v1/me/email", token: f.user.token)
        XCTAssertEqual(del.status, .noContent)
        let s = try await f.t.json(.GET, "/v1/me/email", token: f.user.token)
        XCTAssertNil(s.body?["email"] as? String)
        f.t.app.settings.mail.enabled = false
        let off = try await f.t.json(.POST, "/v1/me/email", ["email": "anna@example.org"], token: f.user.token)
        XCTAssertEqual(off.status, .conflict); XCTAssertEqual(off.body?["reason"] as? String, "mail_disabled")
    }

    func testRateLimits() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for i in 0..<3 {
            let r = try await f.t.json(.POST, "/v1/me/email", ["email": "a\(i)@example.org"], token: f.user.token)
            XCTAssertEqual(r.status, .accepted)
        }
        let fourth = try await f.t.json(.POST, "/v1/me/email", ["email": "a9@example.org"], token: f.user.token)
        XCTAssertEqual(fourth.status, .tooManyRequests)
        // Another account is not affected by the per-account budget.
        let b = try await f.t.json(.POST, "/v1/me/email", ["email": "b@example.org"], token: f.other.token)
        XCTAssertEqual(b.status, .accepted)
    }

    func testTestMailGoesOnlyToConfirmedAddressAndIsRateLimited() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await confirmAddress(f, f.user, "anna@example.org")
        let first = try await f.t.json(.POST, "/v1/me/email/test", token: f.user.token)
        XCTAssertEqual(first.status, .accepted)
        let second = try await f.t.json(.POST, "/v1/me/email/test", token: f.user.token)
        XCTAssertEqual(second.status, .tooManyRequests)
        let before = f.mock.sent.count
        _ = try await f.worker.tick()
        let mail = try XCTUnwrap(f.mock.sent.dropFirst(before).first)
        XCTAssertEqual(mail.to, "anna@example.org"); XCTAssertEqual(mail.subject, "Todolino: Test-Mail")
        let s = try await f.t.json(.GET, "/v1/me/email", token: f.user.token)
        let last = try XCTUnwrap(s.body?["lastMail"] as? [String: Any])
        XCTAssertEqual(last["state"] as? String, "sent"); XCTAssertEqual(last["kind"] as? String, "test")
    }

    func testTestMailSkippedWhenAddressRemovedBeforeSending() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await confirmAddress(f, f.user, "anna@example.org")
        _ = try await f.t.json(.POST, "/v1/me/email/test", token: f.user.token)
        _ = try await f.t.json(.DELETE, "/v1/me/email", token: f.user.token)
        let before = f.mock.sent.count
        let report = try await f.worker.tick()
        XCTAssertEqual(report.skipped, 1); XCTAssertEqual(f.mock.sent.count, before)
    }

    // MARK: Recovery mail

    func issue(_ f: Fixture, for a: Account, sendEmail: Bool?) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let body: [String: Any]? = sendEmail.map { ["sendEmail": $0] }
        let r = try await f.t.json(.POST, "/v1/identity/accounts/\(a.id.uuidString)/recovery", body, token: f.admin.token)
        return (r.status, r.body)
    }

    func testRecoveryMailIsOptionalAndGoesToConfirmedAddress() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        // Unchanged behaviour without the flag: no mail field.
        let plain = try await issue(f, for: f.user, sendEmail: nil)
        XCTAssertEqual(plain.status, .ok); XCTAssertNil(plain.body?["mail"]); XCTAssertNotNil(plain.body?["token"])
        // No confirmed address yet.
        let none = try await issue(f, for: f.user, sendEmail: true)
        XCTAssertEqual(none.body?["mail"] as? String, "no_verified_email")
        try await confirmAddress(f, f.user, "anna@example.org")
        let before = f.mock.sent.count
        let r = try await issue(f, for: f.user, sendEmail: true)
        XCTAssertEqual(r.body?["mail"] as? String, "queued")
        let code = try XCTUnwrap(r.body?["token"] as? String)
        _ = try await f.worker.tick()
        let mail = try XCTUnwrap(f.mock.sent.dropFirst(before).first)
        XCTAssertEqual(mail.to, "anna@example.org")
        XCTAssertTrue(mail.text.contains(code)); XCTAssertTrue(mail.text.contains("https://todo.example.org/recover#code=\(code)"))
        XCTAssertTrue(mail.text.contains("kein sicherer Kanal"))
        let row = try await MailOutbox.query(on: f.t.app.db).filter(\.$kind == MailKind.recoveryCode).first()
        XCTAssertEqual(row?.payload, "{}", "the code does not stay in the outbox")
        // Non-admins cannot issue codes.
        let denied = try await f.t.json(.POST, "/v1/identity/accounts/\(f.user.id.uuidString)/recovery", ["sendEmail": true], token: f.other.token)
        XCTAssertEqual(denied.status, .forbidden)
    }

    func testRecoveryMailNeverGoesToUnconfirmedAddress() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "unconfirmed@example.org"], token: f.user.token)
        _ = try await f.worker.tick()
        let before = f.mock.sent.count
        let r = try await issue(f, for: f.user, sendEmail: true)
        XCTAssertEqual(r.body?["mail"] as? String, "no_verified_email")
        _ = try await f.worker.tick()
        XCTAssertEqual(f.mock.sent.count, before)
    }

    func testRecoveryMailDisabledAndReissueInvalidatesQueuedMail() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await confirmAddress(f, f.user, "anna@example.org")
        f.t.app.settings.mail.enabled = false
        let off = try await issue(f, for: f.user, sendEmail: true)
        XCTAssertEqual(off.body?["mail"] as? String, "mail_disabled")
        f.t.app.settings.mail.enabled = true
        let first = try await issue(f, for: f.user, sendEmail: true)
        let second = try await issue(f, for: f.user, sendEmail: true)
        XCTAssertNotEqual(first.body?["token"] as? String, second.body?["token"] as? String)
        let before = f.mock.sent.count
        let report = try await f.worker.tick()
        XCTAssertEqual(report.sent, 1); XCTAssertEqual(report.skipped, 1, "the superseded code is not mailed")
        let newest = try XCTUnwrap(f.mock.sent.dropFirst(before).first)
        XCTAssertTrue(newest.text.contains(try XCTUnwrap(second.body?["token"] as? String)))
    }

    // MARK: Outbox

    func testRetryWithBackoffThenSuccess() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        f.mock.failNext(MailSendError(stage: .connect, code: nil), MailSendError(stage: .recipient, code: 451))
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "anna@example.org"], token: f.user.token)
        let start = Date()
        var r = try await f.worker.tick(now: start)
        XCTAssertEqual(r.retried, 1)
        r = try await f.worker.tick(now: start.addingTimeInterval(1))
        XCTAssertEqual(r, MailWorker.Report(), "not due before the backoff has passed")
        r = try await f.worker.tick(now: start.addingTimeInterval(120))
        XCTAssertEqual(r.retried, 1)
        r = try await f.worker.tick(now: start.addingTimeInterval(400))
        XCTAssertEqual(r.sent, 1)
        let found = try await MailOutbox.query(on: f.t.app.db).first()
        let row = try XCTUnwrap(found)
        XCTAssertEqual(row.state, "sent"); XCTAssertEqual(row.attempts, 3)
    }

    func testPermanentFailureAndMaxAttempts() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        f.mock.failNext(MailSendError(stage: .recipient, code: 550))
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "gone@example.org"], token: f.user.token)
        var r = try await f.worker.tick()
        XCTAssertEqual(r.failed, 1)
        var found = try await MailOutbox.query(on: f.t.app.db).first()
        var row = try XCTUnwrap(found)
        XCTAssertEqual(row.state, "failed"); XCTAssertEqual(row.lastError, "recipient_550"); XCTAssertEqual(row.payload, "{}")
        try await row.delete(on: f.t.app.db)
        // Endless transient errors end after maxAttempts.
        for _ in 0..<MailService.maxAttempts { f.mock.failNext(MailSendError(stage: .connect, code: nil)) }
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "slow@example.org"], token: f.other.token)
        var now = Date()
        for _ in 0..<MailService.maxAttempts { r = try await f.worker.tick(now: now); now = now.addingTimeInterval(5000) }
        found = try await MailOutbox.query(on: f.t.app.db).first()
        row = try XCTUnwrap(found)
        XCTAssertEqual(row.state, "failed"); XCTAssertEqual(row.attempts, MailService.maxAttempts); XCTAssertEqual(row.lastError, "connect")
        XCTAssertEqual(r.failed, 1)
    }

    func testDedupeAndExpiry() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let service = MailService(db: f.t.app.db, settings: f.t.app.settings)
        let a = try await service.enqueue(kind: MailKind.test, to: "x@example.org", userID: f.user.id, payload: MailPayload(), dedupeKey: "k1", expiresAt: Date().addingTimeInterval(60))
        let b = try await service.enqueue(kind: MailKind.test, to: "x@example.org", userID: f.user.id, payload: MailPayload(), dedupeKey: "k1", expiresAt: Date().addingTimeInterval(60))
        XCTAssertTrue(a); XCTAssertFalse(b)
        let r = try await f.worker.tick(now: Date().addingTimeInterval(120))
        XCTAssertEqual(r.expired, 1); XCTAssertTrue(f.mock.sent.isEmpty)
    }

    func testOnlyOneReplicaWorksPerInterval() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let replica = try await f.t.replica(); defer { Task { await replica.shutdown() } }
        replica.app.settings.mail = Self.mailConfig(); replica.app.mailTransport = f.mock
        let one = MailWorker(app: f.t.app, interval: 3600), two = MailWorker(app: replica.app, interval: 3600)
        let first = await one.runIfDue(), second = await two.runIfDue()
        XCTAssertEqual([first, second].filter { if case .ran = $0 { return true }; return false }.count, 1)
        XCTAssertTrue([first, second].contains(.skipped))
    }

    func testDisabledServerSkipsPendingRows() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        _ = try await f.t.json(.POST, "/v1/me/email", ["email": "anna@example.org"], token: f.user.token)
        f.t.app.settings.mail.enabled = false
        let r = try await f.worker.tick()
        XCTAssertEqual(r.skipped, 1); XCTAssertTrue(f.mock.sent.isEmpty)
    }

    func testReadyEndpointReportsMailStatus() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let anon = try await f.t.json(.GET, "/health/ready")
        XCTAssertEqual(anon.status, .ok); XCTAssertNil(anon.body?["mail"]); XCTAssertEqual(anon.body?["status"] as? String, "ok")
        let admin = try await MailTests.account(f.t, "Root", admin: true)
        let r = try await f.t.json(.GET, "/v1/admin/health", token: admin.token)
        XCTAssertEqual((r.body?["mail"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    // MARK: Push test endpoint

    func pushFixture(enabled: Bool = true) async throws -> (t: TestApp, mock: MockAPNs, user: Account, other: Account) {
        let t = try await TestApp.make()
        let user = try await Self.account(t, "Anna"), other = try await Self.account(t, "Ben")
        var cfg = APNsConfig()
        cfg.enabled = enabled; cfg.keyPEM = P256.Signing.PrivateKey().pemRepresentation
        cfg.keyID = "ABCDE12345"; cfg.teamID = "TEAMID1234"; cfg.topics = ["de.linolaske.todo"]
        t.app.settings.apns = cfg
        let mock = MockAPNs()
        if enabled { t.app.apnsSender = try APNsSender(config: cfg, transport: mock) }
        return (t, mock, user, other)
    }

    func device(_ t: TestApp, _ a: Account, token: String) async throws -> String {
        let r = try await t.json(.POST, "/v1/push/devices", ["token": token, "platform": "ios", "environment": "sandbox", "bundleId": "de.linolaske.todo"], token: a.token)
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    func testPushTestDisabled() async throws {
        let f = try await pushFixture(enabled: false); defer { Task { await f.t.shutdown() } }
        let r = try await f.t.json(.POST, "/v1/push/test", token: f.user.token)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.body?["reason"] as? String, "push_disabled")
    }

    func testPushTestSendsToOwnDevicesOnlyWithoutLeakingTokens() async throws {
        let f = try await pushFixture(); defer { Task { await f.t.shutdown() } }
        let tokenA = String(repeating: "ab", count: 32), tokenB = String(repeating: "cd", count: 32), foreign = String(repeating: "ef", count: 32)
        let idA = try await device(f.t, f.user, token: tokenA), idB = try await device(f.t, f.user, token: tokenB)
        _ = try await device(f.t, f.other, token: foreign)
        f.mock.handler = { $0.deviceToken == tokenB ? APNsResponse(status: 410, reason: "Unregistered") : APNsResponse(status: 200, reason: nil) }
        let r = try await f.t.json(.POST, "/v1/push/test", token: f.user.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["sent"] as? Int, 1)
        let devices = try XCTUnwrap(r.body?["devices"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byID[idA]?["result"] as? String, "sent")
        XCTAssertEqual(byID[idB]?["result"] as? String, "revoked"); XCTAssertEqual(byID[idB]?["detail"] as? String, "Unregistered")
        XCTAssertEqual(Set(f.mock.requests.map(\.deviceToken)), [tokenA, tokenB], "the other account's device is untouched")
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: r.body ?? [:]), as: UTF8.self)
        XCTAssertFalse(raw.contains(tokenA)); XCTAssertFalse(raw.contains(tokenB))
        // The dead token is revoked and not listed any more.
        let list = try await f.t.json(.GET, "/v1/push/devices", token: f.user.token)
        XCTAssertEqual(list.list?.count, 1)
    }

    func testPushTestRateLimitAndNoDevices() async throws {
        let f = try await pushFixture(); defer { Task { await f.t.shutdown() } }
        let empty = try await f.t.json(.POST, "/v1/push/test", token: f.user.token)
        XCTAssertEqual(empty.status, .ok); XCTAssertEqual(empty.body?["sent"] as? Int, 0)
        let again = try await f.t.json(.POST, "/v1/push/test", token: f.user.token)
        XCTAssertEqual(again.status, .tooManyRequests)
        let anon = try await f.t.json(.POST, "/v1/push/test")
        XCTAssertEqual(anon.status, .unauthorized)
    }

    func testPushTestReportsApnsFailureCodes() async throws {
        let f = try await pushFixture(); defer { Task { await f.t.shutdown() } }
        let id = try await device(f.t, f.user, token: String(repeating: "ab", count: 32))
        f.mock.handler = { _ in APNsResponse(status: 403, reason: "InvalidProviderToken") }
        let r = try await f.t.json(.POST, "/v1/push/test", token: f.user.token)
        let d = try XCTUnwrap((r.body?["devices"] as? [[String: Any]])?.first)
        XCTAssertEqual(d["id"] as? String, id); XCTAssertEqual(d["result"] as? String, "failed"); XCTAssertEqual(d["detail"] as? String, "InvalidProviderToken")
    }
}

// MARK: - SMTP client against a scripted loopback server

/// Tiny SMTP server for the client dialog. It records what it received and answers according to its settings.
final class FakeSMTPServer: @unchecked Sendable {
    struct Received: Sendable { var commands: [String] = []; var data = "" }
    private let lock = NSLock()
    private var _received = Received()
    var received: Received { lock.withLock { _received } }
    var mechanisms = "PLAIN LOGIN"
    var rejectRecipientWith: Int?
    var rejectAuth = false
    var port = 0
    private var channel: (any Channel)?

    fileprivate func record(_ command: String) { lock.withLock { _received.commands.append(command) } }
    fileprivate func recordData(_ d: String) { lock.withLock { _received.data = d } }

    func start() async throws {
        let server = self
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Handler(server)) }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        channel = ch; port = ch.localAddress!.port!
    }
    func stop() async { try? await channel?.close().get() }

    /// The client sends QUIT fire-and-forget and closes right away, so the server records it on its own
    /// event loop after `send` has returned. Waits (up to `timeout`) until `command` has been recorded.
    func waitFor(_ command: String, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !received.commands.contains(command), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let server: FakeSMTPServer
        var buffer = ""
        var inData = false
        var loginStep = 0
        init(_ s: FakeSMTPServer) { server = s }
        func channelActive(context: ChannelHandlerContext) { reply(context, "220 fake ESMTP") }
        func reply(_ context: ChannelHandlerContext, _ text: String) {
            var b = context.channel.allocator.buffer(capacity: text.utf8.count + 2)
            b.writeString(text + "\r\n"); context.writeAndFlush(wrapOutboundOut(b), promise: nil)
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffer += bytes.readString(length: bytes.readableBytes) ?? ""
            if inData {
                guard buffer.hasSuffix("\r\n.\r\n") else { return }
                server.recordData(buffer); buffer = ""; inData = false
                reply(context, "250 queued"); return
            }
            while let r = buffer.range(of: "\r\n") {
                let line = String(buffer[..<r.lowerBound]); buffer.removeSubrange(..<r.upperBound)
                handle(context, line)
                if inData { if !buffer.isEmpty, buffer.hasSuffix("\r\n.\r\n") { server.recordData(buffer); buffer = ""; inData = false; reply(context, "250 queued") }; return }
            }
        }
        func handle(_ context: ChannelHandlerContext, _ line: String) {
            if loginStep > 0 {
                server.record("login-step-\(loginStep)")
                if loginStep == 1 { loginStep = 2; reply(context, "334 UGFzc3dvcmQ6"); return }
                loginStep = 0
                reply(context, server.rejectAuth ? "535 no" : "235 ok"); return
            }
            let upper = line.uppercased()
            if !upper.hasPrefix("AUTH PLAIN") { server.record(line) }
            if upper.hasPrefix("EHLO") { reply(context, "250-fake\r\n250-AUTH \(server.mechanisms)\r\n250 SIZE 1000000") }
            else if upper.hasPrefix("AUTH PLAIN") {
                server.record("plain:" + String(line.dropFirst(11)))
                reply(context, server.rejectAuth ? "535 no" : "235 ok")
            }
            else if upper == "AUTH LOGIN" { loginStep = 1; reply(context, "334 VXNlcm5hbWU6") }
            else if upper.hasPrefix("MAIL FROM") { reply(context, "250 ok") }
            else if upper.hasPrefix("RCPT TO") { reply(context, server.rejectRecipientWith.map { "\($0) rejected" } ?? "250 ok") }
            else if upper == "DATA" { inData = true; reply(context, "354 go") }
            else if upper == "QUIT" { reply(context, "221 bye"); context.close(promise: nil) }
            else { reply(context, "500 what") }
        }
    }
}

final class SMTPClientTests: XCTestCase {
    func config(_ port: Int, user: String? = nil, password: String? = nil) -> MailConfig {
        var c = MailConfig()
        c.enabled = true; c.host = "127.0.0.1"; c.port = port; c.security = .none; c.from = "todolino@example.org"
        c.user = user; c.password = password
        return c
    }
    let message = MailMessage(to: "anna@example.org", subject: "Betreff", text: "Hallo\n.Welt", html: "<p>Hallo</p>")

    func testDeliversMessageWithoutAuth() async throws {
        let server = FakeSMTPServer(); try await server.start()
        let client = try SMTPClient(config: config(server.port))
        try await client.send(message)
        await server.waitFor("QUIT")
        await server.stop()
        let got = server.received
        XCTAssertEqual(got.commands, ["EHLO todolino.local", "MAIL FROM:<todolino@example.org>", "RCPT TO:<anna@example.org>", "DATA", "QUIT"])
        XCTAssertTrue(got.data.contains("Subject: Betreff")); XCTAssertTrue(got.data.contains("..Welt"))
        XCTAssertFalse(got.commands.contains { $0.hasPrefix("AUTH") })
    }

    func testAuthPlain() async throws {
        let server = FakeSMTPServer(); try await server.start()
        try await SMTPClient(config: config(server.port, user: "user", password: "pw")).send(message)
        await server.stop()
        let expected = Data("\0user\0pw".utf8).base64EncodedString()
        XCTAssertTrue(server.received.commands.contains("plain:" + expected))
    }

    func testAuthLoginWhenPlainIsNotOffered() async throws {
        let server = FakeSMTPServer(); server.mechanisms = "LOGIN"; try await server.start()
        try await SMTPClient(config: config(server.port, user: "user", password: "pw")).send(message)
        await server.stop()
        XCTAssertTrue(server.received.commands.contains("login-step-2"))
        XCTAssertFalse(server.received.commands.contains { $0.hasPrefix("plain:") })
    }

    func testFailureClassesCarryNoServerText() async throws {
        let server = FakeSMTPServer(); server.rejectAuth = true; try await server.start()
        do { try await SMTPClient(config: config(server.port, user: "user", password: "hunter2")).send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertEqual(e.stage, .auth); XCTAssertEqual(e.code, 535); XCTAssertFalse(e.isPermanent); XCTAssertFalse(e.description.contains("hunter2")) }
        server.rejectAuth = false; server.rejectRecipientWith = 550
        do { try await SMTPClient(config: config(server.port)).send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertEqual(e.stage, .recipient); XCTAssertTrue(e.isPermanent); XCTAssertEqual(e.description, "recipient_550") }
        server.rejectRecipientWith = 451
        do { try await SMTPClient(config: config(server.port)).send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertFalse(e.isPermanent) }
        await server.stop()
    }

    func testConnectFailureAndTimeout() async throws {
        // Nothing listens on this port.
        let closed = try await { () -> Int in
            let s = FakeSMTPServer(); try await s.start(); let p = s.port; await s.stop(); return p
        }()
        do { try await SMTPClient(config: config(closed)).send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertEqual(e.stage, .connect) }
        // A server that accepts but never speaks hits the dialog timeout.
        let silent = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        defer { silent.close(promise: nil) }
        let client = try SMTPClient(config: config(silent.localAddress!.port!), timeout: .milliseconds(300))
        do { try await client.send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertEqual(e.stage, .timeout) }
    }
}
