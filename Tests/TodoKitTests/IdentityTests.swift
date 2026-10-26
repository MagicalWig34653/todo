import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

final class IdentityTests: XCTestCase {
    override func setUpWithError() throws {
        // The shared helper uses one file so a second Application can act as a replica.
        // Identity test cases each need an isolated schema when run in one XCTest process.
        if !TestApp.useMariaDB {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: TestApp.sqliteFile + suffix)
            }
        }
    }

    private func addKey(_ t: TestApp, token: String, recovery: Bool = false, name: String = "Laptop") async throws -> VirtualAuthenticator {
        let path = recovery ? "/v1/identity/recovery/passkeys" : "/v1/me/passkeys"
        let begin = try await t.json(.POST, path + "/begin", token: token)
        XCTAssertEqual(begin.status, .ok)
        let body = try XCTUnwrap(begin.body)
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        let key = VirtualAuthenticator()
        let finish = try await t.json(.POST, path + "/finish", [
            "challengeID": body["challengeID"]!,
            "credential": key.registrationResponse(challenge: options["challenge"] as! String), "passkeyName": name,
        ], token: token)
        XCTAssertEqual(finish.status, .noContent)
        return key
    }

    func testRegistrationOptionsRequireDiscoverableCredentials() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        // Bootstrap registration (no session yet).
        let boot = try await t.json(.POST, "/v1/auth/register/begin", ["token": "bootstrap-secret", "displayName": "Alice"])
        XCTAssertEqual(boot.status, .ok)
        func assertResident(_ body: [String: Any]?, _ label: String) {
            let options = body?["options"] as? [String: Any]
            let selection = options?["authenticatorSelection"] as? [String: Any]
            XCTAssertEqual(selection?["residentKey"] as? String, "required", label)
            XCTAssertEqual(selection?["requireResidentKey"] as? Bool, true, label)
            XCTAssertNotNil(options?["challenge"], label)
        }
        assertResident(boot.body, "register")
        let a = try await t.register(token: "bootstrap-secret", name: "Bob")
        let more = try await t.json(.POST, "/v1/me/passkeys/begin", token: a.session)
        assertResident(more.body, "add passkey")
    }

    func testNamedKeysOwnershipAndLastKeyProtection() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let first = try await t.json(.GET, "/v1/me/passkeys", token: a.session)
        let firstID = first.list!.first!["id"] as! String
        let denied = try await t.json(.DELETE, "/v1/me/passkeys/\(firstID)", token: a.session)
        XCTAssertEqual(denied.status, .conflict)
        let key = try await addKey(t, token: a.session)
        let list = try await t.json(.GET, "/v1/me/passkeys", token: a.session)
        XCTAssertEqual(list.list?.count, 2)
        let keyID = list.list!.first { $0["name"] as? String == "Laptop" }!["id"] as! String
        let renamed = try await t.json(.PATCH, "/v1/me/passkeys/\(keyID)", ["name": "Telefon"], token: a.session)
        XCTAssertEqual(renamed.status, .noContent)
        let renamedList = try await t.json(.GET, "/v1/me/passkeys", token: a.session)
        XCTAssertTrue(renamedList.list!.contains { $0["name"] as? String == "Telefon" })
        let inv = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: inv.body!["token"] as! String, name: "Bob")
        let foreign = try await t.json(.DELETE, "/v1/me/passkeys/\(keyID)", token: b.session)
        XCTAssertEqual(foreign.status, .notFound)
        let revoked = try await t.json(.DELETE, "/v1/me/passkeys/\(keyID)", token: a.session)
        XCTAssertEqual(revoked.status, .noContent)
        let login = try await t.login(key)
        XCTAssertEqual(login.status, .unauthorized)
        let stillWorks = try await t.login(a.key)
        XCTAssertEqual(stillWorks.status, .ok)
    }

    func testSessionsArePrivateAndRevocationIsImmediate() async throws {
        let t = try await TestApp.make()
        let replica = try await t.replica()
        defer { Task { await t.shutdown(); await replica.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let secondLogin = try await t.login(a.key)
        let second = try XCTUnwrap(secondLogin.token)
        let listed = try await t.json(.GET, "/v1/me/sessions", token: a.session)
        XCTAssertEqual(listed.list?.count, 2)
        XCTAssertEqual(listed.list?.filter { $0["current"] as? Bool == true }.count, 1)
        XCTAssertNil(listed.list?.first?["tokenHash"])
        let secondID = listed.list!.first { $0["current"] as? Bool == false }!["id"] as! String
        let inv = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: inv.body!["token"] as! String, name: "Bob")
        let foreign = try await t.json(.DELETE, "/v1/me/sessions/\(secondID)", token: b.session)
        XCTAssertEqual(foreign.status, .notFound)
        let revoked = try await t.json(.DELETE, "/v1/me/sessions/\(secondID)", token: a.session)
        XCTAssertEqual(revoked.status, .noContent)
        let denied = try await replica.json(.GET, "/v1/me", token: second)
        XCTAssertEqual(denied.status, .unauthorized)
        let thirdLogin = try await replica.login(a.key)
        let third = try XCTUnwrap(thirdLogin.token)
        let others = try await t.json(.POST, "/v1/me/sessions/revoke-others", token: a.session)
        XCTAssertEqual(others.status, .noContent)
        let gone = try await replica.json(.GET, "/v1/me", token: third)
        XCTAssertEqual(gone.status, .unauthorized)
        let current = try await t.json(.GET, "/v1/me", token: a.session)
        XCTAssertEqual(current.status, .ok)
    }

    func testRecoveryIsRestrictedSingleUseAndIndependentOfPasswordSwitch() async throws {
        let t = try await TestApp.make(password: true)
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let password = ["username": "alice", "password": "correct horse battery"]
        let set = try await t.json(.POST, "/v1/me/password", password, token: a.session)
        XCTAssertEqual(set.status, .noContent)
        let passwordSession = try await t.json(.POST, "/v1/auth/password/login", password)
        XCTAssertEqual(passwordSession.status, .ok)
        t.app.settings.passwordLoginEnabled = false
        let disabled = try await t.json(.POST, "/v1/auth/password/login", password)
        XCTAssertEqual(disabled.status, .forbidden)
        let cannotChange = try await t.json(.POST, "/v1/me/password", password, token: a.session)
        XCTAssertEqual(cannotChange.status, .forbidden)
        let existing = try await t.json(.GET, "/v1/me", token: passwordSession.body!["token"] as? String)
        XCTAssertEqual(existing.status, .ok)
        let oldKey = try await t.json(.GET, "/v1/me/passkeys", token: a.session).list!.first!["id"] as! String
        let disabledFallback = try await t.json(.DELETE, "/v1/me/passkeys/\(oldKey)", token: a.session)
        XCTAssertEqual(disabledFallback.status, .conflict)
        let issued = try await t.json(.POST, "/v1/identity/accounts/\(a.userID)/recovery", token: a.session)
        let code = issued.body!["token"] as! String
        let redeemed = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": code])
        XCTAssertEqual(redeemed.status, .ok)
        let recoveryToken = redeemed.body!["token"] as! String
        let replay = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": code])
        XCTAssertEqual(replay.status, .unauthorized)
        for path in ["/v1/me", "/v1/projects", "/v1/me/sessions", "/v1/me/passkeys"] {
            let forbidden = try await t.json(.GET, path, token: recoveryToken)
            XCTAssertEqual(forbidden.status, .unauthorized)
        }
        let deniedAdmin = try await t.json(.POST, "/v1/identity/accounts/\(a.userID)/recovery", token: recoveryToken)
        XCTAssertEqual(deniedAdmin.status, .unauthorized)
        let revoked = try await t.json(.DELETE, "/v1/me/passkeys/\(oldKey)", token: a.session)
        XCTAssertEqual(revoked.status, .noContent)
        let key = try await addKey(t, token: recoveryToken, recovery: true)
        let used = try await t.json(.POST, "/v1/identity/recovery/passkeys/begin", token: recoveryToken)
        XCTAssertEqual(used.status, .unauthorized)
        let sessionGone = try await t.json(.GET, "/v1/me", token: a.session)
        XCTAssertEqual(sessionGone.status, .unauthorized)
        let login = try await t.login(key)
        XCTAssertEqual(login.status, .ok)
        t.app.settings.passwordLoginEnabled = true
        let restored = try await t.json(.POST, "/v1/auth/password/login", password)
        XCTAssertEqual(restored.status, .ok, "Existing password hashes survive disabling and recovery")
    }

    func testRecoveryExpiryReissueAndAdminBoundary() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let inv = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: inv.body!["token"] as! String, name: "Bob")
        let denied = try await t.json(.POST, "/v1/identity/accounts/\(a.userID)/recovery", token: b.session)
        XCTAssertEqual(denied.status, .forbidden)
        let issued = try await t.json(.POST, "/v1/identity/accounts/\(b.userID)/recovery", token: a.session)
        let code = issued.body!["token"] as! String
        let grant = try await RecoveryGrant.query(on: t.app.db).first()!
        XCTAssertNotEqual(grant.codeHash, code)
        grant.expiresAt = .distantPast
        try await grant.save(on: t.app.db)
        let expired = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": code])
        XCTAssertEqual(expired.status, .unauthorized)
        let fresh = try await t.json(.POST, "/v1/identity/accounts/\(b.userID)/recovery", token: a.session)
        let redeemed = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": fresh.body!["token"]!])
        let token = redeemed.body!["token"] as! String
        let active = try await RecoveryGrant.query(on: t.app.db).first()!
        active.sessionExpiresAt = .distantPast
        try await active.save(on: t.app.db)
        let expiredSession = try await t.json(.POST, "/v1/identity/recovery/passkeys/begin", token: token)
        XCTAssertEqual(expiredSession.status, .unauthorized)
        _ = try await t.json(.POST, "/v1/identity/accounts/\(b.userID)/recovery", token: a.session)
        let old = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": fresh.body!["token"]!])
        XCTAssertEqual(old.status, .unauthorized)
    }

    func testAdditionalRegistrationIsBoundToItsSessionAndSingleUse() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let secondLogin = try await t.login(a.key)
        let second = try XCTUnwrap(secondLogin.token)
        let begin = try await t.json(.POST, "/v1/me/passkeys/begin", token: a.session)
        let challenge = (begin.body!["options"] as! [String: Any])["challenge"] as! String
        let body: [String: Any] = ["challengeID": begin.body!["challengeID"]!, "credential": VirtualAuthenticator().registrationResponse(challenge: challenge), "passkeyName": "Phone"]
        let stolen = try await t.json(.POST, "/v1/me/passkeys/finish", body, token: second)
        XCTAssertEqual(stolen.status, .badRequest)
        let valid = try await t.json(.POST, "/v1/me/passkeys/finish", body, token: a.session)
        XCTAssertEqual(valid.status, .noContent)
        let replay = try await t.json(.POST, "/v1/me/passkeys/finish", body, token: a.session)
        XCTAssertEqual(replay.status, .badRequest)
    }

    func testEveryPublicEntryPointIsRateLimited() async throws {
        let t = try await TestApp.make(password: true)
        defer { Task { await t.shutdown() } }
        var settings = IdentitySettings()
        settings.window = 3600
        settings.loginLimit = 1; settings.passwordLimit = 1; settings.registerLimit = 1; settings.recoveryLimit = 1
        t.app.identitySettings = settings
        for (path, body) in [
            ("/v1/auth/login/begin", [String: String]()),
            ("/v1/auth/password/login", ["username": "nobody", "password": "wrong"]),
            ("/v1/auth/register/begin", ["displayName": "A", "token": "wrong"]),
            ("/v1/identity/recovery/redeem", ["code": "wrong"]),
        ] {
            let first = try await t.json(.POST, path, body)
            XCTAssertNotEqual(first.status, .tooManyRequests)
            let blocked = try await t.json(.POST, path, body)
            XCTAssertEqual(blocked.status, .tooManyRequests, path)
        }
        let finish = try await t.json(.POST, "/v1/auth/login/finish", [:])
        XCTAssertEqual(finish.status, .tooManyRequests)
    }

    func testMariaDBReplicaRateLimitAndRecoveryRaces() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "requires isolated MariaDB via TODO_TEST_DB")
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let statuses = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<20 {
                let app = i % 2 == 0 ? a.app : b.app
                group.addTask {
                    try await IdentityRateLimit.take(scope: "race", subject: "same", limit: 3, window: 86400, on: app.db)
                }
            }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 }.count, 3)
        let user = try await a.register(token: "bootstrap-secret", name: "Alice")
        let issued = try await a.json(.POST, "/v1/identity/accounts/\(user.userID)/recovery", token: user.session)
        let data = try JSONSerialization.data(withJSONObject: ["code": issued.body!["token"]!])
        let results = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for app in [a, b] {
                group.addTask { try await app.rawStatus(.POST, "/v1/identity/recovery/redeem", body: data) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(results.filter { $0 == .ok }.count, 1)
        XCTAssertEqual(results.filter { $0 == .unauthorized }.count, 1)
    }

    func testPasswordFallbackAndRecoveryChallengeSurviveSwitch() async throws {
        let t = try await TestApp.make(password: true)
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let password = ["username": "alice", "password": "correct horse battery"]
        _ = try await t.json(.POST, "/v1/me/password", password, token: a.session)
        let keyID = try await t.json(.GET, "/v1/me/passkeys", token: a.session).list!.first!["id"] as! String
        let removed = try await t.json(.DELETE, "/v1/me/passkeys/\(keyID)", token: a.session)
        XCTAssertEqual(removed.status, .noContent)
        let issued = try await t.json(.POST, "/v1/identity/accounts/\(a.userID)/recovery", token: a.session)
        let redeemed = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": issued.body!["token"]!])
        let token = redeemed.body!["token"] as! String
        let begin = try await t.json(.POST, "/v1/identity/recovery/passkeys/begin", token: token)
        t.app.settings.passwordLoginEnabled = false
        let key = VirtualAuthenticator()
        let challenge = (begin.body!["options"] as! [String: Any])["challenge"] as! String
        let completed = try await t.json(.POST, "/v1/identity/recovery/passkeys/finish", [
            "challengeID": begin.body!["challengeID"]!, "credential": key.registrationResponse(challenge: challenge),
        ], token: token)
        XCTAssertEqual(completed.status, .noContent)
        let login = try await t.login(key)
        XCTAssertEqual(login.status, .ok)
    }

    func testMariaDBHTTPBudgetsAreSharedAndRecoveryFinishesOnce() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "requires isolated MariaDB via TODO_TEST_DB")
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        var settings = IdentitySettings()
        settings.window = 86400; settings.loginLimit = 3
        a.app.identitySettings = settings; b.app.identitySettings = settings
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<10 {
                let app = i % 2 == 0 ? a : b
                group.addTask { try await app.rawStatus(.POST, "/v1/auth/login/begin", body: Data()) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 3)
        XCTAssertEqual(statuses.filter { $0 == .tooManyRequests }.count, 7)
        let user = try await a.register(token: "bootstrap-secret", name: "Alice")
        let issued = try await a.json(.POST, "/v1/identity/accounts/\(user.userID)/recovery", token: user.session)
        let redeemed = try await b.json(.POST, "/v1/identity/recovery/redeem", ["code": issued.body!["token"]!])
        let token = redeemed.body!["token"] as! String
        let begin = try await a.json(.POST, "/v1/identity/recovery/passkeys/begin", token: token)
        let key = VirtualAuthenticator()
        let challenge = (begin.body!["options"] as! [String: Any])["challenge"] as! String
        let data = try JSONSerialization.data(withJSONObject: [
            "challengeID": begin.body!["challengeID"]!, "credential": key.registrationResponse(challenge: challenge),
        ])
        let finishes = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for app in [a, b] {
                group.addTask { try await app.rawStatus(.POST, "/v1/identity/recovery/passkeys/finish", body: data, token: token) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(finishes.filter { $0 == .noContent }.count, 1)
        XCTAssertEqual(finishes.filter { $0 == .unauthorized }.count, 1)
        let oldSession = try await b.json(.GET, "/v1/me", token: user.session)
        XCTAssertEqual(oldSession.status, .unauthorized)
    }

    func testMariaDBConcurrentLastKeyRevocationHasOneWinner() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "requires isolated MariaDB via TODO_TEST_DB")
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let user = try await a.register(token: "bootstrap-secret", name: "Alice")
        _ = try await addKey(a, token: user.session)
        let list = try await a.json(.GET, "/v1/me/passkeys", token: user.session).list!
        let ids = list.map { $0["id"] as! String }
        let token = user.session
        let results = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for (app, id) in zip([a, b], ids) {
                group.addTask { try await app.rawStatus(.DELETE, "/v1/me/passkeys/\(id)", body: Data(), token: token) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(results.filter { $0 == .noContent }.count, 1)
        XCTAssertEqual(results.filter { $0 == .conflict }.count, 1)
    }
}
