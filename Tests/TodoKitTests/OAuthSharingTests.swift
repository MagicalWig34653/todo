import Fluent
import XCTVapor
@testable import TodoKit

final class OAuthSharingTests: XCTestCase {
    func testConsentPageAndOptionalScopeResource() async throws {
        let f = try await OAuthFixture.make()
        do {
            // Logged out: redirected to the login with the exact request as return target.
            try await f.test.app.test(.GET, "/oauth/authorize?response_type=code&state=a%2Bb", beforeRequest: { $0.headers.replaceOrAdd(name: .accept, value: "text/html") }, afterResponse: { res async in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/login?next=%2Foauth%2Fauthorize%3Fresponse_type%3Dcode%26state%3Da%252Bb")
            })
            try await f.test.app.test(.GET, "/oauth/authorize?response_type=code", beforeRequest: { $0.headers.replaceOrAdd(name: .accept, value: "text/html"); $0.headers.bearerAuthorization = BearerAuthorization(token: f.session) }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.contentType, .html)
                XCTAssertTrue(res.headers.first(name: "Content-Security-Policy")?.contains("sha256-") == true)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
            })
            // No scope and no resource parameter: defaults to all supported scopes and this server's resource.
            let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
            let url = "/oauth/authorize?response_type=code&client_id=\(f.clientID)&redirect_uri=\(f.redirect)&code_challenge=\(challenge)&code_challenge_method=S256"
            let r = try await f.test.json(.GET, url, token: f.session)
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual((r.body?["scopes"] as? [String])?.sorted(), OAuthController.scopes.sorted())
            let noSession = try await f.test.json(.GET, url)
            XCTAssertEqual(noSession.status, .unauthorized)
            let unknownScope = try await f.authorization(scope: "tasks:read admin")
            XCTAssertEqual(unknownScope.status, .badRequest)
            let unauth = try await f.test.json(.POST, "/mcp", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
            XCTAssertEqual(unauth.status, .unauthorized)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testEffectiveRightsFromSharingLimitMcp() async throws {
        let f = try await OAuthFixture.make()
        do {
            let owner = User(displayName: "Owner", isAdmin: false); try await owner.save(on: f.test.app.db)
            let shared = Project(ownerID: try owner.requireID(), parentID: nil, name: "Shared"); try await shared.save(on: f.test.app.db)
            let sharing = try ProjectSharing(project: shared); try await sharing.save(on: f.test.app.db)
            let ownerTask = TodoTask(ownerID: try owner.requireID(), projectID: try shared.requireID(), title: "By owner", details: "")
            try await ownerTask.save(on: f.test.app.db)
            let grant = ProjectGrant(projectID: try shared.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read)
            try await grant.save(on: f.test.app.db)
            // Consent for the shared (read-only) project plus the user's own project.
            let auth = try await f.authorization()
            let consent = try await f.test.json(.POST, "/oauth/consent", ["consent_token": try XCTUnwrap(auth.body?["consent_token"]), "approve": true,
                "project_ids": [try shared.requireID().uuidString]], token: f.session)
            XCTAssertEqual(consent.status, .ok)
            let callback = try XCTUnwrap(consent.body?["redirect_uri"] as? String)
            let items = try XCTUnwrap(URLComponents(string: callback)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "iss" }?.value, AppSettings().oauthIssuer)
            let ex = try await f.exchange(try XCTUnwrap(items.first { $0.name == "code" }?.value))
            let access = try XCTUnwrap(ex.body?["access_token"] as? String)
            let sid = try shared.requireID().uuidString
            let listed = try await f.rpc("tools/call", ["name": "list_tasks", "arguments": ["projectID": sid]], access: access)
            XCTAssertTrue(try text(listed.body).contains("By owner"))
            let denied = try await f.rpc("tools/call", ["name": "create_task", "arguments": ["projectID": sid, "title": "No"]], access: access)
            XCTAssertEqual((denied.body?["result"] as? [String: Any])?["isError"] as? Bool, true)
            let deniedUpdate = try await f.rpc("tools/call", ["name": "update_task", "arguments": ["id": try ownerTask.requireID().uuidString, "version": 1, "title": "No"]], access: access)
            XCTAssertEqual((deniedUpdate.body?["result"] as? [String: Any])?["isError"] as? Bool, true)
            // Not consented: the user's own project stays invisible to this grant.
            let own = try await f.rpc("tools/call", ["name": "list_tasks", "arguments": ["projectID": try f.project.requireID().uuidString]], access: access)
            XCTAssertEqual(try text(own.body), "not_found")
            // Live rights: upgrading the user's sharing role takes effect without a new token.
            grant.role = .edit; try await grant.save(on: f.test.app.db)
            let ok = try await f.rpc("tools/call", ["name": "create_task", "arguments": ["projectID": sid, "title": "Now allowed"]], access: access)
            XCTAssertEqual((ok.body?["result"] as? [String: Any])?["isError"] as? Bool, false)
            try await grant.delete(on: f.test.app.db)
            let gone = try await f.rpc("tools/call", ["name": "list_tasks", "arguments": ["projectID": sid]], access: access)
            XCTAssertEqual(try text(gone.body), "not_found")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testGrantProjectsCanBeChangedAfterwards() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let grants = try await f.test.json(.GET, "/oauth/grants", token: f.session)
            let id = try XCTUnwrap(grants.list?.first?["id"] as? String)
            let allowed = try f.project.requireID().uuidString, other = try f.other.requireID().uuidString
            let call = { (pid: String) in try await f.rpc("tools/call", ["name": "list_tasks", "arguments": ["projectID": pid]], access: tokens.access) }
            let before = try await call(other)
            XCTAssertEqual(try text(before.body), "not_found")
            // Authorise a further project afterwards; the same token reaches it at once.
            let added = try await f.test.json(.PUT, "/oauth/grants/\(id)/projects", ["project_ids": [allowed, other]], token: f.session)
            XCTAssertEqual(added.status, .ok)
            XCTAssertEqual(Set(added.body?["project_ids"] as? [String] ?? []), [allowed, other])
            let after = try await call(other)
            XCTAssertNotEqual(try text(after.body), "not_found")
            // Deauthorise the first one again.
            let removed = try await f.test.json(.PUT, "/oauth/grants/\(id)/projects", ["project_ids": [other]], token: f.session)
            XCTAssertEqual(removed.status, .ok)
            let dropped = try await call(allowed)
            XCTAssertEqual(try text(dropped.body), "not_found")
            // Boundaries: empty list without projects:write, foreign project, unknown grant.
            let empty = try await f.test.json(.PUT, "/oauth/grants/\(id)/projects", ["project_ids": [String]()], token: f.session)
            XCTAssertEqual(empty.status, .badRequest)
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Private"); try await foreign.save(on: f.test.app.db)
            let denied = try await f.test.json(.PUT, "/oauth/grants/\(id)/projects", ["project_ids": [try foreign.requireID().uuidString]], token: f.session)
            XCTAssertEqual(denied.status, .notFound)
            let unknown = try await f.test.json(.PUT, "/oauth/grants/\(UUID().uuidString)/projects", ["project_ids": [allowed]], token: f.session)
            XCTAssertEqual(unknown.status, .notFound)
            // Revoked grants stay revoked.
            _ = try await f.test.json(.DELETE, "/oauth/grants/\(id)", token: f.session)
            let late = try await f.test.json(.PUT, "/oauth/grants/\(id)/projects", ["project_ids": [allowed]], token: f.session)
            XCTAssertEqual(late.status, .conflict)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// Writes replace the whole list, so the last accepted PUT decides (this is why the PWA sends one PUT per grant at a
    /// time). Parallel writers are serialised by lockRow on MariaDB; SQLite would answer "database is locked", so the
    /// order is tested sequentially: a withdrawal followed by a stale re-add of the same list is a re-add by design.
    func testLastGrantProjectsPutWinsAndWithdrawalSticks() async throws {
        let f = try await OAuthFixture.make()
        do {
            _ = try await f.tokens()
            let grants = try await f.test.json(.GET, "/oauth/grants", token: f.session)
            let id = try XCTUnwrap(grants.list?.first?["id"] as? String)
            let allowed = try f.project.requireID().uuidString, other = try f.other.requireID().uuidString
            func put(_ ids: [String]) async throws -> Set<String> {
                let r = try await f.test.json(.PUT, "/oauth/grants/\(id)/projects", ["project_ids": ids], token: f.session)
                XCTAssertEqual(r.status, .ok)
                return Set(r.body?["project_ids"] as? [String] ?? [])
            }
            func listed() async throws -> Set<String> {
                let r = try await f.test.json(.GET, "/oauth/grants", token: f.session)
                return Set(r.list?.first?["project_ids"] as? [String] ?? [])
            }
            let rp1 = try await put([allowed, other]); XCTAssertEqual(rp1, [allowed, other])
            let rp2 = try await put([other]); XCTAssertEqual(rp2, [other])
            let rl3 = try await listed(); XCTAssertEqual(rl3, [other])
            // A stale writer that still holds [allowed, other] overwrites the withdrawal: last write wins.
            let rp5 = try await put([allowed, other]); XCTAssertEqual(rp5, [allowed, other])
            let rl6 = try await listed(); XCTAssertEqual(rl6, [allowed, other])
            let rp7 = try await put([other]); XCTAssertEqual(rp7, [other])
            let rl8 = try await listed(); XCTAssertEqual(rl8, [other])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func text(_ body: [String: Any]?) throws -> String {
        let content = try XCTUnwrap((body?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}
