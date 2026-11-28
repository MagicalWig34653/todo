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
        XCTAssertEqual(status, ["index.php": "same", "css/app.css": "same", "about.php": "changed", "contact.php": "new", "designer.html": "serverOnly",
                                "inc/config.php": "serverOnly"],
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

    // MARK: Pull (phase 2a, ADR 0041)

    private func pulled(_ body: Obj) -> [String: String] {
        Dictionary((body["files"] as? [Obj] ?? []).map { file in
            let text = file["content"] as? String ?? ""
            let data = file["encoding"] as? String == "base64" ? (Data(base64Encoded: text) ?? Data()) : Data(text.utf8)
            return (file["path"] as? String ?? "?", String(decoding: data, as: UTF8.self))
        }, uniquingKeysWith: { a, _ in a })
    }

    private func connection(_ f: Fixture, _ id: String, password: String) async throws -> DeployConnection {
        let found = try await DeployTarget.find(UUID(uuidString: id), on: f.test.app.db)
        let t = try XCTUnwrap(found)
        return DeployConnection(protocolName: t.protocolName, host: t.host, port: t.port, basePath: t.basePath, username: t.username,
                                password: password, privateKey: nil, passphrase: nil, hostKey: t.hostKey, tlsCertificate: t.tlsCertificate)
    }

    func testSFTPPullDeliversDriftAndTargetedReadsNeverFollowLinks() async throws {
        try await fixture { f in
            let id = try await f.create(["name": "SFTP Pull", "stage": "test", "protocol": "sftp", "host": "127.0.0.1", "port": Self.sftpPort,
                                         "basePath": "site", "username": "deploy", "password": Self.sftpPassword])
            let first = try await f.post("/v1/deploy-targets/\(id)/test")
            let fp = try XCTUnwrap((first.body["offeredHostKey"] as? Obj)?["fingerprint"] as? String)
            _ = try await f.post("/v1/deploy-targets/\(id)/host-key", ["fingerprint": fp])

            let pull = try await f.post("/v1/deploy-targets/\(id)/pull", ["files": Self.manifest])
            XCTAssertEqual(pull.body["ok"] as? Bool, true, pull.text)
            XCTAssertEqual(pulled(pull.body), ["about.php": "alt\n", "designer.html": "<p>vom Designer</p>\n"], pull.text)
            XCTAssertFalse(pull.text.contains("outside-secret"), pull.text)
            for word in ["E2E-GEHEIM-ENV", "E2E-GEHEIM-GIT", "E2E-GEHEIM-CFG"] { XCTAssertFalse(pull.text.contains(word), word) }
            let named = Dictionary(uniqueKeysWithValues: (pull.body["findings"] as? [Obj] ?? []).map { ($0["serverPath"] as? String ?? "?", $0["reason"] as? String ?? "?") })
            XCTAssertEqual(named, [".env": "secret_name", ".git/config": "blocked_path", "inc/config.php": "secret_content"], pull.text)
            assertNoSecret(f, [pull.text], Self.sftpPassword)

            // The transport itself, asked for the links by name (a file swapped for a link after the listing): nothing comes back.
            let conn = try await connection(f, id, password: Self.sftpPassword)
            let read = try await RcloneDeployTransport(workDirectory: f.work).read(conn, paths: ["index.php", "link.txt", "etclink/hostname", "etclink/passwd"])
            XCTAssertEqual(read.keys.sorted(), ["index.php"])
        }
    }

    func testFTPSPullDeliversDriftAndNeverFollowsLinks() async throws {
        let cert = try String(contentsOfFile: Self.dir + "/ftp-cert.pem", encoding: .utf8)
        let other = try String(contentsOfFile: Self.dir + "/other-cert.pem", encoding: .utf8)
        try await fixture { f in
            let site = try await f.create(["name": "FTPS Pull", "stage": "prod", "protocol": "ftps", "host": "127.0.0.1", "port": Self.ftpPort,
                                           "basePath": "site", "username": "deploy", "password": Self.ftpPassword, "tlsCertificate": cert])
            let pull = try await f.post("/v1/deploy-targets/\(site)/pull", ["files": Self.manifest])
            XCTAssertEqual(pull.body["ok"] as? Bool, true, pull.text)
            XCTAssertEqual(pulled(pull.body), ["about.php": "alt\n", "designer.html": "<p>vom Designer</p>\n"], pull.text)
            XCTAssertFalse(pull.text.contains("E2E-GEHEIM"), pull.text)
            assertNoSecret(f, [pull.text], Self.ftpPassword)

            // Base path "links": FTP lists symlinks like files, and the server follows them. twin.txt points to a file outside whose
            // length equals the length of the link text, so a size check alone would let its content through.
            let links = try await f.create(["name": "FTPS Links", "stage": "test", "protocol": "ftps", "host": "127.0.0.1", "port": Self.ftpPort,
                                            "basePath": "links", "username": "deploy", "password": Self.ftpPassword, "tlsCertificate": cert])
            let escaped = try await f.post("/v1/deploy-targets/\(links)/pull", ["files": []])
            XCTAssertEqual(escaped.body["ok"] as? Bool, true, escaped.text)
            XCTAssertEqual(pulled(escaped.body), ["plain.txt": "plain\n", "sub/deep file #1.txt": "deep\n"], escaped.text)
            XCTAssertFalse(escaped.text.contains("STRENG-GEHEIM"), escaped.text)
            let conn = try await connection(f, links, password: Self.ftpPassword)
            let transport = RcloneDeployTransport(workDirectory: f.work)
            let read = try await transport.read(conn, paths: ["plain.txt", "twin.txt", "dirlink/in-dir.txt", "sub/deep file #1.txt"])
            XCTAssertEqual(read.keys.sorted(), ["plain.txt", "sub/deep file #1.txt"])

            // pure-ftpd hides dot files in a plain LIST: links with such names must be found as well, or a write would follow them.
            let hidden = try await transport.linkedPaths(conn, paths: [".well-known/in-dir.txt", ".versteckt.txt", "plain.txt", "sub/neu.txt"])
            XCTAssertEqual(hidden, [".well-known/in-dir.txt", ".versteckt.txt"])
            let secrets = try await transport.read(conn, paths: [".well-known/in-dir.txt", ".versteckt.txt"])
            XCTAssertEqual(secrets, [:])

            // A server that takes `-a` for a file name answers with an empty listing: that is refused, never read as "no links".
            let real = ProcessInfo.processInfo.environment["DEPLOY_CURL_PATH"] ?? "/usr/bin/curl"
            let fake = f.work.appendingPathComponent("curl-without-list-a")
            try FileManager.default.createDirectory(at: f.work, withIntermediateDirectories: true)
            try Data("""
                #!/bin/sh
                case " $* " in *" LIST -a "*)
                  while [ $# -gt 0 ]; do if [ "$1" = -o ]; then shift; : > "$1"; fi; shift; done; exit 0 ;;
                esac
                exec "\(real)" "$@"

                """.utf8).write(to: fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            setenv("DEPLOY_CURL_PATH", fake.path, 1)
            defer { unsetenv("DEPLOY_CURL_PATH") }
            do {
                let found = try await transport.linkedPaths(conn, paths: ["twin.txt", "plain.txt"])
                XCTFail("an empty listing was taken as an answer: \(found)")
            } catch let e as DeployTransportError { XCTAssertEqual(e.code, "deploy_failed") }
            unsetenv("DEPLOY_CURL_PATH")
            try FileManager.default.removeItem(at: fake)

            // The link check itself refuses an untrusted certificate (it logs in on its own).
            let wrong = DeployConnection(protocolName: conn.protocolName, host: conn.host, port: conn.port, basePath: conn.basePath,
                                         username: conn.username, password: conn.password, privateKey: nil, passphrase: nil,
                                         hostKey: nil, tlsCertificate: other)
            do {
                _ = try await transport.read(wrong, paths: ["plain.txt"])
                XCTFail("wrong certificate accepted")
            } catch let e as DeployTransportError { XCTAssertEqual(e.code, "deploy_tls_untrusted") }

            // Plain FTP: same cage.
            let plain = try await f.create(["name": "FTP Links", "stage": "test", "protocol": "ftp", "host": "127.0.0.1", "port": Self.ftpPort,
                                            "basePath": "links", "username": "deploy", "password": Self.ftpPassword])
            let ftp = try await f.post("/v1/deploy-targets/\(plain)/pull", ["files": []])
            XCTAssertEqual(pulled(ftp.body), ["plain.txt": "plain\n", "sub/deep file #1.txt": "deep\n"], ftp.text)
            assertNoSecret(f, [escaped.text, ftp.text], Self.ftpPassword)
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
