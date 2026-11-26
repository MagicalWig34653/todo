import Crypto
import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card BEF08998 part 2 (ADR 0036): a new sign-in of the same client by the same person takes over the project list and the
/// active brain mandate of the previous connection, but only through the consent step of the signed-in person.
final class OAuthTakeoverTests: XCTestCase {
    private typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)
    private static let scopes = "projects:read projects:write tasks:read tasks:write comments:write agents:read"
    private static let loopback = "http://127.0.0.1:54321/callback"

    private struct Login {
        let grant: UUID
        let client: String
        let access: String, refresh: String
    }

    private func run(_ body: (OAuthFixture) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { try await body(f) } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func register(_ f: OAuthFixture, name: String = "Test Client", redirect: String = loopback) async throws -> String {
        let r = try await f.test.json(.POST, "/oauth/register", ["client_name": name, "redirect_uris": [redirect]])
        return try XCTUnwrap(r.body?["client_id"] as? String)
    }

    private func authorize(_ f: OAuthFixture, client: String? = nil, redirect: String = loopback, session: String? = nil, scope: String = scopes) async throws -> [String: Any] {
        let challenge = Data(SHA256.hash(data: Data(f.verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(); url.path = "/oauth/authorize"
        url.queryItems = ["response_type": "code", "client_id": client ?? f.clientID, "redirect_uri": redirect, "scope": scope,
            "state": "s", "resource": f.test.settings.oauthResource, "code_challenge": challenge, "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let r = try await f.test.json(.GET, url.string!, token: session ?? f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body)
    }

    private func consent(_ f: OAuthFixture, _ auth: [String: Any], projects: [String], takeover: String? = nil, approve: Bool = true, session: String? = nil) async throws -> Reply {
        var body: [String: Any] = ["consent_token": try XCTUnwrap(auth["consent_token"]), "approve": approve, "project_ids": projects]
        if let takeover { body["takeover_grant_id"] = takeover }
        return try await f.test.json(.POST, "/oauth/consent", body, token: session ?? f.session)
    }

    private func grants(_ f: OAuthFixture) async throws -> [OAuthGrant] { try await OAuthGrant.query(on: f.test.app.db).all() }

    /// Finishes an approved consent: exchanges the code and returns the new connection.
    private func finish(_ f: OAuthFixture, _ reply: Reply, client: String, redirect: String = loopback, before: Set<UUID>) async throws -> Login {
        XCTAssertEqual(reply.status, .ok, "\(reply.body ?? [:])")
        let callback = try XCTUnwrap(reply.body?["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: callback)?.queryItems?.first { $0.name == "code" }?.value)
        let t = try await f.test.json(.POST, "/oauth/token", ["grant_type": "authorization_code", "client_id": client,
            "resource": f.test.settings.oauthResource, "code": code, "redirect_uri": redirect, "code_verifier": f.verifier])
        XCTAssertEqual(t.status, .ok, "\(t.body ?? [:])")
        let new = try await grants(f).compactMap(\.id).filter { !before.contains($0) }
        XCTAssertEqual(new.count, 1)
        return Login(grant: try XCTUnwrap(new.first), client: client, access: try XCTUnwrap(t.body?["access_token"] as? String),
                     refresh: try XCTUnwrap(t.body?["refresh_token"] as? String))
    }

    /// One sign-in; `takeOver` accepts the offered takeover with the offered projects, as the consent page preselects it.
    private func login(_ f: OAuthFixture, client: String? = nil, redirect: String = loopback, projects: [String] = [], takeOver: Bool = false, scope: String = scopes) async throws -> Login {
        let auth = try await authorize(f, client: client, redirect: redirect, scope: scope)
        let offer = auth["takeover"] as? [String: Any]
        if takeOver { XCTAssertNotNil(offer, "a takeover must be offered") }
        let ids = takeOver ? (offer?["project_ids"] as? [String] ?? []) : projects
        let before = Set(try await grants(f).compactMap(\.id))
        let reply = try await consent(f, auth, projects: ids, takeover: takeOver ? offer?["grant_id"] as? String : nil)
        return try await finish(f, reply, client: client ?? f.clientID, redirect: redirect, before: before)
    }

    private func pid(_ p: Project) throws -> String { try p.requireID().uuidString }

    private func mandate(_ f: OAuthFixture, _ grant: UUID, _ projects: [Project]) async throws {
        let r = try await f.test.json(.PUT, "/v1/settings/brain-mandate",
            ["grantID": grant.uuidString, "projectIDs": try projects.map(pid)], token: f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func mandates(_ f: OAuthFixture) async throws -> [[String: Any]] {
        let r = try await f.test.json(.GET, "/v1/settings/brain-mandate", token: f.session)
        return r.body?["mandates"] as? [[String: Any]] ?? []
    }

    private func mandate(of grant: UUID, _ f: OAuthFixture) async throws -> [String: Any]? {
        try await mandates(f).first { ($0["grantID"] as? String)?.uppercased() == grant.uuidString }
    }

    private func ids(_ value: Any?) -> Set<String> { Set((value as? [String] ?? []).map { $0.uppercased() }) }

    private func audit(_ f: OAuthFixture) async throws -> [[String: Any]] {
        let r = try await f.test.json(.GET, "/v1/settings/brain-mandate/audit", token: f.session)
        return r.body?["items"] as? [[String: Any]] ?? []
    }

    private func grant(_ f: OAuthFixture, _ id: UUID) async throws -> OAuthGrant {
        let g = try await OAuthGrant.find(id, on: f.test.app.db)
        return try XCTUnwrap(g)
    }

    private func reason(_ f: OAuthFixture, _ id: UUID) async throws -> String? {
        let sql = try XCTUnwrap(f.test.app.db as? any SQLDatabase)
        let row = try await sql.raw("SELECT revoked_reason FROM oauth_grants WHERE id = \(bind: id)").first()
        return try row?.decode(column: "revoked_reason", as: String?.self)
    }

    /// Replay detection as it really happens: the old token comes back after its successor was used.
    private func replay(_ f: OAuthFixture, _ login: Login) async throws {
        func refresh(_ raw: String) async throws -> Reply {
            try await f.test.json(.POST, "/oauth/token", ["grant_type": "refresh_token", "client_id": login.client,
                "resource": f.test.settings.oauthResource, "refresh_token": raw])
        }
        let second = try await refresh(login.refresh)
        _ = try await refresh(try XCTUnwrap(second.body?["refresh_token"] as? String))
        let r = try await refresh(login.refresh)
        XCTAssertEqual(r.status, .badRequest)
        let g = try await grant(f, login.grant)
        XCTAssertTrue(g.revoked)
    }

    // MARK: Takeover

    func testSameClientSignInTakesOverProjectsAndMandate() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project), try pid(f.other)])
            try await mandate(f, old.grant, [f.project, f.other])
            let auth = try await authorize(f)
            let offer = try XCTUnwrap(auth["takeover"] as? [String: Any])
            XCTAssertEqual((offer["grant_id"] as? String)?.uppercased(), old.grant.uuidString)
            XCTAssertEqual(offer["name"] as? String, "Test Client")
            XCTAssertEqual(offer["match"] as? String, "client")
            XCTAssertEqual(offer["reason"] as? String, "active")
            XCTAssertEqual(ids(offer["project_ids"]), [try pid(f.project), try pid(f.other)])
            XCTAssertEqual(ids((offer["mandate"] as? [String: Any])?["project_ids"]), [try pid(f.project), try pid(f.other)])
            // Merely opening the consent page changes nothing.
            let untouched = try await mandate(of: old.grant, f)
            XCTAssertEqual(untouched?["active"] as? Bool, true)

            let new = try await login(f, takeOver: true)
            let g = try await grant(f, new.grant)
            XCTAssertEqual(Set(g.explicitProjects.map(\.uuidString)), [try pid(f.project), try pid(f.other)])
            let previous = try await grant(f, old.grant)
            XCTAssertTrue(previous.revoked)
            let why = try await reason(f, old.grant)
            XCTAssertEqual(why, "superseded")
            let dead = try await f.rpc("tools/list", access: old.access)
            XCTAssertEqual(dead.status, .unauthorized)

            let foundNew = try await mandate(of: new.grant, f)
            let m = try XCTUnwrap(foundNew)
            XCTAssertEqual(m["active"] as? Bool, true)
            XCTAssertEqual(ids(m["projectIDs"]), [try pid(f.project), try pid(f.other)])
            XCTAssertEqual((m["takenOver"] as? [String: Any])?["fromName"] as? String, "Test Client")
            let foundOld = try await mandate(of: old.grant, f)
            XCTAssertEqual(foundOld?["active"] as? Bool, false)
            XCTAssertEqual(foundOld?["grantRevokedReason"] as? String, "superseded")

            let rows = try await audit(f).filter { $0["kind"] as? String == "mandate.taken_over" }
            XCTAssertEqual(ids(rows.compactMap { $0["projectID"] as? String }), [try pid(f.project), try pid(f.other)])
            XCTAssertEqual((rows.first?["grantID"] as? String)?.uppercased(), new.grant.uuidString)
            XCTAssertEqual((rows.first?["subjectID"] as? String)?.uppercased(), old.grant.uuidString)
            XCTAssertTrue((rows.first?["quote"] as? String)?.contains("Test Client") == true)

            let connection = try await f.rpc("tools/call", ["name": "get_connection", "arguments": [String: Any]()], access: new.access)
            let text = (((connection.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            XCTAssertEqual((json?["brainMandate"] as? [String: Any])?["active"] as? Bool, true)
        }
    }

    func testReplayRevokedConnectionIsOfferedAndHandedOver() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            try await replay(f, old)
            let auth = try await authorize(f)
            XCTAssertEqual((auth["takeover"] as? [String: Any])?["reason"] as? String, "replay")
            let new = try await login(f, takeOver: true)
            let m = try await mandate(of: new.grant, f)
            XCTAssertEqual(m?["active"] as? Bool, true)
            // The locked-out branch stays locked out.
            let dead = try await f.rpc("tools/list", access: old.access)
            XCTAssertEqual(dead.status, .unauthorized)
        }
    }

    func testNothingIsTakenOverWithoutTheExplicitChoice() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            let auth = try await authorize(f)
            let denied = try await consent(f, auth, projects: [], takeover: old.grant.uuidString, approve: false)
            XCTAssertEqual(denied.status, .ok)
            let new = try await login(f, projects: [try pid(f.project)])
            let none = try await mandate(of: new.grant, f)
            XCTAssertNil(none)
            let kept = try await mandate(of: old.grant, f)
            XCTAssertEqual(kept?["active"] as? Bool, true)
        }
    }

    // MARK: Match by name

    func testNewClientWithTheSameNameTakesOverOnlyADeadLoopbackConnection() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            let second = try await register(f, redirect: "http://localhost:4444/callback")
            let whileAlive = try await authorize(f, client: second, redirect: "http://localhost:4444/callback")
            XCTAssertNil(whileAlive["takeover"], "a working connection is never replaced by name")
            try await replay(f, old)
            let auth = try await authorize(f, client: second, redirect: "http://localhost:4444/callback")
            XCTAssertEqual((auth["takeover"] as? [String: Any])?["match"] as? String, "name")

            let web = try await register(f, redirect: "https://evil.example/callback")
            let remote = try await authorize(f, client: web, redirect: "https://evil.example/callback")
            XCTAssertNil(remote["takeover"], "never by name for a non-loopback redirect")
            let rejected = try await consent(f, remote, projects: [try pid(f.project)], takeover: old.grant.uuidString)
            XCTAssertEqual(rejected.status, .conflict)

            let other = try await register(f, name: "Test Client 2")
            let different = try await authorize(f, client: other)
            XCTAssertNil(different["takeover"])

            let new = try await login(f, client: second, redirect: "http://localhost:4444/callback", takeOver: true)
            let m = try await mandate(of: new.grant, f)
            XCTAssertEqual(m?["active"] as? Bool, true)
        }
    }

    func testOldNonLoopbackClientIsNotMatchedByName() async throws {
        try await run { f in
            let web = try await register(f, redirect: "https://app.example/callback")
            let old = try await login(f, client: web, redirect: "https://app.example/callback", projects: [try pid(f.project)])
            try await replay(f, old)
            let auth = try await authorize(f)
            XCTAssertNil(auth["takeover"])
        }
    }

    func testSeveralMatchesOfferNothing() async throws {
        try await run { f in
            let a = try await login(f, projects: [try pid(f.project)])
            let b = try await login(f, projects: [try pid(f.other)])
            let auth = try await authorize(f)
            XCTAssertNil(auth["takeover"])
            XCTAssertEqual(auth["takeover_ambiguous"] as? Bool, true)
            for old in [a, b] {
                let r = try await consent(f, auth, projects: [try pid(f.project)], takeover: old.grant.uuidString)
                XCTAssertEqual(r.status, .conflict)
            }
            let count = try await grants(f).filter { !$0.revoked }.count
            XCTAssertEqual(count, 2)
        }
    }

    // MARK: Never

    private func assertNoOffer(_ f: OAuthFixture, _ old: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try await grants(f).count
        let auth = try await authorize(f)
        XCTAssertNil(auth["takeover"], file: file, line: line)
        let r = try await consent(f, auth, projects: [try pid(f.project)], takeover: old.uuidString)
        XCTAssertEqual(r.status, .conflict, "\(r.body ?? [:])", file: file, line: line)
        let after = try await grants(f).count
        XCTAssertEqual(after, before, "a refused takeover creates nothing", file: file, line: line)
    }

    func testConnectionRevokedByThePersonIsNeverTakenOver() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            _ = try await f.test.json(.DELETE, "/oauth/grants/\(old.grant)", token: f.session)
            try await assertNoOffer(f, old.grant)
        }
    }

    func testPersonCanEndARecoverableConnection() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await replay(f, old)
            let r = try await f.test.json(.DELETE, "/oauth/grants/\(old.grant)", token: f.session)
            XCTAssertEqual(r.status, .noContent)
            try await assertNoOffer(f, old.grant)
        }
    }

    /// Rows revoked before the reason was stored cannot be told apart from a revocation by the person.
    func testRevocationWithoutAStoredReasonIsNeverTakenOver() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            let sql = try XCTUnwrap(f.test.app.db as? any SQLDatabase)
            try await sql.raw("UPDATE oauth_grants SET revoked = \(bind: true), revoked_reason = NULL").run()
            try await assertNoOffer(f, old.grant)
        }
    }

    func testAccountLockEndsEveryTakeover() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await replay(f, old)
            let id = try f.user.requireID()
            try await AccountLock.apply(.disable, userID: id, actor: f.user, allowSelf: true, on: f.test.app.db)
            try await AccountLock.apply(.enable, userID: id, actor: f.user, allowSelf: true, on: f.test.app.db)
            let session = AuthSupport.randomToken()
            try await UserSession(userID: id, tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
            let auth = try await authorize(f, session: session)
            XCTAssertNil(auth["takeover"])
            let why = try await reason(f, old.grant)
            XCTAssertEqual(why, "account_locked")
        }
    }

    func testAnotherPersonsConnectionIsNeverTakenOver() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let session = AuthSupport.randomToken()
            try await UserSession(userID: stranger.requireID(), tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
            let mine = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Mine"); try await mine.save(on: f.test.app.db)
            let auth = try await authorize(f, session: session)
            XCTAssertNil(auth["takeover"])
            XCTAssertNil(auth["takeover_ambiguous"])
            let r = try await consent(f, auth, projects: [try pid(mine)], takeover: old.grant.uuidString, session: session)
            XCTAssertEqual(r.status, .conflict)
            let kept = try await mandate(of: old.grant, f)
            XCTAssertEqual(kept?["active"] as? Bool, true)
        }
    }

    func testMandateRevokedByThePersonStaysRevoked() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            _ = try await f.test.json(.DELETE, "/v1/settings/brain-mandate/\(old.grant)", token: f.session)
            let auth = try await authorize(f)
            XCTAssertNil((auth["takeover"] as? [String: Any])?["mandate"] as? [String: Any])
            let new = try await login(f, takeOver: true)
            let m = try await mandate(of: new.grant, f)
            XCTAssertNil(m)
            let rows = try await audit(f)
            XCTAssertFalse(rows.contains { $0["kind"] as? String == "mandate.taken_over" })
            XCTAssertTrue(rows.contains { $0["kind"] as? String == "connection.taken_over" })
        }
    }

    // MARK: Between page and click

    func testStateIsCheckedAgainAtTheClick() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])

            // Widened after the page was shown: only what the page showed is handed over.
            let first = try await authorize(f)
            try await mandate(f, old.grant, [f.project, f.other])
            var before = Set(try await grants(f).compactMap(\.id))
            let a = try await finish(f, try await consent(f, first, projects: [try pid(f.project)], takeover: old.grant.uuidString), client: f.clientID, before: before)
            let m = try await mandate(of: a.grant, f)
            XCTAssertEqual(ids(m?["projectIDs"]), [try pid(f.project)])

            // Revoked after the page was shown: no mandate.
            let second = try await authorize(f)
            _ = try await f.test.json(.DELETE, "/v1/settings/brain-mandate/\(a.grant)", token: f.session)
            before = Set(try await grants(f).compactMap(\.id))
            let b = try await finish(f, try await consent(f, second, projects: [try pid(f.project)], takeover: a.grant.uuidString), client: f.clientID, before: before)
            let none = try await mandate(of: b.grant, f)
            XCTAssertNil(none)

            // The connection revoked after the page was shown: the click is refused.
            let third = try await authorize(f)
            _ = try await f.test.json(.DELETE, "/oauth/grants/\(b.grant)", token: f.session)
            let count = try await grants(f).count
            let r = try await consent(f, third, projects: [try pid(f.project)], takeover: b.grant.uuidString)
            XCTAssertEqual(r.status, .conflict)
            let after = try await grants(f).count
            XCTAssertEqual(after, count)
        }
    }

    /// MariaDB row locks: two clicks for the same connection at the same moment hand it over exactly once.
    func testTwoClicksAtOnceTakeOverOnce() async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("MariaDB row locks required") }
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            let first = try await authorize(f), second = try await authorize(f)
            let tokens = [try XCTUnwrap(first["consent_token"] as? String), try XCTUnwrap(second["consent_token"] as? String)]
            let project = try pid(f.project), grant = old.grant.uuidString
            let statuses = try await withThrowingTaskGroup(of: UInt.self) { group in
                for token in tokens {
                    group.addTask {
                        try await f.test.json(.POST, "/oauth/consent",
                            ["consent_token": token, "approve": true, "project_ids": [project], "takeover_grant_id": grant], token: f.session).status.code
                    }
                }
                var out: [UInt] = []
                for try await status in group { out.append(status) }
                return out
            }
            XCTAssertEqual(statuses.sorted(), [200, 409])
            let active = try await mandates(f).filter { $0["active"] as? Bool == true }
            XCTAssertEqual(active.count, 1)
        }
    }

    // MARK: Limits of what moves

    func testUncheckedProjectsLeaveTheMandateAndScopesComeFromTheNewSignIn() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project), try pid(f.other)])
            try await mandate(f, old.grant, [f.project, f.other])
            let auth = try await authorize(f, scope: "projects:read tasks:read")
            let before = Set(try await grants(f).compactMap(\.id))
            let new = try await finish(f, try await consent(f, auth, projects: [try pid(f.project)], takeover: old.grant.uuidString), client: f.clientID, before: before)
            let g = try await grant(f, new.grant)
            XCTAssertEqual(g.scopes, ["projects:read", "tasks:read"])
            let m = try await mandate(of: new.grant, f)
            XCTAssertEqual(ids(m?["projectIDs"]), [try pid(f.project)])
        }
    }

    func testProjectsThePersonCanNoLongerReadAreNotTakenOver() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project), try pid(f.other)])
            try await mandate(f, old.grant, [f.project, f.other])
            let stranger = User(displayName: "New Owner", isAdmin: false); try await stranger.save(on: f.test.app.db)
            f.other.ownerID = try stranger.requireID(); try await f.other.save(on: f.test.app.db)
            let auth = try await authorize(f)
            let offer = try XCTUnwrap(auth["takeover"] as? [String: Any])
            XCTAssertEqual(ids(offer["project_ids"]), [try pid(f.project)])
            XCTAssertEqual(ids((offer["mandate"] as? [String: Any])?["project_ids"]), [try pid(f.project)])
            let new = try await login(f, takeOver: true)
            let m = try await mandate(of: new.grant, f)
            XCTAssertEqual(ids(m?["projectIDs"]), [try pid(f.project)])
        }
    }

    /// ADR 0032: a connection never decides its own requests. A new sign-in of the same client is still that requester.
    func testTheNewConnectionCannotDecideThePredecessorsOwnRequests() async throws {
        try await run { f in
            let old = try await login(f, projects: [try pid(f.project)], scope: CommandCenterTests.scopes)
            try await mandate(f, old.grant, [f.project])
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Own", details: "")
            try await task.save(on: f.test.app.db)
            func call(_ token: String, _ name: String, _ args: [String: Any]) async throws -> String {
                let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: token)
                let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
                return try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            }
            let id = try task.requireID().uuidString
            let asked = try await call(old.access, "ask_question", ["taskID": id, "prompt": "A?", "options": ["A", "B"]])
            let question = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(asked.utf8)) as? [String: Any])?["id"] as? String)
            _ = try await call(old.access, "request_review", ["taskID": id, "summary": "Done"])
            let first = try await login(f, takeOver: true, scope: CommandCenterTests.scopes)
            // Also after a second re-login (the chain counts, not only the direct predecessor).
            let new = try await login(f, takeOver: true, scope: CommandCenterTests.scopes)
            XCTAssertNotEqual(first.grant, new.grant)
            let decided = try await call(new.access, "decide_review", ["taskID": id, "decision": "accept", "quote": "ok"])
            XCTAssertTrue(decided.contains("cannot_decide_own_review"), decided)
            let answered = try await call(new.access, "answer_question", ["questionID": question, "answer": "A", "quote": "ok"])
            XCTAssertTrue(answered.contains("cannot_answer_own_question"), answered)
        }
    }
}
