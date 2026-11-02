import Foundation
import XCTest
import XCTVapor
@testable import TodoKit

/// Security review part 2: credentials stay bound to their destination (finding 1), outbound target protection (finding 2).
final class OutboundSecurityTests: XCTestCase {
    // MARK: Finding 1 - credential/destination binding

    private func mailEnv(_ extra: [String: String]) -> (String) -> String? {
        let base = ["MAIL_ENABLED": "true", "MAIL_FROM": "todolino@example.org", "SMTP_SECURITY": "starttls"]
        let all = base.merging(extra) { $1 }
        return { all[$0] }
    }

    func testEnvPasswordCannotBeCombinedWithDatabaseHost() throws {
        let env = mailEnv(["SMTP_USER": "u", "SMTP_PASSWORD": "secret-pass"])
        let values = try SettingsResolver.resolve(env: env, stored: ["mail.smtpHost": "evil.example.net"])
        XCTAssertThrowsError(try values.mailConfig()) { error in
            XCTAssertEqual((error as? SettingsProblem)?.code, "setting_dependency")
            XCTAssertEqual((error as? SettingsProblem)?.key, "mail.smtpHost")
        }
        // A database port is a destination change as well.
        let withPort = try SettingsResolver.resolve(env: mailEnv(["SMTP_HOST": "smtp.example.org", "SMTP_USER": "u", "SMTP_PASSWORD": "p"]), stored: ["mail.smtpPort": "2525"])
        XCTAssertThrowsError(try withPort.mailConfig())
    }

    func testEnvPasswordWithEnvHostStillWorks() throws {
        let env = mailEnv(["SMTP_HOST": "smtp.example.org", "SMTP_USER": "u", "SMTP_PASSWORD": "p"])
        let config = try SettingsResolver.resolve(env: env, stored: [:]).mailConfig()
        XCTAssertEqual(config.host, "smtp.example.org"); XCTAssertEqual(config.password, "p")
        // Database credentials with a database host are the admin's own configuration.
        let db = try SettingsResolver.resolve(env: mailEnv([:]), stored: ["mail.smtpHost": "smtp.example.org", "mail.smtpUser": "u", "mail.smtpPassword": "p"]).mailConfig()
        XCTAssertEqual(db.host, "smtp.example.org")
    }

    func testEnvS3KeysCannotBeCombinedWithDatabaseEndpoint() throws {
        let env: (String) -> String? = { ["S3_BUCKET": "b", "S3_ACCESS_KEY": "ak", "S3_SECRET_KEY": "sk"][$0] }
        let values = try SettingsResolver.resolve(env: env, stored: ["attachments.s3Endpoint": "https://evil.example.net"])
        XCTAssertThrowsError(try values.s3Config()) { XCTAssertEqual(($0 as? SettingsProblem)?.key, "attachments.s3Endpoint") }
    }

    func testStoredPasswordBlocksHostChangeUntilReset() async throws {
        let s = ServerSettingsTests()
        let f = try await s.fixture(); defer { Task { await f.t.shutdown() } }
        var r = try await s.put(f, "mail.smtpHost", "smtp.example.org")
        XCTAssertEqual(r.status, .ok)
        r = try await s.put(f, "mail.smtpUser", "u"); XCTAssertEqual(r.status, .ok)
        r = try await s.put(f, "mail.smtpPassword", "pw-1"); XCTAssertEqual(r.status, .ok)
        r = try await s.put(f, "mail.smtpHost", "evil.example.net", version: 1)
        XCTAssertEqual(r.status, .unprocessableEntity)
        XCTAssertEqual(r.body?["reason"] as? String, "setting_dependency")
        let reset = try await f.t.json(.DELETE, "/v1/admin/settings/mail.smtpHost", token: f.admin.token)
        XCTAssertEqual(reset.status, .unprocessableEntity)
        // Same value is not a change.
        r = try await s.put(f, "mail.smtpHost", "smtp.example.org", version: 1)
        XCTAssertEqual(r.status, .ok)
        // After removing the credentials the destination can change.
        for key in ["mail.smtpPassword", "mail.smtpUser"] {
            let d = try await f.t.json(.DELETE, "/v1/admin/settings/\(key)", token: f.admin.token)
            XCTAssertEqual(d.status, .ok)
        }
        r = try await s.put(f, "mail.smtpHost", "other.example.org", version: 2)
        XCTAssertEqual(r.status, .ok)
    }

    // MARK: Finding 2 - target protection

    func testAddressClassification() {
        let blockedStandard = ["169.254.169.254", "169.254.0.1", "0.0.0.0", "fe80::1", "fd00:ec2::254", "::", "::ffff:169.254.169.254", "[fe80::1]", "not-an-ip"]
        for ip in blockedStandard { XCTAssertTrue(OutboundGuard.isBlocked(ip, .standard), ip) }
        let allowedStandard = ["127.0.0.1", "::1", "10.0.0.5", "172.16.1.1", "192.168.1.1", "93.184.216.34", "2001:db8::1", "::ffff:10.0.0.1"]
        for ip in allowedStandard { XCTAssertFalse(OutboundGuard.isBlocked(ip, .standard), ip) }
        let blockedStrict = ["127.0.0.1", "::1", "10.1.2.3", "172.31.0.1", "192.168.0.1", "100.64.0.1", "fc00::1", "fd12::1", "::ffff:127.0.0.1"]
        for ip in blockedStrict { XCTAssertTrue(OutboundGuard.isBlocked(ip, .strict), ip) }
        XCTAssertFalse(OutboundGuard.isBlocked("93.184.216.34", .strict))
        XCTAssertFalse(OutboundGuard.isBlocked("172.32.0.1", .strict))
        for ip in ["169.254.169.254", "127.0.0.1"] { XCTAssertFalse(OutboundGuard.isBlocked(ip, .off)) }
    }

    func testSMTPClientRefusesMetadataAndLinkLocalTargets() async throws {
        for host in ["169.254.169.254", "fe80::1", "::ffff:169.254.169.254"] {
            var config = MailConfig(); config.enabled = true; config.host = host; config.port = 25; config.security = .none
            config.from = "a@example.org"
            let client = try SMTPClient(config: config, timeout: .seconds(5))
            do {
                try await client.send(MailMessage(to: "b@example.org", subject: "s", text: "t", html: "<p>t</p>"))
                XCTFail("must be blocked: \(host)")
            } catch let e as MailSendError {
                XCTAssertEqual(e.stage, .blocked, host)
            }
        }
    }

    func testStrictBlocksLoopbackButStandardDoesNot() async throws {
        var config = MailConfig(); config.enabled = true; config.host = "127.0.0.1"; config.port = 1; config.security = .none
        config.from = "a@example.org"
        let message = MailMessage(to: "b@example.org", subject: "s", text: "t", html: "<p>t</p>")
        config.protection = .strict
        do { try await SMTPClient(config: config, timeout: .seconds(5)).send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertEqual(e.stage, .blocked) }
        config.protection = .standard
        do { try await SMTPClient(config: config, timeout: .seconds(5)).send(message); XCTFail() }
        catch let e as MailSendError { XCTAssertEqual(e.stage, .connect, "loopback is allowed; nothing listens on port 1") }
    }

    func testHostnameResolvingToBlockedAddressIsRefused() async throws {
        // "localhost" resolves to loopback: allowed by default, refused when strict (the resolved IP is checked, not the name).
        let group = MultiThreadedEventLoopGroup.singleton
        _ = try await OutboundGuard.resolve(host: "localhost", port: 25, protection: .standard, group: group)
        do { _ = try await OutboundGuard.resolve(host: "localhost", port: 25, protection: .strict, group: group); XCTFail() }
        catch is OutboundBlocked {}
    }

    func testS3StoreRefusesMetadataEndpoint() async throws {
        let store = S3Store(endpoint: URL(string: "http://169.254.169.254")!, bucket: "b", accessKey: nil, secretKey: nil, region: "us-east-1")
        do { _ = try await store.send("GET", key: "k"); XCTFail() }
        catch let e as Abort { XCTAssertEqual(e.reason, "outbound_target_blocked") }
    }

    func testProtectionIsAnAdminSettingWithSafeDefault() throws {
        let values = try SettingsResolver.resolve(env: { _ in nil }, stored: [:])
        XCTAssertEqual(values.outboundProtection(), .standard)
        XCTAssertEqual(try SettingsResolver.resolve(env: { _ in nil }, stored: ["security.outboundProtection": "strict"]).outboundProtection(), .strict)
        XCTAssertEqual(try SettingsResolver.resolve(env: { ["OUTBOUND_TARGET_PROTECTION": "off"][$0] }, stored: [:]).outboundProtection(), .off)
    }

    // MARK: Finding 4 - logout CSRF

    func testCookieLogoutNeedsJSONAndMatchingOrigin() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let origin = t.app.settings.relyingPartyOrigin
        func logout(json: Bool, origin sent: String?) async throws -> HTTPStatus {
            var status = HTTPStatus.ok
            try await t.app.test(.POST, "/v1/auth/logout", beforeRequest: { req async in
                req.headers.add(name: .cookie, value: "\(AuthSupport.cookieName)=\(a.session)")
                if json { req.headers.contentType = .json; req.body = ByteBuffer(string: "{}") }
                if let sent { req.headers.replaceOrAdd(name: .origin, value: sent) }
            }, afterResponse: { res async in status = res.status })
            return status
        }
        let plainForm = try await logout(json: false, origin: nil)
        XCTAssertEqual(plainForm, .unsupportedMediaType)
        let foreign = try await logout(json: true, origin: "https://sibling.example.org")
        XCTAssertEqual(foreign, .forbidden)
        let stillIn = try await t.json(.GET, "/v1/me", token: a.session)
        XCTAssertEqual(stillIn.status, .ok, "a rejected logout must keep the session")
        let ok = try await logout(json: true, origin: origin)
        XCTAssertEqual(ok, .noContent)
    }
}
