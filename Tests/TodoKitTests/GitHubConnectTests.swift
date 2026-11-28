import _CryptoExtras
import Crypto
import Fluent
import Foundation
import SQLKit
import XCTVapor
@testable import TodoKit

/// One GitHub App of the operator, one installation per person (card E51E8B8C, ADR 0042 addendum, contracts/deploy.yaml 1.3.0):
/// a person connects an installation in the PWA (state bound to the person, installation proven with the app's user OAuth) and maps
/// a project to one of its repositories. Nobody sees or uses another person's connection; rights are checked again on every use.
/// GitHub is an in-memory double here (several users, installations and repositories).
extension DeployTargetTests {
    private static let hubKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    private static let clientSecret = "cs-GEHEIM-0f9a8b7c6d5e4f"

    private static var operatorEnvironment: [String: String] {
        ["GITHUB_APP_ID": "424242", "GITHUB_APP_PRIVATE_KEY": hubKey.pemRepresentation, "GITHUB_APP_SLUG": "todolino-test",
         "GITHUB_APP_CLIENT_ID": "Iv23liTESTCLIENT", "GITHUB_APP_CLIENT_SECRET": clientSecret]
    }

    private static func operatorSetup(_ extra: [String: String?] = [:]) -> GitHubAppSetup {
        var env = operatorEnvironment
        for (k, v) in extra { env[k] = v }
        return GitHubAppSetup.fromEnvironment { env[$0] }
    }

    /// A person of Todolino with a session, a project of their own and one FTPS deploy target in it (FTPS: no host key step).
    struct Person {
        let user: User
        let session: String
        let project: Project
        var projectID: String { project.id!.uuidString }
        var targetID = ""
    }

    private func person(_ f: Fixture, _ name: String) async throws -> Person {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: f.app.db)
        let session = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.db)
        let project = Project(ownerID: try user.requireID(), parentID: nil, name: "Projekt \(name)")
        try await project.save(on: f.app.db)
        var p = Person(user: user, session: session, project: project)
        let r = try await f.test.json(.POST, "/v1/projects/\(p.projectID)/deploy-targets",
                                      ["name": "Server \(name)", "stage": "test", "protocol": "ftps", "port": 21, "host": "test.example.com",
                                       "basePath": "site", "username": "deploy", "password": Self.password], token: session)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        p.targetID = r.body?["id"] as? String ?? ""
        return p
    }

    /// GitHub with alice (installation 111: alice/site, alice/open public), bob (222: bob/site) and the organization acme
    /// (333: acme/web, acme/docs; alice writes acme/web, carol only reads it).
    private func hubFixture(_ run: (Fixture, FakeGitHubHub, Person, Person) async throws -> Void) async throws {
        try await fixture { f in
            let hub = FakeGitHubHub(publicKey: Self.hubKey.publicKey, appID: 424242, clientID: "Iv23liTESTCLIENT", clientSecret: Self.clientSecret)
            hub.user("alice", id: 1001); hub.user("bob", id: 1002); hub.user("carol", id: 1003)
            hub.install(111, account: "alice", accountID: 1001, type: "User")
            hub.install(222, account: "bob", accountID: 1002, type: "User")
            hub.install(333, account: "acme", accountID: 9000, type: "Organization")
            hub.repository(111, "alice/site", id: 5001, permissions: ["alice": "admin"])
            hub.repository(111, "alice/open", id: 5002, isPrivate: false, permissions: ["alice": "admin"])
            hub.repository(222, "bob/site", id: 5003, permissions: ["bob": "admin"])
            hub.repository(333, "acme/web", id: 5004, permissions: ["alice": "write", "carol": "read"])
            hub.repository(333, "acme/docs", id: 5005, permissions: ["alice": "read"])
            f.app.githubApp = Self.operatorSetup()
            f.app.githubTransport = hub
            f.transport.files = ["about.php": Data("neu\n".utf8)]
            let alice = try await person(f, "Alice"), bob = try await person(f, "Bob")
            try await run(f, hub, alice, bob)
        }
    }

    private func call(_ f: Fixture, _ method: HTTPMethod, _ path: String, _ body: Obj? = nil, as p: Person) async throws -> (status: HTTPStatus, body: Obj, text: String) {
        let r = try await f.test.json(method, path, body, token: p.session)
        let out = r.body ?? [:]
        return (r.status, out, String(decoding: (try? JSONSerialization.data(withJSONObject: out)) ?? Data(), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/"))
    }

    private static func query(_ url: String, _ name: String) -> String {
        URLComponents(string: url)?.queryItems?.first { $0.name == name }?.value ?? ""
    }

    /// The whole browser flow: "Mit GitHub verbinden", install on GitHub, setup URL, user authorization, callback.
    @discardableResult
    private func connect(_ f: Fixture, _ hub: FakeGitHubHub, _ p: Person, as login: String, installation: Int,
                         line: UInt = #line) async throws -> String {
        let start = try await call(f, .POST, "/v1/github/connect", ["mode": "install"], as: p)
        XCTAssertEqual(start.status, .ok, start.text, line: line)
        let state = Self.query(start.body["url"] as? String ?? "", "state")
        let setup = try await call(f, .POST, "/v1/github/setup", ["state": state, "installationID": "\(installation)"], as: p)
        XCTAssertEqual(setup.status, .ok, setup.text, line: line)
        let second = Self.query(setup.body["url"] as? String ?? "", "state")
        let done = try await call(f, .POST, "/v1/github/callback", ["state": second, "code": hub.code(for: login)], as: p)
        XCTAssertEqual(done.status, .ok, done.text, line: line)
        let items = done.body["connections"] as? [Obj] ?? []
        let made = items.first { ($0["manageURL"] as? String)?.hasSuffix("/\(installation)") == true }
        XCTAssertNotNil(made, done.text, line: line)
        return made?["id"] as? String ?? ""
    }

    private func connections(_ f: Fixture, _ p: Person) async throws -> [Obj] {
        let r = try await call(f, .GET, "/v1/github", as: p)
        XCTAssertEqual(r.status, .ok, r.text)
        return r.body["connections"] as? [Obj] ?? []
    }

    @discardableResult
    private func assign(_ f: Fixture, _ p: Person, project: String? = nil, _ connection: String, _ repository: String) async throws
        -> (status: HTTPStatus, body: Obj, text: String) {
        try await call(f, .POST, "/v1/projects/\(project ?? p.projectID)/github-repositories", ["connectionID": connection, "repository": repository], as: p)
    }

    private func publish(_ f: Fixture, _ hub: FakeGitHubHub, _ p: Person, target: String, repo: String? = nil, base: String? = nil) async throws
        -> (status: HTTPStatus, body: Obj, text: String) {
        var body: Obj = ["files": [], "baseCommit": base ?? hub.head("\(repo ?? "alice/site")", "main")]
        if let repo { body["repository"] = repo }
        return try await call(f, .POST, "/v1/deploy-targets/\(target)/pull-request", body, as: p)
    }

    private func assigned(_ f: Fixture, _ p: Person, project: String? = nil) async throws -> [Obj] {
        let r = try await call(f, .GET, "/v1/projects/\(project ?? p.projectID)/github-repositories", as: p)
        XCTAssertEqual(r.status, .ok, r.text)
        return r.body["items"] as? [Obj] ?? []
    }

    // MARK: Operator configuration

    func testGitHubOperatorAppNeedsNothingPerUserInTheEnvironment() throws {
        func load(_ changes: [String: String?]) -> GitHubAppSetup { Self.operatorSetup(changes) }
        guard case .enabled = load([:]) else { return XCTFail("app id, key, slug and OAuth client are enough: \(load([:]))") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gh-cs-\(UUID().uuidString)")
        try (Self.clientSecret + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .enabled = load(["GITHUB_APP_CLIENT_SECRET": nil, "GITHUB_APP_CLIENT_SECRET_FILE": file.path]) else { return XCTFail("secret file") }
        guard case .enabled = load(["GITHUB_WEB_URL": "http://127.0.0.1:9"]) else { return XCTFail("loopback web url") }
        let bad: [(String, [String: String?])] = [
            ("GITHUB_APP_SLUG", ["GITHUB_APP_SLUG": nil]), ("GITHUB_APP_SLUG", ["GITHUB_APP_SLUG": "../evil"]),
            ("GITHUB_APP_CLIENT_ID", ["GITHUB_APP_CLIENT_ID": nil]), ("GITHUB_APP_CLIENT_ID", ["GITHUB_APP_CLIENT_ID": "a&b=c"]),
            ("GITHUB_APP_CLIENT_SECRET", ["GITHUB_APP_CLIENT_SECRET": nil]),
            ("GITHUB_APP_CLIENT_SECRET", ["GITHUB_APP_CLIENT_SECRET": nil, "GITHUB_APP_CLIENT_SECRET_FILE": "/nonexistent/secret"]),
            ("GITHUB_WEB_URL", ["GITHUB_WEB_URL": "http://github.example"]),
            // App and key alone allow nothing: neither the connect flow nor the old per-instance variables.
            ("GITHUB_APP_SLUG", ["GITHUB_APP_SLUG": nil, "GITHUB_APP_CLIENT_ID": nil, "GITHUB_APP_CLIENT_SECRET": nil]),
            // The old pair only works together.
            ("GITHUB_APP_REPOSITORIES", ["GITHUB_APP_INSTALLATION_ID": "777"]),
            ("GITHUB_APP_INSTALLATION_ID", ["GITHUB_APP_REPOSITORIES": "\(UUID().uuidString)=acme/site"]),
        ]
        for (name, changes) in bad {
            guard case .invalid(let names) = load(changes) else { XCTFail("invalid expected: \(changes)"); continue }
            XCTAssertTrue(names.contains(name), "\(name) in \(names)")
            XCTAssertFalse(names.joined().contains("GEHEIM"))
        }
    }

    // MARK: Connect

    func testPersonConnectsAnInstallationAndOnlyThatIsStored() async throws {
        try await hubFixture { f, hub, alice, bob in
            let overview = try await call(f, .GET, "/v1/github", as: alice)
            XCTAssertEqual(overview.status, .ok, overview.text)
            XCTAssertEqual(overview.body["available"] as? Bool, true, overview.text)

            let start = try await call(f, .POST, "/v1/github/connect", ["mode": "install"], as: alice)
            let install = try XCTUnwrap(start.body["url"] as? String, start.text)
            XCTAssertTrue(install.hasPrefix("https://github.com/apps/todolino-test/installations/new?state="), install)
            let state = Self.query(install, "state")
            XCTAssertGreaterThanOrEqual(state.count, 32)

            let setup = try await call(f, .POST, "/v1/github/setup", ["state": state, "installationID": "111"], as: alice)
            let authorize = try XCTUnwrap(setup.body["url"] as? String, setup.text)
            XCTAssertTrue(authorize.hasPrefix("https://github.com/login/oauth/authorize?"), authorize)
            XCTAssertEqual(Self.query(authorize, "client_id"), "Iv23liTESTCLIENT")
            XCTAssertEqual(Self.query(authorize, "redirect_uri"), "\(f.test.settings.relyingPartyOrigin)/github/callback")
            let second = Self.query(authorize, "state")
            XCTAssertNotEqual(second, state)

            let code = hub.code(for: "alice")
            let done = try await call(f, .POST, "/v1/github/callback", ["state": second, "code": code], as: alice)
            XCTAssertEqual(done.status, .ok, done.text)
            let mine = try await connections(f, alice)
            XCTAssertEqual(mine.count, 1)
            XCTAssertEqual(mine.first?["accountLogin"] as? String, "alice")
            XCTAssertEqual(mine.first?["accountType"] as? String, "User")
            XCTAssertEqual(mine.first?["githubLogin"] as? String, "alice")
            XCTAssertEqual(mine.first?["manageURL"] as? String, "https://github.com/settings/installations/111")
            let others = try await connections(f, bob)
            XCTAssertTrue(others.isEmpty)

            // Connecting the same installation again keeps one entry.
            try await connect(f, hub, alice, as: "alice", installation: 111)
            let again = try await connections(f, alice)
            XCTAssertEqual(again.count, 1)

            // Neither the client secret nor GitHub tokens, codes or states reach an answer, the log or the database.
            let sql = try XCTUnwrap(f.app.db as? any SQLDatabase)
            var stored = ""
            for table in ["github_connections", "github_connect_states"] {
                for row in try await sql.raw("SELECT * FROM \(unsafeRaw: table)").all() {
                    stored += row.allColumns.compactMap { try? row.decode(column: $0, as: String.self) }.joined(separator: "|")
                }
            }
            for text in [done.text, f.capture.lines.joined(separator: "\n"), stored] {
                for secret in [Self.clientSecret, "ghu_", "ghs_", "eyJ", "PRIVATE KEY", code, state, second] {
                    XCTAssertFalse(text.contains(secret), "\(secret.prefix(6)) in \(text.prefix(400))")
                }
            }
        }
    }

    func testSetupAndCallbackAreProtectedAgainstForgery() async throws {
        try await hubFixture { f, hub, alice, bob in
            func state(_ p: Person, _ mode: String = "install") async throws -> String {
                let r = try await call(f, .POST, "/v1/github/connect", ["mode": mode], as: p)
                return Self.query(r.body["url"] as? String ?? "", "state")
            }
            func refused(_ path: String, _ body: Obj, as p: Person, _ status: HTTPStatus, _ reason: String, line: UInt = #line) async throws {
                let r = try await call(f, .POST, path, body, as: p)
                XCTAssertEqual(r.status, status, r.text, line: line)
                XCTAssertEqual(r.body["reason"] as? String, reason, r.text, line: line)
            }
            // A state of somebody else is worthless and is not used up by the attempt (CSRF in both directions).
            let alices = try await state(alice)
            try await refused("/v1/github/setup", ["state": alices, "installationID": "222"], as: bob, .badRequest, "github_state_invalid")
            let own = try await call(f, .POST, "/v1/github/setup", ["state": alices, "installationID": "111"], as: alice)
            XCTAssertEqual(own.status, .ok, own.text)
            // Single use; a setup state is no callback state.
            try await refused("/v1/github/setup", ["state": alices, "installationID": "111"], as: alice, .badRequest, "github_state_invalid")
            let installState = try await state(alice)
            try await refused("/v1/github/callback", ["state": installState, "code": hub.code(for: "alice")], as: alice, .badRequest, "github_state_invalid")
            try await refused("/v1/github/callback", ["state": "erfunden", "code": "x"], as: alice, .badRequest, "github_state_invalid")
            for id in ["", "0x1", "111/../222", "-1", String(repeating: "9", count: 30)] {
                try await refused("/v1/github/setup", ["state": try await state(alice), "installationID": id], as: alice, .badRequest, "github_installation_invalid")
            }

            // The installation id in the setup URL can be forged: alice names bob's installation, GitHub says it is not hers.
            let forged = try await call(f, .POST, "/v1/github/setup", ["state": try await state(alice), "installationID": "222"], as: alice)
            let second = Self.query(forged.body["url"] as? String ?? "", "state")
            try await refused("/v1/github/callback", ["state": second, "code": hub.code(for: "alice")], as: alice, .forbidden, "github_installation_not_yours")
            // ... and that state is gone.
            try await refused("/v1/github/callback", ["state": second, "code": hub.code(for: "alice")], as: alice, .badRequest, "github_state_invalid")
            let wrongCode = try await call(f, .POST, "/v1/github/setup", ["state": try await state(alice), "installationID": "111"], as: alice)
            try await refused("/v1/github/callback", ["state": Self.query(wrongCode.body["url"] as? String ?? "", "state"), "code": "falsch"], as: alice,
                              .badRequest, "github_authorization_failed")

            // Expired.
            let old = try await state(alice)
            try await GitHubConnectState.query(on: f.app.db).set(\.$expiresAt, to: Date().addingTimeInterval(-60)).update()
            try await refused("/v1/github/setup", ["state": old, "installationID": "111"], as: alice, .badRequest, "github_state_invalid")

            let stored = try await connections(f, alice)
            XCTAssertTrue(stored.isEmpty, "nothing was connected by any of this")

            // Agents (OAuth access tokens) have no part in any of this.
            let token = try await f.mcpToken()
            for (method, path) in [(HTTPMethod.GET, "/v1/github"), (.POST, "/v1/github/connect"), (.GET, "/v1/projects/\(f.projectID)/github-repositories")] {
                let r = try await f.test.json(method, path, method == .POST ? ["mode": "install"] : nil, token: token)
                XCTAssertEqual(r.status, .unauthorized, path)
            }
            let tools = try await f.o.rpc("tools/list", access: token)
            let names = ((tools.body?["result"] as? Obj)?["tools"] as? [Obj] ?? []).compactMap { $0["name"] as? String }
            XCTAssertFalse(names.contains { $0.contains("github") }, "\(names)")

            // Without the operator app there is nothing to connect.
            f.app.githubApp = .disabled
            let off = try await call(f, .GET, "/v1/github", as: alice)
            XCTAssertEqual(off.body["available"] as? Bool, false, off.text)
            try await refused("/v1/github/connect", ["mode": "install"], as: alice, .conflict, "github_not_configured")
        }
    }

    func testConcurrentCallbacksUseAStateOnce() async throws {
        try await hubFixture { f, hub, alice, _ in
            let start = try await call(f, .POST, "/v1/github/connect", ["mode": "existing"], as: alice)
            let state = Self.query(start.body["url"] as? String ?? "", "state")
            let codes = (0..<4).map { _ in hub.code(for: "alice") }
            let results = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for code in codes {
                    group.addTask { try await f.test.json(.POST, "/v1/github/callback", ["state": state, "code": code], token: alice.session).status }
                }
                var out: [HTTPStatus] = []
                for try await s in group { out.append(s) }
                return out
            }
            XCTAssertEqual(results.filter { $0 == .ok }.count, 1, "\(results)")
        }
    }

    // MARK: Review findings (security-auditor, 28.11.2026)

    /// The same installation connected again by another GitHub account: what was mapped under the old account must not carry over.
    func testReconnectingAnInstallationWithAnotherGitHubAccountDropsItsMappings() async throws {
        try await hubFixture { f, hub, alice, _ in
            let c = try await connect(f, hub, alice, as: "alice", installation: 333)
            let made = try await assign(f, alice, c, "acme/web")
            XCTAssertEqual(made.status, .created, made.text)
            let again = try await connect(f, hub, alice, as: "carol", installation: 333)
            XCTAssertEqual(again, c)
            let left = try await assigned(f, alice)
            XCTAssertTrue(left.isEmpty, "\(left)")
            let sameAgain = try await connect(f, hub, alice, as: "carol", installation: 333)
            XCTAssertEqual(sameAgain, c)
        }
    }

    /// Over the limit nothing is stored at all, and installations without an app id are not taken for this app.
    func testConnectionLimitStoresNothingAndInstallationsWithoutAppIDAreIgnored() async throws {
        try await hubFixture { f, hub, alice, _ in
            hub.user("dora", id: 1004)
            for i in 0..<21 { hub.install(500 + i, account: "dora", accountID: 1004, type: "User") }
            let start = try await call(f, .POST, "/v1/github/connect", ["mode": "existing"], as: alice)
            let done = try await call(f, .POST, "/v1/github/callback", ["state": Self.query(start.body["url"] as? String ?? "", "state"), "code": hub.code(for: "dora")], as: alice)
            XCTAssertEqual(done.status, .badRequest, done.text)
            XCTAssertEqual(done.body["reason"] as? String, "github_connection_limit")
            let stored = try await connections(f, alice)
            XCTAssertTrue(stored.isEmpty, "\(stored)")

            hub.leaveOutAppID(true)
            let second = try await call(f, .POST, "/v1/github/connect", ["mode": "existing"], as: alice)
            let none = try await call(f, .POST, "/v1/github/callback", ["state": Self.query(second.body["url"] as? String ?? "", "state"), "code": hub.code(for: "alice")], as: alice)
            XCTAssertEqual(none.status, .notFound, none.text)
            XCTAssertEqual(none.body["reason"] as? String, "github_no_installation")
        }
    }

    func testConnectingInstallationsThatAlreadyExist() async throws {
        try await hubFixture { f, hub, alice, bob in
            // The app is installed already (GitHub then shows no setup redirect): authorize and take what GitHub lists for the person.
            let start = try await call(f, .POST, "/v1/github/connect", ["mode": "existing"], as: alice)
            let url = try XCTUnwrap(start.body["url"] as? String, start.text)
            XCTAssertTrue(url.hasPrefix("https://github.com/login/oauth/authorize?"), url)
            let done = try await call(f, .POST, "/v1/github/callback", ["state": Self.query(url, "state"), "code": hub.code(for: "alice")], as: alice)
            XCTAssertEqual(done.status, .ok, done.text)
            let mine = try await connections(f, alice)
            XCTAssertEqual(Set(mine.compactMap { $0["accountLogin"] as? String }), ["alice", "acme"], done.text)
            XCTAssertEqual(mine.first { $0["accountLogin"] as? String == "acme" }?["manageURL"] as? String,
                           "https://github.com/organizations/acme/settings/installations/333")

            hub.user("dora", id: 1004)
            let none = try await call(f, .POST, "/v1/github/connect", ["mode": "existing"], as: bob)
            let empty = try await call(f, .POST, "/v1/github/callback",
                                       ["state": Self.query(none.body["url"] as? String ?? "", "state"), "code": hub.code(for: "dora")], as: bob)
            XCTAssertEqual(empty.status, .notFound, empty.text)
            XCTAssertEqual(empty.body["reason"] as? String, "github_no_installation")
        }
    }

    /// The app may ask for the authorization during the installation: GitHub then comes back with code and installation id at once.
    func testSetupWithACodeFinishesInOneStep() async throws {
        try await hubFixture { f, hub, alice, _ in
            func state() async throws -> String {
                let r = try await call(f, .POST, "/v1/github/connect", ["mode": "install"], as: alice)
                return Self.query(r.body["url"] as? String ?? "", "state")
            }
            let forged = try await call(f, .POST, "/v1/github/setup", ["state": try await state(), "installationID": "222", "code": hub.code(for: "alice")], as: alice)
            XCTAssertEqual(forged.status, .forbidden, forged.text)
            XCTAssertEqual(forged.body["reason"] as? String, "github_installation_not_yours")
            let none = try await connections(f, alice)
            XCTAssertTrue(none.isEmpty)
            let done = try await call(f, .POST, "/v1/github/setup", ["state": try await state(), "installationID": "111", "code": hub.code(for: "alice")], as: alice)
            XCTAssertEqual(done.status, .ok, done.text)
            XCTAssertNil(done.body["url"], done.text)
            XCTAssertEqual((done.body["connections"] as? [Obj] ?? []).compactMap { $0["accountLogin"] as? String }, ["alice"], done.text)
        }
    }

    /// GitHub being down is said; it must not look like "you may write nowhere". And one repository is one entry, even if the operator
    /// listed it too.
    func testListingSaysWhenGitHubFailsAndOneRepositoryCountsOnce() async throws {
        try await hubFixture { f, hub, alice, _ in
            let a = try await connect(f, hub, alice, as: "alice", installation: 111)
            hub.failPermissions = 500
            let down = try await call(f, .GET, "/v1/github/connections/\(a)/repositories", as: alice)
            XCTAssertEqual(down.body["ok"] as? Bool, false, down.text)
            XCTAssertEqual(down.body["code"] as? String, "deploy_github_unavailable", down.text)
            hub.failPermissions = nil
            hub.install(777, account: "alice", accountID: 1001, type: "User")
            hub.select(777, "alice/site")
            f.app.githubApp = Self.operatorSetup(["GITHUB_APP_INSTALLATION_ID": "777", "GITHUB_APP_REPOSITORIES": "\(alice.projectID)=alice/site"])
            try await assign(f, alice, a, "alice/site")
            let r = try await publish(f, hub, alice, target: alice.targetID)
            XCTAssertEqual(r.body["ok"] as? Bool, true, r.text)
        }
    }

    // MARK: Two people, two installations

    func testTwoPeopleNeverSeeOrUseEachOthersInstallation() async throws {
        try await hubFixture { f, hub, alice, bob in
            let a = try await connect(f, hub, alice, as: "alice", installation: 111)
            let b = try await connect(f, hub, bob, as: "bob", installation: 222)

            // Seeing: only the own connection; the other one does not exist for you.
            let bobs = try await connections(f, bob)
            XCTAssertEqual(bobs.compactMap { $0["id"] as? String }, [b])
            for (method, path) in [(HTTPMethod.GET, "/v1/github/connections/\(a)/repositories"), (.DELETE, "/v1/github/connections/\(a)")] {
                let r = try await call(f, method, path, method == .DELETE ? [:] : nil, as: bob)
                XCTAssertEqual(r.status, .notFound, "\(method) \(path): \(r.text)")
            }
            let repos = try await call(f, .GET, "/v1/github/connections/\(b)/repositories", as: bob)
            XCTAssertEqual((repos.body["items"] as? [Obj] ?? []).compactMap { $0["repository"] as? String }, ["bob/site"], repos.text)
            XCTAssertFalse(repos.text.contains("alice"), repos.text)

            // Using: not with her connection, not her repository through his own, not into her project.
            let stolen = try await assign(f, bob, a, "alice/site")
            XCTAssertEqual(stolen.status, .notFound, stolen.text)
            let through = try await assign(f, bob, b, "alice/site")
            XCTAssertEqual(through.status, .forbidden, through.text)
            XCTAssertEqual(through.body["reason"] as? String, "deploy_github_repository_not_allowed")
            let intoHers = try await assign(f, bob, project: alice.projectID, b, "bob/site")
            XCTAssertEqual(intoHers.status, .notFound, intoHers.text)

            let aliceAssigned = try await assign(f, alice, a, "alice/site")
            XCTAssertEqual(aliceAssigned.status, .created, aliceAssigned.text)
            let reading = try await call(f, .GET, "/v1/projects/\(alice.projectID)/github-repositories", as: bob)
            XCTAssertEqual(reading.status, .notFound, reading.text)

            // Before bob maps anything, his target writes nowhere, although an installation with repositories exists next door.
            let before = try await publish(f, hub, bob, target: bob.targetID, base: hub.head("bob/site", "main"))
            XCTAssertEqual(before.body["code"] as? String, "deploy_github_repository_not_allowed", before.text)
            let bobAssigned = try await assign(f, bob, b, "bob/site")
            XCTAssertEqual(bobAssigned.status, .created, bobAssigned.text)

            let named = try await publish(f, hub, bob, target: bob.targetID, repo: "alice/site")
            XCTAssertEqual(named.body["code"] as? String, "deploy_github_repository_not_allowed", named.text)
            let foreignTarget = try await publish(f, hub, bob, target: alice.targetID)
            XCTAssertEqual(foreignTarget.status, .notFound, foreignTarget.text)

            hub.clearJournal()
            let hers = try await publish(f, hub, alice, target: alice.targetID)
            XCTAssertEqual(hers.body["ok"] as? Bool, true, hers.text)
            XCTAssertEqual(hers.body["repository"] as? String, "alice/site")
            XCTAssertEqual(hub.installationsUsed, [111], "only her installation")
            XCTAssertEqual(hub.repositoriesWritten, ["alice/site"])
            XCTAssertEqual(hub.refNames("bob/site"), ["main"])

            hub.clearJournal()
            let his = try await publish(f, hub, bob, target: bob.targetID, base: hub.head("bob/site", "main"))
            XCTAssertEqual(his.body["ok"] as? Bool, true, his.text)
            XCTAssertEqual(his.body["repository"] as? String, "bob/site")
            XCTAssertEqual(hub.installationsUsed, [222])
            XCTAssertEqual(hub.repositoriesWritten, ["bob/site"])
        }
    }

    // MARK: GitHub rights of the connecting person

    func testOnlyRepositoriesThePersonMayWriteCanBeMapped() async throws {
        try await hubFixture { f, hub, alice, bob in
            // carol may only read acme/web: GitHub still lists the organization's installation for her.
            let carol = try await connect(f, hub, bob, as: "carol", installation: 333)
            let list = try await call(f, .GET, "/v1/github/connections/\(carol)/repositories", as: bob)
            XCTAssertEqual(list.body["ok"] as? Bool, true, list.text)
            XCTAssertEqual((list.body["items"] as? [Obj])?.count, 0, list.text)
            XCTAssertFalse(list.text.contains("acme/docs"), "no names of repositories she cannot write")
            let denied = try await assign(f, bob, carol, "acme/web")
            XCTAssertEqual(denied.status, .forbidden, denied.text)
            XCTAssertEqual(denied.body["reason"] as? String, "deploy_github_repository_not_allowed")

            let org = try await connect(f, hub, alice, as: "alice", installation: 333)
            let hers = try await call(f, .GET, "/v1/github/connections/\(org)/repositories", as: alice)
            XCTAssertEqual((hers.body["items"] as? [Obj] ?? []).compactMap { $0["repository"] as? String }, ["acme/web"], hers.text)
            let docs = try await assign(f, alice, org, "acme/docs")
            XCTAssertEqual(docs.status, .forbidden, docs.text)

            // Public repositories are shown as such and never mapped.
            let own = try await connect(f, hub, alice, as: "alice", installation: 111)
            let all = try await call(f, .GET, "/v1/github/connections/\(own)/repositories", as: alice)
            let open = (all.body["items"] as? [Obj])?.first { $0["repository"] as? String == "alice/open" }
            XCTAssertEqual(open?["private"] as? Bool, false, all.text)
            let refused = try await assign(f, alice, own, "alice/open")
            XCTAssertEqual(refused.status, .badRequest, refused.text)
            XCTAssertEqual(refused.body["reason"] as? String, "deploy_github_repository_public")
            for name in ["", "alice", "alice/..", "alice/site?x=1", "alice/site/../../bob/site"] {
                let r = try await assign(f, alice, own, name)
                XCTAssertEqual(r.status, .badRequest, "\(name): \(r.text)")
                XCTAssertEqual(r.body["reason"] as? String, "github_repository_invalid", name)
            }
        }
    }

    func testGitHubRightsAreCheckedAgainOnEveryUse() async throws {
        try await hubFixture { f, hub, alice, _ in
            let org = try await connect(f, hub, alice, as: "alice", installation: 333)
            let made = try await assign(f, alice, org, "acme/web")
            XCTAssertEqual(made.status, .created, made.text)
            func code(line: UInt = #line) async throws -> String? {
                let r = try await publish(f, hub, alice, target: alice.targetID, base: hub.head("acme/web", "main"))
                XCTAssertEqual(r.status, .ok, r.text, line: line)
                XCTAssertEqual(r.body["ok"] as? Bool, false, r.text, line: line)
                XCTAssertEqual(hub.refNames("acme/web"), ["main"], line: line)
                return r.body["code"] as? String
            }
            hub.permission("acme/web", "alice", "read")
            let reduced = try await code()
            XCTAssertEqual(reduced, "deploy_github_repository_access_lost")
            hub.permission("acme/web", "alice", nil)
            let gone = try await code()
            XCTAssertEqual(gone, "deploy_github_repository_access_lost")
            // The login now belongs to another GitHub account (rename and re-registration).
            hub.permission("acme/web", "alice", "write")
            hub.user("alice", id: 7777)
            let reused = try await code()
            XCTAssertEqual(reused, "deploy_github_repository_access_lost")
            hub.user("alice", id: 1001)
            // Another repository under the same name (deleted and recreated).
            hub.repositoryID("acme/web", 6000)
            let replaced = try await code()
            XCTAssertEqual(replaced, "deploy_github_repository_changed")
            hub.repositoryID("acme/web", 5004)
            XCTAssertTrue(f.transport.connections.isEmpty, "the server of the target is not even read")

            // Deselected in the installation.
            hub.deselect(333, "acme/web")
            let deselected = try await code()
            XCTAssertEqual(deselected, "deploy_github_repository_removed")
            hub.select(333, "acme/web")

            hub.suspend(333, true)
            let suspended = try await code()
            XCTAssertEqual(suspended, "deploy_github_installation_suspended")
            let list = try await call(f, .GET, "/v1/github/connections/\(org)/repositories", as: alice)
            XCTAssertEqual(list.body["code"] as? String, "deploy_github_installation_suspended", list.text)
            hub.suspend(333, false)

            hub.uninstall(333)
            let uninstalled = try await code()
            XCTAssertEqual(uninstalled, "deploy_github_installation_removed")
            let after = try await call(f, .GET, "/v1/github/connections/\(org)/repositories", as: alice)
            XCTAssertEqual(after.body["ok"] as? Bool, false)
            XCTAssertEqual(after.body["code"] as? String, "deploy_github_installation_removed", after.text)

            // Removing the connection in Todolino removes its mappings; the project writes nowhere any more.
            let removed = try await call(f, .DELETE, "/v1/github/connections/\(org)", [:], as: alice)
            XCTAssertEqual(removed.status, .noContent, removed.text)
            let left = try await assigned(f, alice)
            XCTAssertTrue(left.isEmpty)
            let nothing = try await code()
            XCTAssertEqual(nothing, "deploy_github_repository_not_allowed")
        }
    }

    // MARK: Project rights

    func testMappingNeedsManageAndLastsOnlyWhileItsPersonMayManage() async throws {
        try await hubFixture { f, hub, alice, bob in
            let a = try await connect(f, hub, alice, as: "alice", installation: 111)
            let bobID = try bob.user.requireID(), aliceID = try alice.user.requireID()
            // alice helps in bob's project.
            let grant = ProjectGrant(projectID: try bob.project.requireID(), principalType: "person", principalID: aliceID, role: .edit)
            try await grant.save(on: f.app.db)
            let asEditor = try await assign(f, alice, project: bob.projectID, a, "alice/site")
            XCTAssertEqual(asEditor.status, .forbidden, asEditor.text)
            grant.role = .manage
            try await grant.save(on: f.app.db)
            let asManager = try await assign(f, alice, project: bob.projectID, a, "alice/site")
            XCTAssertEqual(asManager.status, .created, asManager.text)
            let twice = try await assign(f, alice, project: bob.projectID, a, "alice/site")
            XCTAssertEqual(twice.status, .conflict, twice.text)
            XCTAssertEqual(twice.body["reason"] as? String, "github_repository_assigned")

            // Everybody with rights on the project sees the mapping, but nobody else gets the connection behind it.
            let seen = try await assigned(f, bob)
            XCTAssertEqual(seen.count, 1)
            XCTAssertEqual(seen.first?["repository"] as? String, "alice/site")
            XCTAssertEqual(seen.first?["source"] as? String, "user")
            XCTAssertEqual(seen.first?["assignedBy"] as? String, "Alice")
            XCTAssertEqual(seen.first?["mine"] as? Bool, false)
            XCTAssertEqual(seen.first?["active"] as? Bool, true)
            XCTAssertNil(seen.first?["connectionID"])
            let still = try await connections(f, bob)
            XCTAssertTrue(still.isEmpty)

            // The mapping is how alice shares her repository with this project: bob, who owns it, may publish through it.
            let shared = try await publish(f, hub, bob, target: bob.targetID)
            XCTAssertEqual(shared.body["ok"] as? Bool, true, shared.text)

            func revoked(_ why: String, line: UInt = #line) async throws {
                hub.clearJournal()
                let r = try await publish(f, hub, bob, target: bob.targetID)
                XCTAssertEqual(r.body["code"] as? String, "deploy_github_assignment_revoked", "\(why): \(r.text)", line: line)
                XCTAssertTrue(hub.installationsUsed.isEmpty, why, line: line)
                let items = try await assigned(f, bob)
                XCTAssertEqual(items.first?["active"] as? Bool, false, why, line: line)
            }
            grant.role = .edit
            try await grant.save(on: f.app.db)
            try await revoked("only edit left")
            try await grant.delete(on: f.app.db)
            try await revoked("removed from the project")
            try await ProjectGrant(projectID: try bob.project.requireID(), principalType: "person", principalID: aliceID, role: .manage).save(on: f.app.db)
            alice.user.disabledAt = Date()
            try await alice.user.save(on: f.app.db)
            try await revoked("account locked")

            // A manager of the project may remove somebody else's mapping.
            let items = try await assigned(f, bob)
            let id = try XCTUnwrap(items.first?["id"] as? String)
            let wrongProject = try await call(f, .DELETE, "/v1/projects/\(alice.projectID)/github-repositories/\(id)", [:], as: bob)
            XCTAssertEqual(wrongProject.status, .notFound)
            let reader = try await person(f, "Rita")
            try await ProjectGrant(projectID: try bob.project.requireID(), principalType: "person", principalID: try reader.user.requireID(), role: .read).save(on: f.app.db)
            let byReader = try await call(f, .DELETE, "/v1/projects/\(bob.projectID)/github-repositories/\(id)", [:], as: reader)
            XCTAssertEqual(byReader.status, .forbidden, byReader.text)
            let byOwner = try await call(f, .DELETE, "/v1/projects/\(bob.projectID)/github-repositories/\(id)", [:], as: bob)
            XCTAssertEqual(byOwner.status, .noContent, byOwner.text)
            let empty = try await assigned(f, bob)
            XCTAssertTrue(empty.isEmpty)
            _ = bobID
        }
    }

    func testDeletingTheAccountRemovesConnectionsAndMappings() async throws {
        try await hubFixture { f, hub, alice, bob in
            let a = try await connect(f, hub, alice, as: "alice", installation: 111)
            try await ProjectGrant(projectID: try bob.project.requireID(), principalType: "person", principalID: try alice.user.requireID(), role: .manage).save(on: f.app.db)
            let made = try await assign(f, alice, project: bob.projectID, a, "alice/site")
            XCTAssertEqual(made.status, .created, made.text)
            _ = try await call(f, .POST, "/v1/github/connect", ["mode": "install"], as: alice)
            try await AccountDeletion.delete(userID: try alice.user.requireID(), on: f.app.db)
            let sql = try XCTUnwrap(f.app.db as? any SQLDatabase)
            for table in ["github_connections", "github_project_repositories", "github_connect_states"] {
                let rows = try await sql.raw("SELECT id FROM \(unsafeRaw: table)").all()
                XCTAssertEqual(rows.count, 0, table)
            }
        }
    }

    // MARK: Transition from the per-instance variables

    func testTheOldEnvironmentVariablesKeepWorkingBesideTheConnections() async throws {
        try await hubFixture { f, hub, alice, bob in
            hub.install(777, account: "operator", accountID: 2000, type: "User")
            hub.repository(777, "operator/site", id: 5100, permissions: ["operator": "admin"])
            f.app.githubApp = Self.operatorSetup(["GITHUB_APP_INSTALLATION_ID": "777", "GITHUB_APP_REPOSITORIES": "\(alice.projectID)=operator/site"])
            let legacy = try await publish(f, hub, alice, target: alice.targetID, base: hub.head("operator/site", "main"))
            XCTAssertEqual(legacy.body["ok"] as? Bool, true, legacy.text)
            XCTAssertEqual(hub.installationsUsed, [777])
            let listed = try await assigned(f, alice)
            XCTAssertEqual(listed.first?["source"] as? String, "operator", "\(listed)")
            XCTAssertEqual(listed.first?["repository"] as? String, "operator/site")
            XCTAssertNil(listed.first?["id"])
            // The operator's entry is for that project only and gives nobody a connection.
            let none = try await assigned(f, bob)
            XCTAssertTrue(none.isEmpty)
            let notHis = try await publish(f, hub, bob, target: bob.targetID, base: hub.head("operator/site", "main"))
            XCTAssertEqual(notHis.body["code"] as? String, "deploy_github_repository_not_allowed")

            // Beside a mapping from the PWA both count: the caller has to name one, each runs through its own installation.
            let a = try await connect(f, hub, alice, as: "alice", installation: 111)
            try await assign(f, alice, a, "alice/site")
            let ambiguous = try await publish(f, hub, alice, target: alice.targetID)
            XCTAssertEqual(ambiguous.body["code"] as? String, "deploy_github_repository_required", ambiguous.text)
            hub.clearJournal()
            let named = try await publish(f, hub, alice, target: alice.targetID, repo: "alice/site")
            XCTAssertEqual(named.body["ok"] as? Bool, true, named.text)
            XCTAssertEqual(hub.installationsUsed, [111])

            // Old variables alone: no connect flow.
            f.app.githubApp = GitHubAppSetup.fromEnvironment { name in
                ["GITHUB_APP_ID": "424242", "GITHUB_APP_PRIVATE_KEY": Self.hubKey.pemRepresentation, "GITHUB_APP_INSTALLATION_ID": "777",
                 "GITHUB_APP_REPOSITORIES": "\(alice.projectID)=operator/site"][name]
            }
            let overview = try await call(f, .GET, "/v1/github", as: alice)
            XCTAssertEqual(overview.body["available"] as? Bool, false, overview.text)
        }
    }

    func testAgentsPublishThroughAMappingWithoutLearningAboutTheConnection() async throws {
        try await hubFixture { f, hub, _, _ in
            // The OAuth fixture user is the person behind the agent here.
            let owner = Person(user: f.o.user, session: f.session, project: f.o.project)
            hub.user("olive", id: 1005)
            hub.install(444, account: "olive", accountID: 1005, type: "User")
            hub.repository(444, "olive/site", id: 5200, permissions: ["olive": "admin"])
            let connection = try await connect(f, hub, owner, as: "olive", installation: 444)
            let made = try await assign(f, owner, connection, "olive/site")
            XCTAssertEqual(made.status, .created, made.text)
            let target = try await f.created(["protocol": "ftps", "port": 21])
            let writer = try await f.o.tokens(scope: "projects:read projects:write").access
            let r = try await f.mcp(writer, "open_server_changes_pr",
                                    ["targetID": try XCTUnwrap(target["id"] as? String), "files": [], "baseCommit": hub.head("olive/site", "main")])
            XCTAssertEqual(r.json?["ok"] as? Bool, true, r.text)
            for hidden in [connection, "444", "installation", "ghs_", "ghu_", "connectionID"] {
                XCTAssertFalse(r.text.contains(hidden), hidden)
            }
        }
    }
}

/// GitHub with several users, installations and repositories. Each repository's git calls are answered by its own `FakeGitHub`;
/// this double checks the tokens in front of it: a token of one installation reaches only that installation's repositories.
final class FakeGitHubHub: GitHubTransport, @unchecked Sendable {
    private struct Installation { var account: String; var accountID: Int; var type: String; var repositories: [String] = []; var suspended = false }
    private struct Repository { var id: Int; var isPrivate: Bool; var permissions: [String: String]; let git: FakeGitHub; var ownerID: Int }
    private struct Token { let installation: Int; let repositories: [String]?; let permissions: [String: String] }

    private let lock = NSLock()
    private let publicKey: _RSA.Signing.PublicKey
    private let appID: Int, clientID: String, clientSecret: String
    private var users: [String: Int] = [:], codes: [String: String] = [:], userTokens: [String: String] = [:]
    private var installations: [Int: Installation] = [:], repositories: [String: Repository] = [:], tokens: [String: Token] = [:]
    private var counter = 0
    private var omitAppID = false
    private var _used: [Int] = [], _written: [String] = []

    init(publicKey: _RSA.Signing.PublicKey, appID: Int, clientID: String, clientSecret: String) {
        self.publicKey = publicKey; self.appID = appID; self.clientID = clientID; self.clientSecret = clientSecret
    }

    // MARK: Setting up and changing GitHub

    func user(_ login: String, id: Int) { lock.withLock { users[login] = id } }
    /// Some answers of GitHub name no app at all: the backend must not take those installations for its own.
    func leaveOutAppID(_ value: Bool) { lock.withLock { omitAppID = value } }
    func install(_ id: Int, account: String, accountID: Int, type: String) {
        lock.withLock { installations[id] = Installation(account: account, accountID: accountID, type: type) }
    }
    func repository(_ installation: Int, _ name: String, id: Int, isPrivate: Bool = true, permissions: [String: String]) {
        let git = FakeGitHub(publicKey: publicKey, files: ["about.php": .init("alt\n")], repository: name)
        git.isPrivate = isPrivate
        lock.withLock {
            repositories[name] = Repository(id: id, isPrivate: isPrivate, permissions: permissions, git: git, ownerID: installations[installation]!.accountID)
            installations[installation]!.repositories.append(name)
        }
    }
    func permission(_ repository: String, _ login: String, _ value: String?) { lock.withLock { repositories[repository]!.permissions[login] = value } }
    func repositoryID(_ repository: String, _ id: Int) { lock.withLock { repositories[repository]!.id = id } }
    func deselect(_ installation: Int, _ name: String) { lock.withLock { installations[installation]!.repositories.removeAll { $0 == name } } }
    func select(_ installation: Int, _ name: String) { lock.withLock { installations[installation]!.repositories.append(name) } }
    private var _failPermissions: Int?
    var failPermissions: Int? { get { lock.withLock { _failPermissions } } set { lock.withLock { _failPermissions = newValue } } }
    func suspend(_ installation: Int, _ value: Bool) { lock.withLock { installations[installation]!.suspended = value } }
    func uninstall(_ installation: Int) { lock.withLock { installations[installation] = nil; tokens = tokens.filter { $0.value.installation != installation } } }
    func code(for login: String) -> String {
        lock.withLock { counter += 1; let code = "code-\(login)-\(counter)-xyz"; codes[code] = login; return code }
    }

    // MARK: What happened

    func clearJournal() { lock.withLock { _used = []; _written = [] } }
    var installationsUsed: [Int] { lock.withLock { Array(Set(_used)).sorted() } }
    var repositoriesWritten: [String] { lock.withLock { Array(Set(_written)).sorted() } }
    func head(_ repository: String, _ branch: String) -> String { lock.withLock { repositories[repository]?.git }?.head(branch) ?? "" }
    func refNames(_ repository: String) -> [String] { lock.withLock { repositories[repository]?.git }?.refNames ?? [] }

    // MARK: REST

    private static func answer(_ status: Int, _ object: Any) -> GitHubHTTPResponse {
        GitHubHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func appJWT(_ bearer: String) -> Bool {
        let parts = bearer.split(separator: ".").map(String.init)
        func decode(_ s: String) -> Data? {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)
        }
        guard parts.count == 3, let signature = decode(parts[2]) else { return false }
        return publicKey.isValidSignature(.init(rawRepresentation: signature), for: SHA256.hash(data: Data("\(parts[0]).\(parts[1])".utf8)),
                                          padding: .insecurePKCS1v1_5)
    }

    private func installationBody(_ id: Int, _ i: Installation) -> [String: Any] {
        var body: [String: Any] = ["id": id, "account": ["login": i.account, "id": i.accountID, "type": i.type],
                                   "suspended_at": i.suspended ? "2026-11-28T00:00:00Z" : NSNull()]
        if !omitAppID { body["app_id"] = appID }
        return body
    }

    private enum Next { case done(GitHubHTTPResponse), repository(FakeGitHub, GitHubHTTPRequest) }

    func send(_ r: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        switch lock.withLock({ route(r) }) {
        case .done(let response): return response
        case .repository(let git, let forwarded):
            // The inner double has its own fixed installation token and its own fake app JWT check.
            return try await git.send(forwarded)
        }
    }

    private func route(_ r: GitHubHTTPRequest) -> Next {
        let method = r.method.rawValue
        let components = URLComponents(string: r.url)!
        let path = components.path
        let json = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let bearer = String((r.headers["Authorization"] ?? "").dropFirst("Bearer ".count))
        let missing = Next.done(Self.answer(404, ["message": "Not Found"]))

        if components.host == "github.com" {
            guard method == "POST", path == "/login/oauth/access_token" else { return missing }
            guard json["client_id"] as? String == clientID, json["client_secret"] as? String == clientSecret,
                  let code = json["code"] as? String, let login = codes.removeValue(forKey: code) else {
                return .done(Self.answer(200, ["error": "bad_verification_code"]))
            }
            counter += 1
            let token = "ghu_USERTOKENgeheim\(counter)"
            userTokens[token] = login
            return .done(Self.answer(200, ["access_token": token, "token_type": "bearer"]))
        }
        if path == "/user" || path == "/user/installations" {
            guard let login = userTokens[bearer], let id = users[login] else { return .done(Self.answer(401, ["message": "Bad credentials"])) }
            if path == "/user" { return .done(Self.answer(200, ["id": id, "login": login])) }
            // Like GitHub: the own account and every installation with a repository the user can at least read.
            let visible = installations.filter { _, i in
                i.accountID == id || i.repositories.contains { repositories[$0]?.permissions[login] != nil }
            }.sorted { $0.key < $1.key }
            return .done(Self.answer(200, ["total_count": visible.count, "installations": visible.map { installationBody($0.key, $0.value) }]))
        }
        if path.hasPrefix("/app/installations/") {
            guard appJWT(bearer) else { return .done(Self.answer(401, ["message": "bad jwt"])) }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3, let id = Int(parts[2]), let i = installations[id] else { return missing }
            if parts.count == 3, method == "GET" { return .done(Self.answer(200, installationBody(id, i))) }
            guard parts.count == 4, parts[3] == "access_tokens", method == "POST" else { return missing }
            if i.suspended { return .done(Self.answer(403, ["message": "This installation has been suspended"])) }
            var scope: [String]?
            if let names = json["repositories"] as? [String] {
                let full = names.map { "\(i.account)/\($0)" }
                guard full.allSatisfy({ i.repositories.contains($0) }) else { return .done(Self.answer(422, ["message": "not accessible"])) }
                scope = full
            }
            counter += 1
            let token = "ghs_INSTALLtokengeheim\(id)n\(counter)"
            tokens[token] = Token(installation: id, repositories: scope, permissions: json["permissions"] as? [String: String] ?? [:])
            _used.append(id)
            return .done(Self.answer(201, ["token": token]))
        }
        guard let token = tokens[bearer], let i = installations[token.installation] else { return .done(Self.answer(401, ["message": "bad token"])) }
        let reachable = i.repositories.filter { token.repositories?.contains($0) ?? true }
        if path == "/installation/repositories" {
            let list: [[String: Any]] = reachable.sorted().map { name in
                let repo = repositories[name]!
                return ["id": repo.id, "full_name": name, "private": repo.isPrivate, "owner": ["id": repo.ownerID]]
            }
            return .done(Self.answer(200, ["total_count": list.count, "repositories": list]))
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "repos" else { return missing }
        let name = "\(parts[1])/\(parts[2])"
        guard let repo = repositories[name], reachable.contains(name) || (!repo.isPrivate && method == "GET") else { return missing }
        if parts.count == 3, method == "GET" {
            return .done(Self.answer(200, ["id": repo.id, "full_name": name, "private": repo.isPrivate, "default_branch": "main", "owner": ["id": repo.ownerID]]))
        }
        if parts.count == 6, parts[3] == "collaborators", parts[5] == "permission", method == "GET" {
            if let status = _failPermissions { return .done(Self.answer(status, ["message": "boom"])) }
            guard let userID = users[parts[4]] else { return missing }
            return .done(Self.answer(200, ["permission": repo.permissions[parts[4]] ?? "none", "user": ["id": userID, "login": parts[4]]]))
        }
        if method != "GET" {
            guard reachable.contains(name), token.permissions["contents"] == "write" else { return .done(Self.answer(403, ["message": "Resource not accessible"])) }
            _written.append(name)
        }
        // The git part: hand over to the repository's double with the token it expects.
        var headers = r.headers
        headers["Authorization"] = "Bearer \(FakeGitHub.token)"
        return .repository(repo.git, GitHubHTTPRequest(method: r.method, url: r.url, headers: headers, body: r.body))
    }
}
