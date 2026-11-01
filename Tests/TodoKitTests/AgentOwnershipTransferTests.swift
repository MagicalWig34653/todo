import Fluent
import XCTVapor
@testable import TodoKit

final class AgentOwnershipTransferTests: XCTestCase {
    func testFormerOwnerWithReadAccessLosesRunnerCapabilitiesAndNewOwnerGainsThem() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        // A has an open (claimed) job from before the transfer.
        let openJob = try await f.release()
        let run = try await f.claim(openJob)
        let b = User(displayName: "B", isAdmin: false)
        try await b.save(on: f.app.app.db)
        let bID = try b.requireID()
        let bToken = AuthSupport.randomToken()
        try await UserSession(userID: bID, tokenHash: AuthSupport.hash(bToken), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.app.db)
        let current = try await f.app.json(.GET, "/v1/projects", token: f.human)
        let version = (current.list?.first?["version"] as? Int) ?? 1
        let transfer = try await f.app.json(.PUT, "/v1/projects/\(f.projectID)/owner",
            ["version": version, "ownerType": "person", "ownerID": bID.uuidString], token: f.human)
        XCTAssertEqual(transfer.status, .ok, "\(transfer.body ?? [:])")
        // A keeps read access.
        let grant = try await f.app.json(.PUT, "/v1/projects/\(f.projectID)/grants",
            ["principalType": "person", "principalID": try f.user.requireID().uuidString, "role": "read"], token: bToken)
        XCTAssertEqual(grant.status, .ok, "\(grant.body ?? [:])")
        let read = try await f.app.json(.GET, "/v1/projects", token: f.human)
        XCTAssertEqual(read.list?.count, 1)
        // A can create neither a binding nor a job any more.
        let newBinding = try await f.app.json(.POST, "/v1/agents/bindings", ["projectID": f.projectID, "deviceID": f.deviceID,
            "repositoryKey": UUID().uuidString, "label": "Again"], token: f.human)
        XCTAssertEqual(newBinding.status, .forbidden)
        let newJob = try await f.app.json(.POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": f.taskID, "bindingID": f.bindingID,
            "taskRevision": 1, "mode": "implement", "scope": "x"], token: f.human)
        XCTAssertEqual(newJob.status, .forbidden)
        let list = try await f.app.json(.GET, "/v1/agents/jobs?projectID=\(f.projectID)", token: f.human)
        XCTAssertEqual(list.status, .forbidden)
        // The open job and run of A were cancelled at the transfer; the runner of A cannot continue.
        let job = try await AgentJob.find(UUID(uuidString: openJob), on: f.app.app.db)
        XCTAssertEqual(job?.state, "cancelled")
        let heartbeat = try await f.command(run, "heartbeat")
        XCTAssertNotEqual(heartbeat, .ok)
        // B registers his own device and binds the project.
        let pairing = try await f.app.json(.POST, "/v1/agents/devices", ["label": "B Mac"], token: bToken)
        let code = try XCTUnwrap(pairing.body?["code"] as? String)
        let bDevice = try XCTUnwrap(pairing.body?["deviceID"] as? String)
        _ = try await f.app.json(.POST, "/v1/runner/pair", ["code": code])
        let bind = try await f.app.json(.POST, "/v1/agents/bindings", ["projectID": f.projectID, "deviceID": bDevice,
            "repositoryKey": UUID().uuidString, "label": "B checkout"], token: bToken)
        XCTAssertEqual(bind.status, .ok, "\(bind.body ?? [:])")
        let bBinding = try XCTUnwrap(bind.body?["id"] as? String)
        let bJob = try await f.app.json(.POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": f.taskID, "bindingID": bBinding,
            "taskRevision": 1, "mode": "implement", "scope": "x"], token: bToken)
        XCTAssertEqual(bJob.status, .ok, "\(bJob.body ?? [:])")
    }
}
