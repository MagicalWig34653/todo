import Fluent
import Foundation
import XCTVapor
@testable import TodoKit

/// Deploy targets, phase 2a "pull" (card 354ADE12, ADR 0041, contracts/deploy.yaml): files that differ on the server are delivered
/// read-only with the line endings of the repo; secrets and excluded files are never delivered, only named as findings. The real
/// SFTP/FTPS servers are exercised in `DeployServerTests` and `scripts/deploy-e2e.sh`.
extension DeployTargetTests {
    static func entry(_ path: String, _ text: String, eol: String) -> Obj {
        var e = entry(path, text); e["eol"] = eol; return e
    }

    private static var berlinDay: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Berlin"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func pullTarget(_ f: Fixture, _ body: Obj = [:]) async throws -> String {
        var b: Obj = ["protocol": "ftps", "port": 21]
        for (k, v) in body { b[k] = v }
        let made = try await f.created(b)
        return try XCTUnwrap(made["id"] as? String)
    }

    private func pull(_ f: Fixture, _ id: String, _ body: Obj, file: StaticString = #filePath, line: UInt = #line) async throws -> (status: HTTPStatus, body: Obj, text: String) {
        let r = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/pull", body, token: f.session)
        let out = r.body ?? [:]
        return (r.status, out, String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
    }

    private func delivered(_ body: Obj) -> [String: Obj] {
        Dictionary(uniqueKeysWithValues: (body["files"] as? [Obj] ?? []).map { ($0["path"] as? String ?? "?", $0) })
    }

    private func content(_ file: Obj?) -> Data? {
        guard let file, let text = file["content"] as? String else { return nil }
        return file["encoding"] as? String == "base64" ? Data(base64Encoded: text) : Data(text.utf8)
    }

    private func findings(_ body: Obj) -> [String: String] {
        Dictionary((body["findings"] as? [Obj] ?? []).map { ($0["serverPath"] as? String ?? "?", $0["reason"] as? String ?? "?") }, uniquingKeysWith: { a, _ in a })
    }

    func testPullDeliversDriftWithRepoLineEndingsBranchAndCommitMessage() async throws {
        try await fixture { f in
            let id = try await pullTarget(f, ["rules": ["mappings": [["local": "public", "remote": ""]]]])
            let image = Data([0x89, 0x50, 0x00, 0x0d, 0x0a, 0x1a, 0x0a, 0xff])
            let bom = Data([0xef, 0xbb, 0xbf]) + Data("<p>mit BOM</p>\n".utf8)
            f.transport.files = [
                "index.php": Data("<?php\r\necho 1;\r\n".utf8),   // same (line endings only)
                "about.php": Data("neu vom Designer\r\nzwei\r\n".utf8),   // changed, repo uses LF
                "win.txt": Data("a\nB geändert\n".utf8),          // changed, repo uses CRLF
                "same-crlf.txt": Data("x\ny\n".utf8),             // only line endings differ from a CRLF repo file
                "raw.txt": Data("k\r\neep\n".utf8),               // keep: bytes untouched
                "designer.html": Data("<p>neu</p>\r\n".utf8),     // only on the server
                "bom.html": bom,
                "logo.png": image,                                // binary: bytes untouched
            ]
            let manifest: [Obj] = [
                Self.entry("public/index.php", "<?php\necho 1;\n"),
                Self.entry("public/about.php", "alt\n"),
                Self.entry("public/win.txt", "a\r\nb\r\n", eol: "crlf"),
                Self.entry("public/same-crlf.txt", "x\r\ny\r\n", eol: "crlf"),
                Self.entry("public/raw.txt", "alt\n", eol: "keep"),
                Self.entry("public/logo.png", "alt"),
                Self.entry("public/contact.php", "noch nicht oben\n"),
            ]
            let r = try await pull(f, id, ["files": manifest])
            XCTAssertEqual(r.status, .ok, r.text)
            XCTAssertEqual(r.body["ok"] as? Bool, true, r.text)
            let files = delivered(r.body)
            XCTAssertEqual(Set(files.keys), ["public/about.php", "public/win.txt", "public/raw.txt", "public/designer.html", "public/bom.html", "public/logo.png"])

            XCTAssertEqual(content(files["public/about.php"]), Data("neu vom Designer\nzwei\n".utf8))
            XCTAssertEqual(files["public/about.php"]?["eol"] as? String, "lf")
            XCTAssertEqual(files["public/about.php"]?["status"] as? String, "changed")
            XCTAssertEqual(files["public/about.php"]?["serverPath"] as? String, "about.php")
            XCTAssertEqual(files["public/about.php"]?["encoding"] as? String, "utf-8")
            XCTAssertEqual(content(files["public/win.txt"]), Data("a\r\nB geändert\r\n".utf8))
            XCTAssertEqual(files["public/win.txt"]?["eol"] as? String, "crlf")
            XCTAssertEqual(content(files["public/raw.txt"]), Data("k\r\neep\n".utf8))
            XCTAssertEqual(content(files["public/designer.html"]), Data("<p>neu</p>\n".utf8))
            XCTAssertEqual(files["public/designer.html"]?["status"] as? String, "serverOnly")
            XCTAssertEqual(content(files["public/bom.html"]), bom)
            XCTAssertEqual(content(files["public/logo.png"]), image)
            XCTAssertEqual(files["public/logo.png"]?["eol"] as? String, "binary")
            XCTAssertEqual(files["public/logo.png"]?["encoding"] as? String, "base64")
            for (path, file) in files {
                let data = try XCTUnwrap(content(file), path)
                XCTAssertEqual(file["sha256"] as? String, Self.sha(data), path)
                XCTAssertEqual(file["size"] as? Int, data.count, path)
            }
            let summary = try XCTUnwrap(r.body["summary"] as? Obj)
            XCTAssertEqual(summary["changed"] as? Int, 4, r.text)
            XCTAssertEqual(summary["serverOnly"] as? Int, 2, r.text)
            XCTAssertEqual(summary["onlyInRepo"] as? Int, 1, r.text)
            XCTAssertEqual(summary["withheld"] as? Int, 0, r.text)
            XCTAssertEqual(r.body["remaining"] as? [String], [])

            XCTAssertEqual(r.body["branch"] as? String, "server/kubus-test-\(Self.berlinDay)")
            let message = try XCTUnwrap(r.body["commitMessage"] as? String)
            let first = String(message.split(separator: "\n").first ?? "")
            XCTAssertTrue(first.hasPrefix("Server-Änderungen von „Kubus Test“ geholt ("), message)
            XCTAssertTrue(message.contains("- public/about.php"), message)
            XCTAssertTrue(message.contains("- public/designer.html"), message)
            XCTAssertFalse(message.contains("index.php"), message)
            XCTAssertFalse(message.contains("Designer\nzwei"), message)
        }
    }

    func testPullNeverDeliversSecretsOrExcludedFilesEvenWithoutDefaultExcludes() async throws {
        try await fixture { f in
            let id = try await pullTarget(f, ["rules": ["defaultExcludes": false, "excludes": ["cache/**"]]])
            let secrets = ["env-GEHEIM-1", "env-GEHEIM-2", "pem-GEHEIM-3", "ssh-GEHEIM-4", "git-GEHEIM-5", "ci-GEHEIM-6",
                           "wp-GEHEIM-7", "cfg-GEHEIM-8", "key-GEHEIM-9", "url-GEHEIM-10", "bak-GEHEIM-11", "cache-GEHEIM-12"]
            f.transport.files = [
                ".env": Data("DB_PASSWORD=env-GEHEIM-1\n".utf8),
                "app/.ENV.production": Data("X=env-GEHEIM-2\n".utf8),
                "certs/server.PEM": Data("pem-GEHEIM-3\n".utf8),
                ".ssh/deploy": Data("ssh-GEHEIM-4\n".utf8),
                ".git/config": Data("git-GEHEIM-5\n".utf8),
                ".github/workflows/evil.yml": Data("run: ci-GEHEIM-6\n".utf8),
                "wp-config.php": Data("<?php\ndefine('DB_PASSWORD', 'wp-GEHEIM-7');\n".utf8),
                "config/config.php": Data("<?php\nreturn ['smtp' => ['password' => 'cfg-GEHEIM-8']];\n".utf8),
                "helper.php": Data("<?php $k = \"-----BEGIN RSA PRIVATE KEY-----\\nkey-GEHEIM-9\";\n".utf8),
                "deploy.sh": Data("curl ftp://admin:url-GEHEIM-10@example.com/\n".utf8),
                "config.php.bak": Data("<?php $db_pass = \"bak-GEHEIM-11\";\n".utf8),
                "cache/page.html": Data("cache-GEHEIM-12\n".utf8),
                // Harmless: a config file without keys, and an ordinary page.
                "app_config.php": Data("<?php return ['password' => getenv('DB_PASSWORD'), 'host' => 'localhost'];\n".utf8),
                "ok.php": Data("<p>Passwort vergessen?</p>\n".utf8),
            ]
            // The repo knows older versions of some of them: a changed secret file stays withheld too.
            let manifest: [Obj] = [Self.entry(".env", "DB_PASSWORD=\n"), Self.entry("config/config.php", "<?php\n"),
                                   Self.entry("ok.php", "alt\n"), Self.entry("certs/server.PEM", "x\n")]
            let r = try await pull(f, id, ["files": manifest])
            XCTAssertEqual(r.body["ok"] as? Bool, true, r.text)
            XCTAssertEqual(Set(delivered(r.body).keys), ["app_config.php", "ok.php"], r.text)
            XCTAssertEqual(findings(r.body), [
                ".env": "secret_name", "app/.ENV.production": "secret_name", "certs/server.PEM": "secret_name", ".ssh/deploy": "secret_name",
                ".git/config": "blocked_path", ".github/workflows/evil.yml": "blocked_path",
                "wp-config.php": "secret_content", "config/config.php": "secret_content", "helper.php": "secret_content",
                "deploy.sh": "secret_content", "config.php.bak": "secret_content", "cache/page.html": "excluded",
            ], r.text)
            XCTAssertEqual((r.body["summary"] as? Obj)?["withheld"] as? Int, 12)
            XCTAssertEqual(r.body["findingsTotal"] as? Int, 12)
            for secret in secrets {
                XCTAssertFalse(r.text.contains(secret), "secret delivered: \(secret)")
                XCTAssertFalse(f.capture.lines.joined(separator: "\n").contains(secret), "secret logged: \(secret)")
            }
            // Secret-named, blocked and excluded files are not even downloaded.
            let read = Set(f.transport.reads.flatMap { $0 })
            for path in [".env", "app/.ENV.production", "certs/server.PEM", ".ssh/deploy", ".git/config", ".github/workflows/evil.yml", "cache/page.html"] {
                XCTAssertFalse(read.contains(path), "downloaded: \(path)")
            }
            let message = try XCTUnwrap(r.body["commitMessage"] as? String)
            XCTAssertTrue(message.contains("Nicht geholt"), message)

            // Selecting a withheld file explicitly changes nothing.
            let forced = try await pull(f, id, ["files": manifest, "paths": [".env", "config/config.php", "cache/page.html"]])
            XCTAssertEqual((forced.body["files"] as? [Obj])?.count, 0, forced.text)
            for secret in secrets { XCTAssertFalse(forced.text.contains(secret), secret) }
        }
    }

    func testPullSelectionBudgetLimitsAndInvalidArguments() async throws {
        try await fixture { f in
            let id = try await pullTarget(f)
            f.transport.files = [
                "a.txt": Data(repeating: 0x61, count: 600), "b.txt": Data(repeating: 0x62, count: 600), "c.txt": Data(repeating: 0x63, count: 600),
                "big.bin": Data(count: 8 * 1024 * 1024 + 1), "gone.txt": Data("weg\n".utf8),
            ]
            f.transport.unreadable = ["gone.txt"]
            let first = try await pull(f, id, ["files": [], "maxBytes": 1300])
            XCTAssertEqual(Set(delivered(first.body).keys), ["a.txt", "b.txt"], String(first.text.prefix(300)))
            XCTAssertEqual(first.body["remaining"] as? [String], ["c.txt", "gone.txt"])
            XCTAssertEqual(findings(first.body), ["big.bin": "too_large"])
            XCTAssertFalse(f.transport.reads.flatMap { $0 }.contains("big.bin"))

            let rest = try await pull(f, id, ["files": [], "paths": first.body["remaining"] as? [String] ?? [], "maxBytes": 1300])
            XCTAssertEqual(Set(delivered(rest.body).keys), ["c.txt"], String(rest.text.prefix(300)))
            XCTAssertEqual(rest.body["remaining"] as? [String], [])
            XCTAssertEqual(findings(rest.body)["gone.txt"], "unreadable")

            // A single file above the budget is still delivered (otherwise it could never be pulled).
            let one = try await pull(f, id, ["files": [], "paths": ["a.txt"], "maxBytes": 1])
            XCTAssertEqual(Set(delivered(one.body).keys), ["a.txt"])

            for bad: Obj in [["files": [], "maxBytes": 0], ["files": [], "maxBytes": 17 * 1024 * 1024], ["files": [], "eol": "cr"]] {
                let r = try await pull(f, id, bad)
                XCTAssertEqual(r.status, .badRequest, "\(bad)")
                XCTAssertEqual(r.body["reason"] as? String, "deploy_pull_invalid", "\(bad)")
            }
            let manifest = try await pull(f, id, ["files": [Self.entry("a.txt", "x", eol: "mac")]])
            XCTAssertEqual(manifest.body["reason"] as? String, "deploy_manifest_invalid", manifest.text)
            let escape = try await pull(f, id, ["files": [Self.entry("../a.txt", "x")]])
            XCTAssertEqual(escape.body["reason"] as? String, "deploy_manifest_invalid", escape.text)
        }
    }

    func testPullRightsHostKeyAndTransportFailures() async throws {
        try await fixture { f in
            let made = try await f.created()
            let id = try XCTUnwrap(made["id"] as? String)
            f.transport.files = ["page.html": Data("INHALT-vom-Server-771\n".utf8)]
            f.transport.hostKey = DeployHostKey(type: "ssh-ed25519", base64: Data(repeating: 5, count: 51).base64EncodedString())
            let unconfirmed = try await pull(f, id, ["files": []])
            XCTAssertEqual(unconfirmed.body["ok"] as? Bool, false, unconfirmed.text)
            XCTAssertEqual(unconfirmed.body["code"] as? String, "deploy_host_key_unconfirmed")
            XCTAssertNil(unconfirmed.body["files"])
            XCTAssertTrue(f.transport.connections.isEmpty, "nothing logs in before the host key is confirmed")
            _ = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/host-key", ["fingerprint": f.transport.hostKey!.fingerprint], token: f.session)

            let ok = try await pull(f, id, ["files": []])
            XCTAssertEqual(ok.body["ok"] as? Bool, true, ok.text)
            XCTAssertTrue(ok.text.contains("INHALT-vom-Server-771"), ok.text)

            let token = try await f.mcpToken()
            let viaToken = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/pull", ["files": []], token: token)
            XCTAssertEqual(viaToken.status, .unauthorized)
            // Another account: 404. A person who may only read the project: 404 too (file contents need edit rights).
            let other = User(displayName: "Fremd", isAdmin: false)
            try await other.save(on: f.app.db)
            let stranger = AuthSupport.randomToken()
            try await UserSession(userID: other.requireID(), tokenHash: AuthSupport.hash(stranger), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.db)
            let foreign = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/pull", ["files": []], token: stranger)
            XCTAssertEqual(foreign.status, .notFound)
            try await ProjectGrant(projectID: try f.o.project.requireID(), principalType: "person", principalID: other.requireID(), role: .read).save(on: f.app.db)
            let seen = try await f.test.json(.GET, "/v1/deploy-targets/\(id)", token: stranger)
            XCTAssertEqual(seen.status, .ok, "reader sees the target")
            let reader = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/pull", ["files": []], token: stranger)
            XCTAssertEqual(reader.status, .forbidden, "\(reader.body ?? [:])")
            XCTAssertFalse(String(describing: reader.body ?? [:]).contains("INHALT-vom-Server-771"))

            f.transport.failure = "deploy_unreachable"
            let down = try await pull(f, id, ["files": []])
            XCTAssertEqual(down.body["ok"] as? Bool, false, down.text)
            XCTAssertEqual(down.body["code"] as? String, "deploy_unreachable")
            XCTAssertNil(down.body["files"])

            let log = f.capture.lines.joined(separator: "\n")
            XCTAssertFalse(log.contains("INHALT-vom-Server-771"), "file content logged")
            XCTAssertFalse(log.contains(Self.password))
            for text in [unconfirmed.text, ok.text, down.text] { XCTAssertFalse(text.contains(Self.password)) }
        }
    }

    func testMCPPullServerChangesDeliversTheSameFilesWithoutSecrets() async throws {
        try await fixture { f in
            let made = try await f.created(["protocol": "ftps", "port": 21])
            let id = try XCTUnwrap(made["id"] as? String)
            f.transport.files = ["about.php": Data("neu\r\n".utf8), ".env": Data("T=env-GEHEIM-mcp\n".utf8),
                                 "big.css": Data(repeating: 0x61, count: 200_000), "zz.css": Data(repeating: 0x62, count: 200_000)]
            let token = try await f.mcpToken()
            let r = try await f.mcp(token, "pull_server_changes", ["targetID": id, "files": [Self.entry("about.php", "alt\n")]])
            XCTAssertFalse(r.isError, r.text)
            let body = try XCTUnwrap(r.json)
            XCTAssertEqual(body["ok"] as? Bool, true)
            XCTAssertEqual(content(delivered(body)["about.php"]), Data("neu\n".utf8))
            XCTAssertEqual(findings(body), [".env": "secret_name"])
            // Agents get a smaller default budget (256 kB): the rest is named in `remaining`.
            XCTAssertEqual(body["remaining"] as? [String], ["zz.css"], String(r.text.prefix(300)))
            for word in ["env-GEHEIM-mcp", Self.password, "test.example.com", "\"deploy\""] {
                XCTAssertFalse(r.text.contains(word), word)
            }
            let more = try await f.mcp(token, "pull_server_changes", ["targetID": id, "files": [], "paths": ["zz.css"], "eol": "keep", "maxBytes": 1_000_000])
            XCTAssertFalse(more.isError, String(more.text.prefix(300)))
            XCTAssertEqual(Set(delivered(more.json ?? [:]).keys), ["zz.css"])

            let unknown = try await f.mcp(token, "pull_server_changes", ["targetID": UUID().uuidString, "files": []])
            XCTAssertTrue(unknown.isError, unknown.text)
            let readOnly = try await f.o.tokens(scope: "tasks:read").access
            let noScope = try await f.o.rpc("tools/call", ["name": "pull_server_changes", "arguments": ["targetID": id, "files": []]], access: readOnly)
            XCTAssertFalse(String(describing: noScope.body ?? [:]).contains("neu"), "\(noScope.body ?? [:])")
        }
    }

    // MARK: Secret guard

    func testSecretGuardNamesAndContent() {
        for path in [".env", ".env.local", "prod.env", "a/.envrc", "x/key.pem", "x/KEY.PEM", "server.key.old", "cert.p12", "id_ed25519", "id_rsa.bak",
                     ".htpasswd", ".netrc", ".npmrc", "credentials.json", ".aws/credentials", ".ssh/known", ".git-credentials"] {
            XCTAssertEqual(DeploySecretGuard.pathReason(path), "secret_name", path)
        }
        for path in [".git/HEAD", "a/.GIT/config", ".github/workflows/ci.yml", ".gitlab-ci.yml", ".gitattributes", ".gitmodules"] {
            XCTAssertEqual(DeploySecretGuard.pathReason(path), "blocked_path", path)
        }
        for path in ["index.php", "config.php", "css/keyboard.css", "monkey.js", "environment.md", ".gitignore", "pemberton.txt"] {
            XCTAssertNil(DeploySecretGuard.pathReason(path), path)
        }
        let secret: [(String, String)] = [
            ("config.php", "$cfg['db']['password'] = 'abc';"),
            ("inc/config.local.php", "<?php define( \"AUTH_KEY\", 'q9$x' );"),
            ("app/Config/mail.php", "return ['smtp_pass' => \"s3cret\"];"),
            ("config.php", "'password' => env('DB_PASSWORD', 'hunter2'),"),
            ("config.php", "$token = getenv('T') ?: 'fallback-token';"),
            ("db.php", "$pdo = new PDO('mysql:host=x;dbname=y', 'user', 'pw123');"),
            ("anything.php", "mysqli_connect(\"h\", \"u\", \"p4ss\");"),
            ("anything.txt", "-----BEGIN OPENSSH PRIVATE KEY-----"),
            ("anything.js", "const id = 'AKIAABCDEFGHIJKLMNOP';"),
            ("anything.js", "token: 'ghp_" + String(repeating: "a1", count: 18) + "'"),
            ("anything.php", "$k = 'sk_live_" + String(repeating: "Ab3", count: 10) + "';"),
            ("anything.yml", "url: postgres://admin:pw@db:5432/x"),
            ("settings.ini", "db_password = hunter2\n"),
            ("config.yml", "smtp:\n  password: hunter2\n"),
            ("config.json", "{\"apiKey\": \"abcdef123456\"}"),
            ("web.config", "<add key=\"x\" password=\"abc\" />"),
            ("config.xml", "<db><password>abc</password></db>"),
        ]
        for (path, text) in secret { XCTAssertTrue(DeploySecretGuard.containsSecret(path: path, data: Data(text.utf8)), "\(path): \(text)") }
        // A config-like file that cannot be read as text is withheld (fail closed).
        XCTAssertTrue(DeploySecretGuard.containsSecret(path: "config.php", data: Data([0x3c, 0x00, 0x3f])))
        let harmless: [(String, String)] = [
            ("config.php", "return ['password' => getenv('DB_PASSWORD'), 'user' => 'root'];"),
            ("config.php", "return ['password' => ''];"),
            ("config.php", "$password = $_POST['password'];"),
            ("config.yml", "smtp:\n  password: ${SMTP_PASSWORD}\n"),
            ("lang/de.php", "return ['password' => 'Passwort'];"),
            ("form.html", "<input type=\"password\" name=\"password\">"),
            ("login.js", "if (token === '') return;"),
            ("page.php", "<a href=\"https://example.com/a:b\">@name</a>"),
        ]
        for (path, text) in harmless { XCTAssertFalse(DeploySecretGuard.containsSecret(path: path, data: Data(text.utf8)), "\(path): \(text)") }
    }

    /// Server files are untrusted: a large file must not make the patterns explode.
    func testSecretGuardStaysFastOnHostileInput() {
        let blobs = [String(repeating: "a", count: 1_000_000), String(repeating: "password", count: 125_000),
                     String(repeating: "<password", count: 100_000), String(repeating: "://a:", count: 200_000),
                     String(repeating: "token = ", count: 100_000)]
        let started = Date()
        for blob in blobs {
            for path in ["config.yml", "config.xml", "x.js"] { _ = DeploySecretGuard.containsSecret(path: path, data: Data(blob.utf8)) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    // MARK: Review findings (Gegenlesen)

    /// A symlink named like `x -> y` or with a leading blank must still be recognised: the LIST line cannot say where the name ends,
    /// so every prefix before an arrow counts as a name (conservative).
    func testSymlinkNamesOfTrickyListLines() throws {
        let list = [
            "lrwxrwxrwx    1 1000       ftpgroup           14 Nov 27 21:51 link.txt -> ../outside.txt",
            "lrwxrwxrwx    1 1000       ftpgroup           30 Nov 27 21:51 x -> y -> /home/other/wp-config.php",
            "lrwxrwxrwx    1 1000       ftpgroup           30 Nov 27 21:51  lead -> /etc/passwd",
            "-rw-r--r--    1 1000       ftpgroup            4 Nov 27 21:51 about.php",
            "drwxr-xr-x    2 1000       ftpgroup         4096 Nov 27 21:51 css",
        ].joined(separator: "\r\n")
        let names = try RcloneDeployTransport.symlinkNames(inList: list)
        XCTAssertTrue(names.isSuperset(of: ["link.txt", "x", "x -> y", "lead", " lead"]), "\(names)")
        XCTAssertFalse(names.contains("about.php")); XCTAssertFalse(names.contains("css"))
        // An `l` line that cannot be read fails the whole check.
        XCTAssertThrowsError(try RcloneDeployTransport.symlinkNames(inList: "lrwxrwxrwx weird"))
    }

    func testFTPListURLs() {
        func url(_ proto: DeployProtocol, _ host: String, _ base: String, _ dir: String) -> String {
            RcloneDeployTransport.ftpListURL(proto: proto, host: host, port: proto.defaultPort, basePath: base, directory: dir)
        }
        XCTAssertEqual(url(.ftp, "h.example", "", ""), "ftp://h.example:21/", "empty base path = login directory, not /")
        XCTAssertEqual(url(.ftp, "h.example", "site", ""), "ftp://h.example:21/site/")
        XCTAssertEqual(url(.ftp, "h.example", "site/", "sub/deep dir"), "ftp://h.example:21/site/sub/deep%20dir/")
        XCTAssertEqual(url(.ftps, "h.example", "/abs/site", "a#b?c%d"), "ftp://h.example:21//abs/site/a%23b%3Fc%25d/")
        XCTAssertEqual(url(.ftps, "h.example", "/", ""), "ftp://h.example:21//")
        XCTAssertEqual(url(.ftpsImplicit, "::1", "x", "y"), "ftps://[::1]:990/x/y/")
    }

    func testSecretGuardReviewGaps() {
        for path in [".env/prod", "deploy/.envs/x", "credentials/x.txt", "app/id_rsa/key", "auth.json", "a/prod.tfvars", "terraform.tfstate", ".s3cfg", "x/.git/hooks/pre-commit"] {
            XCTAssertNotNil(DeploySecretGuard.pathReason(path), path)
        }
        let secret: [(String, String)] = [
            ("app/config.php", "return ['key' => 'base64:q8Zl0aB3'];"),
            ("config/app.php", "'encryption_key' => 'abcdef123456',"),
            ("config.php", "<?php\r$cfg['password'] = 'x';\r"),
            ("config.yml", "db:\r  password: hunter2\r"),
            ("local.settings.json", "{\"jwt_key\": \"abc123456\"}"),
        ]
        for (path, text) in secret { XCTAssertTrue(DeploySecretGuard.containsSecret(path: path, data: Data(text.utf8)), "\(path): \(text)") }
        // A configuration file above the scan window is withheld rather than half checked.
        XCTAssertTrue(DeploySecretGuard.containsSecret(path: "config.php", data: Data(repeating: 0x20, count: 2 * 1024 * 1024 + 10)))
        XCTAssertFalse(DeploySecretGuard.containsSecret(path: "lang/de.php", data: Data("return ['key' => 'value'];".utf8)))
    }

    func testPullNamesUnverifiedFilesCapsRemainingAndChecksTheRealSize() async throws {
        let rules = try DeployRules(includes: [], excludes: [], mappings: [], defaultExcludes: true)
        let sha = String(repeating: "a", count: 64)
        let repo = ["huge.bin": DeployManifestEntry(path: "huge.bin", size: 100 * 1024 * 1024, sha256: sha)]
        var listed = [DeployRemoteFile(path: "huge.bin", size: 100 * 1024 * 1024), DeployRemoteFile(path: "liar.txt", size: 10)]
        listed += (0..<6000).map { DeployRemoteFile(path: String(format: "many/f%05d.txt", $0), size: 3) }
        let outcome = try await DeployService.pull(repo: repo, server: listed, rules: rules, selection: nil, maxBytes: 1, defaultEOL: "lf") { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, $0 == "liar.txt" ? Data(count: 9 * 1024 * 1024) : Data("abc".utf8)) })
        }
        XCTAssertEqual(outcome.findings.first { $0.path == "huge.bin" }?.reason, "unverified")
        XCTAssertEqual(outcome.findings.first { $0.path == "liar.txt" }?.reason, "too_large", "the size that was read counts, not the listed one")
        XCTAssertEqual(outcome.remaining.count, 5000)
        XCTAssertEqual(outcome.remainingTotal, 6000, "liar.txt took the one file that always goes through; the 6000 small files wait")
    }
}
