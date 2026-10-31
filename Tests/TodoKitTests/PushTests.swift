import Crypto
import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// APNs transport double: records requests and answers with a scripted status. No network is involved.
final class MockAPNs: APNsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [APNsRequest] = []
    var handler: @Sendable (APNsRequest) -> APNsResponse = { _ in APNsResponse(status: 200, reason: nil) }
    var requests: [APNsRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func record(_ request: APNsRequest) -> APNsResponse {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return handler(request)
    }
    func send(_ request: APNsRequest) async throws -> APNsResponse { record(request) }
}

final class PushTests: XCTestCase {
    struct Account { let id: UUID; let token: String }

    struct Fixture {
        let t: TestApp
        let mock: MockAPNs
        let sender: APNsSender
        let owner: Account
        let guest: Account
        let project: String
        let task: String
        let config: APNsConfig
        var worker: PushWorker { PushWorker(app: t.app, sender: sender, interval: 0) }
    }

    static func config(enabled: Bool = true) -> APNsConfig {
        var c = APNsConfig()
        c.enabled = enabled
        c.keyPEM = P256.Signing.PrivateKey().pemRepresentation
        c.keyID = "ABCDE12345"; c.teamID = "TEAMID1234"
        c.topics = ["de.linolaske.todo", "de.linolaske.todo.mac"]
        return c
    }

    static func account(_ t: TestApp, _ name: String) async throws -> Account {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return Account(id: try user.requireID(), token: token)
    }

    func fixture(guestRole: String? = "edit") async throws -> Fixture {
        let t = try await TestApp.make()
        let owner = try await Self.account(t, "Owner"), guest = try await Self.account(t, "Guest")
        let cfg = Self.config()
        t.app.settings.apns = cfg
        let mock = MockAPNs()
        let sender = try APNsSender(config: cfg, transport: mock)
        let p = try await t.json(.POST, "/v1/projects", ["name": "Secret project"], token: owner.token)
        let pid = try XCTUnwrap(p.body?["id"] as? String)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "Quarterly tax filing"], token: owner.token)
        let tid = try XCTUnwrap(task.body?["id"] as? String)
        if let guestRole {
            let g = try await t.json(.PUT, "/v1/projects/\(pid)/grants", ["principalType": "person", "principalID": guest.id.uuidString, "role": guestRole], token: owner.token)
            XCTAssertEqual(g.status, .ok)
        }
        return Fixture(t: t, mock: mock, sender: sender, owner: owner, guest: guest, project: pid, task: tid, config: cfg)
    }

    @discardableResult
    func register(_ f: Fixture, _ a: Account, token: String = String(repeating: "ab", count: 32), platform: String = "ios",
                  env: String? = "sandbox", locale: String? = "de-DE") async throws -> String {
        var body: [String: Any] = ["token": token, "platform": platform, "bundleId": "de.linolaske.todo", "appVersion": "1.0"]
        if let env { body["environment"] = env }
        if let locale { body["locale"] = locale }
        let r = try await f.t.json(.POST, "/v1/push/devices", body, token: a.token)
        XCTAssertTrue([.ok, .created].contains(r.status), "\(r.status) \(r.body ?? [:])")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    func setReminder(_ f: Fixture, minutesAgo: Double = 30) async throws {
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
        let r = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.task)", ["priority": 0, "reminders": [at]], token: f.owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    func payload(_ r: APNsRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
    }

    func outbox(_ f: Fixture) async throws -> [PushOutbox] { try await PushOutbox.query(on: f.t.app.db).sort(\.$createdAt).all() }

    // MARK: Devices and preferences

    func testRegistrationIsIdempotentValidatedAndOwnerScoped() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let body: [String: Any] = ["token": "AB" + String(repeating: "cd", count: 31), "platform": "ios", "environment": "sandbox", "bundleId": "de.linolaske.todo", "appVersion": "1.2", "locale": "de"]
        let first = try await f.t.json(.POST, "/v1/push/devices", body, token: f.owner.token)
        XCTAssertEqual(first.status, .created)
        let second = try await f.t.json(.POST, "/v1/push/devices", body, token: f.owner.token)
        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(first.body?["id"] as? String, second.body?["id"] as? String)
        XCTAssertNil(first.body?["token"], "the token must never be returned")
        let list = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(list.list?.count, 1)
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: list.list as Any), encoding: .utf8)!.contains("abcdcd"))
        // Other accounts see nothing and cannot delete it.
        let others = try await f.t.json(.GET, "/v1/push/devices", token: f.guest.token)
        XCTAssertEqual(others.list?.count, 0)
        let id = try XCTUnwrap(first.body?["id"] as? String)
        let foreign = try await f.t.json(.DELETE, "/v1/push/devices/\(id)", token: f.guest.token)
        XCTAssertEqual(foreign.status, .notFound)
        let anonymous = try await f.t.json(.GET, "/v1/push/devices")
        XCTAssertEqual(anonymous.status, .unauthorized)
        // Validation.
        for bad: [String: Any] in [["token": "xyz"], ["platform": "android"], ["environment": "dev"], ["bundleId": "nodots"]] {
            let r = try await f.t.json(.POST, "/v1/push/devices", body.merging(bad) { $1 }, token: f.owner.token)
            XCTAssertEqual(r.status, .badRequest, "\(bad)")
        }
        // Topic outside APNS_TOPIC is rejected while push is enabled.
        let wrongTopic = try await f.t.json(.POST, "/v1/push/devices", body.merging(["bundleId": "com.other.app"]) { $1 }, token: f.owner.token)
        XCTAssertEqual(wrongTopic.status, .badRequest)
        // Revoke, then the same token registers again and reactivates the row.
        let gone = try await f.t.json(.DELETE, "/v1/push/devices/\(id)", token: f.owner.token)
        XCTAssertEqual(gone.status, .noContent)
        let afterDelete = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(afterDelete.list?.count, 0)
        let again = try await f.t.json(.POST, "/v1/push/devices", body, token: f.owner.token)
        XCTAssertEqual(again.body?["id"] as? String, id)
        // The token moves to the account that registers it last.
        _ = try await f.t.json(.POST, "/v1/push/devices", body, token: f.guest.token)
        let ownerList = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(ownerList.list?.count, 0)
    }

    func testDeviceLimitRevokesLeastRecentlySeen() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for i in 0..<(PushService.maxActiveDevices + 3) {
            try await register(f, f.owner, token: String(format: "%064x", i + 1))
        }
        let list = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(list.list?.count, PushService.maxActiveDevices)
    }

    func testPreferencesDefaultsAndPartialUpdates() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let d = try await f.t.json(.GET, "/v1/me/push-prefs", token: f.owner.token)
        XCTAssertEqual(d.body?["categories"] as? [String: Bool], ["reminders": true, "agent_questions": true, "agent_reviews": true, "assignments": false, "comments": false])
        XCTAssertEqual(d.body?["showContent"] as? Bool, false)
        let u = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["comments": true, "reminders": false], "showContent": true], token: f.owner.token)
        XCTAssertEqual(u.status, .ok)
        let c = u.body?["categories"] as? [String: Bool]
        XCTAssertEqual(c?["comments"], true); XCTAssertEqual(c?["reminders"], false); XCTAssertEqual(c?["agent_questions"], true)
        let again = try await f.t.json(.POST, "/v1/me/push-prefs", ["badge": false], token: f.owner.token)
        XCTAssertEqual(again.body?["showContent"] as? Bool, true)
        XCTAssertEqual(again.body?["badge"] as? Bool, false)
        let bad = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["spam": true]], token: f.owner.token)
        XCTAssertEqual(bad.status, .badRequest)
        let other = try await f.t.json(.GET, "/v1/me/push-prefs", token: f.guest.token)
        XCTAssertEqual(other.body?["showContent"] as? Bool, false)
    }

    // MARK: JWT and configuration

    func testJWTHeaderClaimsSignatureAndCache() async throws {
        let key = P256.Signing.PrivateKey()
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try APNsAuthProvider.makeJWT(key: key, keyID: "ABCDE12345", teamID: "TEAMID1234", issuedAt: issued)
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
        XCTAssertEqual(header["alg"] as? String, "ES256"); XCTAssertEqual(header["kid"] as? String, "ABCDE12345")
        XCTAssertEqual(claims["iss"] as? String, "TEAMID1234"); XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)
        XCTAssertFalse(jwt.contains("=") || jwt.contains("+") || jwt.contains("/"))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertEqual(decode(parts[2]).count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))

        // Cache: reused for 50 minutes, renewed afterwards; early invalidation only once 20 minutes old.
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let provider = try APNsAuthProvider(keyPEM: key.pemRepresentation, keyID: "ABCDE12345", teamID: "TEAMID1234", clock: { clock.now })
        let a = try await provider.token()
        clock.now += 49 * 60
        let b = try await provider.token()
        XCTAssertEqual(a, b)
        clock.now += 2 * 60
        let c = try await provider.token()
        XCTAssertNotEqual(a, c)
        await provider.invalidate()   // only 0 seconds old: must keep the token
        let d = try await provider.token()
        XCTAssertEqual(c, d)
        clock.now += 21 * 60
        await provider.invalidate()
        clock.now += 1
        let e = try await provider.token()
        XCTAssertNotEqual(d, e)
    }

    func testConfigurationValidation() throws {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".p8")
        defer { try? FileManager.default.removeItem(at: file) }
        try pem.write(to: file, atomically: true, encoding: .utf8)
        func load(_ v: [String: String]) throws -> AppSettings { try AppSettings.fromEnvironment(get: { v[$0] }) }
        // Old environments without APNs variables keep working; push stays off.
        XCTAssertFalse(try load([:]).apns.enabled)
        XCTAssertFalse(try load(["APNS_KEY_ID": "bogus"]).apns.enabled)
        let good = ["APNS_ENABLED": "true", "APNS_KEY_FILE": file.path, "APNS_KEY_ID": "ABCDE12345", "APNS_TEAM_ID": "TEAMID1234", "APNS_ENVIRONMENT": "sandbox"]
        let ok = try load(good).apns
        XCTAssertTrue(ok.enabled); XCTAssertEqual(ok.environment, .sandbox); XCTAssertEqual(ok.topics, ["de.linolaske.todo"])
        XCTAssertEqual(try load(good.merging(["APNS_TOPIC": "de.a.b, de.a.c"]) { $1 }).apns.topics, ["de.a.b", "de.a.c"])
        // Enabled but incomplete or broken: startup error with a message naming the problem.
        for (drop, fragment) in [("APNS_KEY_FILE", "APNS_KEY_FILE"), ("APNS_KEY_ID", "APNS_KEY_ID"), ("APNS_TEAM_ID", "APNS_TEAM_ID")] {
            var v = good; v[drop] = nil
            XCTAssertThrowsError(try load(v)) { XCTAssertTrue("\($0)".contains(fragment), "\($0)") }
        }
        XCTAssertThrowsError(try load(good.merging(["APNS_ENVIRONMENT": "staging"]) { $1 }))
        XCTAssertThrowsError(try load(good.merging(["APNS_KEY_ID": "short"]) { $1 }))
        XCTAssertThrowsError(try load(good.merging(["APNS_TOPIC": "nodots"]) { $1 }))
        XCTAssertThrowsError(try load(good.merging(["APNS_ENABLED": "yes"]) { $1 }))
        try "not a key".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try load(good)) { XCTAssertTrue("\($0)".contains("valid APNs .p8"), "\($0)") }
        XCTAssertThrowsError(try load(good.merging(["APNS_KEY_FILE": "/nonexistent/key"]) { $1 }))
    }

    // MARK: Delivery

    func testReminderIsSentOnceWithDedupeAndGenericContent() async throws {
        let f = try await fixture(guestRole: nil); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner)
        try await setReminder(f)
        let worker = f.worker
        let first = try await worker.tick()
        XCTAssertEqual(first.enqueued, 1); XCTAssertEqual(first.sent, 1)
        let req = try XCTUnwrap(f.mock.requests.first)
        XCTAssertEqual(req.environment, .sandbox)
        XCTAssertEqual(req.topic, "de.linolaske.todo")
        XCTAssertEqual(req.priority, 10)
        XCTAssertEqual(req.deviceToken, String(repeating: "ab", count: 32))
        XCTAssertNotNil(req.collapseID); XCTAssertLessThanOrEqual(req.collapseID?.utf8.count ?? 99, 64)
        XCTAssertGreaterThan(req.expiration, Int(Date().timeIntervalSince1970))
        XCTAssertFalse(req.jwt.isEmpty)
        let body = try payload(req)
        let aps = try XCTUnwrap(body["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertEqual(alert["title"] as? String, "Erinnerung")
        XCTAssertFalse(String(decoding: req.body, as: UTF8.self).contains("Quarterly"), "generic by default: no task title")
        XCTAssertEqual(body["kind"] as? String, "reminder")
        XCTAssertEqual(body["taskID"] as? String, f.task); XCTAssertEqual(body["projectID"] as? String, f.project)
        XCTAssertEqual(aps["thread-id"] as? String, f.project)
        // Same reminder again: nothing new, nothing sent.
        let second = try await worker.tick()
        XCTAssertEqual(second.enqueued, 0); XCTAssertEqual(f.mock.requests.count, 1)
        // A fresh sender run on another replica instance does not duplicate it either.
        let other = try await f.t.replica(); defer { Task { await other.shutdown() } }
        let third = try await PushWorker(app: other.app, sender: f.sender, interval: 0).tick()
        XCTAssertEqual(third.enqueued, 0); XCTAssertEqual(f.mock.requests.count, 1)
        // Content opt-in: title and English locale.
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["showContent": true], token: f.owner.token)
        try await setReminder(f, minutesAgo: 10)
        let fourth = try await worker.tick()
        XCTAssertEqual(fourth.sent, 1)
        let alert2 = try XCTUnwrap((try payload(f.mock.requests[1])["aps"] as? [String: Any])?["alert"] as? [String: Any])
        XCTAssertEqual(alert2["title"] as? String, "Quarterly tax filing")
    }

    func testOldAndFutureRemindersAndDoneTasksAreNotSent() async throws {
        let f = try await fixture(guestRole: nil); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner)
        try await setReminder(f, minutesAgo: 60 * 24)      // older than the lookback
        let v1 = try await f.worker.tick().enqueued
        XCTAssertEqual(v1, 0)
        try await setReminder(f, minutesAgo: -60)          // in the future
        let v2 = try await f.worker.tick().enqueued
        XCTAssertEqual(v2, 0)
        try await setReminder(f, minutesAgo: 5)
        let done = try await f.t.json(.PATCH, "/v1/tasks/\(f.task)", ["status": "done"], token: f.owner.token)
        _ = done
        let task = try await TodoTask.find(UUID(uuidString: f.task), on: f.t.app.db)!
        task.status = "done"; try await task.save(on: f.t.app.db)
        let v3 = try await f.worker.tick().enqueued
        XCTAssertEqual(v3, 0)
        XCTAssertTrue(f.mock.requests.isEmpty)
    }

    func testQuestionAndReviewReachCollaboratorsButNotTheirAuthor() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner, token: String(repeating: "01", count: 32))
        try await register(f, f.guest, token: String(repeating: "02", count: 32), env: "production", locale: "en-US")
        let q = try await f.t.json(.POST, "/v1/tasks/\(f.task)/questions", ["prompt": "Use SwiftData or GRDB?", "blocking": true], token: f.owner.token)
        XCTAssertEqual(q.status, .created)
        let r = try await f.t.json(.POST, "/v1/tasks/\(f.task)/review", ["summary": "Finished the migration"], token: f.owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let report = try await f.worker.tick()
        XCTAssertEqual(report.enqueued, 2); XCTAssertEqual(report.sent, 2)
        XCTAssertTrue(f.mock.requests.allSatisfy { $0.deviceToken == String(repeating: "02", count: 32) }, "the person who asked/requested gets no push")
        XCTAssertTrue(f.mock.requests.allSatisfy { $0.environment == .production })
        let kinds = Set(try f.mock.requests.map { try payload($0)["kind"] as? String ?? "" })
        XCTAssertEqual(kinds, ["question", "review"])
        let first = try payload(try XCTUnwrap(f.mock.requests.first { try payload($0)["kind"] as? String == "question" }))
        XCTAssertEqual(((first["aps"] as? [String: Any])?["alert"] as? [String: Any])?["title"] as? String, "Question from the agent")
        XCTAssertNotNil(first["subjectID"] as? String)
        XCTAssertNotNil((first["aps"] as? [String: Any])?["badge"], "badge counts open questions and reviews")
        // Answering withdraws a still queued notification at send time (state is rechecked).
        let q2 = try await f.t.json(.POST, "/v1/tasks/\(f.task)/questions", ["prompt": "Second?"], token: f.owner.token)
        let qid = try XCTUnwrap(q2.body?["id"] as? String)
        let pending = f.worker
        let triggers = PushTriggers(db: f.t.app.db, candidates: try await Candidate.load(on: f.t.app.db), since: Date().addingTimeInterval(-3600), now: Date())
        let v4 = try await triggers.run()
        XCTAssertEqual(v4, 1)
        _ = try await f.t.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "Yes"], token: f.owner.token)
        let before = f.mock.requests.count
        let late = try await pending.tick()
        XCTAssertEqual(late.skipped, 1); XCTAssertEqual(f.mock.requests.count, before)
    }

    func testCategoryDisabledAndRightsLostBeforeSendingMeanNothingIsSent() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await register(f, f.guest)
        _ = try await f.t.json(.POST, "/v1/tasks/\(f.task)/questions", ["prompt": "Which one?"], token: f.owner.token)
        // Enqueue only, then lose the grant before the sender runs.
        let triggers = PushTriggers(db: f.t.app.db, candidates: try await Candidate.load(on: f.t.app.db), since: Date().addingTimeInterval(-3600), now: Date())
        let v5 = try await triggers.run()
        XCTAssertEqual(v5, 1)
        let grants = try await f.t.json(.GET, "/v1/projects/\(f.project)/grants", token: f.owner.token)
        let gid = try XCTUnwrap(grants.list?.first { $0["principalID"] as? String == f.guest.id.uuidString }?["id"] as? String)
        _ = try await f.t.json(.DELETE, "/v1/projects/\(f.project)/grants/\(gid)", token: f.owner.token)
        let report = try await f.worker.tick()
        XCTAssertEqual(report.skipped, 1); XCTAssertEqual(report.sent, 0)
        XCTAssertTrue(f.mock.requests.isEmpty)
        let v6 = try await outbox(f).first?.lastError
        XCTAssertEqual(v6, "no_longer_relevant")
        // Without rights a new question is not even enqueued.
        _ = try await f.t.json(.POST, "/v1/tasks/\(f.task)/questions", ["prompt": "Another?"], token: f.owner.token)
        let v7 = try await f.worker.tick().enqueued
        XCTAssertEqual(v7, 0)
        // Category switched off: nothing is enqueued; one switched off after queueing is skipped.
        _ = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants", ["principalType": "person", "principalID": f.guest.id.uuidString, "role": "edit"], token: f.owner.token)
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["agent_questions": false]], token: f.guest.token)
        let v8 = try await f.worker.tick().enqueued
        XCTAssertEqual(v8, 0)
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["agent_questions": true]], token: f.guest.token)
        let t2 = PushTriggers(db: f.t.app.db, candidates: try await Candidate.load(on: f.t.app.db), since: Date().addingTimeInterval(-3600), now: Date())
        let v9 = try await t2.run()
        XCTAssertGreaterThan(v9, 0)
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["agent_questions": false]], token: f.guest.token)
        let late = try await f.worker.tick()
        XCTAssertGreaterThan(late.skipped, 0); XCTAssertTrue(f.mock.requests.isEmpty)
    }

    func testCommentsOnlyWhenEnabledAndNeverToTheAuthor() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner, token: String(repeating: "01", count: 32))
        try await register(f, f.guest, token: String(repeating: "02", count: 32))
        let c1 = try await f.t.json(.POST, "/v1/tasks/\(f.task)/comments", ["body": "private remark"], token: f.guest.token)
        XCTAssertEqual(c1.status, .created, "\(c1.body ?? [:])")
        let v10 = try await f.worker.tick().enqueued
        XCTAssertEqual(v10, 0, "comments are off by default")
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["comments": true]], token: f.owner.token)
        let report = try await f.worker.tick()
        XCTAssertEqual(report.enqueued, 1); XCTAssertEqual(report.sent, 1)
        XCTAssertEqual(f.mock.requests.first?.deviceToken, String(repeating: "01", count: 32))
        XCTAssertEqual(f.mock.requests.first?.priority, 5)
        XCTAssertFalse(String(decoding: f.mock.requests[0].body, as: UTF8.self).contains("private remark"), "comment text never leaves the server")
    }

    func testDeadTokensAreRevokedAndTransientFailuresBackOff() async throws {
        let f = try await fixture(guestRole: nil); defer { Task { await f.t.shutdown() } }
        let dead = String(repeating: "0d", count: 32), good = String(repeating: "0a", count: 32)
        try await register(f, f.owner, token: dead); try await register(f, f.owner, token: good)
        f.mock.handler = { r in
            r.deviceToken == dead ? APNsResponse(status: 410, reason: "Unregistered") : APNsResponse(status: 200, reason: nil)
        }
        try await setReminder(f)
        let report = try await f.worker.tick()
        XCTAssertEqual(report.sent, 1); XCTAssertEqual(report.revokedDevices, 1)
        let devices = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(devices.list?.count, 1)
        // BadDeviceToken revokes as well.
        f.mock.handler = { _ in APNsResponse(status: 400, reason: "BadDeviceToken") }
        try await setReminder(f, minutesAgo: 20)
        let bad = try await f.worker.tick()
        XCTAssertEqual(bad.revokedDevices, 1); XCTAssertEqual(bad.skipped, 1)
        let none = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(none.list?.count, 0)

        // Transient errors: 503, then success after the backoff; the row is not retried before it is due.
        try await register(f, f.owner, token: good)
        f.mock.handler = { _ in APNsResponse(status: 503, reason: "ServiceUnavailable") }
        try await setReminder(f, minutesAgo: 15)
        let retry = try await f.worker.tick()
        XCTAssertEqual(retry.retried, 1)
        let pendingRows = try await outbox(f).filter { $0.state == "pending" }
        let row = try XCTUnwrap(pendingRows.first)
        XCTAssertEqual(row.attempts, 1)
        XCTAssertGreaterThan(row.nextAttemptAt, Date().addingTimeInterval(20))
        let count = f.mock.requests.count
        _ = try await f.worker.tick()
        XCTAssertEqual(f.mock.requests.count, count, "not due yet")
        f.mock.handler = { _ in APNsResponse(status: 200, reason: nil) }
        row.nextAttemptAt = Date().addingTimeInterval(-1); try await row.save(on: f.t.app.db)
        let v11 = try await f.worker.tick().sent
        XCTAssertEqual(v11, 1)
        // 429 backs off too; after the last attempt the row fails instead of looping.
        f.mock.handler = { _ in APNsResponse(status: 429, reason: "TooManyRequests") }
        try await setReminder(f, minutesAgo: 8)
        _ = try await f.worker.tick()
        for _ in 0..<PushDelivery.maxAttempts {
            guard let r = try await outbox(f).first(where: { $0.state == "pending" }) else { break }
            r.nextAttemptAt = Date().addingTimeInterval(-1); try await r.save(on: f.t.app.db)
            _ = try await f.worker.tick()
        }
        let v12 = try await outbox(f).first { $0.state == "pending" }
        XCTAssertNil(v12)
        let v13 = try await outbox(f).first { $0.state == "failed" && $0.attempts == PushDelivery.maxAttempts }
        XCTAssertNotNil(v13)
        // Permanent configuration errors fail at once and keep the device.
        f.mock.handler = { _ in APNsResponse(status: 403, reason: "InvalidProviderToken") }
        try await setReminder(f, minutesAgo: 4)
        let v14 = try await f.worker.tick().failed
        XCTAssertEqual(v14, 1)
        let kept = try await f.t.json(.GET, "/v1/push/devices", token: f.owner.token)
        XCTAssertEqual(kept.list?.count, 1)
    }

    func testOnlyOneWorkerRunsAtATime() async throws {
        let f = try await fixture(guestRole: nil); defer { Task { await f.t.shutdown() } }
        let other = try await f.t.replica(); defer { Task { await other.shutdown() } }
        let a = PushWorker(app: f.t.app, sender: f.sender, interval: 15), b = PushWorker(app: other.app, sender: f.sender, interval: 15)
        async let ra = a.runIfDue(), rb = b.runIfDue()
        let results = await [ra, rb]
        let ran = results.filter { if case .ran = $0 { return true }; return false }
        XCTAssertEqual(ran.count, 1, "\(results)")
        // Within the interval nobody runs again; an expired lease of a crashed holder is taken over.
        let again = await [a.runIfDue(), b.runIfDue()]
        XCTAssertEqual(again, [.skipped, .skipped])
        guard let sql = f.t.app.db as? any SQLDatabase else { return XCTFail() }
        try await sql.raw("UPDATE maintenance_leases SET holder = 'crashed', expires_at = 1, last_run_at = 1 WHERE name = \(bind: PushWorker.jobName)").run()
        let taken = await b.runIfDue()
        if case .ran = taken {} else { XCTFail("lease was not taken over: \(taken)") }
    }

    func testHealthReportsPushStatusWithoutSecrets() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let on = try await f.t.json(.GET, "/health/ready")
        XCTAssertEqual((on.body?["push"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((on.body?["push"] as? [String: Any])?["environment"] as? String, "production")
        f.t.app.settings.apns = Self.config(enabled: false)
        let off = try await f.t.json(.GET, "/health/ready")
        XCTAssertEqual((off.body?["push"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertNil((off.body?["push"] as? [String: Any])?["keyID"])
    }

    func testDeletingAnAccountRemovesItsDevicesAndQueue() async throws {
        let f = try await fixture(guestRole: nil); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner); try await setReminder(f)
        _ = try await f.worker.tick()
        let v15 = try await PushDevice.query(on: f.t.app.db).count()
        XCTAssertEqual(v15, 1)
        _ = try await AccountDeletion.delete(userID: f.owner.id, on: f.t.app.db)
        let v16 = try await PushDevice.query(on: f.t.app.db).count()
        XCTAssertEqual(v16, 0)
        let v17 = try await PushOutbox.query(on: f.t.app.db).count()
        XCTAssertEqual(v17, 0)
    }
}
