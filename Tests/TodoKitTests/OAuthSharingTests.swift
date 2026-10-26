import Fluent
import XCTVapor
@testable import TodoKit

final class OAuthSharingTests: XCTestCase {
    func testConsentPageAndOptionalScopeResource() async throws {
        let f = try await OAuthFixture.make()
        do {
            try await f.test.app.test(.GET, "/oauth/authorize?response_type=code", beforeRequest: { $0.headers.replaceOrAdd(name: .accept, value: "text/html") }, afterResponse: { res async in
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
            XCTAssertEqual(items.first { $0.name == "iss" }?.value, OAuthController.issuer)
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

    private func text(_ body: [String: Any]?) throws -> String {
        let content = try XCTUnwrap((body?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}
