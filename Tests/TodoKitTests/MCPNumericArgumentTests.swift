import XCTVapor
@testable import TodoKit

/// Numeric tool arguments arrive as JSON doubles; out-of-range values must become tool errors, never traps.
final class MCPNumericArgumentTests: XCTestCase {
    private func call(_ f: OAuthFixture, _ access: String, _ name: String, _ args: [String: Any]) async throws -> Bool {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        XCTAssertEqual(r.status, .ok)
        return ((r.body?["result"] as? [String: Any])?["isError"] as? Bool) == true
    }

    func testHugeAndFractionalNumbersAreToolErrorsAndServerSurvives() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let bad: [Any] = [1e100, -1e100, 1.5, 1e300, "abc", true, [1], 4e9]
            for key in ["limit", "offset", "laneLimit", "updatesLimit", "doneWithinDays"] {
                for value in bad {
                    let isError = try await call(f, tokens.access, "get_command_center", [key: value])
                    XCTAssertTrue(isError, "\(key)=\(value)")
                }
            }
            let id = UUID().uuidString
            for value in bad where !(value is String) {
                let a = try await call(f, tokens.access, "move_task_to_column", ["id": id, "version": value])
                XCTAssertTrue(a, "version=\(value)")
                let b = try await call(f, tokens.access, "move_task_to_column", ["id": id, "version": 1, "index": value])
                XCTAssertTrue(b, "index=\(value)")
            }
            // The server is still alive and a valid call works.
            let ok = try await call(f, tokens.access, "get_command_center", ["limit": 5])
            XCTAssertFalse(ok)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
