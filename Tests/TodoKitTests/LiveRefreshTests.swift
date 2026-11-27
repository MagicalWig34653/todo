import Fluent
import NIOCore
import NIOPosix
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

    /// Deterministic sync: blocks until the hub has registered `count` waiters (bounded, fails otherwise).
    private func waitForWaiters(_ t: TestApp, _ count: Int) async throws {
        for _ in 0..<500 {
            if await t.app.liveHub.waiterCount >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("waiters not registered")
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

    /// Card A7865053: binding, re-binding with a threshold, and unbinding a repository move the live token, so an open repository
    /// line refreshes on the hint (they were the only project writes without one, the line stayed stale until a reload).
    func testTokenRisesForRepositoryBindingChanges() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let project = try await t.json(.POST, "/v1/projects", ["name": "Bindungen"], token: a.token)
        let projectID = try XCTUnwrap(project.body?["id"] as? String)
        var last = try await token(t, a.token)
        func step(_ what: String, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil) async throws {
            let r = body == nil ? try await t.json(method, path, token: a.token) : try await t.json(method, path, body!, token: a.token)
            XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(what): \(r.status)")
            let now = try await token(t, a.token)
            XCTAssertNotEqual(now, last, what)
            last = now
        }
        try await step("repository bound", .PUT, "/v1/projects/\(projectID)/sync", ["repository": "github.com/example/eins"])
        try await step("second repository bound", .PUT, "/v1/projects/\(projectID)/sync", ["repository": "github.com/example/zwei"])
        try await step("threshold changed", .PUT, "/v1/projects/\(projectID)/sync", ["repository": "github.com/example/zwei", "staleAfterDays": 7])
        try await step("repository unbound", .DELETE, "/v1/projects/\(projectID)/bindings?repository=github.com/example/eins")
    }

    func testTokenRisesForTeamInvitationAndGrant() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t), b = try await account(t)
        var last = try await token(t, b.token)
        let team = try await t.json(.POST, "/v1/teams", ["name": "Live"], token: a.token)
        XCTAssertTrue((200..<300).contains(Int(team.status.code)), "\(team.status)")
        let teamID = try XCTUnwrap(team.body?["id"] as? String)
        var now = try await token(t, b.token)
        XCTAssertNotEqual(now, last, "team created")
        last = now
        let invite = try await t.json(.PUT, "/v1/teams/\(teamID)/members", ["userID": b.id, "isAdmin": false], token: a.token)
        XCTAssertTrue((200..<300).contains(Int(invite.status.code)), "\(invite.status)")
        now = try await token(t, b.token)
        XCTAssertNotEqual(now, last, "team invitation")
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
        try await waitForWaiters(t, 2)
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
        try await waitForWaiters(t, 1)
        let second = try await t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=1", token: a.token)
        XCTAssertEqual(second.status, .tooManyRequests)
        try await UserSession.query(on: t.app.db).delete()
        let r = try await first
        XCTAssertEqual(r.status, .unauthorized)
    }

    private func waitForRegistrations(_ t: TestApp, _ count: Int) async throws {
        for _ in 0..<500 {
            if await t.app.liveHub.registrations >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("waits not registered")
    }

    /// A replaced or shut-down wait that carries a newer token must say `changed`, otherwise the client takes over the token
    /// without reloading and misses the change until the next one.
    func testSupersededAndShutdownRepliesReportAChangedToken() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.pollInterval = 30 // the poller must not wake the first wait before it is replaced
        let a = try await account(t)
        let old = try await token(t, a.token)
        async let first = t.json(.GET, "/v1/sync/wait?since=\(old)&timeout=10&client=tab-aaaaaaaa", token: a.token)
        try await waitForRegistrations(t, 1)
        try await mutate(t, a.token, "project.create", id: UUID().uuidString, ["name": "X"])
        let new = try await token(t, a.token)
        async let second = t.json(.GET, "/v1/sync/wait?since=\(new)&timeout=10&client=tab-aaaaaaaa", token: a.token)
        let replaced = try await first
        XCTAssertEqual(replaced.body?["token"] as? String, new)
        XCTAssertEqual(replaced.body?["changed"] as? Bool, true)
        XCTAssertEqual(replaced.body?["retryAfter"] as? Int, 2)
        try await waitForRegistrations(t, 2)
        try await mutate(t, a.token, "project.create", id: UUID().uuidString, ["name": "Y"])
        await t.app.liveHub.shutdown()
        let ended = try await second
        XCTAssertNotEqual(ended.body?["token"] as? String, new)
        XCTAssertEqual(ended.body?["changed"] as? Bool, true)
        XCTAssertEqual(ended.body?["retryAfter"] as? Int, 2)
    }

    func testSameClientKeyOfAnotherAccountReplacesNothing() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.pollInterval = 30
        let a = try await account(t), b = try await account(t)
        let cur = try await token(t, a.token)
        async let first = t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=1&client=tab-aaaaaaaa", token: a.token)
        try await waitForRegistrations(t, 1)
        async let second = t.json(.GET, "/v1/sync/wait?since=\(cur)&timeout=1&client=tab-aaaaaaaa", token: b.token)
        try await waitForRegistrations(t, 2)
        let count = await t.app.liveHub.waiterCount
        XCTAssertEqual(count, 2)
        let (r1, r2) = try await (first, second)
        XCTAssertNil(r1.body?["retryAfter"] as? Int)
        XCTAssertNil(r2.body?["retryAfter"] as? Int)
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

/// Card A1A4690B: the PWA got 429 on /v1/sync/wait after quick page changes. Every page change or reload aborts the browser's
/// pending long poll, but the server cannot see that and kept the abandoned waiter registered until its deadline (up to 25 s),
/// counted against the per-account limit of 8. A client key (`client=`, one per tab) lets a newer wait replace the older one.
final class LiveRefreshDisconnectTests: XCTestCase {
    /// One raw HTTP/1.1 request over its own TCP connection (Linux has no URLSession without FoundationNetworking).
    /// `cancel()` closes the connection like a browser that leaves the page; `value` is the status (-1: no response).
    final class RawRequest: @unchecked Sendable {
        private final class Collect: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            let done: EventLoopPromise<String>
            var text = ""
            init(_ done: EventLoopPromise<String>) { self.done = done }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) { text += String(buffer: unwrapInboundIn(data)) }
            func channelInactive(context: ChannelHandlerContext) { done.succeed(text) }
            func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
        }
        private let channel: Channel
        private let done: EventLoopFuture<String>

        init(port: Int, path: String, bearer: String) async throws {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let promise = loop.makePromise(of: String.self)
            channel = try await ClientBootstrap(group: loop)
                .channelInitializer { $0.pipeline.addHandler(Collect(promise)) }
                .connect(host: "127.0.0.1", port: port).get()
            done = promise.futureResult
            let head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(bearer)\r\nConnection: close\r\n\r\n"
            try await channel.writeAndFlush(channel.allocator.buffer(string: head)).get()
        }

        func cancel() { channel.close(promise: nil) }

        var value: Int {
            get async {
                let text = (try? await done.get()) ?? ""
                let parts = text.split(separator: " ", maxSplits: 2)
                return parts.count > 1 ? Int(parts[1]) ?? -1 : -1
            }
        }
    }

    private struct Fixture {
        let t: TestApp
        let session: String
        let current: String
        let port: Int

        /// Starts a wait over real HTTP.
        func wait(client: String?, timeout: Int = 3) async throws -> RawRequest {
            var path = "/v1/sync/wait?since=\(current)&timeout=\(timeout)"
            if let client { path += "&client=\(client)" }
            return try await RawRequest(port: port, path: path, bearer: session)
        }

        /// Starts a wait and returns once the hub has registered it (so requests reach the server strictly in order).
        func registeredWait(client: String?, timeout: Int = 3) async throws -> RawRequest {
            let before = await t.app.liveHub.registrations
            let w = try await wait(client: client, timeout: timeout)
            for _ in 0..<250 {
                if await t.app.liveHub.registrations > before { return w }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("wait was not registered")
            return w
        }

        func waiters(_ n: Int) async throws {
            for _ in 0..<100 {
                if await t.app.liveHub.waiterCount == n { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let now = await t.app.liveHub.waiterCount
            XCTFail("expected \(n) registered waiters, have \(now)")
        }
    }

    /// Real HTTP server (client disconnects only exist there), account limit 3.
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        t.app.liveSettings.pollInterval = 0.1
        t.app.liveSettings.maxWaitersPerAccount = 3
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let session = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(session),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        let head = try await t.json(.GET, "/v1/sync/head", token: session)
        let current = try XCTUnwrap(head.body?["token"] as? String)
        let probe = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).wait()
        let port = try XCTUnwrap(probe.localAddress?.port)
        try probe.close().wait()
        try await t.app.server.start(address: .hostname("127.0.0.1", port: port))
        do { try await body(Fixture(t: t, session: session, current: current, port: port)) } catch { await t.app.server.shutdown(); throw error }
        await t.app.server.shutdown()
    }

    func testQuickPageChangesOfOneTabNeverExceedTheAccountLimit() async throws {
        try await withFixture { f in
            // Each round is one page load: the browser aborts its pending wait and the new page waits again, far more
            // often than the limit of 3 allows for abandoned requests.
            var older: [RawRequest] = []
            for _ in 0..<8 {
                let w = try await f.registeredWait(client: "tab-0123456789")
                older.append(w)
                try await f.waiters(1) // the newer wait replaced the abandoned one
                w.cancel() // the browser let go; the server still holds the request
            }
            // The newest request is accepted (not 429) and is the only waiter left; every abandoned one ended at once.
            let last = try await f.registeredWait(client: "tab-0123456789", timeout: 1)
            let status = await last.value
            XCTAssertEqual(status, 200)
            for w in older { let s = await w.value; XCTAssertNotEqual(s, 429) }
            try await f.waiters(0)
        }
    }

    func testOtherTabsKeepTheirOwnWaitAndLimitStillApplies() async throws {
        try await withFixture { f in
            let a = try await f.registeredWait(client: "tab-aaaaaaaa", timeout: 4)
            let b = try await f.registeredWait(client: "tab-bbbbbbbb", timeout: 4)
            let c = try await f.registeredWait(client: "tab-cccccccc", timeout: 4)
            try await f.waiters(3)
            let d = await (try await f.wait(client: "tab-dddddddd", timeout: 1)).value
            XCTAssertEqual(d, 429, "a fourth tab is still limited")
            // Without a client key (old clients) every request counts on its own, as before.
            let anonymous = await (try await f.wait(client: nil, timeout: 1)).value
            XCTAssertEqual(anonymous, 429)
            // They end by their own deadline: the server must be idle again before the test app shuts down.
            for w in [a, b, c] { let s = await w.value; XCTAssertEqual(s, 200) }
        }
    }

    func testClientKeyIsValidated() {
        XCTAssertEqual(LiveController.clientID("tab-0123456789"), "tab-0123456789")
        XCTAssertNil(LiveController.clientID(nil))
        XCTAssertNil(LiveController.clientID("short"))
        XCTAssertNil(LiveController.clientID(String(repeating: "a", count: 65)))
        XCTAssertNil(LiveController.clientID("tab 0123456789"))
        XCTAssertNil(LiveController.clientID("tab-ä123456789"))
    }
}
