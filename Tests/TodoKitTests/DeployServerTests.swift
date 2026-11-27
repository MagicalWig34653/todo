import Fluent
import Foundation
import XCTVapor
@testable import TodoKit

/// Deploy targets against real servers in containers (card 354ADE12, ADR 0039): atmoz/sftp and pure-ftpd with TLS, started by
/// `scripts/test-deploy-servers.sh`. Skipped unless `TODO_TEST_DEPLOY_SERVERS=1`. Real rclone, real ssh-keyscan.
final class DeployServerTests: XCTestCase {
    typealias Obj = [String: Any]
    static let env = ProcessInfo.processInfo.environment
    static var dir: String { env["TODO_TEST_DEPLOY_DIR"] ?? "" }
    static var sftpPort: Int { Int(env["TODO_TEST_DEPLOY_SFTP_PORT"] ?? "") ?? 24822 }
    static var ftpPort: Int { Int(env["TODO_TEST_DEPLOY_FTP_PORT"] ?? "") ?? 24821 }
    static let sftpPassword = "sftp-Geheim-41d9"
    static let ftpPassword = "ftp-Geheim-83c2"

    override func setUp() async throws {
        try XCTSkipUnless(Self.env["TODO_TEST_DEPLOY_SERVERS"] == "1", "set TODO_TEST_DEPLOY_SERVERS=1 (scripts/test-deploy-servers.sh)")
    }

    struct Fixture {
        let o: OAuthFixture
        let capture: LogCapture
        let work: URL
        var test: TestApp { o.test }
        var session: String { o.session }
        var projectID: String { o.project.id!.uuidString }
        var responses: [String] = []

        func create(_ body: Obj) async throws -> String {
            let r = try await test.json(.POST, "/v1/projects/\(projectID)/deploy-targets", body, token: session)
            XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
            return try XCTUnwrap(r.body?["id"] as? String)
        }
        func post(_ path: String, _ body: Obj? = nil) async throws -> (status: HTTPStatus, body: Obj, text: String) {
            let r = try await test.json(.POST, path, body, token: session)
            let body = r.body ?? [:]
            let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
            return (r.status, body, text)
        }
    }

    func fixture(_ run: (inout Fixture) async throws -> Void) async throws {
        let o = try await OAuthFixture.make()
        let capture = LogCapture()
        WebhookFixture.installRuntime(o.test.app)
        o.test.app.deployAllowPrivateHosts = true
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        o.test.app.deployWorkDirectory = work
        o.test.app.logger = Logger(label: "deploy-server-test") { _ in var h = CaptureLogHandler(capture: capture); h.logLevel = .trace; return h }
        var f = Fixture(o: o, capture: capture, work: work)
        do { try await run(&f) } catch { await o.test.shutdown(); try? FileManager.default.removeItem(at: work); throw error }
        // Nothing of a run stays on disk (rclone configuration with the obscured password, known_hosts, certificates, copies).
        let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertEqual(left, [], "temporary deploy files left behind")
        try? FileManager.default.removeItem(at: work)
        await o.test.shutdown()
    }

    func assertNoSecret(_ f: Fixture, _ texts: [String], _ secret: String, file: StaticString = #filePath, line: UInt = #line) {
        for t in texts + [f.capture.lines.joined(separator: "\n")] {
            XCTAssertFalse(t.contains(secret), "secret leaked: \(t.prefix(400))", file: file, line: line)
        }
    }

    static var manifest: [Obj] { [
        DeployTargetTests.entry("index.php", "hi\n"),
        DeployTargetTests.entry("css/app.css", "a{}\nb{}\n"),
        DeployTargetTests.entry("about.php", "neu\n"),
        DeployTargetTests.entry("contact.php", "kontakt\n"),
    ] }

    func check(_ result: Obj, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)", file: file, line: line)
        var status: [String: String] = [:]
        for f in result["files"] as? [Obj] ?? [] { status[f["path"] as? String ?? "?"] = f["status"] as? String }
        XCTAssertEqual(status, ["index.php": "same", "css/app.css": "same", "about.php": "changed", "contact.php": "new", "designer.html": "serverOnly"],
                       file: file, line: line)
    }

    // MARK: SFTP (atmoz/sftp)

    func testSFTPHostKeyConfirmCompareAndCage() async throws {
        try await fixture { f in
            let id = try await f.create(["name": "SFTP", "stage": "test", "protocol": "sftp", "host": "127.0.0.1", "port": Self.sftpPort,
                                         "basePath": "site", "username": "deploy", "password": Self.sftpPassword])
            let first = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(first.body["code"] as? String, "deploy_host_key_unconfirmed", first.text)
            let fp = try XCTUnwrap((first.body["offeredHostKey"] as? Obj)?["fingerprint"] as? String)
            XCTAssertTrue(fp.hasPrefix("SHA256:"))
            let confirm = try await f.post("/v1/deploy-targets/\(id)/host-key", ["fingerprint": fp])
            XCTAssertEqual(confirm.status, .ok, confirm.text)

            let ok = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(ok.body["ok"] as? Bool, true, ok.text)

            let compare = try await f.post("/v1/deploy-targets/\(id)/compare", ["files": Self.manifest])
            check(compare.body)
            // Cage: the symlinks in the base path (one to a file outside, one to /etc) are neither listed nor followed.
            XCTAssertFalse(compare.text.contains("link.txt"), compare.text)
            XCTAssertFalse(compare.text.contains("etclink"), compare.text)
            XCTAssertFalse(compare.text.contains("outside"), compare.text)
            assertNoSecret(f, [first.text, confirm.text, ok.text, compare.text], Self.sftpPassword)
        }
    }

    func testSFTPWrongHostKeyIsRefused() async throws {
        try await fixture { f in
            let id = try await f.create(["name": "SFTP", "stage": "test", "protocol": "sftp", "host": "127.0.0.1", "port": Self.sftpPort,
                                         "basePath": "site", "username": "deploy", "password": Self.sftpPassword])
            let first = try await f.post("/v1/deploy-targets/\(id)/test")
            let fp = try XCTUnwrap((first.body["offeredHostKey"] as? Obj)?["fingerprint"] as? String)
            _ = try await f.post("/v1/deploy-targets/\(id)/host-key", ["fingerprint": fp])
            // The server now presents a key other than the pinned one (simulated by pinning a foreign key).
            let found = try await DeployTarget.find(UUID(uuidString: id), on: f.test.app.db)
            let target = try XCTUnwrap(found)
            target.hostKeyBase64 = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C7okWi4dh2l9GKJl"
            try await target.save(on: f.test.app.db)
            let test = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(test.body["ok"] as? Bool, false, test.text)
            XCTAssertEqual(test.body["code"] as? String, "deploy_host_key_mismatch", test.text)
            let compare = try await f.post("/v1/deploy-targets/\(id)/compare", ["files": Self.manifest])
            XCTAssertEqual(compare.body["code"] as? String, "deploy_host_key_mismatch", compare.text)
            XCTAssertNil(compare.body["files"])
            assertNoSecret(f, [test.text, compare.text], Self.sftpPassword)
        }
    }

    func testSFTPWrongPasswordAndPathEscape() async throws {
        try await fixture { f in
            let id = try await f.create(["name": "SFTP", "stage": "test", "protocol": "sftp", "host": "127.0.0.1", "port": Self.sftpPort,
                                         "basePath": "site", "username": "deploy", "password": "falsch-Geheim-0000"])
            let first = try await f.post("/v1/deploy-targets/\(id)/test")
            let fp = try XCTUnwrap((first.body["offeredHostKey"] as? Obj)?["fingerprint"] as? String)
            _ = try await f.post("/v1/deploy-targets/\(id)/host-key", ["fingerprint": fp])
            let test = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(test.body["code"] as? String, "deploy_auth_failed", test.text)
            assertNoSecret(f, [test.text], "falsch-Geheim-0000")

            // The base path cannot leave the cage, neither on create nor on change.
            let escape = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["basePath": "site/../.."], token: f.session)
            XCTAssertEqual(escape.status, .badRequest)
            XCTAssertEqual(escape.body?["reason"] as? String, "deploy_base_path_invalid")
            let missing = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["basePath": "does-not-exist", "password": Self.sftpPassword], token: f.session)
            XCTAssertEqual(missing.status, .ok, "\(missing.body ?? [:])")
            let none = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(none.body["code"] as? String, "deploy_base_path_missing", none.text)
        }
    }

    // MARK: FTPS / FTP (pure-ftpd with TLS)

    func testFTPSWithPinnedCertificateComparesAndWrongCertificateIsRefused() async throws {
        let cert = try String(contentsOfFile: Self.dir + "/ftp-cert.pem", encoding: .utf8)
        let other = try String(contentsOfFile: Self.dir + "/other-cert.pem", encoding: .utf8)
        try await fixture { f in
            let id = try await f.create(["name": "FTPS", "stage": "prod", "protocol": "ftps", "host": "127.0.0.1", "port": Self.ftpPort,
                                         "basePath": "site", "username": "deploy", "password": Self.ftpPassword, "tlsCertificate": cert])
            let ok = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(ok.body["ok"] as? Bool, true, ok.text)
            let compare = try await f.post("/v1/deploy-targets/\(id)/compare", ["files": Self.manifest])
            check(compare.body)

            let wrong = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["tlsCertificate": other], token: f.session)
            XCTAssertEqual(wrong.status, .ok)
            let refused = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(refused.body["code"] as? String, "deploy_tls_untrusted", refused.text)
            // Without a pinned certificate the self-signed one is not trusted either (system trust only).
            let unpinned = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["tlsCertificate": NSNull()], token: f.session)
            XCTAssertEqual(unpinned.status, .ok)
            let system = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(system.body["code"] as? String, "deploy_tls_untrusted", system.text)
            assertNoSecret(f, [ok.text, compare.text, refused.text, system.text], Self.ftpPassword)
        }
    }

    func testPlainFTPWorksButWrongPasswordFails() async throws {
        try await fixture { f in
            let id = try await f.create(["name": "FTP", "stage": "test", "protocol": "ftp", "host": "127.0.0.1", "port": Self.ftpPort,
                                         "basePath": "site", "username": "deploy", "password": Self.ftpPassword])
            let compare = try await f.post("/v1/deploy-targets/\(id)/compare", ["files": Self.manifest])
            check(compare.body)
            let bad = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["password": "ftp-falsch-9999"], token: f.session)
            XCTAssertEqual(bad.status, .ok)
            let test = try await f.post("/v1/deploy-targets/\(id)/test")
            XCTAssertEqual(test.body["code"] as? String, "deploy_auth_failed", test.text)
            assertNoSecret(f, [compare.text, test.text], Self.ftpPassword)
            assertNoSecret(f, [test.text], "ftp-falsch-9999")
        }
    }
}
