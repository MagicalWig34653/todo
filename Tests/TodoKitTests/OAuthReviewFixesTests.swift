import Crypto
import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Security review of card BEF08998 (ADR 0036, 26.11.2026): limits of the reuse window, of the takeover offer and of what a
/// takeover hands over, and the protocol of all three.
final class OAuthReviewFixesTests: XCTestCase {
    private typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)
    private static let loopback = "http://127.0.0.1:54321/callback"
    private struct Login { let grant: UUID; let client: String; let access: String; let refresh: String }

    private func run(_ body: (OAuthFixture) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { try await body(f) } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func pid(_ p: Project) throws -> String { try p.requireID().uuidString }
    private func ids(_ value: Any?) -> Set<String> { Set((value as? [String] ?? []).map { $0.uppercased() }) }
    private func sql(_ f: OAuthFixture) throws -> any SQLDatabase { try XCTUnwrap(f.test.app.db as? any SQLDatabase) }

    private func register(_ f: OAuthFixture, name: String?) async throws -> String {
        var body: [String: Any] = ["redirect_uris": [Self.loopback]]
        if let name { body["client_name"] = name }
        let r = try await f.test.json(.POST, "/oauth/register", body)
        return try XCTUnwrap(r.body?["client_id"] as? String)
    }

    private func authorize(_ f: OAuthFixture, client: String) async throws -> [String: Any] {
        let challenge = Data(SHA256.hash(data: Data(f.verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(); url.path = "/oauth/authorize"
        url.queryItems = ["response_type": "code", "client_id": client, "redirect_uri": Self.loopback, "scope": "projects:read tasks:read",
            "state": "s", "resource": f.test.settings.oauthResource, "code_challenge": challenge, "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let r = try await f.test.json(.GET, url.string!, token: f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body)
    }

    private func consent(_ f: OAuthFixture, _ auth: [String: Any], projects: [String], takeover: UUID? = nil) async throws -> Reply {
        var body: [String: Any] = ["consent_token": try XCTUnwrap(auth["consent_token"]), "approve": true, "project_ids": projects]
        if let takeover { body["takeover_grant_id"] = takeover.uuidString }
        return try await f.test.json(.POST, "/oauth/consent", body, token: f.session)
    }

    private func login(_ f: OAuthFixture, client: String, projects: [String], takeover: UUID? = nil) async throws -> Login {
        let auth = try await authorize(f, client: client)
        let before = Set(try await OAuthGrant.query(on: f.test.app.db).all().compactMap(\.id))
        let reply = try await consent(f, auth, projects: projects, takeover: takeover)
        XCTAssertEqual(reply.status, .ok, "\(reply.body ?? [:])")
        let callback = try XCTUnwrap(reply.body?["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: callback)?.queryItems?.first { $0.name == "code" }?.value)
        let t = try await f.test.json(.POST, "/oauth/token", ["grant_type": "authorization_code", "client_id": client,
            "resource": f.test.settings.oauthResource, "code": code, "redirect_uri": Self.loopback, "code_verifier": f.verifier])
        XCTAssertEqual(t.status, .ok, "\(t.body ?? [:])")
        let new = try await OAuthGrant.query(on: f.test.app.db).all().compactMap(\.id).filter { !before.contains($0) }
        return Login(grant: try XCTUnwrap(new.first), client: client, access: try XCTUnwrap(t.body?["access_token"] as? String),
                     refresh: try XCTUnwrap(t.body?["refresh_token"] as? String))
    }

    private func refresh(_ f: OAuthFixture, _ login: Login, _ raw: String) async throws -> Reply {
        try await f.test.json(.POST, "/oauth/token", ["grant_type": "refresh_token", "client_id": login.client,
            "resource": f.test.settings.oauthResource, "refresh_token": raw])
    }

    private func mandate(_ f: OAuthFixture, _ grant: UUID, _ projects: [Project]) async throws {
        let r = try await f.test.json(.PUT, "/v1/settings/brain-mandate", ["grantID": grant.uuidString, "projectIDs": try projects.map(pid)], token: f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func mandateProjects(_ f: OAuthFixture, of grant: UUID) async throws -> Set<String>? {
        let r = try await f.test.json(.GET, "/v1/settings/brain-mandate", token: f.session)
        let m = (r.body?["mandates"] as? [[String: Any]])?.first { ($0["grantID"] as? String)?.uppercased() == grant.uuidString }
        return m.map { ids($0["projectIDs"]) }
    }

    /// The old token comes back after its successor was used: the connection is revoked by replay detection.
    private func replay(_ f: OAuthFixture, _ login: Login) async throws {
        let second = try await refresh(f, login, login.refresh)
        _ = try await refresh(f, login, try XCTUnwrap(second.body?["refresh_token"] as? String))
        let r = try await refresh(f, login, login.refresh)
        XCTAssertEqual(r.status, .badRequest)
    }

    private func revokedReason(_ f: OAuthFixture, _ grant: UUID) async throws -> String? {
        let row = try await sql(f).raw("SELECT revoked_reason FROM oauth_grants WHERE id = \(bind: grant)").first()
        return try row?.decode(column: "revoked_reason", as: String?.self)
    }

    // MARK: Reuse window

    /// Every repeat makes one more sibling; the number per token stays bounded (ADR 0040: 50, enough for many sessions that
    /// find the same stored token; before: 5).
    func testATokenMayBeRepeatedAtMostFiftyTimes() async throws {
        try await run { f in
            let first = try await login(f, client: f.clientID, projects: [try pid(f.project)])
            let used = try await refresh(f, first, first.refresh)
            XCTAssertEqual(used.status, .ok)
            for n in 1...50 {
                let again = try await refresh(f, first, first.refresh)
                XCTAssertEqual(again.status, .ok, "repeat \(n)")
            }
            let over = try await refresh(f, first, first.refresh)
            XCTAssertEqual(over.status, .badRequest)
            let reason = try await revokedReason(f, first.grant)
            XCTAssertEqual(reason, "replay")
        }
    }

    /// Repeats in the window and revocations by replay detection are visible to the operator, without any token value.
    func testRepeatsAndReplayRevocationsAreLoggedWithoutTokens() async throws {
        try await run { f in
            let capture = LogCapture()
            // Info and above: what a production instance writes (query debug lines are not part of this check).
            f.test.app.logger = Logger(label: "oauth-review-test") { _ in var h = CaptureLogHandler(capture: capture); h.logLevel = .info; return h }
            let first = try await login(f, client: f.clientID, projects: [try pid(f.project)])
            let next = try await refresh(f, first, first.refresh)
            let successor = try XCTUnwrap(next.body?["refresh_token"] as? String)
            let again = try await refresh(f, first, first.refresh)
            XCTAssertEqual(again.status, .ok)
            let repeated = capture.lines.filter { $0.contains("oauth.refresh_repeated") }
            XCTAssertEqual(repeated.count, 1, "\(capture.lines)")
            XCTAssertTrue(repeated.first?.contains(first.grant.uuidString) == true, "\(repeated)")

            _ = try await refresh(f, first, successor)
            let replay = try await refresh(f, first, first.refresh)
            XCTAssertEqual(replay.status, .badRequest)
            let revoked = capture.lines.filter { $0.contains("oauth.replay_revoked") }
            XCTAssertEqual(revoked.count, 1, "\(capture.lines)")
            XCTAssertTrue(revoked.first?.contains(first.grant.uuidString) == true, "\(revoked)")

            let secrets = [first.access, first.refresh, successor, AuthSupport.hash(first.refresh), AuthSupport.hash(successor)]
                + [next.body?["access_token"], again.body?["access_token"], again.body?["refresh_token"]].compactMap { $0 as? String }
            for line in capture.lines { for s in secrets { XCTAssertFalse(line.contains(s), "token value in log: \(line)") } }
        }
    }

    // MARK: Takeover offer

    /// A connection signed out by replay detection is offered for seven days, counted from the revocation; also at the click.
    func testReplayRevokedConnectionIsOfferedForSevenDaysOnly() async throws {
        try await run { f in
            let old = try await login(f, client: f.clientID, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            try await replay(f, old)
            let age = { (days: Double) in
                try await self.sql(f).raw("UPDATE oauth_grants SET revoked_at = \(bind: Date().addingTimeInterval(-days * 86_400)) WHERE id = \(bind: old.grant)").run()
            }
            try await age(6.9)
            let offered = try await authorize(f, client: f.clientID)
            XCTAssertNotNil(offered["takeover"], "within seven days the takeover is offered")
            try await age(7.1)
            let late = try await consent(f, offered, projects: [try pid(f.project)], takeover: old.grant)
            XCTAssertEqual(late.status, .conflict)
            let again = try await authorize(f, client: f.clientID)
            XCTAssertNil(again["takeover"])
        }
    }

    /// Without `client_name` every client is called the same; such a name proves nothing.
    func testTheDefaultClientNameIsNeverMatchedByName() async throws {
        try await run { f in
            let first = try await register(f, name: nil)
            let old = try await login(f, client: first, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project])
            try await replay(f, old)
            let second = try await register(f, name: nil)
            let auth = try await authorize(f, client: second)
            XCTAssertNil(auth["takeover"])
            let blank = try await register(f, name: "  ")
            let blankOld = try await login(f, client: blank, projects: [try pid(f.other)])
            try await replay(f, blankOld)
            let blankNew = try await register(f, name: "  ")
            let blankAuth = try await authorize(f, client: blankNew)
            XCTAssertNil(blankAuth["takeover"])
        }
    }

    // MARK: What moves

    /// A mandate project that was not in the old project list is preselected as well; whatever the person unchecks leaves the
    /// mandate.
    func testMandateFollowsTheProjectsThePersonConfirms() async throws {
        try await run { f in
            let old = try await login(f, client: f.clientID, projects: [try pid(f.project)])
            try await mandate(f, old.grant, [f.project, f.other])
            let auth = try await authorize(f, client: f.clientID)
            let offer = try XCTUnwrap(auth["takeover"] as? [String: Any])
            XCTAssertEqual(ids(offer["project_ids"]), [try pid(f.project), try pid(f.other)], "mandate projects are preselected")
            let listed = Set((auth["projects"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String)?.uppercased() })
            XCTAssertTrue(listed.contains(try pid(f.other)))

            let before = Set(try await OAuthGrant.query(on: f.test.app.db).all().compactMap(\.id))
            let reply = try await consent(f, auth, projects: [try pid(f.project)], takeover: old.grant)
            XCTAssertEqual(reply.status, .ok, "\(reply.body ?? [:])")
            let new = try await OAuthGrant.query(on: f.test.app.db).all().compactMap(\.id).filter { !before.contains($0) }
            let carried = try await mandateProjects(f, of: try XCTUnwrap(new.first))
            XCTAssertEqual(carried, [try pid(f.project)], "an unchecked mandate project must not move along")
        }
    }

    /// Even when nothing but the connection itself moves, the protocol says so.
    func testTakeoverWithoutCommonProjectOrMandateIsAudited() async throws {
        try await run { f in
            let old = try await login(f, client: f.clientID, projects: [try pid(f.project)])
            let new = try await login(f, client: f.clientID, projects: [try pid(f.other)], takeover: old.grant)
            let r = try await f.test.json(.GET, "/v1/settings/brain-mandate/audit", token: f.session)
            let rows = (r.body?["items"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "connection.taken_over" }
            XCTAssertEqual(rows.count, 1, "\(rows)")
            XCTAssertEqual((rows.first?["grantID"] as? String)?.uppercased(), new.grant.uuidString)
            XCTAssertEqual((rows.first?["subjectID"] as? String)?.uppercased(), old.grant.uuidString)
            // No project is involved: the row names the earlier connection instead.
            XCTAssertEqual((rows.first?["projectID"] as? String)?.uppercased(), old.grant.uuidString)
        }
    }

    // MARK: Schema

    /// Sibling lookups go through an index on `rotated_from` (MariaDB would otherwise lock every scanned row). Also after
    /// upgrading a database of the state before ADR 0036 (cf4237e: neither the columns nor the index).
    func testRotatedFromIsIndexedOnFreshAndUpgradedDatabases() async throws {
        try await run { f in
            let db = f.test.app.db
            let fresh = try await Self.rotatedFromIndexed(try sql(f))
            XCTAssertTrue(fresh, "fresh database")
            try await AddOAuthRotatedFromIndex().revert(on: db)
            try await AddOAuthGrantLineage().revert(on: db)
            try await AddOAuthReuseAndRevocation().revert(on: db)
            let old = try await Self.rotatedFromIndexed(try sql(f))
            XCTAssertFalse(old)
            try await AddOAuthReuseAndRevocation().prepare(on: db)
            try await AddOAuthGrantLineage().prepare(on: db)
            try await AddOAuthRotatedFromIndex().prepare(on: db)
            // Idempotent: a half-applied run can be repeated.
            try await AddOAuthRotatedFromIndex().prepare(on: db)
            let upgraded = try await Self.rotatedFromIndexed(try sql(f))
            XCTAssertTrue(upgraded, "upgraded database")
            // A database migrated with dc842e3 (columns without index) can still revert the columns.
            try await AddOAuthReuseAndRevocation().revert(on: db)
            try await AddOAuthReuseAndRevocation().prepare(on: db)
            try await AddOAuthRotatedFromIndex().prepare(on: db)
        }
    }

    static func rotatedFromIndexed(_ sql: any SQLDatabase) async throws -> Bool {
        if sql.dialect.name == "sqlite" {
            let rows = try await sql.raw("SELECT il.name AS n FROM pragma_index_list('oauth_secrets') il JOIN pragma_index_info(il.name) ii WHERE ii.name = 'rotated_from' AND ii.seqno = 0").all()
            return !rows.isEmpty
        }
        let rows = try await sql.raw("SELECT index_name AS n FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = 'oauth_secrets' AND column_name = 'rotated_from' AND seq_in_index = 1").all()
        return !rows.isEmpty
    }
}
