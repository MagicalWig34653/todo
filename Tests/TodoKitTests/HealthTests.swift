import XCTVapor
@testable import TodoKit

final class HealthTests: XCTestCase {
    func testLiveAndReady() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        try configureDatabase(app, settings: DatabaseSettings(
            driver: .sqlite, host: "", port: 0, name: "", user: "", password: ""))
        try routes(app)

        try await app.test(.GET, "health/live") { res async in XCTAssertEqual(res.status, .ok) }
        try await app.test(.GET, "health/ready") { res async in XCTAssertEqual(res.status, .ok) }
    }
}
