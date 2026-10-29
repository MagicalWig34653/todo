import Fluent
import XCTVapor
@testable import TodoKit

/// Regression for the runner end-to-end run: on MariaDB the agent text columns were VARCHAR(255), so contract-sized
/// values (up to 4000 characters) failed with HTTP 500. Runs on SQLite by default and on MariaDB with TODO_TEST_DB.
final class AgentLongTextTests: XCTestCase {
    func testContractSizedTextRoundTripsThroughJobQuestionAnswerCheckpointAndResult() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let long = String(repeating: "Länge ü€ ", count: 480).prefix(3990).description  // multi-byte, under 4000
        XCTAssertGreaterThan(long.count, 3000)

        let task = try await f.app.json(.POST, "/v1/tasks", ["projectID": f.projectID, "title": "Long", "description": long], token: f.human)
        XCTAssertEqual(task.status, .created, "\(task.body ?? [:])")
        XCTAssertEqual(task.body?["description"] as? String, long)
        let taskID = try XCTUnwrap(task.body?["id"] as? String)

        let job = try await f.app.json(.POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": taskID, "bindingID": f.bindingID,
            "taskRevision": try XCTUnwrap(task.body?["version"] as? Int), "mode": "implement", "scope": long], token: f.human)
        XCTAssertEqual(job.status, .ok, "\(job.body ?? [:])")
        let jobID = try XCTUnwrap(job.body?["id"] as? String)
        let run = try await f.claim(jobID)

        var status = try await f.command(run, "progress", ["generation": 1, "progress": long])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "checkpoint", ["generation": 1, "checkpoint": [
            "contextRevision": 1, "sessionReference": UUID().uuidString, "nextStep": long]])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "question", ["generation": 1, "prompt": long])
        XCTAssertEqual(status, .ok)
        var detail = try await f.app.json(.GET, "/v1/agents/jobs/\(jobID)", token: f.human)
        let question = try XCTUnwrap((detail.body?["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(question["prompt"] as? String, long)
        let answered = try await f.app.json(.POST, "/v1/agents/questions/\(try XCTUnwrap(question["id"] as? String))/answer",
                                            ["value": long], token: f.human)
        XCTAssertEqual(answered.status, .ok, "\(answered.body ?? [:])")
        status = try await f.command(run, "resume")
        XCTAssertEqual(status, .ok)
        let references = (0..<20).map { "ref-\($0)-" + String(repeating: "r", count: 3900) }
        status = try await f.command(run, "submit", ["generation": 1, "result": [
            "summary": long, "references": references, "checks": [long], "limitations": [long]]])
        XCTAssertEqual(status, .ok)
        detail = try await f.app.json(.GET, "/v1/agents/jobs/\(jobID)", token: f.human)
        let result = try XCTUnwrap((detail.body?["job"] as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(result["summary"] as? String, long)
        XCTAssertEqual((result["references"] as? [String])?.count, 20)
    }
}
