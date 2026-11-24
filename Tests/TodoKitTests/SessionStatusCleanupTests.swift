import Fluent
import XCTVapor
@testable import TodoKit

/// `ExpiredCleanup` deletes session status rows that the overview has hidden for a while already (older than 24 hours).
final class SessionStatusCleanupTests: XCTestCase {
    private func seed(_ f: OAuthFixture, _ name: String, ago: TimeInterval, project: Project? = nil) async throws {
        try await SessionStatus(userID: try f.user.requireID(), projectID: try (project ?? f.project).requireID(), sessionName: name,
                                activity: "x", updatedAt: Date().addingTimeInterval(-ago)).save(on: f.test.app.db)
    }
    private func names(_ f: OAuthFixture) async throws -> Set<String> {
        Set(try await SessionStatus.query(on: f.test.app.db).all().map(\.sessionName))
    }

    func testCleanupRemovesSessionStatusesOlderThan24HoursOnly() async throws {
        let f = try await OAuthFixture.make()
        do {
            try await seed(f, "fresh", ago: 60)
            try await seed(f, "almost", ago: 23 * 3600)
            try await seed(f, "stale", ago: 25 * 3600)
            try await seed(f, "ancient-other-project", ago: 40 * 3600, project: f.other)
            let report = try await ExpiredCleanup().run(on: f.test.app.db)
            XCTAssertEqual(report.sessionStatuses, 2, "\(report)")
            XCTAssertGreaterThanOrEqual(report.total, 2)
            let left = try await names(f)
            XCTAssertEqual(left, ["fresh", "almost"])
            let again = try await ExpiredCleanup().run(on: f.test.app.db)
            XCTAssertEqual(again.sessionStatuses, 0, "idempotent")
            // Time shift instead of waiting: a day later the rest is gone as well.
            let later = try await ExpiredCleanup().run(on: f.test.app.db, now: Date().addingTimeInterval(25 * 3600))
            XCTAssertEqual(later.sessionStatuses, 2)
            let none = try await names(f)
            XCTAssertTrue(none.isEmpty)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRemovedRowsAreExactlyTheOnesTheOverviewHides() async throws {
        let f = try await OAuthFixture.make()
        do {
            try await seed(f, "visible", ago: 23 * 3600 + 3000)
            try await seed(f, "hidden", ago: 24 * 3600 + 60)
            let before = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            let shown = ((before.body?["projects"] as? [[String: Any]])?.first?["sessions"] as? [[String: Any]])?.compactMap { $0["sessionName"] as? String }
            XCTAssertEqual(shown, ["visible"])
            _ = try await ExpiredCleanup().run(on: f.test.app.db)
            let left = try await names(f)
            XCTAssertEqual(left, ["visible"])
            let after = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            let still = ((after.body?["projects"] as? [[String: Any]])?.first?["sessions"] as? [[String: Any]])?.compactMap { $0["sessionName"] as? String }
            XCTAssertEqual(still, shown, "the answer does not change")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
