import _CryptoExtras
import Crypto
import Fluent
import Foundation
import XCTVapor
@testable import TodoKit

/// Deploy targets, phase 2b "open a pull request" (card 354ADE12, ADR 0042, contracts/deploy.yaml): the server puts the files a pull
/// delivers on a new branch `server/*` through a GitHub App and opens a pull request. GitHub is an in-memory double here; the same
/// flow against a fake API server backed by a real git repository is `scripts/deploy-e2e.sh`.
extension DeployTargetTests {
    private static let rsa = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    private static var pem: String { rsa.pemRepresentation }

    private func setup(_ projectID: String, _ extra: [String: String] = [:]) -> GitHubAppSetup {
        var env = ["GITHUB_APP_ID": "424242", "GITHUB_APP_INSTALLATION_ID": "777", "GITHUB_APP_PRIVATE_KEY": Self.pem,
                   "GITHUB_APP_REPOSITORIES": "\(projectID)=acme/site"]
        for (k, v) in extra { env[k] = v }
        return GitHubAppSetup.fromEnvironment { env[$0] }
    }

    /// A configured server with an FTPS target (no host key step) and a repo whose `main` holds `repo`.
    private func publishFixture(_ repo: [String: FakeGitHub.File] = ["about.php": .init("alt\n")], _ run: (Fixture, FakeGitHub, String) async throws -> Void) async throws {
        try await fixture { f in
            let github = FakeGitHub(publicKey: Self.rsa.publicKey, files: repo)
            f.app.githubApp = setup(f.projectID)
            f.app.githubTransport = github
            let made = try await f.created(["name": "Kubus Test", "protocol": "ftps", "port": 21])
            try await run(f, github, try XCTUnwrap(made["id"] as? String))
        }
    }

    private func publish(_ f: Fixture, _ id: String, _ body: Obj, token: String? = nil) async throws -> (status: HTTPStatus, body: Obj, text: String) {
        let r = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/pull-request", body, token: token ?? f.session)
        let out = r.body ?? [:]
        return (r.status, out, String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
    }

    private var day: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Europe/Berlin"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Nothing secret in an answer or a log line: key material, the JWT, the installation token, the target password.
    private func assertNoSecrets(_ f: Fixture, _ github: FakeGitHub, _ answers: [String], file: StaticString = #filePath, line: UInt = #line) {
        let keyLines = Self.pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.map(String.init)
        let all = answers + [f.capture.lines.joined(separator: "\n")]
        for text in all {
            let plain = text.replacingOccurrences(of: "\\/", with: "/")
            XCTAssertFalse(plain.contains("PRIVATE KEY"), "private key header", file: file, line: line)
            XCTAssertFalse(keyLines.contains { plain.contains($0) }, "private key material", file: file, line: line)
            XCTAssertFalse(plain.contains(FakeGitHub.token), "installation token", file: file, line: line)
            XCTAssertFalse(github.jwts.contains { plain.contains($0) }, "app JWT", file: file, line: line)
            XCTAssertFalse(plain.contains("eyJ"), "a JWT", file: file, line: line)
            XCTAssertFalse(plain.contains(Self.password), "target password", file: file, line: line)
        }
    }

    // MARK: Happy path

    func testPublishPutsDriftOnANewServerBranchAndOpensAPullRequest() async throws {
        let image = Data([0x89, 0x50, 0x00, 0x0d, 0x0a, 0x1a, 0x0a, 0xff])
        try await publishFixture(["about.php": .init("alt\n"), "bin/run.sh": .init("old\n", mode: "100755"), "untouched.txt": .init("bleibt\n")]) { f, github, id in
            f.transport.files = [
                "about.php": Data("neu vom Designer\r\n".utf8), "bin/run.sh": Data("new\n".utf8), "neu/seite @lino #1.html": Data("<p>neu</p>\r\n".utf8),
                "logo.png": image, ".env": Data("T=env-GEHEIM-publish\n".utf8), "untouched.txt": Data("bleibt\n".utf8),
            ]
            let manifest: [Obj] = [Self.entry("about.php", "alt\n"), Self.entry("bin/run.sh", "old\n"), Self.entry("untouched.txt", "bleibt\n")]
            let base = github.head("main")
            let r = try await publish(f, id, ["files": manifest, "baseCommit": base])
            XCTAssertEqual(r.status, .ok, r.text)
            XCTAssertEqual(r.body["ok"] as? Bool, true, r.text)
            let branch = "server/kubus-test-\(day)"
            XCTAssertEqual(r.body["branch"] as? String, branch)
            XCTAssertEqual(r.body["repository"] as? String, "acme/site")
            XCTAssertEqual(r.body["baseBranch"] as? String, "main")
            XCTAssertEqual(r.body["baseCommit"] as? String, base)
            XCTAssertEqual((r.body["pullRequest"] as? Obj)?["number"] as? Int, 1)
            XCTAssertEqual((r.body["pullRequest"] as? Obj)?["url"] as? String, "https://github.example/acme/site/pull/1")

            // One commit on top of the base; `main` unchanged; only the new branch was created.
            let commit = try XCTUnwrap(r.body["commit"] as? String)
            XCTAssertEqual(github.head(branch), commit)
            XCTAssertEqual(github.head("main"), base)
            XCTAssertEqual(github.parents(commit), [base])
            XCTAssertEqual(Set(github.refNames), ["main", branch])
            XCTAssertEqual(github.files(branch), [
                "about.php": .init("neu vom Designer\n"), "bin/run.sh": .init("new\n", mode: "100755"), "untouched.txt": .init("bleibt\n"),
                "neu/seite @lino #1.html": .init("<p>neu</p>\n"), "logo.png": .init(data: image),
            ])
            XCTAssertEqual((r.body["files"] as? [Obj] ?? []).compactMap { $0["path"] as? String }, ["about.php", "bin/run.sh", "logo.png", "neu/seite @lino #1.html"])
            XCTAssertNil((r.body["files"] as? [Obj])?.first?["content"], "the answer carries no file contents")
            XCTAssertFalse(r.text.contains("env-GEHEIM-publish"))
            XCTAssertEqual((r.body["findings"] as? [Obj])?.first?["reason"] as? String, "secret_name")

            // The pull request: head is the new branch, base is the default branch, no mention or issue reference from file names.
            let pull = try XCTUnwrap(github.pulls.first)
            XCTAssertEqual(pull.head, branch)
            XCTAssertEqual(pull.base, "main")
            XCTAssertTrue(pull.title.hasPrefix("Server-Änderungen von „Kubus Test“ geholt"), pull.title)
            XCTAssertTrue(pull.body.contains("about.php"), pull.body)
            XCTAssertTrue(pull.body.contains(".env"), "findings are named")
            for text in [pull.body, github.message(commit)] {
                XCTAssertFalse(text.contains("@lino"), text)
                XCTAssertFalse(text.contains("#1"), text)
            }

            // GitHub App: RS256 JWT of the app (signature checked by the double), token scoped to this repository and these rights.
            let claims = try XCTUnwrap(github.claims.first)
            XCTAssertEqual(claims["iss"] as? String, "424242")
            let iat = try XCTUnwrap(claims["iat"] as? Int), exp = try XCTUnwrap(claims["exp"] as? Int)
            XCTAssertLessThanOrEqual(iat, Int(Date().timeIntervalSince1970))
            XCTAssertLessThanOrEqual(exp - iat, 600)
            let tokenRequest = try XCTUnwrap(github.requests.first)
            XCTAssertEqual(tokenRequest.url, "https://api.github.com/app/installations/777/access_tokens")
            XCTAssertEqual(tokenRequest.json["repositories"] as? [String], ["site"])
            XCTAssertEqual(tokenRequest.json["permissions"] as? [String: String], ["contents": "write", "pull_requests": "write"])
            // Never anything but reads and creating requests: no ref update, no merge, no delete.
            XCTAssertTrue(github.requests.allSatisfy { $0.method == "GET" || $0.method == "POST" })
            XCTAssertEqual(github.requests.filter { $0.url.hasSuffix("/git/refs") }.compactMap { $0.json["ref"] as? String }, ["refs/heads/\(branch)"])
            XCTAssertTrue(f.transport.connections.count > 0)
            assertNoSecrets(f, github, [r.text, pull.body])

            // A second run the same day: a new branch, the first one is never moved.
            let again = try await publish(f, id, ["files": manifest, "baseCommit": base])
            XCTAssertEqual(again.body["branch"] as? String, branch + "-2", again.text)
            XCTAssertEqual(github.head(branch), commit)
            XCTAssertEqual(github.head("main"), base)
        }
    }

    // MARK: Never main or a foreign branch

    func testPublishRefusesEveryBranchOutsideServer() async throws {
        try await publishFixture { f, github, id in
            f.transport.files = ["about.php": Data("neu\n".utf8)]
            let base = github.head("main")
            for branch in ["main", "master", "refs/heads/main", "feature/x", "server", "server/", "Server/x", "server/../main", "server/a/../../main",
                           "server/x\n", "server/x\nmain", "server/-x", "server/x y", "server/x.lock", "server/é", "heads/server/x", " server/x",
                           "server/" + String(repeating: "a", count: 90)] {
                let r = try await publish(f, id, ["files": [], "baseCommit": base, "branch": branch])
                XCTAssertEqual(r.status, .badRequest, "\(branch.debugDescription): \(r.text)")
                XCTAssertEqual(r.body["reason"] as? String, "deploy_branch_forbidden", branch.debugDescription)
            }
            XCTAssertTrue(github.requests.isEmpty, "refused before GitHub is asked")
            XCTAssertTrue(f.transport.connections.isEmpty, "refused before the server is asked")
            XCTAssertEqual(github.refNames, ["main"])
            // A name below server/ chosen by the caller is fine.
            let own = try await publish(f, id, ["files": [], "baseCommit": base, "branch": "server/kubus-faq"])
            XCTAssertEqual(own.body["branch"] as? String, "server/kubus-faq", own.text)
        }
    }

    /// The guard sits in the GitHub client itself, so no caller inside the server can write another ref either.
    func testGitHubClientCreatesNoOtherRefAndNoPullRequestFromAnotherHead() async throws {
        let github = FakeGitHub(publicKey: Self.rsa.publicKey, files: ["a": .init("a\n")])
        guard case .enabled(let config) = setup(UUID().uuidString) else { return XCTFail("config") }
        let client = try await GitHubRepoClient.open(config: config, repository: "acme/site", transport: github)
        let before = github.requests.count
        for name in ["main", "refs/heads/main", "feature/x", "server/../main"] {
            do { _ = try await client.createBranch(name, commit: github.head("main")); XCTFail(name) }
            catch let e as GitHubError { XCTAssertEqual(e.code, "deploy_branch_forbidden", name) }
            do { _ = try await client.createPullRequest(head: name, base: "main", title: "t", body: "b"); XCTFail(name) }
            catch let e as GitHubError { XCTAssertEqual(e.code, "deploy_branch_forbidden", name) }
        }
        XCTAssertEqual(github.requests.count, before, "nothing was sent")
        XCTAssertEqual(github.refNames, ["main"])
    }

    // MARK: Switched off and configuration

    func testPublishIsCleanlySwitchedOffWithoutConfiguration() async throws {
        try await fixture { f in
            let github = FakeGitHub(publicKey: Self.rsa.publicKey, files: [:])
            f.app.githubTransport = github
            f.transport.files = ["about.php": Data("neu\n".utf8)]
            let made = try await f.created(["protocol": "ftps", "port": 21])
            let id = try XCTUnwrap(made["id"] as? String)
            let body: Obj = ["files": [], "baseCommit": String(repeating: "a", count: 40)]

            f.app.githubApp = GitHubAppSetup.fromEnvironment { _ in nil }
            let off = try await publish(f, id, body)
            XCTAssertEqual(off.status, .ok, off.text)
            XCTAssertEqual(off.body["ok"] as? Bool, false)
            XCTAssertEqual(off.body["code"] as? String, "deploy_github_not_configured", off.text)

            f.app.githubApp = GitHubAppSetup.fromEnvironment { ["GITHUB_APP_ID": "1"][$0] }
            let half = try await publish(f, id, body)
            XCTAssertEqual(half.body["code"] as? String, "deploy_github_config_invalid", half.text)

            XCTAssertTrue(github.requests.isEmpty)
            XCTAssertTrue(f.transport.connections.isEmpty, "the server is not asked while the write path is off")
            // Pull (read only) keeps working without the app.
            let pulled = try await f.test.json(.POST, "/v1/deploy-targets/\(id)/pull", ["files": []], token: f.session)
            XCTAssertEqual(pulled.body?["ok"] as? Bool, true)
        }
    }

    func testGitHubAppConfigurationFromEnvironment() throws {
        let project = UUID()
        let good = ["GITHUB_APP_ID": "424242", "GITHUB_APP_INSTALLATION_ID": "777", "GITHUB_APP_PRIVATE_KEY": Self.pem,
                    "GITHUB_APP_REPOSITORIES": " \(project.uuidString.lowercased())=acme/site , \(project.uuidString)=acme/Other.repo_1 "]
        func load(_ changes: [String: String?]) -> GitHubAppSetup {
            var env = good
            for (k, v) in changes { env[k] = v }
            return GitHubAppSetup.fromEnvironment { env[$0] }
        }
        guard case .enabled(let config) = load([:]) else { return XCTFail("enabled expected: \(load([:]))") }
        XCTAssertEqual(config.appID, "424242")
        XCTAssertEqual(config.installationID, "777")
        XCTAssertEqual(config.apiURL, "https://api.github.com")
        XCTAssertEqual(config.repositories[project], ["acme/site", "acme/Other.repo_1"])
        guard case .disabled = GitHubAppSetup.fromEnvironment(get: { _ in nil }) else { return XCTFail("disabled") }
        guard case .disabled = load(["GITHUB_APP_ID": "", "GITHUB_APP_INSTALLATION_ID": "", "GITHUB_APP_PRIVATE_KEY": "", "GITHUB_APP_REPOSITORIES": ""]) else {
            return XCTFail("empty variables count as unset")
        }
        // Docker secret file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString).pem")
        try (Self.pem + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .enabled = load(["GITHUB_APP_PRIVATE_KEY": nil, "GITHUB_APP_PRIVATE_KEY_FILE": file.path]) else { return XCTFail("key file") }
        guard case .enabled(let local) = load(["GITHUB_API_URL": "http://127.0.0.1:9/"]) else { return XCTFail("loopback http") }
        XCTAssertEqual(local.apiURL, "http://127.0.0.1:9")

        let bad: [(String, [String: String?])] = [
            ("GITHUB_APP_ID", ["GITHUB_APP_ID": "12a"]), ("GITHUB_APP_ID", ["GITHUB_APP_ID": nil]),
            ("GITHUB_APP_INSTALLATION_ID", ["GITHUB_APP_INSTALLATION_ID": "7/..", ]),
            ("GITHUB_APP_PRIVATE_KEY", ["GITHUB_APP_PRIVATE_KEY": "-----BEGIN RSA PRIVATE KEY-----\nKEY-GEHEIM-kaputt\n-----END RSA PRIVATE KEY-----"]),
            ("GITHUB_APP_PRIVATE_KEY", ["GITHUB_APP_PRIVATE_KEY_FILE": "/nonexistent/key.pem"]),
            ("GITHUB_APP_REPOSITORIES", ["GITHUB_APP_REPOSITORIES": nil]), ("GITHUB_APP_REPOSITORIES", ["GITHUB_APP_REPOSITORIES": "acme/site"]),
            ("GITHUB_APP_REPOSITORIES", ["GITHUB_APP_REPOSITORIES": "\(project.uuidString)=acme/../x"]),
            ("GITHUB_APP_REPOSITORIES", ["GITHUB_APP_REPOSITORIES": "\(project.uuidString)=acme/.."]),
            ("GITHUB_APP_REPOSITORIES", ["GITHUB_APP_REPOSITORIES": "\(project.uuidString)=acme/site?x=1"]),
            ("GITHUB_API_URL", ["GITHUB_API_URL": "http://api.github.example"]), ("GITHUB_API_URL", ["GITHUB_API_URL": "http://127.0.0.1.evil.example"]),
            ("GITHUB_API_URL", ["GITHUB_API_URL": "https://user:pw@api.github.com"]),
        ]
        for (name, changes) in bad {
            guard case .invalid(let names) = load(changes) else { XCTFail("invalid expected: \(changes.keys)"); continue }
            XCTAssertTrue(names.contains(name), "\(name) in \(names)")
            XCTAssertFalse(names.joined().contains("GEHEIM"), "only variable names, never values")
        }
    }

    // MARK: Repository allowlist and base commit

    func testPublishNeedsAnAllowedRepositoryAndAKnownBase() async throws {
        try await publishFixture { f, github, id in
            f.transport.files = ["about.php": Data("neu\n".utf8)]
            let base = github.head("main")
            func code(_ body: Obj, line: UInt = #line) async throws -> String? {
                var b: Obj = ["files": [], "baseCommit": base]
                for (k, v) in body { b[k] = v }
                let r = try await publish(f, id, b)
                XCTAssertEqual(r.status, .ok, r.text, line: line)
                XCTAssertEqual(r.body["ok"] as? Bool, false, r.text, line: line)
                XCTAssertNil(r.body["branch"], r.text, line: line)
                return r.body["code"] as? String
            }
            // Another repository of the same installation is never reachable.
            let foreign = try await code(["repository": "acme/secret"])
            XCTAssertEqual(foreign, "deploy_github_repository_not_allowed")
            // The repository is allowed for another project only.
            f.app.githubApp = setup(UUID().uuidString)
            let otherProject = try await code([:])
            XCTAssertEqual(otherProject, "deploy_github_repository_not_allowed")
            let named = try await code(["repository": "acme/site"])
            XCTAssertEqual(named, "deploy_github_repository_not_allowed")
            f.app.githubApp = setup(f.projectID, ["GITHUB_APP_REPOSITORIES": "\(f.projectID)=acme/site,\(f.projectID)=acme/two"])
            let ambiguous = try await code([:])
            XCTAssertEqual(ambiguous, "deploy_github_repository_required")
            XCTAssertTrue(github.requests.isEmpty)

            f.app.githubApp = setup(f.projectID)
            let unknown = try await code(["baseCommit": String(repeating: "b", count: 40)])
            XCTAssertEqual(unknown, "deploy_github_base_unknown")
            // A commit that is not on the default branch would drag foreign commits into the pull request.
            let side = github.commit(on: "wip", files: ["wip.txt": .init("unfertig\n")])
            let offMain = try await code(["baseCommit": side])
            XCTAssertEqual(offMain, "deploy_github_base_unknown")
            XCTAssertTrue(f.transport.connections.isEmpty, "the server is not asked without a usable base")
            XCTAssertEqual(Set(github.refNames), ["main", "wip"])
            XCTAssertTrue(github.pulls.isEmpty)

            for body: Obj in [["files": []], ["files": [], "baseCommit": "main"], ["files": [], "baseCommit": String(repeating: "A", count: 39)]] {
                let r = try await publish(f, id, body)
                XCTAssertEqual(r.status, .badRequest, r.text)
                XCTAssertEqual(r.body["reason"] as? String, "deploy_pull_invalid", r.text)
            }
            // An older commit of the default branch is a good base: the branch starts there.
            _ = github.commit(on: "main", files: ["later.txt": .init("später\n")])
            let older = try await publish(f, id, ["files": [], "baseCommit": base])
            XCTAssertEqual(older.body["ok"] as? Bool, true, older.text)
            XCTAssertEqual(github.parents(older.body["commit"] as? String ?? ""), [base])
        }
    }

    func testPublishSkipsUnchangedFilesSymlinksSubmodulesAndDirectories() async throws {
        let repo: [String: FakeGitHub.File] = ["same.txt": .init("gleich\n"), "link.txt": .init("ziel", mode: "120000"),
                                               "vendor/lib": .init("x", mode: "160000"), "dir/inner.txt": .init("i\n"), "plain": .init("p\n")]
        try await publishFixture(repo) { f, github, id in
            let base = github.head("main")
            f.transport.files = ["same.txt": Data("gleich\r\n".utf8)]
            // Nothing differs from the base commit, even though the manifest does not know the file.
            let nothing = try await publish(f, id, ["files": [], "baseCommit": base])
            XCTAssertEqual(nothing.body["code"] as? String, "deploy_pull_nothing", nothing.text)
            XCTAssertEqual(nothing.body["ok"] as? Bool, false)
            XCTAssertEqual(github.refNames, ["main"])
            XCTAssertTrue(github.requests.allSatisfy { $0.method == "GET" || $0.url.hasSuffix("/access_tokens") }, "nothing was written")

            f.transport.files = ["same.txt": Data("gleich\n".utf8), "link.txt": Data("überschreibt Link\n".utf8), "vendor/lib": Data("x2\n".utf8),
                                 "vendor/lib/deep.txt": Data("in Submodul\n".utf8), "dir": Data("Datei statt Ordner\n".utf8),
                                 "plain/child.txt": Data("Ordner statt Datei\n".utf8), "ok.txt": Data("neu\n".utf8)]
            let r = try await publish(f, id, ["files": [], "baseCommit": base])
            XCTAssertEqual(r.body["ok"] as? Bool, true, r.text)
            XCTAssertEqual((r.body["files"] as? [Obj] ?? []).compactMap { $0["path"] as? String }, ["ok.txt"], r.text)
            let blocked = (r.body["findings"] as? [Obj] ?? []).filter { $0["reason"] as? String == "blocked_path" }.compactMap { $0["path"] as? String }
            XCTAssertEqual(Set(blocked), ["link.txt", "vendor/lib", "vendor/lib/deep.txt", "dir", "plain/child.txt"], r.text)
            var expected = repo
            expected["ok.txt"] = .init("neu\n")
            XCTAssertEqual(github.files(r.body["branch"] as? String ?? ""), expected)
        }
    }

    func testPublishPutsAtMostFiftyBinariesIntoOnePullRequest() async throws {
        try await publishFixture { f, github, id in
            f.transport.files = Dictionary(uniqueKeysWithValues: (0..<53).map { (String(format: "img/%02d.png", $0), Data([0x00, UInt8($0)])) })
            let r = try await publish(f, id, ["files": [], "baseCommit": github.head("main")])
            XCTAssertEqual(r.body["ok"] as? Bool, true, r.text)
            XCTAssertEqual((r.body["files"] as? [Obj])?.count, 50)
            XCTAssertEqual(r.body["remaining"] as? [String], ["img/50.png", "img/51.png", "img/52.png"])
            XCTAssertEqual(r.body["remainingTotal"] as? Int, 3)
            XCTAssertTrue(github.pulls.first?.body.contains("3 weitere Dateien") == true, github.pulls.first?.body ?? "")
        }
    }

    // MARK: Failures, secrets and rights

    func testPublishFailuresAreFixedCodesWithoutSecrets() async throws {
        try await publishFixture { f, github, id in
            f.transport.files = ["about.php": Data("neu\n".utf8)]
            let body: Obj = ["files": [], "baseCommit": github.head("main")]
            var answers: [String] = []
            // The double answers errors with a body that echoes the Authorization header: it must never be passed on or logged.
            let cases: [(String, Int, String)] = [("/access_tokens", 401, "deploy_github_auth_failed"), ("/access_tokens", 403, "deploy_github_forbidden"),
                                                  ("/repos/acme/site", 404, "deploy_github_not_found"), ("/git/trees", 500, "deploy_github_unavailable"),
                                                  ("/git/commits", 422, "deploy_github_failed"), ("/git/refs", 403, "deploy_github_forbidden"),
                                                  ("/git/refs", 422, "deploy_github_failed")]
            for (suffix, status, expected) in cases {
                github.failure = (suffix, status)
                let r = try await publish(f, id, body)
                XCTAssertEqual(r.body["code"] as? String, expected, "\(suffix) \(status): \(r.text)")
                XCTAssertEqual(r.body["ok"] as? Bool, false)
                XCTAssertEqual(github.refNames, ["main"])
                answers.append(r.text)
            }
            github.failure = ("transport", 0)
            let down = try await publish(f, id, body)
            XCTAssertEqual(down.body["code"] as? String, "deploy_github_unavailable", down.text)

            // The branch exists but the pull request fails: the person is told where the commit is.
            github.failure = ("/pulls", 422)
            let noPR = try await publish(f, id, body)
            XCTAssertEqual(noPR.body["code"] as? String, "deploy_github_pr_failed", noPR.text)
            XCTAssertEqual(noPR.body["branch"] as? String, "server/kubus-test-\(day)")
            XCTAssertEqual(noPR.body["commit"] as? String, github.head("server/kubus-test-\(day)"))

            github.failure = nil
            f.transport.failure = "deploy_unreachable"
            let target = try await publish(f, id, body)
            XCTAssertEqual(target.body["code"] as? String, "deploy_unreachable", target.text)
            assertNoSecrets(f, github, answers + [down.text, noPR.text, target.text])
            XCTAssertTrue(f.capture.lines.contains { $0.contains("deploy_github_auth_failed") }, "failures are logged with their code")
        }
    }

    func testPublishRightsForPersonsAndAgents() async throws {
        try await publishFixture { f, github, id in
            f.transport.files = ["about.php": Data("neu\n".utf8)]
            let base = github.head("main")
            let body: Obj = ["files": [], "baseCommit": base]
            let token = try await f.mcpToken()
            let viaToken = try await publish(f, id, body, token: token)
            XCTAssertEqual(viaToken.status, .unauthorized)
            let other = User(displayName: "Fremd", isAdmin: false)
            try await other.save(on: f.app.db)
            let stranger = AuthSupport.randomToken()
            try await UserSession(userID: other.requireID(), tokenHash: AuthSupport.hash(stranger), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.db)
            let foreign = try await publish(f, id, body, token: stranger)
            XCTAssertEqual(foreign.status, .notFound)
            try await ProjectGrant(projectID: try f.o.project.requireID(), principalType: "person", principalID: other.requireID(), role: .read).save(on: f.app.db)
            let reader = try await publish(f, id, body, token: stranger)
            XCTAssertEqual(reader.status, .forbidden, reader.text)
            XCTAssertTrue(github.requests.isEmpty)

            // MCP: writing to GitHub needs projects:write; reading scopes are not enough.
            let args: Obj = ["targetID": id, "files": [], "baseCommit": base]
            let readOnly = try await f.o.rpc("tools/call", ["name": "open_server_changes_pr", "arguments": args], access: token)
            XCTAssertTrue(String(describing: readOnly.body ?? [:]).contains("scope"), "\(readOnly.body ?? [:])")
            XCTAssertTrue(github.requests.isEmpty)
            let writer = try await f.o.tokens(scope: "projects:read projects:write").access
            let refused = try await f.mcp(writer, "open_server_changes_pr", ["targetID": id, "files": [], "baseCommit": base, "branch": "main"])
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("deploy_branch_forbidden"), refused.text)
            XCTAssertTrue(github.requests.isEmpty)
            let ok = try await f.mcp(writer, "open_server_changes_pr", args)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(ok.json?["ok"] as? Bool, true, ok.text)
            XCTAssertEqual(ok.json?["branch"] as? String, "server/kubus-test-\(day)")
            let unknown = try await f.mcp(writer, "open_server_changes_pr", ["targetID": UUID().uuidString, "files": [], "baseCommit": base])
            XCTAssertTrue(unknown.isError)
            for word in ["test.example.com", "\"deploy\""] { XCTAssertFalse(ok.text.contains(word), word) }
            assertNoSecrets(f, github, [ok.text, refused.text])
        }
    }
}

/// In-memory GitHub REST API: just the calls the write path may use. Blob ids are real git ids; the JWT signature is verified.
final class FakeGitHub: GitHubTransport, @unchecked Sendable {
    static let token = "ghs_INSTALLATIONTOKENgeheim0123456789abcd"

    struct File: Equatable {
        let data: Data
        let mode: String
        init(_ text: String, mode: String = "100644") { data = Data(text.utf8); self.mode = mode }
        init(data: Data, mode: String = "100644") { self.data = data; self.mode = mode }
    }
    struct Request { let method: String; let url: String; let json: [String: Any] }
    struct Pull { let head: String; let base: String; let title: String; let body: String }
    private struct Commit { let files: [String: File]; let parents: [String]; let message: String }

    private let lock = NSLock()
    private let publicKey: _RSA.Signing.PublicKey
    private var commits: [String: Commit] = [:], refs: [String: String] = [:], blobs: [String: Data] = [:]
    /// Tree id -> the whole file set and the directory inside it.
    private var trees: [String: (files: [String: File], prefix: String)] = [:]
    private var _requests: [Request] = [], _pulls: [Pull] = [], _jwts: [String] = [], _claims: [[String: Any]] = []
    private var _failure: (String, Int)?

    var requests: [Request] { lock.withLock { _requests } }
    var pulls: [Pull] { lock.withLock { _pulls } }
    var jwts: [String] { lock.withLock { _jwts } }
    var claims: [[String: Any]] { lock.withLock { _claims } }
    /// (URL suffix, status) to fail, or ("transport", 0) for a network error.
    var failure: (String, Int)? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    var refNames: [String] { lock.withLock { refs.keys.sorted() } }
    func head(_ branch: String) -> String { lock.withLock { refs[branch] ?? "" } }
    func parents(_ sha: String) -> [String] { lock.withLock { commits[sha]?.parents ?? [] } }
    func message(_ sha: String) -> String { lock.withLock { commits[sha]?.message ?? "" } }
    func files(_ branch: String) -> [String: File] { lock.withLock { refs[branch].flatMap { commits[$0]?.files } ?? [:] } }

    init(publicKey: _RSA.Signing.PublicKey, files: [String: File]) {
        self.publicKey = publicKey
        _ = commit(on: "main", files: files)
    }

    /// A commit made outside Todolino (seed, or somebody else working in the repository).
    func commit(on branch: String, files: [String: File]) -> String {
        lock.withLock {
            let parent = refs[branch] ?? refs["main"]
            var all = parent.flatMap { commits[$0]?.files } ?? [:]
            for (k, v) in files { all[k] = v }
            let sha = store(Commit(files: all, parents: parent.map { [$0] } ?? [], message: "seed \(commits.count)"))
            refs[branch] = sha
            return sha
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
    static func blobSHA(_ data: Data) -> String { hex(Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data)) }

    private func store(_ c: Commit) -> String {
        let sha = Self.hex(Insecure.SHA1.hash(data: Data("commit \(commits.count) \(c.message)".utf8)))
        commits[sha] = c
        return sha
    }

    private func treeSHA(_ files: [String: File], _ prefix: String) -> String {
        let inside = files.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        let text = inside.map { "\($0.key.dropFirst(prefix.count)) \($0.value.mode) \(Self.blobSHA($0.value.data))" }.joined(separator: "\n")
        let sha = Self.hex(Insecure.SHA1.hash(data: Data(("tree\n" + text).utf8)))
        trees[sha] = (files, prefix)
        return sha
    }

    private func entries(_ files: [String: File], _ prefix: String) -> [[String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (path, file) in files where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard let name = rest.first else { continue }
            if rest.count > 1 { out[name] = ["path": name, "mode": "040000", "type": "tree", "sha": treeSHA(files, prefix + name + "/")] }
            else {
                let sha = Self.blobSHA(file.data)
                blobs[sha] = file.data
                out[name] = ["path": name, "mode": file.mode, "type": file.mode == "160000" ? "commit" : "blob", "sha": sha]
            }
        }
        return out.keys.sorted().map { out[$0]! }
    }

    private func isAncestor(_ base: String, of head: String) -> Bool {
        var queue = [head]
        while let sha = queue.popLast() {
            if sha == base { return true }
            queue += commits[sha]?.parents ?? []
        }
        return false
    }

    private func verify(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".").map(String.init)
        func decode(_ s: String) -> Data? {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)
        }
        guard parts.count == 3, let header = decode(parts[0]), let payload = decode(parts[1]), let signature = decode(parts[2]),
              (try? JSONSerialization.jsonObject(with: header) as? [String: String])?["alg"] == "RS256",
              publicKey.isValidSignature(.init(rawRepresentation: signature), for: SHA256.hash(data: Data("\(parts[0]).\(parts[1])".utf8)),
                                         padding: .insecurePKCS1v1_5) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    func send(_ r: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        try lock.withLock { try handle(r) }
    }

    private func handle(_ r: GitHubHTTPRequest) throws -> GitHubHTTPResponse {
        let method = r.method.rawValue
        let json = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        _requests.append(Request(method: method, url: r.url, json: json))
        func answer(_ status: Int, _ object: Any) -> GitHubHTTPResponse {
            GitHubHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
        let authorization = r.headers["Authorization"] ?? ""
        let url = String(r.url.split(separator: "?", maxSplits: 1)[0])
        if let (suffix, status) = _failure {
            if suffix == "transport" { throw URLError(.cannotConnectToHost) }
            if url.hasSuffix(suffix) && (method == "POST" || suffix == "/repos/acme/site") {
                return answer(status, ["message": "boom \(authorization) \(Self.token)"])
            }
        }
        let api = "https://api.github.com"
        if url == "\(api)/app/installations/777/access_tokens", method == "POST" {
            let jwt = String(authorization.dropFirst("Bearer ".count))
            guard let claims = verify(jwt) else { return answer(401, ["message": "bad jwt"]) }
            _jwts.append(jwt); _claims.append(claims)
            return answer(201, ["token": Self.token])
        }
        guard authorization == "Bearer \(Self.token)" else { return answer(401, ["message": "bad token"]) }
        let repo = "\(api)/repos/acme/site"
        guard url == repo || url.hasPrefix(repo + "/") else { return answer(404, ["message": "Not Found"]) }
        let path = String(url.dropFirst(repo.count))
        switch (method, path) {
        case ("GET", ""): return answer(200, ["default_branch": "main"])
        case ("GET", _) where path.hasPrefix("/compare/"):
            let ends = path.dropFirst("/compare/".count).components(separatedBy: "...")
            guard ends.count == 2, commits[ends[0]] != nil, let head = refs[ends[1]] ?? (commits[ends[1]] != nil ? ends[1] : nil) else { return answer(404, ["message": "Not Found"]) }
            return answer(200, ["status": ends[0] == head ? "identical" : isAncestor(ends[0], of: head) ? "ahead" : "diverged"])
        case ("GET", _) where path.hasPrefix("/git/commits/"):
            guard let c = commits[String(path.dropFirst("/git/commits/".count))] else { return answer(404, ["message": "Not Found"]) }
            return answer(200, ["tree": ["sha": treeSHA(c.files, "")]])
        case ("GET", _) where path.hasPrefix("/git/trees/"):
            guard let t = trees[String(path.dropFirst("/git/trees/".count))] else { return answer(404, ["message": "Not Found"]) }
            return answer(200, ["tree": entries(t.files, t.prefix), "truncated": false])
        case ("POST", "/git/blobs"):
            guard json["encoding"] as? String == "base64", let data = (json["content"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return answer(422, [:]) }
            let sha = Self.blobSHA(data)
            blobs[sha] = data
            return answer(201, ["sha": sha])
        case ("POST", "/git/trees"):
            guard let base = (json["base_tree"] as? String).flatMap({ trees[$0] }), let list = json["tree"] as? [[String: Any]] else { return answer(422, [:]) }
            var files = base.files
            for e in list {
                guard let p = e["path"] as? String, let mode = e["mode"] as? String,
                      let data = (e["content"] as? String).map({ Data($0.utf8) }) ?? (e["sha"] as? String).flatMap({ blobs[$0] }) else { return answer(422, [:]) }
                files[p] = File(data: data, mode: mode)
            }
            return answer(201, ["sha": treeSHA(files, "")])
        case ("POST", "/git/commits"):
            guard let tree = (json["tree"] as? String).flatMap({ trees[$0] }), let parents = json["parents"] as? [String], let message = json["message"] as? String
            else { return answer(422, [:]) }
            return answer(201, ["sha": store(Commit(files: tree.files, parents: parents, message: message))])
        case ("POST", "/git/refs"):
            guard let ref = json["ref"] as? String, ref.hasPrefix("refs/heads/"), let sha = json["sha"] as? String, commits[sha] != nil else { return answer(422, [:]) }
            let name = String(ref.dropFirst("refs/heads/".count))
            if refs[name] != nil { return answer(422, ["message": "Reference already exists"]) }
            refs[name] = sha
            return answer(201, ["ref": ref])
        case ("POST", "/pulls"):
            guard let head = json["head"] as? String, let base = json["base"] as? String, let title = json["title"] as? String, let body = json["body"] as? String,
                  refs[head] != nil else { return answer(422, [:]) }
            _pulls.append(Pull(head: head, base: base, title: title, body: body))
            return answer(201, ["number": _pulls.count, "html_url": "https://github.example/acme/site/pull/\(_pulls.count)"])
        default: return answer(404, ["message": "Not Found"])
        }
    }
}
