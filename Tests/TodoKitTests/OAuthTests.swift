import Crypto
import Fluent
import XCTVapor
@testable import TodoKit

struct OAuthFixture {
    let test: TestApp
    let user: User
    let session: String
    let project: Project
    let other: Project
    let clientID: String
    let redirect = "http://127.0.0.1:54321/callback"
    let verifier = String(repeating: "a", count: 64)

    static func make(issuer: String? = nil) async throws -> OAuthFixture {
        let t = try await TestApp.make(issuer: issuer)
        let u = User(displayName: "OAuth User", isAdmin: false)
        try await u.save(on: t.app.db)
        let session = AuthSupport.randomToken()
        try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        let p = Project(ownerID: try u.requireID(), parentID: nil, name: "Allowed")
        let other = Project(ownerID: try u.requireID(), parentID: nil, name: "Excluded")
        try await p.save(on: t.app.db); try await other.save(on: t.app.db)
        let r = try await t.json(.POST, "/oauth/register", ["client_name": "Test Client", "redirect_uris": ["http://127.0.0.1:54321/callback"]])
        return OAuthFixture(test: t, user: u, session: session, project: p, other: other, clientID: try XCTUnwrap(r.body?["client_id"] as? String))
    }
    func authorization(scope: String = "projects:read tasks:read tasks:write", resource: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(); url.path = "/oauth/authorize"
        url.queryItems = ["response_type": "code", "client_id": clientID, "redirect_uri": redirect,
            "scope": scope, "state": "test-state", "resource": resource ?? test.settings.oauthResource, "code_challenge": challenge, "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await test.json(.GET, url.string!, token: session)
    }
    func code(scope: String = "projects:read tasks:read tasks:write") async throws -> String {
        let auth = try await authorization(scope: scope)
        XCTAssertEqual(auth.status, .ok)
        XCTAssertEqual(auth.body?["client_name"] as? String, "Test Client")
        let consent = try await test.json(.POST, "/oauth/consent", ["consent_token": try XCTUnwrap(auth.body?["consent_token"]), "approve": true, "project_ids": [try project.requireID().uuidString]], token: session)
        XCTAssertEqual(consent.status, .ok)
        let callback = try XCTUnwrap(consent.body?["redirect_uri"] as? String)
        let items = URLComponents(string: callback)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "test-state")
        return try XCTUnwrap(items.first { $0.name == "code" }?.value)
    }
    func exchange(_ code: String, verifier: String? = nil, resource: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        try await test.json(.POST, "/oauth/token", ["grant_type": "authorization_code", "client_id": clientID, "resource": resource ?? test.settings.oauthResource, "code": code, "redirect_uri": redirect, "code_verifier": verifier ?? self.verifier])
    }
    func tokens(scope: String = "projects:read tasks:read tasks:write") async throws -> (access: String, refresh: String) {
        let r = try await exchange(code(scope: scope))
        XCTAssertEqual(r.status, .ok)
        return (try XCTUnwrap(r.body?["access_token"] as? String), try XCTUnwrap(r.body?["refresh_token"] as? String))
    }
    func refresh(_ raw: String) async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        try await test.json(.POST, "/oauth/token", ["grant_type": "refresh_token", "client_id": clientID, "resource": test.settings.oauthResource, "refresh_token": raw])
    }
    func rpc(_ method: String, _ params: [String: Any] = [:], access: String) async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        try await test.json(.POST, "/mcp", ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], token: access)
    }
}

final class OAuthTests: XCTestCase {
    func testDiscoveryConsentPKCEAndResourceBinding() async throws {
        let f = try await OAuthFixture.make()
        do {
            let metadata = try await f.test.json(.GET, "/.well-known/oauth-protected-resource/mcp")
            XCTAssertEqual(metadata.body?["resource"] as? String, AppSettings().oauthResource)
            let asMetadata = try await f.test.json(.GET, "/.well-known/oauth-authorization-server")
            XCTAssertEqual(asMetadata.body?["code_challenge_methods_supported"] as? [String], ["S256"])
            let wrongResource = try await f.authorization(resource: "https://foreign.example/mcp")
            XCTAssertEqual(wrongResource.status, .badRequest)
            let code = try await f.code()
            let wrongPKCE = try await f.exchange(code, verifier: String(repeating: "b", count: 64))
            XCTAssertEqual(wrongPKCE.status, .badRequest)
            let wrongAudience = try await f.exchange(code, resource: "https://foreign.example/mcp")
            XCTAssertEqual(wrongAudience.status, .badRequest)
            let valid = try await f.exchange(code)
            XCTAssertEqual(valid.status, .ok)
            let replay = try await f.exchange(code)
            XCTAssertEqual(replay.status, .badRequest)
            let revoked = try await f.rpc("tools/list", access: XCTUnwrap(valid.body?["access_token"] as? String))
            XCTAssertEqual(revoked.status, .unauthorized)
            let secrets = try await OAuthSecret.query(on: f.test.app.db).all()
            XCTAssertTrue(secrets.allSatisfy { $0.hash.count == 64 })
            XCTAssertFalse(secrets.contains { $0.hash == code || $0.payload.contains(code) })
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRefreshReuseRevokesRotatedFamilyAcrossReplicas() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let rotated = try await f.refresh(tokens.refresh)
            XCTAssertEqual(rotated.status, .ok)
            let newRefresh = try XCTUnwrap(rotated.body?["refresh_token"] as? String)
            XCTAssertNotEqual(newRefresh, tokens.refresh)
            let replica = try await f.test.replica()
            let replay = try await replica.json(.POST, "/oauth/token", ["grant_type": "refresh_token", "client_id": f.clientID, "resource": AppSettings().oauthResource, "refresh_token": tokens.refresh])
            await replica.shutdown()
            XCTAssertEqual(replay.status, .badRequest)
            let rejected = try await f.refresh(newRefresh)
            XCTAssertEqual(rejected.status, .badRequest)
            for token in [tokens.access, try XCTUnwrap(rotated.body?["access_token"] as? String)] {
                let r = try await f.rpc("tools/list", access: token)
                XCTAssertEqual(r.status, .unauthorized)
            }
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testIndividualRevocationAndConsentBoundaries() async throws {
        let f = try await OAuthFixture.make()
        do {
            let first = try await f.tokens(), second = try await f.tokens()
            let grants = try await f.test.json(.GET, "/oauth/grants", token: f.session)
            let id = try XCTUnwrap(grants.list?.first?["id"] as? String)
            let revoked = try await f.test.json(.DELETE, "/oauth/grants/" + id, token: f.session)
            XCTAssertEqual(revoked.status, .noContent)
            let statuses = try await [f.rpc("tools/list", access: first.access).status, f.rpc("tools/list", access: second.access).status]
            XCTAssertEqual(statuses.filter { $0 == .unauthorized }.count, 1)
            XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1)
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Private"); try await foreign.save(on: f.test.app.db)
            let a = try await f.authorization()
            let rejected = try await f.test.json(.POST, "/oauth/consent", ["consent_token": try XCTUnwrap(a.body?["consent_token"]), "approve": true, "project_ids": [try foreign.requireID().uuidString]], token: f.session)
            XCTAssertEqual(rejected.status, .notFound)
            let denied = try await f.test.json(.POST, "/oauth/consent", ["consent_token": try XCTUnwrap(a.body?["consent_token"]), "approve": false, "project_ids": []], token: f.session)
            XCTAssertTrue((denied.body?["redirect_uri"] as? String)?.contains("access_denied") == true)
            let replay = try await f.test.json(.POST, "/oauth/consent", ["consent_token": try XCTUnwrap(a.body?["consent_token"]), "approve": true, "project_ids": [try f.project.requireID().uuidString]], token: f.session)
            XCTAssertEqual(replay.status, .badRequest)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
