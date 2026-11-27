import Crypto
import Fluent
import Foundation
import SQLKit
import XCTVapor
@testable import TodoKit

/// Deploy targets, phase 1a (card 354ADE12, ADR 0039, contracts/deploy.yaml): targets with encrypted credentials, rules,
/// connection test and read-only compare over REST and MCP. The transport is a recording double here; the real SFTP/FTPS
/// servers are exercised in `DeployServerTests`.
final class DeployTargetTests: XCTestCase {
    typealias Obj = [String: Any]
    static let password = "PW-geheim-7f3a9c"
    static let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nKEY-geheim-b2e1\n-----END OPENSSH PRIVATE KEY-----"

    struct Fixture {
        let o: OAuthFixture
        let transport: FakeDeployTransport
        let capture: LogCapture
        var test: TestApp { o.test }
        var app: Application { o.test.app }
        var session: String { o.session }
        var projectID: String { o.project.id!.uuidString }

        func create(_ body: Obj = [:], session: String? = nil) async throws -> (status: HTTPStatus, body: Obj?) {
            var b: Obj = ["name": "Kubus Test", "stage": "test", "protocol": "sftp", "host": "test.example.com", "port": 22,
                          "basePath": "site", "username": "deploy", "password": DeployTargetTests.password]
            for (k, v) in body { b[k] = v }
            let r = try await test.json(.POST, "/v1/projects/\(projectID)/deploy-targets", b, token: session ?? self.session)
            return (r.status, r.body)
        }

        func created(_ body: Obj = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> Obj {
            let r = try await create(body)
            XCTAssertEqual(r.status, .created, "\(r.body ?? [:])", file: file, line: line)
            return try XCTUnwrap(r.body, file: file, line: line)
        }

        func mcpToken() async throws -> String { try await o.tokens(scope: CommandCenterTests.scopes).access }

        func mcp(_ token: String, _ name: String, _ args: Obj) async throws -> (isError: Bool, text: String, json: Obj?) {
            let r = try await o.rpc("tools/call", ["name": name, "arguments": args], access: token)
            let result = try XCTUnwrap(r.body?["result"] as? Obj, "\(r.body ?? [:])")
            let text = try XCTUnwrap((result["content"] as? [Obj])?.first?["text"] as? String)
            return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? Obj)
        }

        /// Every column of every stored target, as text.
        func storedText() async throws -> String {
            let sql = try XCTUnwrap(app.db as? any SQLDatabase)
            let rows = try await sql.raw("SELECT * FROM deploy_targets").all()
            return rows.map { row in
                row.allColumns.map { c in (try? row.decode(column: c, as: String?.self)) .flatMap { $0 } ?? "" }.joined(separator: "|")
            }.joined(separator: "\n")
        }
    }

    func fixture(key: Bool = true, allowPrivate: Bool = true, _ run: (Fixture) async throws -> Void) async throws {
        let o = try await OAuthFixture.make()
        let transport = FakeDeployTransport(), capture = LogCapture()
        WebhookFixture.installRuntime(o.test.app, key: key)
        o.test.app.deployTransport = transport
        o.test.app.deployAllowPrivateHosts = allowPrivate
        o.test.app.webhookResolver = FixedWebhookResolver()
        o.test.app.logger = Logger(label: "deploy-test") { _ in CaptureLogHandler(capture: capture) }
        let f = Fixture(o: o, transport: transport, capture: capture)
        do { try await run(f) } catch { await o.test.shutdown(); throw error }
        await o.test.shutdown()
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func entry(_ path: String, _ text: String) -> Obj { ["path": path, "size": text.utf8.count, "sha256": sha(Data(text.utf8))] }

    // MARK: Targets and credentials

    func testPersonCreatesTargetCredentialsAreEncryptedAndNeverReturned() async throws {
        try await fixture { f in
            let t = try await f.created(["rules": ["excludes": ["*.log"], "mappings": [["local": "public", "remote": ""]]]])
            XCTAssertEqual(t["name"] as? String, "Kubus Test")
            XCTAssertEqual(t["protocol"] as? String, "sftp")
            XCTAssertEqual(t["host"] as? String, "test.example.com")
            XCTAssertEqual(t["authMethod"] as? String, "password")
            XCTAssertEqual((t["hostKey"] as? Obj)?["confirmed"] as? Bool, false)
            let rules = try XCTUnwrap(t["rules"] as? Obj)
            XCTAssertEqual(rules["excludes"] as? [String], ["*.log"])
            XCTAssertEqual(rules["defaultExcludes"] as? Bool, true)
            XCTAssertTrue((t["effectiveExcludes"] as? [String] ?? []).contains(".git/**"))
            let id = try XCTUnwrap(t["id"] as? String)

            let list = try await f.test.json(.GET, "/v1/projects/\(f.projectID)/deploy-targets", token: f.session)
            XCTAssertEqual(list.status, .ok)
            XCTAssertEqual((list.body?["items"] as? [Obj])?.count, 1)
            let one = try await f.test.json(.GET, "/v1/deploy-targets/\(id)", token: f.session)
            XCTAssertEqual(one.status, .ok)

            let storedAll = try await f.storedText()
            for text in [String(describing: t), String(describing: list.body ?? [:]), String(describing: one.body ?? [:]), storedAll] {
                XCTAssertFalse(text.contains(Self.password), "password leaked: \(text)")
            }
            let stored = try await f.storedText()
            XCTAssertTrue(stored.contains("v1."), "ciphertext stored")

            let key = try await f.created(["name": "Key", "password": NSNull(), "privateKey": Self.privateKey])
            XCTAssertEqual(key["authMethod"] as? String, "key")
            let storedKey = try await f.storedText()
            XCTAssertFalse(storedKey.contains("KEY-geheim-b2e1"))
            XCTAssertFalse(f.capture.lines.joined(separator: "\n").contains(Self.password))
        }
    }

    func testOnlyPersonsManageTargetsAndValidation() async throws {
        try await fixture(allowPrivate: false) { f in
            // An MCP connection (OAuth access token) is no person session.
            let token = try await f.mcpToken()
            let viaToken = try await f.create(session: token)
            XCTAssertEqual(viaToken.status, .unauthorized)
            // MCP offers no tool to create or change a target.
            let tools = try await f.o.rpc("tools/list", access: token)
            let names = ((tools.body?["result"] as? Obj)?["tools"] as? [Obj] ?? []).compactMap { $0["name"] as? String }
            XCTAssertTrue(names.contains("list_deploy_targets"))
            XCTAssertTrue(names.contains("compare_deploy_target"))
            XCTAssertTrue(names.contains("test_deploy_target"))
            XCTAssertFalse(names.contains { $0.contains("deploy") && ($0.hasPrefix("create") || $0.hasPrefix("update") || $0.hasPrefix("delete")) })

            func rejected(_ body: Obj, _ reason: String, line: UInt = #line) async throws {
                let r = try await f.create(body)
                XCTAssertEqual(r.status, .badRequest, "\(body)", line: line)
                XCTAssertEqual(r.body?["reason"] as? String, reason, line: line)
            }
            try await rejected(["basePath": "site/../../etc"], "deploy_base_path_invalid")
            try await rejected(["basePath": "site/./x"], "deploy_base_path_invalid")
            try await rejected(["rules": ["mappings": [["local": "public", "remote": "../www"]]]], "deploy_rules_invalid")
            try await rejected(["rules": ["mappings": [["local": "/abs", "remote": ""]]]], "deploy_rules_invalid")
            try await rejected(["protocol": "http"], "deploy_protocol_invalid")
            try await rejected(["port": 0], "deploy_port_invalid")
            try await rejected(["host": "bad host"], "deploy_host_invalid")
            try await rejected(["password": NSNull()], "deploy_credentials_required")
            try await rejected(["protocol": "ftps", "tlsCertificate": "not a pem"], "deploy_certificate_invalid")
            // Private and loopback targets are refused unless the server allows them (DEPLOY_ALLOW_PRIVATE_HOSTS).
            try await rejected(["host": "127.0.0.1"], "deploy_target_blocked")
            try await rejected(["host": "10.1.2.3"], "deploy_target_blocked")
            // Unknown project: 404 as everywhere.
            let unknown = try await f.test.json(.POST, "/v1/projects/\(UUID().uuidString)/deploy-targets",
                                                ["name": "x", "stage": "test", "protocol": "sftp", "host": "a.example.com", "basePath": "", "username": "u", "password": "p"],
                                                token: f.session)
            XCTAssertEqual(unknown.status, .notFound)
        }
    }

    func testNoEncryptionKeyRefusesToStoreCredentials() async throws {
        try await fixture(key: false) { f in
            let r = try await f.create()
            XCTAssertEqual(r.status, .conflict)
            XCTAssertEqual(r.body?["reason"] as? String, "encryption_key_missing")
        }
    }

    func testChangingHostNeedsNewCredentialsAndResetsHostKey() async throws {
        try await fixture { f in
            let t = try await f.created()
            let id = try XCTUnwrap(t["id"] as? String)
            f.transport.hostKey = DeployHostKey(type: "ssh-ed25519", base64: Data(repeating: 1, count: 51).base64EncodedString())
            let fp = f.transport.hostKey!.fingerprint
            let confirm = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/host-key", ["fingerprint": fp], token: f.session)
            XCTAssertEqual(confirm.status, .ok, "\(confirm.body ?? [:])")
            XCTAssertEqual((confirm.body?["hostKey"] as? Obj)?["confirmed"] as? Bool, true)
            XCTAssertEqual((confirm.body?["hostKey"] as? Obj)?["fingerprint"] as? String, fp)

            let moved = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["host": "other.example.com"], token: f.session)
            XCTAssertEqual(moved.status, .badRequest)
            XCTAssertEqual(moved.body?["reason"] as? String, "deploy_credentials_required")
            let port = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["port": 2222], token: f.session)
            XCTAssertEqual(port.body?["reason"] as? String, "deploy_credentials_required")

            let renamed = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["name": "Kubus Test neu", "rules": ["excludes": ["cache/**"]]], token: f.session)
            XCTAssertEqual(renamed.status, .ok, "\(renamed.body ?? [:])")
            XCTAssertEqual((renamed.body?["hostKey"] as? Obj)?["confirmed"] as? Bool, true)

            let ok = try await f.test.json(.PATCH, "/v1/deploy-targets/\(id)", ["host": "other.example.com", "password": "neu-geheim-123"], token: f.session)
            XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
            XCTAssertEqual((ok.body?["hostKey"] as? Obj)?["confirmed"] as? Bool, false, "a new host needs a new confirmation")
            let storedNew = try await f.storedText()
            XCTAssertFalse(storedNew.contains("neu-geheim-123"))

            // The host key offered now differs from the fingerprint the person saw: refused.
            let stale = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/host-key", ["fingerprint": "SHA256:something-else"], token: f.session)
            XCTAssertEqual(stale.status, .conflict)
            XCTAssertEqual(stale.body?["reason"] as? String, "deploy_host_key_changed")

            let del = try await f.test.json(.DELETE, "/v1/deploy-targets/\(id)", token: f.session)
            XCTAssertEqual(del.status, .noContent)
            let gone = try await f.test.json(.GET, "/v1/deploy-targets/\(id)", token: f.session)
            XCTAssertEqual(gone.status, .notFound)
        }
    }

    // MARK: Connection test and compare

    func testConnectionTestNeedsConfirmedHostKeyAndPassesDecryptedCredentialsToTheTransport() async throws {
        try await fixture { f in
            let made = try await f.created()
            let id = try XCTUnwrap(made["id"] as? String)
            f.transport.hostKey = DeployHostKey(type: "ssh-ed25519", base64: Data(repeating: 2, count: 51).base64EncodedString())
            f.transport.files = ["index.php": Data("hi\n".utf8)]
            let first = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/test", token: f.session)
            XCTAssertEqual(first.status, .ok)
            XCTAssertEqual(first.body?["ok"] as? Bool, false)
            XCTAssertEqual(first.body?["code"] as? String, "deploy_host_key_unconfirmed")
            XCTAssertEqual((first.body?["offeredHostKey"] as? Obj)?["fingerprint"] as? String, f.transport.hostKey!.fingerprint)
            XCTAssertEqual(f.transport.connections.count, 0, "no login before the person confirmed the host key")

            _ = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/host-key", ["fingerprint": f.transport.hostKey!.fingerprint], token: f.session)
            let second = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/test", token: f.session)
            XCTAssertEqual(second.body?["ok"] as? Bool, true, "\(second.body ?? [:])")
            XCTAssertEqual(second.body?["files"] as? Int, 1)
            let used = try XCTUnwrap(f.transport.connections.last)
            XCTAssertEqual(used.password, Self.password)
            XCTAssertEqual(used.host, "test.example.com")
            XCTAssertEqual(used.basePath, "site")
            XCTAssertEqual(used.hostKey?.base64, f.transport.hostKey!.base64)

            f.transport.failure = "deploy_auth_failed"
            let failed = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/test", token: f.session)
            XCTAssertEqual(failed.body?["ok"] as? Bool, false)
            XCTAssertEqual(failed.body?["code"] as? String, "deploy_auth_failed")
        }
    }

    func testCompareStatusesRulesMappingAndLineEndings() async throws {
        try await fixture { f in
            let made = try await f.created(["protocol": "ftps", "port": 21,
                "rules": ["excludes": ["*.log"], "mappings": [["local": "public", "remote": ""]]]])
            let id = try XCTUnwrap(made["id"] as? String)
            f.transport.files = [
                "index.php": Data("<?php echo 1;\n".utf8),           // same
                "css/app.css": Data("a{}\r\nb{}\r\n".utf8),          // same after CRLF -> LF
                "about.php": Data("old\n".utf8),                     // changed (same size? no: different content, same length)
                "big.js": Data("x\n".utf8),                          // changed (size differs)
                "designer.html": Data("<p>neu</p>\n".utf8),          // server only
                "error.log": Data("noise\n".utf8),                   // excluded by rule
                ".git/HEAD": Data("ref\n".utf8),                     // excluded by default
            ]
            let manifest: [Obj] = [
                Self.entry("public/index.php", "<?php echo 1;\n"),
                Self.entry("public/css/app.css", "a{}\nb{}\n"),
                Self.entry("public/about.php", "new\n"),
                Self.entry("public/big.js", "xxxxxxxx\n"),
                Self.entry("public/contact.php", "kontakt\n"),        // new
                Self.entry("README.md", "not mapped\n"),             // outside the mapping: not part of the target
                Self.entry("public/tests/a.php", "t\n"),             // excluded by default (tests/)
            ]
            let r = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/compare", ["files": manifest], token: f.session)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            XCTAssertEqual(r.body?["ok"] as? Bool, true, "\(r.body ?? [:])")
            let files = try XCTUnwrap(r.body?["files"] as? [Obj])
            var status: [String: String] = [:]
            for file in files { status[file["path"] as? String ?? "?"] = file["status"] as? String }
            XCTAssertEqual(status, [
                "public/index.php": "same", "public/css/app.css": "same", "public/about.php": "changed", "public/big.js": "changed",
                "public/contact.php": "new", "designer.html": "serverOnly",
            ])
            let server = files.first { $0["path"] as? String == "public/index.php" }?["serverPath"] as? String
            XCTAssertEqual(server, "index.php")
            let only = files.first { $0["status"] as? String == "serverOnly" }
            XCTAssertEqual(only?["serverPath"] as? String, "designer.html")
            let summary = try XCTUnwrap(r.body?["summary"] as? Obj)
            XCTAssertEqual(summary["same"] as? Int, 2)
            XCTAssertEqual(summary["changed"] as? Int, 2)
            XCTAssertEqual(summary["new"] as? Int, 1)
            XCTAssertEqual(summary["serverOnly"] as? Int, 1)
            // Only files whose status depends on the content are downloaded, never the excluded or server-only ones.
            XCTAssertEqual(Set(f.transport.reads.flatMap { $0 }), ["index.php", "css/app.css", "about.php"])

            func bad(_ files: [Obj], line: UInt = #line) async throws {
                let r = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/compare", ["files": files], token: f.session)
                XCTAssertEqual(r.status, .badRequest, line: line)
                XCTAssertEqual(r.body?["reason"] as? String, "deploy_manifest_invalid", line: line)
            }
            try await bad([["path": "../etc/passwd", "size": 1, "sha256": String(repeating: "a", count: 64)]])
            try await bad([["path": "/abs", "size": 1, "sha256": String(repeating: "a", count: 64)]])
            try await bad([["path": "ok.txt", "size": 1, "sha256": "nothex"]])
        }
    }

    func testMCPAgentSeesOnlyIdsAndResultsNeverSecretsOrHost() async throws {
        try await fixture { f in
            let made = try await f.created()
            let id = try XCTUnwrap(made["id"] as? String)
            f.transport.hostKey = DeployHostKey(type: "ssh-ed25519", base64: Data(repeating: 3, count: 51).base64EncodedString())
            _ = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/host-key", ["fingerprint": f.transport.hostKey!.fingerprint], token: f.session)
            f.transport.files = ["index.php": Data("hi\n".utf8), "old.php": Data("x\n".utf8)]
            let token = try await f.mcpToken()

            let list = try await f.mcp(token, "list_deploy_targets", ["projectID": f.projectID])
            XCTAssertFalse(list.isError, list.text)
            let targets = try XCTUnwrap(list.json?["targets"] as? [Obj])
            XCTAssertEqual(targets.count, 1)
            XCTAssertEqual(Set(targets[0].keys), ["id", "name", "stage", "protocol", "hostKeyConfirmed"])

            let test = try await f.mcp(token, "test_deploy_target", ["targetID": id])
            XCTAssertFalse(test.isError, test.text)
            XCTAssertEqual(test.json?["ok"] as? Bool, true)

            let compare = try await f.mcp(token, "compare_deploy_target", ["targetID": id, "files": [Self.entry("index.php", "hi\n"), Self.entry("new.php", "n\n")]])
            XCTAssertFalse(compare.isError, compare.text)
            let summary = try XCTUnwrap(compare.json?["summary"] as? Obj)
            XCTAssertEqual(summary["same"] as? Int, 1)
            XCTAssertEqual(summary["new"] as? Int, 1)
            XCTAssertEqual(summary["serverOnly"] as? Int, 1)

            for text in [list.text, test.text, compare.text] {
                XCTAssertFalse(text.contains(Self.password))
                XCTAssertFalse(text.contains("test.example.com"), "agents do not see the host: \(text)")
                XCTAssertFalse(text.contains("deploy\""), "agents do not see the user name: \(text)")
            }

            // A target of a project outside the grant is invisible to the agent.
            let foreign = try await f.test.json(.POST, "/v1/projects/\(f.o.other.id!.uuidString)/deploy-targets",
                ["name": "Fremd", "stage": "prod", "protocol": "sftp", "host": "prod.example.com", "basePath": "", "username": "u", "password": "p"], token: f.session)
            XCTAssertEqual(foreign.status, .created)
            let foreignID = try XCTUnwrap(foreign.body?["id"] as? String)
            let hidden = try await f.mcp(token, "test_deploy_target", ["targetID": foreignID])
            XCTAssertTrue(hidden.isError)
            let hiddenList = try await f.mcp(token, "list_deploy_targets", ["projectID": f.o.other.id!.uuidString])
            XCTAssertTrue(hiddenList.isError)
            XCTAssertFalse(f.capture.lines.joined(separator: "\n").contains(Self.password))
        }
    }

    // MARK: Rules (pure)

    func testGlobRulesAndDefaultExcludes() throws {
        let rules = try DeployRules(includes: [], excludes: ["*.log", "cache/**"], mappings: [], defaultExcludes: true)
        XCTAssertTrue(rules.isExcluded("error.log"))
        XCTAssertTrue(rules.isExcluded("a/b/error.log"))
        XCTAssertTrue(rules.isExcluded("cache/x/y.php"))
        XCTAssertFalse(rules.isExcluded("src/cache/y.php"))
        XCTAssertTrue(rules.isExcluded(".git/config"))
        XCTAssertTrue(rules.isExcluded("node_modules/a/index.js"))
        XCTAssertTrue(rules.isExcluded(".env"))
        XCTAssertTrue(rules.isExcluded("config/server.pem"))
        XCTAssertFalse(rules.isExcluded("index.php"))
        let only = try DeployRules(includes: ["*.php", "css/**"], excludes: [], mappings: [], defaultExcludes: false)
        XCTAssertFalse(only.isExcluded("index.php"))
        XCTAssertFalse(only.isExcluded("css/a/b.css"))
        XCTAssertTrue(only.isExcluded("img/logo.png"))
        let mapped = try DeployRules(includes: [], excludes: [], mappings: [.init(local: "public", remote: ""), .init(local: "public/assets", remote: "static")], defaultExcludes: false)
        XCTAssertEqual(mapped.serverPath(forRepo: "public/index.php"), "index.php")
        XCTAssertEqual(mapped.serverPath(forRepo: "public/assets/a.css"), "static/a.css")
        XCTAssertNil(mapped.serverPath(forRepo: "README.md"))
        XCTAssertEqual(mapped.repoPath(forServer: "static/a.css"), "public/assets/a.css")
        XCTAssertEqual(mapped.repoPath(forServer: "index.php"), "public/index.php")
        XCTAssertThrowsError(try DeployRules(includes: [], excludes: [], mappings: [.init(local: "a/../b", remote: "")], defaultExcludes: true))
    }
}

/// Recording transport double: serves `files` from memory, records every connection and every read.
final class FakeDeployTransport: DeployTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [String: Data] = [:], _hostKey: DeployHostKey?, _failure: String?
    private var _connections: [DeployConnection] = [], _reads: [[String]] = []
    var files: [String: Data] { get { lock.withLock { _files } } set { lock.withLock { _files = newValue } } }
    var hostKey: DeployHostKey? { get { lock.withLock { _hostKey } } set { lock.withLock { _hostKey = newValue } } }
    var failure: String? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    var connections: [DeployConnection] { lock.withLock { _connections } }
    var reads: [[String]] { lock.withLock { _reads } }

    func scanHostKey(host: String, port: Int) async throws -> DeployHostKey {
        guard let hostKey else { throw DeployTransportError(code: "deploy_unreachable") }
        return hostKey
    }
    func list(_ connection: DeployConnection) async throws -> [DeployRemoteFile] {
        lock.withLock { _connections.append(connection) }
        if let failure { throw DeployTransportError(code: failure) }
        return files.map { DeployRemoteFile(path: $0.key, size: $0.value.count) }
    }
    func read(_ connection: DeployConnection, paths: [String]) async throws -> [String: Data] {
        lock.withLock { _reads.append(paths) }
        if let failure { throw DeployTransportError(code: failure) }
        let files = self.files
        return Dictionary(uniqueKeysWithValues: paths.compactMap { p in files[p].map { (p, $0) } })
    }
}
