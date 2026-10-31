import Fluent
import XCTVapor
@testable import TodoKit

final class LiveRefreshTests: XCTestCase {
    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func token(_ t: TestApp, _ session: String) async throws -> String {
        let r = try await t.json(.GET, "/v1/sync/head", token: session)
        XCTAssertEqual(r.status, .ok)
        return try XCTUnwrap(r.body?["token"] as? String)
    }

    private func mutate(_ t: TestApp, _ session: String, _ type: String, id: String, _ f: [String: Any] = [:]) async throws {
        var body: [String: Any] = ["mutationID": UUID().uuidString, "type": type, "id": id]
        body.merge(f) { $1 }
        let r = try await t.json(.POST, "/v1/sync/mutations", body, token: session)
        XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(type): \(r.status)")
    }

    func testHeadAuthEtagAndCapabilities() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let anon = try await t.json(.GET, "/v1/sync/head")
        XCTAssertEqual(anon.status, .unauthorized)
        let first = try await token(t, a.token)
        var status = HTTPStatus.ok
        try await t.app.test(.GET, "/v1/sync/head", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: a.token)
            req.headers.replaceOrAdd(name: .ifNoneMatch, value: "\"\(first)\"")
        }, afterResponse: { res async in status = res.status })
        XCTAssertEqual(status, .notModified)
        let caps = try await t.json(.GET, "/v1/capabilities")
        let live = try XCTUnwrap(caps.body?["liveRefresh"] as? [String: Any])
        XCTAssertEqual(live["head"] as? Bool, true)
        XCTAssertEqual(live["wait"] as? Bool, true)
        XCTAssertEqual(live["pollSeconds"] as? Int, 5)
    }

    func testTokenRisesForTaskCommentQuestionProgressAndPlanning() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        var last = try await token(t, a.token)
        func expectChange(_ what: String, _ body: () async throws -> Void) async throws {
            try await body()
            let now = try await token(t, a.token)
            XCTAssertNotEqual(now, last, what)
            last = now
        }
        let project = UUID().uuidString, task = UUID().uuidString
        try await expectChange("project") { try await mutate(t, a.token, "project.create", id: project, ["name": "P"]) }
        try await expectChange("task") { try await mutate(t, a.token, "task.create", id: task, ["title": "T", "projectID": project]) }
        try await expectChange("planning") {
            let v = try await TodoTask.find(UUID(uuidString: task), on: t.app.db)!.version
            try await mutate(t, a.token, "task.planning", id: task, ["version": v, "priority": 2])
        }
        try await expectChange("comment") {
            let r = try await t.json(.POST, "/v1/tasks/\(task)/comments", ["body": "hi"], token: a.token)
            XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(r.status)")
        }
        try await expectChange("question") {
            let r = try await t.json(.POST, "/v1/tasks/\(task)/questions", ["prompt": "Sure?"], token: a.token)
            XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(r.status)")
        }
        try await expectChange("progress") {
            let r = try await t.json(.POST, "/v1/tasks/\(task)/progress-notes", ["note": "half"], token: a.token)
            XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(r.status)")
        }
        try await expectChange("review") {
            let r = try await t.json(.POST, "/v1/tasks/\(task)/review", ["summary": "done"], token: a.token)
            XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(r.status)")
        }
        // Nothing changed: stable.
        let again = try await token(t, a.token)
        XCTAssertEqual(again, last)
    }

    func testWaitTimesOutEmptyAndReturnsImmediatelyOnStaleToken() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.pollInterval = 0.1
        let a = try await account(t)
        let cur = try await token(t, a.token)
        let started = Date()
        let r = try await t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=1", token: a.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["changed"] as? Bool, false)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
        let stale = try await t.json(.GET, "/v1/sync/wait?since=lstale&timeout=5", token: a.token)
        XCTAssertEqual(stale.body?["changed"] as? Bool, true)
        let none = try await t.json(.GET, "/v1/sync/wait", token: a.token)
        XCTAssertEqual(none.body?["changed"] as? Bool, false)
    }

    func testWaitWakesOnChangeFromOtherReplicaAndManyWaiters() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.pollInterval = 0.1
        let other = try await t.replica()
        defer { Task { await other.shutdown() } }
        let a = try await account(t), b = try await account(t)
        let cur = try await token(t, a.token)
        async let w1 = t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=10", token: a.token)
        async let w2 = t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=10", token: b.token)
        try await Task.sleep(nanoseconds: 400_000_000)
        // The write goes through the other app instance (own hub, own connection pool, same database).
        try await mutate(other, b.token, "project.create", id: UUID().uuidString, ["name": "X"])
        let (r1, r2) = try await (w1, w2)
        XCTAssertEqual(r1.body?["changed"] as? Bool, true)
        XCTAssertEqual(r2.body?["changed"] as? Bool, true)
        XCTAssertNotEqual(r1.body?["token"] as? String, cur)
    }

    func testRevokedSessionEndsWaitAndLimitsApply() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.pollInterval = 0.1
        t.app.liveSettings.sessionRecheckSeconds = 0.3
        t.app.liveSettings.maxWaitersPerAccount = 1
        let a = try await account(t)
        let cur = try await token(t, a.token)
        async let first = t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=10", token: a.token)
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = try await t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=1", token: a.token)
        XCTAssertEqual(second.status, .tooManyRequests)
        try await UserSession.query(on: t.app.db).delete()
        let r = try await first
        XCTAssertEqual(r.status, .unauthorized)
    }

    func testDisabledHidesRoutesAndCapability() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.enabled = false
        let a = try await account(t)
        let r = try await t.json(.GET, "/v1/sync/head", token: a.token)
        XCTAssertEqual(r.status, .notFound)
        let caps = try await t.json(.GET, "/v1/capabilities")
        XCTAssertNil(caps.body?["liveRefresh"])
    }
}
