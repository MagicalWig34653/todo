import Fluent
import XCTVapor
@testable import TodoKit

struct AgentFixture {
    let app: TestApp
    let user: User
    let human: String
    let deviceID: String
    let runner: String
    let projectID: String
    let taskID: String
    let bindingID: String
    let repositoryKey: String

    static func make() async throws -> AgentFixture {
        let t: TestApp
        if TestApp.useMariaDB {
            t = try await TestApp.make()
        } else {
            let application = try await Application.make(.testing)
            configureContent()
            let settings = AppSettings()
            application.settings = settings
            try configureDatabase(application, settings: .init(driver: .sqlite, host: "", port: 0, name: "", user: "", password: ""))
            configureMigrations(application)
            try routes(application)
            try await application.autoMigrate()
            t = TestApp(app: application, settings: settings)
        }
        let user = User(displayName: "Owner", isAdmin: false)
        try await user.save(on: t.app.db)
        let human = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(human), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        let pairing = try await t.json(.POST, "/v1/agents/devices", ["label": "Mac"], token: human)
        let code = try XCTUnwrap(pairing.body?["code"] as? String)
        let deviceID = try XCTUnwrap(pairing.body?["deviceID"] as? String)
        let paired = try await t.json(.POST, "/v1/runner/pair", ["code": code])
        let runner = try XCTUnwrap(paired.body?["token"] as? String)
        let p = try await t.json(.POST, "/v1/projects", ["name": "Project"], token: human)
        let projectID = try XCTUnwrap(p.body?["id"] as? String)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": projectID, "title": "Task"], token: human)
        let taskID = try XCTUnwrap(task.body?["id"] as? String)
        let repositoryKey = UUID().uuidString
        let b = try await t.json(.POST, "/v1/agents/bindings", ["projectID": projectID, "deviceID": deviceID,
            "repositoryKey": repositoryKey, "label": "Checkout"], token: human)
        return AgentFixture(app: t, user: user, human: human, deviceID: deviceID, runner: runner,
            projectID: projectID, taskID: taskID, bindingID: try XCTUnwrap(b.body?["id"] as? String), repositoryKey: repositoryKey)
    }

    func release(id: String = UUID().uuidString, binding: String? = nil, revision: Int = 1) async throws -> String {
        let r = try await app.json(.POST, "/v1/agents/jobs", ["id": id, "taskID": taskID, "bindingID": binding ?? bindingID,
            "taskRevision": revision, "mode": "implement", "scope": "Update the documentation"], token: human)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    func claim(_ job: String) async throws -> String {
        let r = try await app.json(.POST, "/v1/runner/jobs/\(job)/claim", token: runner)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    func command(_ run: String, _ action: String, _ body: [String: Any] = ["generation": 1]) async throws -> HTTPStatus {
        try await app.json(.POST, "/v1/runner/runs/\(run)/\(action)", body, token: runner).status
    }
}

final class AgentTests: XCTestCase {
    func testQuestionAnswerCheckpointAndHumanReviewKeepTaskStatusSeparate() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let run = try await f.claim(job)
        var status = try await f.command(run, "progress", ["generation": 1, "progress": "Investigating"])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "checkpoint", ["generation": 1, "checkpoint": [
            "contextRevision": 1, "sessionReference": UUID().uuidString, "nextStep": "Read the answer"]])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "question", ["generation": 1, "prompt": "Which option?", "options": ["A", "B"]])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "resume")
        XCTAssertEqual(status, .conflict)
        let detail = try await f.app.json(.GET, "/v1/agents/jobs/\(job)", token: f.human)
        let questions = try XCTUnwrap(detail.body?["questions"] as? [[String: Any]])
        let questionID = try XCTUnwrap(questions.first?["id"] as? String)
        let answer = try await f.app.json(.POST, "/v1/agents/questions/\(questionID)/answer", ["value": "A"], token: f.human)
        XCTAssertEqual(answer.status, .ok)
        let duplicate = try await f.app.json(.POST, "/v1/agents/questions/\(questionID)/answer", ["value": "A"], token: f.human)
        XCTAssertEqual(duplicate.status, .ok)
        let conflict = try await f.app.json(.POST, "/v1/agents/questions/\(questionID)/answer", ["value": "B"], token: f.human)
        XCTAssertEqual(conflict.status, .conflict)
        let read = try await f.app.json(.GET, "/v1/runner/jobs/\(job)", token: f.runner)
        XCTAssertEqual((read.body?["questions"] as? [[String: Any]])?.first?["answer"] as? String, "A")
        status = try await f.command(run, "resume")
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "submit", ["generation": 1, "result": [
            "summary": "Ready", "references": ["commit:abc"], "checks": ["Self reported check"], "limitations": ["No device test"]]])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "heartbeat")
        XCTAssertEqual(status, .gone)
        let review = try await f.app.json(.POST, "/v1/agents/jobs/\(job)/review", ["decision": "accept"], token: f.human)
        XCTAssertEqual(review.body?["state"] as? String, "succeeded")
        let task = try await TodoTask.find(UUID(uuidString: f.taskID), on: f.app.app.db)
        XCTAssertEqual(task?.status, "open")
        XCTAssertEqual(task?.version, 1)
        let events = try await AgentEvent.query(on: f.app.app.db).filter(\.$jobID == UUID(uuidString: job)!).all()
        XCTAssertEqual(events.filter { $0.kind == "answered" }.count, 1)
        XCTAssertFalse(events.contains { ["heartbeat", "progress"].contains($0.kind) })
    }

    func testExpiredLeaseBlocksClaimsAndAllStaleWritesUntilReconciliation() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let runID = try await f.claim(job)
        let storedRun = try await AgentRun.find(UUID(uuidString: runID), on: f.app.app.db)
        let run = try XCTUnwrap(storedRun)
        run.leaseUntil = Date().addingTimeInterval(-10)
        try await run.save(on: f.app.app.db)
        var status = try await f.command(runID, "heartbeat")
        XCTAssertEqual(status, .gone)
        let second = try await f.release()
        let blocked = try await f.app.json(.POST, "/v1/runner/jobs/\(second)/claim", token: f.runner)
        XCTAssertEqual(blocked.status, .conflict)
        let reconcile = try await f.app.json(.POST, "/v1/runner/runs/\(runID)/reconcile", ["generation": 1, "observation": "alive"], token: f.runner)
        XCTAssertEqual(reconcile.body?["generation"] as? Int, 2)
        for action in ["heartbeat", "progress", "checkpoint", "question", "resume", "submit", "stop", "fail", "reconcile"] {
            status = try await f.command(runID, action)
            XCTAssertEqual(status, .conflict, action)
        }
        status = try await f.command(runID, "heartbeat", ["generation": 2])
        XCTAssertEqual(status, .ok)
        status = try await f.command(runID, "reconcile", ["generation": 2, "observation": "stopped"])
        XCTAssertEqual(status, .ok)
        _ = try await f.claim(second)
        let saved = try await AgentJob.find(UUID(uuidString: job), on: f.app.app.db)
        XCTAssertEqual(saved?.state, "failed")
    }

    func testHumanStopFencesRunnerAndRequiresConfirmedTermination() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let run = try await f.claim(job)
        let stopped = try await f.app.json(.POST, "/v1/agents/jobs/\(job)/stop", token: f.human)
        XCTAssertEqual(stopped.body?["state"] as? String, "cancelled")
        var status = try await f.command(run, "progress", ["generation": 1, "progress": "Late"])
        XCTAssertEqual(status, .conflict)
        let runs = try await f.app.json(.GET, "/v1/runner/runs", token: f.runner)
        XCTAssertEqual(runs.list?.first?["generation"] as? Int, 2)
        status = try await f.command(run, "reconcile", ["generation": 2, "observation": "alive"])
        XCTAssertEqual(status, .gone)
        let next = try await f.release()
        let blocked = try await f.app.json(.POST, "/v1/runner/jobs/\(next)/claim", token: f.runner)
        XCTAssertEqual(blocked.status, .conflict)
        status = try await f.command(run, "reconcile", ["generation": 2, "observation": "stopped"])
        XCTAssertEqual(status, .ok)
        _ = try await f.claim(next)
    }

    func testPairingIsOneTimeHashedAndDeviceCanBeRevoked() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let begin = try await f.app.json(.POST, "/v1/agents/devices", ["label": "Second Mac"], token: f.human)
        let code = try XCTUnwrap(begin.body?["code"] as? String)
        let first = try await f.app.json(.POST, "/v1/runner/pair", ["code": code])
        let duplicate = try await f.app.json(.POST, "/v1/runner/pair", ["code": code])
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(duplicate.status, .unauthorized)
        let saved = try await RunnerDevice.find(UUID(uuidString: f.deviceID), on: f.app.app.db)
        XCTAssertEqual(saved?.tokenHash, AuthSupport.hash(f.runner))
        XCTAssertNotEqual(saved?.tokenHash, f.runner)
        let pairing = try await RunnerPairing.query(on: f.app.app.db).filter(\.$codeHash == AuthSupport.hash(code)).first()
        XCTAssertNotNil(pairing?.usedAt)
        let job = try await f.release()
        let run = try await f.claim(job)
        let revoked = try await f.app.json(.DELETE, "/v1/agents/devices/\(f.deviceID)", token: f.human)
        XCTAssertEqual(revoked.status, .noContent)
        let status = try await f.command(run, "heartbeat")
        XCTAssertEqual(status, .unauthorized)
        let pending = try await f.app.json(.GET, "/v1/runner/jobs", token: f.runner)
        XCTAssertEqual(pending.status, .unauthorized)
    }

    func testAccountAndDeviceBoundariesAndRevisionChecks() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let other = User(displayName: "Other", isAdmin: true)
        try await other.save(on: f.app.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: other.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.app.db)
        let job = try await f.release()
        let read = try await f.app.json(.GET, "/v1/agents/jobs/\(job)", token: token)
        XCTAssertEqual(read.status, .notFound)
        let foreign = try await f.app.json(.POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": f.taskID,
            "bindingID": f.bindingID, "taskRevision": 1, "mode": "clarify", "scope": "Read"], token: token)
        XCTAssertEqual(foreign.status, .notFound)
        let humanClaim = try await f.app.json(.POST, "/v1/runner/jobs/\(job)/claim", token: f.human)
        XCTAssertEqual(humanClaim.status, .unauthorized)
        let runnerHuman = try await f.app.json(.POST, "/v1/agents/devices", ["label": "Bad"], token: f.runner)
        XCTAssertEqual(runnerHuman.status, .unauthorized)
        let badPath = try await f.app.json(.POST, "/v1/agents/bindings", ["deviceID": f.deviceID, "projectID": f.projectID,
            "repositoryKey": "/Users/private", "label": "Checkout"], token: f.human)
        XCTAssertEqual(badPath.status, .badRequest)
        let storedTask = try await TodoTask.find(UUID(uuidString: f.taskID), on: f.app.app.db)
        let task = try XCTUnwrap(storedTask)
        task.version += 1
        try await task.save(on: f.app.app.db)
        let stale = try await f.app.json(.POST, "/v1/runner/jobs/\(job)/claim", token: f.runner)
        XCTAssertEqual(stale.status, .conflict)
        let device = try RunnerDevice(ownerID: other.requireID(), label: "Foreign", tokenHash: AuthSupport.hash("foreign-device"), revokedAt: nil)
        try await device.save(on: f.app.app.db)
        let foreignRunner = try await f.app.json(.GET, "/v1/runner/jobs/\(job)", token: "foreign-device")
        XCTAssertEqual(foreignRunner.status, .notFound)
    }

    func testBindingsForSameRepositoryShareSlotButOtherRepositoriesCanRun() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let alias = try await f.app.json(.POST, "/v1/agents/bindings", ["projectID": f.projectID, "deviceID": f.deviceID,
            "repositoryKey": f.repositoryKey, "label": "Alias"], token: f.human)
        let aliasID = try XCTUnwrap(alias.body?["id"] as? String)
        let first = try await f.release()
        _ = try await f.claim(first)
        let second = try await f.release(binding: aliasID)
        let blocked = try await f.app.json(.POST, "/v1/runner/jobs/\(second)/claim", token: f.runner)
        XCTAssertEqual(blocked.status, .conflict)
        let other = try await f.app.json(.POST, "/v1/agents/bindings", ["projectID": f.projectID, "deviceID": f.deviceID,
            "repositoryKey": UUID().uuidString, "label": "Other"], token: f.human)
        let otherJob = try await f.release(binding: XCTUnwrap(other.body?["id"] as? String))
        _ = try await f.claim(otherJob)
    }

    func testReleaseRetriesAreIdempotentAndCheckpointCannotRegress() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let id = UUID().uuidString
        let job = try await f.release(id: id)
        let retry = try await f.release(id: id)
        XCTAssertEqual(job, retry)
        let changed = try await f.app.json(.POST, "/v1/agents/jobs", ["id": id, "taskID": f.taskID, "bindingID": f.bindingID,
            "taskRevision": 1, "mode": "clarify", "scope": "Different"], token: f.human)
        XCTAssertEqual(changed.status, .conflict)
        let run = try await f.claim(job)
        var status = try await f.command(run, "checkpoint", ["generation": 1, "checkpoint": [
            "contextRevision": 2, "sessionReference": "session", "nextStep": "Continue"]])
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "checkpoint", ["generation": 1, "checkpoint": [
            "contextRevision": 1, "sessionReference": "session", "nextStep": "Old"]])
        XCTAssertEqual(status, .conflict)
        let savedRuns = try await f.app.json(.GET, "/v1/runner/runs", token: f.runner)
        let checkpoint = savedRuns.list?.first?["checkpoint"] as? [String: Any]
        XCTAssertEqual(checkpoint?["contextRevision"] as? Int, 2)
        XCTAssertEqual(checkpoint?["nextStep"] as? String, "Continue")
    }

    func testReviewRejectionRequiresExplicitLinkedFollowUp() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let run = try await f.claim(job)
        let status = try await f.command(run, "submit", ["generation": 1, "result": [
            "summary": "Review needed", "references": [], "checks": [], "limitations": []]])
        XCTAssertEqual(status, .ok)
        let rejected = try await f.app.json(.POST, "/v1/agents/jobs/\(job)/review", ["decision": "request_changes"], token: f.human)
        XCTAssertEqual(rejected.body?["state"] as? String, "failed")
        let queued = try await f.app.json(.GET, "/v1/runner/jobs", token: f.runner)
        XCTAssertEqual(queued.list?.count, 0)
        let followUp = try await f.app.json(.POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": f.taskID,
            "bindingID": f.bindingID, "previousJobID": job, "taskRevision": 1, "mode": "implement", "scope": "Apply review feedback"], token: f.human)
        XCTAssertEqual(followUp.status, .ok)
        XCTAssertEqual(followUp.body?["previousJobID"] as? String, job)
        XCTAssertEqual(followUp.body?["state"] as? String, "queued")
    }

    func testPairingExpiresAndOwnerCapabilityIsRecheckedOnEachWrite() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let begin = try await f.app.json(.POST, "/v1/agents/devices", ["label": "Offline"], token: f.human)
        let code = try XCTUnwrap(begin.body?["code"] as? String)
        let found = try await RunnerPairing.query(on: f.app.app.db).filter(\.$codeHash == AuthSupport.hash(code)).first()
        let pairing = try XCTUnwrap(found)
        pairing.expiresAt = Date().addingTimeInterval(-1)
        try await pairing.save(on: f.app.app.db)
        let expired = try await f.app.json(.POST, "/v1/runner/pair", ["code": code])
        XCTAssertEqual(expired.status, .unauthorized)
        let job = try await f.release()
        let run = try await f.claim(job)
        let other = User(displayName: "New owner", isAdmin: false)
        try await other.save(on: f.app.app.db)
        let foundProject = try await Project.find(UUID(uuidString: f.projectID), on: f.app.app.db)
        let project = try XCTUnwrap(foundProject)
        project.ownerID = try other.requireID()
        try await project.save(on: f.app.app.db)
        let status = try await f.command(run, "heartbeat")
        XCTAssertEqual(status, .notFound)
        let detail = try await f.app.json(.GET, "/v1/runner/jobs/\(job)", token: f.runner)
        XCTAssertEqual(detail.status, .notFound)
    }

    func testExpiredQuestionPauseCanBeReconciledWithoutBlindRestart() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let runID = try await f.claim(job)
        var status = try await f.command(runID, "checkpoint", ["generation": 1, "checkpoint": [
            "contextRevision": 1, "sessionReference": "local-session", "nextStep": "Wait for decision"]])
        XCTAssertEqual(status, .ok)
        status = try await f.command(runID, "question", ["generation": 1, "prompt": "What should change?"])
        XCTAssertEqual(status, .ok)
        let found = try await AgentRun.find(UUID(uuidString: runID), on: f.app.app.db)
        let run = try XCTUnwrap(found)
        run.leaseUntil = Date().addingTimeInterval(-1)
        try await run.save(on: f.app.app.db)
        status = try await f.command(runID, "reconcile", ["generation": 1, "observation": "paused"])
        XCTAssertEqual(status, .ok)
        status = try await f.command(runID, "resume", ["generation": 2])
        XCTAssertEqual(status, .conflict)
        let detail = try await f.app.json(.GET, "/v1/agents/jobs/\(job)", token: f.human)
        let questionID = try XCTUnwrap((detail.body?["questions"] as? [[String: Any]])?.first?["id"] as? String)
        let answered = try await f.app.json(.POST, "/v1/agents/questions/\(questionID)/answer", ["value": "Update the title"], token: f.human)
        XCTAssertEqual(answered.status, .ok)
        status = try await f.command(runID, "resume", ["generation": 2])
        XCTAssertEqual(status, .ok)
        let runs = try await f.app.json(.GET, "/v1/runner/runs", token: f.runner)
        XCTAssertEqual(runs.list?.count, 1)
        XCTAssertEqual(runs.list?.first?["id"] as? String, runID)
    }
}
