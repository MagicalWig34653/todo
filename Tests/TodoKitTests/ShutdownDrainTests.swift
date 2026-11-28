import Fluent
import NIOCore
import NIOPosix
import XCTVapor
@testable import TodoKit

/// Card 395200D3: shutting the application down with requests in flight closed the databases first; a request that then
/// asked for `req.db` hit Fluent's force unwrap and took the whole process down. Open requests must be answered first.
final class ShutdownDrainTests: XCTestCase {
    private struct Running {
        let t: TestApp
        let session: String
        let port: Int
    }

    private func start(_ configure: (Application) -> Void = { _ in }) async throws -> Running {
        let t = try await TestApp.make()
        configure(t.app)
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let session = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(session),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(probe.localAddress?.port)
        try await probe.close().get()
        // The real `serve` command, as in production: it owns the server and stops it while the application shuts down.
        t.app.environment.arguments = ["App", "serve", "--hostname", "127.0.0.1", "--port", String(port)]
        try await t.app.startup()
        return Running(t: t, session: session, port: port)
    }

    /// `serve` ignores SIGINT and SIGTERM in favour of its own handlers; give the test process its signals back.
    override func tearDown() async throws {
        signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL)
    }

    func testShutdownWithAnOpenWaitAnswersItBeforeTheDatabaseCloses() async throws {
        let r = try await start()
        r.t.app.liveSettings.pollInterval = 0.1
        let head = try await r.t.json(.GET, "/v1/sync/head", token: r.session)
        let current = try XCTUnwrap(head.body?["token"] as? String)
        var waits: [LiveRefreshDisconnectTests.RawRequest] = []
        for client in ["tab-aaaaaaaa", "tab-bbbbbbbb"] {
            waits.append(try await LiveRefreshDisconnectTests.RawRequest(
                port: r.port, path: "/v1/sync/wait?since=\(current)&timeout=20&client=\(client)", bearer: r.session))
        }
        for _ in 0..<500 {
            if await r.t.app.liveHub.waiterCount == 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let waiting = await r.t.app.liveHub.waiterCount
        XCTAssertEqual(waiting, 2)

        let started = Date()
        await r.t.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "open waits end at once, not at their deadline")
        for w in waits {
            let status = await w.value
            XCTAssertEqual(status, 200)
        }
    }

    /// Not only long polls: any request that is still working may use the database after the shutdown began.
    func testShutdownWaitsForARunningRequestThatStillNeedsTheDatabase() async throws {
        let entered = Locked(false)
        let r = try await start { app in
            app.get("test-slow") { req async throws -> String in
                entered.value = true
                try await Task.sleep(nanoseconds: 500_000_000)
                return "\(try await User.query(on: req.db).count())"
            }
        }
        let slow = try await LiveRefreshDisconnectTests.RawRequest(port: r.port, path: "/test-slow", bearer: r.session)
        for _ in 0..<500 {
            if entered.value { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(entered.value)
        await r.t.shutdown()
        let status = await slow.value
        XCTAssertEqual(status, 200)
    }
}
