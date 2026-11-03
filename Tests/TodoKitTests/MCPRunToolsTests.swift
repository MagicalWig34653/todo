import Fluent
import XCTVapor
@testable import TodoKit

/// Batch 7 (docs/MCP-PARITAET.md): review history, progress notes, runner jobs and devices.
final class MCPRunToolsTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private let all = "projects:read tasks:read tasks:write runs:read runs:write"
    private func fixture(_ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: all); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func list(_ c: Called) -> [[String: Any]] { (c.json as? [[String: Any]]) ?? [] }
    private func obj(_ c: Called) -> [String: Any] { (c.json as? [String: Any]) ?? [:] }
    private func task(_ f: OAuthFixture, _ project: Project? = nil) async throws -> TodoTask {
        let t = TodoTask(ownerID: try f.user.requireID(), projectID: try (project ?? f.project).requireID(), title: "Runner task")
        try await t.save(on: f.test.app.db); return t
    }
    private func review(_ f: OAuthFixture, _ task: TodoTask, state: String) async throws {
        let r = TaskReview()
        r.taskID = try task.requireID(); r.state = state; r.requestedByType = .integration; r.requestedByID = UUID()
        r.summary = "Review \(state)"; r.version = 1
        try await r.save(on: f.test.app.db)
    }
    private func device(_ f: OAuthFixture, owner: User? = nil, paired: Bool = true, project: Project? = nil, bind: Bool = true) async throws -> (RunnerDevice, ProjectRunnerBinding?) {
        let d = RunnerDevice(ownerID: try (owner ?? f.user).requireID(), label: "Mac", tokenHash: paired ? "secret-hash-\(UUID().uuidString)" : nil, revokedAt: nil)
        try await d.save(on: f.test.app.db)
        guard bind else { return (d, nil) }
        let b = ProjectRunnerBinding(projectID: try (project ?? f.project).requireID(), deviceID: try d.requireID(), repositoryKey: UUID().uuidString.lowercased(), label: "repo")
        try await b.save(on: f.test.app.db)
        return (d, b)
    }
    private func job(_ f: OAuthFixture, _ task: TodoTask, _ b: ProjectRunnerBinding, state: String) async throws -> AgentJob {
        let j = AgentJob(taskID: try task.requireID(), projectID: task.projectID, bindingID: try b.requireID(), requestedBy: try f.user.requireID(),
                         taskRevision: task.version, mode: "implement", scope: "s", state: state, progress: "p", result: nil)
        try await j.save(on: f.test.app.db); return j
    }
    private func extend(_ f: OAuthFixture, _ projects: [Project]) async throws {
        let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: f.test.app.db).first())
        g.projects.append(contentsOf: try projects.map { try $0.requireID() })
        try await g.save(on: f.test.app.db)
    }
    private func foreign(_ f: OAuthFixture, grant: Bool = true) async throws -> (User, Project) {
        let u = User(displayName: "Stranger", isAdmin: false); try await u.save(on: f.test.app.db)
        let p = Project(ownerID: try u.requireID(), parentID: nil, name: "Foreign"); try await p.save(on: f.test.app.db)
        if grant { try await extend(f, [p]) }
        return (u, p)
    }

    func testRegistrationAndScopes() async throws {
        let expected = ["list_reviews": "tasks:read", "list_progress_notes": "tasks:read", "list_agent_jobs": "runs:read",
                        "list_runner_devices": "runs:read", "start_agent_job": "runs:write", "stop_agent_job": "runs:write"]
        for (n, s) in expected { XCTAssertEqual(MCPController.tools.first { $0.name == n }?.scope, s, n) }
        XCTAssertTrue(OAuthController.scopes.contains("runs:read") && OAuthController.scopes.contains("runs:write"))
    }

    func testMissingScopeIsRejected() async throws {
        try await fixture { f, _ in
            let ro = try await f.tokens(scope: "projects:read").access
            let t = try await task(f).requireID().uuidString
            for (name, args) in [("list_reviews", [:]), ("list_progress_notes", ["taskID": t]), ("list_agent_jobs", [:]),
                                 ("list_runner_devices", [:]), ("start_agent_job", ["taskID": t]), ("stop_agent_job", ["jobID": UUID().uuidString])] as [(String, [String: Any])] {
                let c = try await call(f, name, args, ro)
                XCTAssertEqual(c.text, "insufficient_scope", name)
            }
        }
    }

    // MARK: list_reviews

    func testListReviewsReturnsHistoryAndFiltersByStatus() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            for s in ["pending", "accepted", "changes_requested"] { try await review(f, task, state: s) }
            let allRows = try await call(f, "list_reviews", [:], t)
            XCTAssertEqual(list(allRows).count, 3, allRows.text)
            XCTAssertEqual(list(allRows).first?["taskTitle"] as? String, "Runner task")
            let decided = try await call(f, "list_reviews", ["status": "accepted"], t)
            XCTAssertEqual(list(decided).map { $0["state"] as? String }, ["accepted"])
            let limited = try await call(f, "list_reviews", ["limit": 2, "projectID": f.project.requireID().uuidString], t)
            XCTAssertEqual(list(limited).count, 2)
        }
    }

    func testListReviewsHidesProjectsOutsideGrantAndRejectsBadInput() async throws {
        try await fixture { f, t in
            let (_, p) = try await foreign(f, grant: false)
            let ft = TodoTask(ownerID: try p.ownerID, projectID: try p.requireID(), title: "Secret"); try await ft.save(on: f.test.app.db)
            try await review(f, ft, state: "pending")
            let seen = try await call(f, "list_reviews", [:], t)
            XCTAssertEqual(list(seen).count, 0)
            let direct = try await call(f, "list_reviews", ["projectID": p.requireID().uuidString], t)
            XCTAssertEqual(direct.text, "not_found")
            for bad in [["status": "bogus"], ["limit": 0], ["limit": 1e12], ["limit": 1.5], ["projectID": "nope"]] as [[String: Any]] {
                let v1 = try await call(f, "list_reviews", bad, t).isError
                XCTAssertTrue(v1, "\(bad)")
            }
        }
    }

    // MARK: list_progress_notes

    func testListProgressNotes() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            for i in 1...3 {
                let n = TaskProgressNote()
                n.taskID = try task.requireID(); n.actorType = .integration; n.actorID = UUID(); n.actorLabel = "agent"; n.note = "Step \(i)"; n.percent = i * 10
                try await n.save(on: f.test.app.db)
            }
            let c = try await call(f, "list_progress_notes", ["taskID": task.requireID().uuidString, "limit": 2], t)
            XCTAssertEqual(list(c).count, 2, c.text)
            XCTAssertNotNil(list(c).first?["note"])
            let v2 = try await call(f, "list_progress_notes", ["taskID": task.requireID().uuidString, "limit": 0], t).text
            XCTAssertEqual(v2, "invalid_limit")
            let v3 = try await call(f, "list_progress_notes", ["taskID": "x"], t).isError
            XCTAssertTrue(v3)
        }
    }

    func testProgressNotesOfTaskOutsideGrantAreNotFound() async throws {
        try await fixture { f, t in
            let (_, p) = try await foreign(f, grant: false)
            let ft = TodoTask(ownerID: try p.ownerID, projectID: try p.requireID(), title: "Secret"); try await ft.save(on: f.test.app.db)
            let v4 = try await call(f, "list_progress_notes", ["taskID": ft.requireID().uuidString], t).text
            XCTAssertEqual(v4, "not_found")
            let own = try await task(f, f.other)  // owned, but not in the grant
            let v5 = try await call(f, "list_progress_notes", ["taskID": own.requireID().uuidString], t).text
            XCTAssertEqual(v5, "not_found")
        }
    }

    // MARK: list_runner_devices / list_agent_jobs

    func testListRunnerDevicesHasNoSecretsAndFiltersBindings() async throws {
        try await fixture { f, t in
            let (d, _) = try await device(f)
            _ = try await device(f, project: f.other)  // second device bound only to a project outside the grant
            let (u, _) = try await foreign(f, grant: false)
            _ = try await device(f, owner: u, bind: false)  // somebody else's device
            let c = try await call(f, "list_runner_devices", [:], t)
            XCTAssertEqual(list(c).count, 2, c.text)
            XCTAssertFalse(c.text.contains("secret-hash") || c.text.lowercased().contains("token") || c.text.lowercased().contains("code"))
            let mine = list(c).first { $0["id"] as? String == d.id?.uuidString }
            XCTAssertEqual((mine?["bindings"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual(mine?["paired"] as? Bool, true)
            let other = list(c).first { $0["id"] as? String != d.id?.uuidString }
            XCTAssertEqual((other?["bindings"] as? [[String: Any]])?.count, 0)
        }
    }

    func testListAgentJobsFiltersAndRespectsGrantAndRole() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            let (_, b) = try await device(f)
            _ = try await job(f, task, try XCTUnwrap(b), state: "running")
            _ = try await job(f, task, try XCTUnwrap(b), state: "succeeded")
            let otherTask = try await self.task(f, f.other)
            let (_, ob) = try await device(f, project: f.other)
            _ = try await job(f, otherTask, try XCTUnwrap(ob), state: "running")  // project not in grant
            let everything = try await call(f, "list_agent_jobs", [:], t)
            XCTAssertEqual((obj(everything)["items"] as? [Any])?.count, 2, everything.text)
            let running = try await call(f, "list_agent_jobs", ["status": "running"], t)
            XCTAssertEqual((obj(running)["items"] as? [Any])?.count, 1)
            let one = try await call(f, "list_agent_jobs", ["limit": 1], t)
            XCTAssertEqual((obj(one)["items"] as? [Any])?.count, 1)
            let v6 = try await call(f, "list_agent_jobs", ["projectID": f.other.requireID().uuidString], t).text
            XCTAssertEqual(v6, "not_found")
            for bad in [["status": "x"], ["limit": 0], ["limit": 101], ["limit": 1e12],["projectID": 5]] as [[String: Any]] {
                let v7 = try await call(f, "list_agent_jobs", bad, t).isError
                XCTAssertTrue(v7, "\(bad)")
            }
            // Role: a project the user can see but does not own is refused.
            let (_, p) = try await foreign(f)
            let v8 = try await call(f, "list_agent_jobs", ["projectID": p.requireID().uuidString], t).text
            XCTAssertEqual(v8, "not_found")
        }
    }

    // MARK: start_agent_job / stop_agent_job

    func testStartAgentJobCreatesQueuedJobViaExistingBinding() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            let (d, b) = try await device(f)
            let c = try await call(f, "start_agent_job", ["taskID": task.requireID().uuidString, "version": task.version], t)
            XCTAssertFalse(c.isError, c.text)
            XCTAssertEqual(obj(c)["state"] as? String, "queued")
            XCTAssertEqual(obj(c)["mode"] as? String, "implement")
            XCTAssertEqual(obj(c)["bindingID"] as? String, b?.id?.uuidString)
            let jobs = try await AgentJob.query(on: f.test.app.db).all()
            XCTAssertEqual(jobs.count, 1)
            let activity = try await ActivityEvent.query(on: f.test.app.db).filter(\.$kind == "agent.released").count()
            XCTAssertEqual(activity, 1)
            let withDevice = try await call(f, "start_agent_job", ["taskID": task.requireID().uuidString, "deviceID": d.requireID().uuidString, "mode": "clarify"], t)
            XCTAssertEqual(obj(withDevice)["mode"] as? String, "clarify", withDevice.text)
        }
    }

    func testStartAgentJobNeedsExistingUsableBindingAndUnambiguousDevice() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            let id = try task.requireID().uuidString
            let v9 = try await call(f, "start_agent_job", ["taskID": id], t).text
            XCTAssertEqual(v9, "no_binding")
            _ = try await device(f, paired: false)  // unpaired device is not usable
            let v10 = try await call(f, "start_agent_job", ["taskID": id], t).text
            XCTAssertEqual(v10, "no_binding")
            _ = try await device(f); _ = try await device(f)
            let v11 = try await call(f, "start_agent_job", ["taskID": id], t).text
            XCTAssertEqual(v11, "device_required")
            let v12 = try await call(f, "start_agent_job", ["taskID": id, "deviceID": UUID().uuidString], t).text
            XCTAssertEqual(v12, "no_binding")
            let count = try await AgentJob.query(on: f.test.app.db).count()
            XCTAssertEqual(count, 0)
        }
    }

    func testStartAgentJobRejectsStaleVersionBadInputAndForeignScope() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            let id = try task.requireID().uuidString
            _ = try await device(f)
            let v13 = try await call(f, "start_agent_job", ["taskID": id, "version": task.version + 5], t).text
            XCTAssertEqual(v13, "version_conflict")
            for bad in [["taskID": id, "mode": "x"], ["taskID": id, "version": -1], ["taskID": id, "version": 1.5], ["taskID": id, "scope": 3],
                        ["taskID": id, "deviceID": "zz"], ["taskID": "zz"]] as [[String: Any]] {
                let v14 = try await call(f, "start_agent_job", bad, t).isError
                XCTAssertTrue(v14, "\(bad)")
            }
            let outside = try await self.task(f, f.other)  // project not in the grant
            let v15 = try await call(f, "start_agent_job", ["taskID": outside.requireID().uuidString], t).text
            XCTAssertEqual(v15, "not_found")
            let (_, p) = try await foreign(f)  // in the grant, but another person owns it
            let ft = TodoTask(ownerID: try p.ownerID, projectID: try p.requireID(), title: "x"); try await ft.save(on: f.test.app.db)
            let v16 = try await call(f, "start_agent_job", ["taskID": ft.requireID().uuidString], t).text
            XCTAssertEqual(v16, "not_found")
            let count = try await AgentJob.query(on: f.test.app.db).count()
            XCTAssertEqual(count, 0)
        }
    }

    func testStopAgentJobCancelsAndRejectsFinishedAndForeign() async throws {
        try await fixture { f, t in
            let task = try await task(f)
            let (_, b) = try await device(f)
            let running = try await job(f, task, try XCTUnwrap(b), state: "running")
            let c = try await call(f, "stop_agent_job", ["jobID": running.requireID().uuidString], t)
            XCTAssertFalse(c.isError, c.text)
            XCTAssertEqual(obj(c)["state"] as? String, "cancelled")
            let again = try await call(f, "stop_agent_job", ["jobID": running.requireID().uuidString], t)
            XCTAssertTrue(again.isError)
            let otherTask = try await self.task(f, f.other)
            let (_, ob) = try await device(f, project: f.other)
            let outside = try await job(f, otherTask, try XCTUnwrap(ob), state: "running")
            let v17 = try await call(f, "stop_agent_job", ["jobID": outside.requireID().uuidString], t).text
            XCTAssertEqual(v17, "not_found")
            let state = try await AgentJob.find(outside.requireID(), on: f.test.app.db)?.state
            XCTAssertEqual(state, "running")
            let v18 = try await call(f, "stop_agent_job", ["jobID": UUID().uuidString], t).text
            XCTAssertEqual(v18, "not_found")
            let v19 = try await call(f, "stop_agent_job", ["jobID": "bad"], t).isError
            XCTAssertTrue(v19)
        }
    }
}
