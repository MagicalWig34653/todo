import Fluent
import XCTVapor
@testable import TodoKit

/// After a project is transferred away, the former owner's device keeps a historic binding for it.
final class AgentRunnerAfterTransferTests: XCTestCase {
    private func transferAway(_ f: AgentFixture) async throws {
        let b = User(displayName: "B", isAdmin: false)
        try await b.save(on: f.app.app.db)
        let current = try await f.app.json(.GET, "/v1/projects", token: f.human)
        let version = (current.list?.first?["version"] as? Int) ?? 1
        let transfer = try await f.app.json(.PUT, "/v1/projects/\(f.projectID)/owner",
            ["version": version, "ownerType": "person", "ownerID": try b.requireID().uuidString], token: f.human)
        XCTAssertEqual(transfer.status, .ok, "\(transfer.body ?? [:])")
    }

    func testRunnerListsSkipTransferredBindingsInsteadOfFailing() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        // Second, still authorized project on the same device with a queued job.
        let p2 = try await f.app.json(.POST, "/v1/projects", ["name": "Second"], token: f.human)
        let p2ID = try XCTUnwrap(p2.body?["id"] as? String)
        let t2 = try await f.app.json(.POST, "/v1/tasks", ["projectID": p2ID, "title": "Task 2"], token: f.human)
        let t2ID = try XCTUnwrap(t2.body?["id"] as? String)
        let bind2 = try await f.app.json(.POST, "/v1/agents/bindings", ["projectID": p2ID, "deviceID": f.deviceID,
            "repositoryKey": UUID().uuidString, "label": "Second checkout"], token: f.human)
        let binding2 = try XCTUnwrap(bind2.body?["id"] as? String)
        let job2 = try await f.app.json(.POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": t2ID, "bindingID": binding2,
            "taskRevision": 1, "mode": "implement", "scope": "x"], token: f.human)
        XCTAssertEqual(job2.status, .ok, "\(job2.body ?? [:])")
        // The first project has history (an open run), so its binding survives the transfer.
        let openJob = try await f.release()
        _ = try await f.claim(openJob)
        try await transferAway(f)

        let bindings = try await f.app.json(.GET, "/v1/runner/bindings", token: f.runner)
        XCTAssertEqual(bindings.status, .ok)
        XCTAssertEqual(bindings.list?.map { $0["id"] as? String }, [binding2])
        let queued = try await f.app.json(.GET, "/v1/runner/jobs", token: f.runner)
        XCTAssertEqual(queued.status, .ok)
        XCTAssertEqual(queued.list?.count, 1)
        let runs = try await f.app.json(.GET, "/v1/runner/runs", token: f.runner)
        XCTAssertEqual(runs.status, .ok)
        XCTAssertEqual(runs.list?.count, 0)
    }

    func testRunnerCanConfirmStoppedProcessAfterTransferAndFreeTheRepository() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let openJob = try await f.release()
        let run = try await f.claim(openJob)
        try await transferAway(f)
        // Cancelled at the transfer: generation was bumped, the run still occupies the repository.
        let stored = try await XCTUnwrapAsync(await AgentRun.find(UUID(uuidString: run), on: f.app.app.db))
        XCTAssertNil(stored.endedAt)
        let confirmed = try await f.command(run, "reconcile", ["generation": stored.generation, "observation": "stopped"])
        XCTAssertEqual(confirmed, .ok)
        let ended = try await XCTUnwrapAsync(await AgentRun.find(UUID(uuidString: run), on: f.app.app.db))
        XCTAssertNotNil(ended.endedAt)
        // Other actions stay refused without current project rights.
        let heartbeat = try await f.command(run, "heartbeat", ["generation": stored.generation])
        XCTAssertNotEqual(heartbeat, .ok)
    }
}
