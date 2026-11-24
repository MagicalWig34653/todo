import Foundation
import XCTVapor
@testable import TodoKit

/// Guards the test harness itself: scratch SQLite files must not pile up in TMPDIR (card F49E0207,
/// ~8 GB/day of `todo-<UUID>.sqlite` before the fix).
final class TestTempCleanupTests: XCTestCase {
    private func sqliteLeftovers(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".sqlite") || $0.hasSuffix(".sqlite-wal") || $0.hasSuffix(".sqlite-shm") })
    }

    func testScratchDatabasesLiveInADedicatedDirectoryNotDirectlyInTmpdir() throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        let dir = URL(fileURLWithPath: TestApp.sqliteFile).deletingLastPathComponent().standardizedFileURL
        XCTAssertNotEqual(dir.path, FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    func testShutdownRemovesTheScratchDatabaseIncludingWalAndShm() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        let dir = URL(fileURLWithPath: TestApp.sqliteFile).deletingLastPathComponent()
        let before = sqliteLeftovers(in: dir)
        let t = try await TestApp.make()
        // Writing through the connection pool makes SQLite create the -wal/-shm companions.
        let user = User(displayName: "Temp Cleanup", isAdmin: false)
        try await user.save(on: t.app.db)
        XCTAssertGreaterThan(sqliteLeftovers(in: dir).count, before.count, "the app should be using a scratch file")
        await t.shutdown()
        XCTAssertEqual(sqliteLeftovers(in: dir), before)
    }

    func testReplicaShutdownKeepsTheSharedDatabaseUntilThePrimaryShutsDown() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        let dir = URL(fileURLWithPath: TestApp.sqliteFile).deletingLastPathComponent()
        let before = sqliteLeftovers(in: dir)
        let primary = try await TestApp.make()
        let replica = try await primary.replica()
        await replica.shutdown()
        XCTAssertGreaterThan(sqliteLeftovers(in: dir).count, before.count, "replica must not delete the shared file")
        await primary.shutdown()
        XCTAssertEqual(sqliteLeftovers(in: dir), before)
    }
}
