import XCTVapor
@testable import TodoKit

final class AuthTests: XCTestCase {
    func testBootstrapRequiresToken() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let caps = try await t.json(.GET, "/v1/capabilities")
        XCTAssertEqual(caps.body?["bootstrapOpen"] as? Bool, true)
        XCTAssertEqual(caps.body?["password"] as? Bool, false)

        let bad = try await t.json(.POST, "/v1/auth/register/begin", ["token": "nope", "displayName": "A"])
        XCTAssertEqual(bad.status, .forbidden)

        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let me = try await t.json(.GET, "/v1/me", token: a.session)
        XCTAssertEqual(me.status, .ok)
        XCTAssertEqual(me.body?["isAdmin"] as? Bool, true)

        // Bootstrap is closed once a user exists; the bootstrap token is no invitation.
        let again = try await t.json(.POST, "/v1/auth/register/begin", ["token": "bootstrap-secret", "displayName": "B"])
        XCTAssertEqual(again.status, .forbidden)
        let caps2 = try await t.json(.GET, "/v1/capabilities")
        XCTAssertEqual(caps2.body?["bootstrapOpen"] as? Bool, false)
    }

    func testLoginLogoutReplayAndTamper() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")

        let bad = try await t.login(a.key, tamper: true)
        XCTAssertEqual(bad.status, .unauthorized)

        let ok = try await t.login(a.key)
        XCTAssertEqual(ok.status, .ok)
        let token = try XCTUnwrap(ok.token)
        let me = try await t.json(.GET, "/v1/me", token: token)
        XCTAssertEqual(me.status, .ok)

        let out = try await t.json(.POST, "/v1/auth/logout", token: token)
        XCTAssertEqual(out.status, .noContent)
        let after = try await t.json(.GET, "/v1/me", token: token)
        XCTAssertEqual(after.status, .unauthorized)

        // A challenge is single use.
        let begin = try await t.json(.POST, "/v1/auth/login/begin")
        let challenge = ((begin.body!["options"] as! [String: Any])["challenge"]) as! String
        let cred = try a.key.assertion(challenge: challenge)
        let first = try await t.json(.POST, "/v1/auth/login/finish", ["challengeID": begin.body!["challengeID"]!, "credential": cred])
        XCTAssertEqual(first.status, .ok)
        let replay = try await t.json(.POST, "/v1/auth/login/finish", ["challengeID": begin.body!["challengeID"]!, "credential": cred])
        XCTAssertEqual(replay.status, .badRequest)
    }

    func testPasswordSwitchIsEnforcedServerSide() async throws {
        let off = try await TestApp.make(password: false)
        defer { Task { await off.shutdown() } }
        let a = try await off.register(token: "bootstrap-secret", name: "Alice")
        let set = try await off.json(.POST, "/v1/me/password", ["username": "alice", "password": "correct horse battery"], token: a.session)
        XCTAssertEqual(set.status, .forbidden)
        let login = try await off.json(.POST, "/v1/auth/password/login", ["username": "alice", "password": "correct horse battery"])
        XCTAssertEqual(login.status, .forbidden)
        XCTAssertEqual(login.body?["reason"] as? String, "password_login_disabled")

        let on = try await TestApp.make(password: true)
        defer { Task { await on.shutdown() } }
        let b = try await on.register(token: "bootstrap-secret", name: "Bob")
        let ok = try await on.json(.POST, "/v1/me/password", ["username": "Bob", "password": "correct horse battery"], token: b.session)
        XCTAssertEqual(ok.status, .noContent)
        let good = try await on.json(.POST, "/v1/auth/password/login", ["username": "bob", "password": "correct horse battery"])
        XCTAssertEqual(good.status, .ok)
        let wrong = try await on.json(.POST, "/v1/auth/password/login", ["username": "bob", "password": "wrong"])
        XCTAssertEqual(wrong.status, .unauthorized)
    }

    func testInvitationIsSingleUse() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let inv = try await t.json(.POST, "/v1/invitations", token: a.session)
        let token = try XCTUnwrap(inv.body?["token"] as? String)
        let b = try await t.register(token: token, name: "Bob")
        let me = try await t.json(.GET, "/v1/me", token: b.session)
        XCTAssertEqual(me.body?["isAdmin"] as? Bool, false)
        let reuse = try await t.json(.POST, "/v1/auth/register/begin", ["token": token, "displayName": "C"])
        XCTAssertEqual(reuse.status, .forbidden)
        // Non-admin cannot invite.
        let nope = try await t.json(.POST, "/v1/invitations", token: b.session)
        XCTAssertEqual(nope.status, .forbidden)
    }
}
