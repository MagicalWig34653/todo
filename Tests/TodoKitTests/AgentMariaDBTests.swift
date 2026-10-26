import Fluent
import XCTVapor
@testable import TodoKit

final class AgentMariaDBTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs MariaDB (TODO_TEST_MARIADB=1)")
    }

    func testConcurrentClaimsAcrossTwoReplicasHaveExactlyOneWinner() async throws {
        let f = try await AgentFixture.make()
        let replica = try await f.app.replica()
        defer { Task { await f.app.shutdown(); await replica.shutdown() } }
        let job = try await f.release()
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<8 {
                let app = i.isMultiple(of: 2) ? f.app : replica
                group.addTask {
                    try await app.rawStatus(.POST, "/v1/runner/jobs/\(job)/claim", body: Data("{}".utf8), token: f.runner)
                }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
        XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 7, "\(statuses)")
        let runs = try await AgentRun.query(on: f.app.app.db).filter(\.$jobID == UUID(uuidString: job)!).all()
        XCTAssertEqual(runs.count, 1)
        // A new replica sees the lease without any in-process state.
        let visible = try await replica.json(.GET, "/v1/runner/runs", token: f.runner)
        XCTAssertEqual(visible.list?.count, 1)
        let runID = try XCTUnwrap(visible.list?.first?["id"] as? String)
        let heartbeat = try await replica.json(.POST, "/v1/runner/runs/\(runID)/heartbeat", ["generation": 1], token: f.runner)
        XCTAssertEqual(heartbeat.status, .ok)
    }

    func testDifferentJobsOnAliasBindingsCannotClaimSameRepositoryConcurrently() async throws {
        let f = try await AgentFixture.make()
        let replica = try await f.app.replica()
        defer { Task { await f.app.shutdown(); await replica.shutdown() } }
        let alias = try await f.app.json(.POST, "/v1/agents/bindings", ["deviceID": f.deviceID, "projectID": f.projectID,
            "repositoryKey": f.repositoryKey, "label": "Alias"], token: f.human)
        let aliasID = try XCTUnwrap(alias.body?["id"] as? String)
        let first = try await f.release()
        let second = try await f.release(binding: aliasID)
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for (app, job) in [(f.app, first), (replica, second)] {
                group.addTask {
                    try await app.rawStatus(.POST, "/v1/runner/jobs/\(job)/claim", body: Data("{}".utf8), token: f.runner)
                }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
        XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 1, "\(statuses)")
        let runs = try await AgentRun.query(on: f.app.app.db).filter(\.$endedAt == nil).all()
        XCTAssertEqual(runs.count, 1)
    }
}
