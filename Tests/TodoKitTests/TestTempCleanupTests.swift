import Foundation
import XCTVapor
@testable import TodoKit

/// Guards the test harness itself: scratch SQLite files must not pile up in TMPDIR (card F49E0207,
/// ~8 GB/day of `todo-<UUID>.sqlite` before the fix).
final class TestTempCleanupTests: XCTestCase {
    func testScratchDatabasesLiveInADedicatedDirectoryNotDirectlyInTmpdir() throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        let dir = URL(fileURLWithPath: TestApp.sqliteFile).deletingLastPathComponent().standardizedFileURL
        XCTAssertNotEqual(dir.path, FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    private func companions(_ path: String) -> [String] {
        ["", "-wal", "-shm"].map { path + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    func testShutdownRemovesTheScratchDatabaseIncludingWalAndShm() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        let t = try await TestApp.make()
        let path = try XCTUnwrap(t.sqliteFilePath)
        // Writing through the connection pool makes SQLite create the -wal/-shm companions.
        let user = User(displayName: "Temp Cleanup", isAdmin: false)
        try await user.save(on: t.app.db)
        XCTAssertFalse(companions(path).isEmpty, "the app should be using a scratch file")
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL, TestTemp.directory.standardizedFileURL)
        await t.shutdown()
        XCTAssertEqual(companions(path), [])
    }

    func testReplicaShutdownKeepsTheSharedDatabaseUntilThePrimaryShutsDown() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        let primary = try await TestApp.make()
        let path = try XCTUnwrap(primary.sqliteFilePath)
        let replica = try await primary.replica()
        XCTAssertEqual(replica.sqliteFilePath, path)
        await replica.shutdown()
        XCTAssertFalse(companions(path).isEmpty, "replica must not delete the shared file")
        await primary.shutdown()
        XCTAssertEqual(companions(path), [])
    }

    func testStaleScratchDirectoriesOfDeadProcessesAreSweptOnStart() throws {
        try XCTSkipIf(TestApp.useMariaDB, "SQLite scratch files only")
        // A pid that cannot belong to a live process; the sweep runs once per process, so call it directly.
        let stale = FileManager.default.temporaryDirectory.appendingPathComponent("todo-tests-2147483646-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stale) }
        TestTemp.sweepStale()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// sqlite-kit fakes `.sqlite(.memory)` with `sqlite-kit_memorydb-<pid>-<UUID>.sqlite3` in TMPDIR and never deletes
    /// it (1185 files, 1.3 GB seen on 24.11.2026). Tests use scratch files instead, and the exit hook sweeps the rest.
    func testInMemoryFallbackFilesOfThisProcessAreSweptAndForeignOnesKept() throws {
        let tmp = FileManager.default.temporaryDirectory
        let own = tmp.appendingPathComponent("sqlite-kit_memorydb-\(getpid())-\(UUID().uuidString).sqlite3")
        let foreign = tmp.appendingPathComponent("sqlite-kit_memorydb-1-\(UUID().uuidString).sqlite3")
        for url in [own, foreign] { try Data("x".utf8).write(to: url) }
        defer { try? FileManager.default.removeItem(at: foreign); try? FileManager.default.removeItem(at: own) }
        TestTemp.sweepOwnMemoryDatabases()
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testScratchDatabaseSettingsUseAFileInTheScratchDirectory() throws {
        let settings = DatabaseSettings.testScratch
        XCTAssertEqual(settings.driver, .sqlite)
        XCTAssertTrue(settings.name.hasPrefix(TestTemp.directory.path))
    }
}
