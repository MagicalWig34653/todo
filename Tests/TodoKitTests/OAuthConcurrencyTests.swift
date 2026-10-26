import XCTVapor
@testable import TodoKit

final class OAuthConcurrencyTests: XCTestCase {
    func testConcurrentRefreshHasOneWinnerAndRevokesFamily() async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("MariaDB row locks required") }
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let data = try JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "client_id": f.clientID,
                "resource": OAuthController.resource, "refresh_token": tokens.refresh])
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for _ in 0..<2 {
                    group.addTask { try await f.test.rawStatus(.POST, "/oauth/token", body: data) }
                }
                var statuses: [HTTPStatus] = []
                for try await status in group { statuses.append(status) }
                return statuses
            }
            XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1)
            XCTAssertEqual(statuses.filter { $0 == .badRequest }.count, 1)
            let denied = try await f.rpc("tools/list", access: tokens.access)
            XCTAssertEqual(denied.status, .unauthorized)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
