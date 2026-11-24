import Fluent
import FluentSQLiteDriver
import XCTVapor
@testable import TodoKit

/// SQLite write contention (card 3C2E7F9D; E2E runs 45298835211, 45300226759, 45291638604 answered HTTP 500
/// "busy: database is locked").
///
/// The pool keeps one connection per event loop, and request handlers and background workers (webhook, mail, push,
/// maintenance) write from different loops. Findings these tests pin down:
/// - sqlite-nio's own busy handler retries forever without sleeping, so a plain write already waits, but without a bound.
/// - A Fluent transaction that reads before it writes holds a read lock when it asks for the write lock; SQLite then
///   skips every busy handler and fails at once with SQLITE_BUSY.
final class SQLiteBusyTimeoutTests: XCTestCase {
    private let lockHold = Duration.milliseconds(400)

    private func eventLoops(of app: Application) -> [any EventLoop] {
        Array(app.eventLoopGroup.makeIterator())
    }

    /// Holds the SQLite write lock on a raw second connection for `lockHold`, like a worker mid-transaction would,
    /// while `work` runs; returns how long `work` took.
    private func duringForeignWriteLock(path: String, app: Application, on loop: any EventLoop,
                                        _ work: @escaping @Sendable () async throws -> Void) async throws -> Duration {
        let foreign = try await SQLiteConnection.open(
            storage: .file(path: path), threadPool: app.threadPool, logger: app.logger, on: loop).get()
        _ = try await foreign.query("BEGIN IMMEDIATE").get()
        let worker = Task { () throws -> Duration in
            let started = ContinuousClock.now
            try await work()
            return started.duration(to: .now)
        }
        try await Task.sleep(for: lockHold)
        _ = try await foreign.query("COMMIT").get()
        try await foreign.close().get()
        return try await worker.value
    }

    func testEveryEventLoopConnectionReportsABusyTimeoutOfFiveSeconds() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite only")
        let t = try await TestApp.make()
        do {
            for (index, loop) in eventLoops(of: t.app).enumerated() {
                let db = try XCTUnwrap(t.app.databases.database(.sqlite, logger: t.app.logger, on: loop))
                let sqlite = try XCTUnwrap(db as? any SQLiteDatabase)
                let rows = try await sqlite.query("PRAGMA busy_timeout").get()
                let timeout = try rows.first?.decode(column: "timeout", as: Int.self)
                XCTAssertEqual(timeout, 5000, "loop \(index)")
            }
        } catch {
            await t.shutdown()
            throw error
        }
        await t.shutdown()
    }

    private struct Boom: Error {}

    func testTransactionRollsBackOnErrorAndNestedTransactionsJoinTheOuterOne() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite only")
        let t = try await TestApp.make()
        do {
            let db = t.app.db
            let rolledBack = User(displayName: "Rolled Back", isAdmin: false)
            do {
                try await db.transaction { tx in
                    try await rolledBack.save(on: tx)
                    throw Boom()
                }
                XCTFail("the error must reach the caller")
            } catch is Boom {}
            let rolledBackCount = try await User.query(on: db).filter(\.$displayName == "Rolled Back").count()
            XCTAssertEqual(rolledBackCount, 0)

            let outer = User(displayName: "Nested Outer", isAdmin: false)
            let inner = User(displayName: "Nested Inner", isAdmin: false)
            try await db.transaction { tx in
                try await outer.save(on: tx)
                XCTAssertTrue(tx.inTransaction)
                try await tx.transaction { nested in try await inner.save(on: nested) }
            }
            let nestedCount = try await User.query(on: db).filter(\.$displayName ~~ "Nested ").count()
            XCTAssertEqual(nestedCount, 2)

            // Raw SQL keeps working through the wrapper (48 call sites cast the database to SQLDatabase).
            let sql = try XCTUnwrap(db as? any SQLDatabase)
            let rows = try await sql.raw("SELECT COUNT(*) AS n FROM users WHERE display_name LIKE 'Nested %'").all()
            XCTAssertEqual(try rows.first?.decode(column: "n", as: Int.self), 2)
        } catch {
            await t.shutdown()
            throw error
        }
        await t.shutdown()
    }

    func testTransactionThatReadsBeforeItWritesWaitsForAForeignWriteLockOnEveryEventLoop() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite only")
        let t = try await TestApp.make()
        do {
            let path = try XCTUnwrap(t.sqliteFilePath)
            let loops = eventLoops(of: t.app)
            XCTAssertGreaterThan(loops.count, 1, "every loop owns its own connection, so more than one loop is the point")
            let app = t.app
            for (index, loop) in loops.enumerated() {
                let user = User(displayName: "Busy Transaction \(index)", isAdmin: false)
                let waited = try await duringForeignWriteLock(path: path, app: app, on: loop) {
                    let db = try XCTUnwrap(app.databases.database(.sqlite, logger: app.logger, on: loop))
                    try await db.transaction { tx in
                        _ = try await User.query(on: tx).count()
                        try await user.save(on: tx)
                    }
                }
                XCTAssertGreaterThanOrEqual(waited, .milliseconds(300), "loop \(index) did not wait for the lock")
                let id = try XCTUnwrap(user.id)
                let db = try XCTUnwrap(app.databases.database(.sqlite, logger: app.logger, on: loop))
                let stored = try await User.find(id, on: db)
                XCTAssertEqual(stored?.displayName, "Busy Transaction \(index)")
            }
        } catch {
            await t.shutdown()
            throw error
        }
        await t.shutdown()
    }
}
