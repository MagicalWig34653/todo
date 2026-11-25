import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card F5DD1C00, stage 3 (docs/PLAN-PIPELINE-STUFE-3.md): the runner executes the pipeline of a card.
final class PipelineExecutionTests: XCTestCase {
    private struct Env {
        let f: OAuthFixture
        let deviceID: String, runner: String, bindingID: String
        let agent: String, agentGrant: UUID
        var session: String { f.session }
        var pid: String { f.project.id!.uuidString }
        var db: any Database { f.test.app.db }
    }

    private typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]])

    private func run(_ body: (Env) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens(scope: CommandCenterTests.scopes + " runs:read runs:write")
            let first = try await OAuthGrant.query(on: f.test.app.db).first()?.id
            let grant = try XCTUnwrap(first)
            let pairing = try await f.test.json(.POST, "/v1/agents/devices", ["label": "Mac"], token: f.session)
            let deviceID = try XCTUnwrap(pairing.body?["deviceID"] as? String)
            let paired = try await f.test.json(.POST, "/v1/runner/pair", ["code": try XCTUnwrap(pairing.body?["code"] as? String)])
            let runner = try XCTUnwrap(paired.body?["token"] as? String)
            let binding = try await f.test.json(.POST, "/v1/agents/bindings", ["projectID": try f.project.requireID().uuidString,
                "deviceID": deviceID, "repositoryKey": UUID().uuidString, "label": "Checkout"], token: f.session)
            try await body(Env(f: f, deviceID: deviceID, runner: runner, bindingID: try XCTUnwrap(binding.body?["id"] as? String),
                agent: tokens.access, agentGrant: grant))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: Helpers

    private func req(_ e: Env, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) async throws -> Reply {
        let r = try await e.f.test.json(method, path, body, token: token ?? e.session)
        return (r.status, r.body, r.list ?? [])
    }

    private func expect(_ r: Reply, _ status: HTTPStatus, _ reason: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.status, status, "\(r.body ?? [:])", file: file, line: line)
        if let reason { XCTAssertEqual(r.body?["reason"] as? String, reason, file: file, line: line) }
    }

    private func newTask(_ e: Env, title: String = "Task") async throws -> String {
        let t = TodoTask(ownerID: try e.f.user.requireID(), projectID: try e.f.project.requireID(), title: title, details: "Details")
        try await t.save(on: e.db)
        return try t.requireID().uuidString
    }

    private func person(_ e: Env, name: String, role: ProjectRole) async throws -> String {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: e.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: e.db)
        try await ProjectGrant(projectID: e.f.project.requireID(), principalType: "person", principalID: user.requireID(), role: role).save(on: e.db)
        return token
    }

    @discardableResult
    private func start(_ e: Env, _ task: String, id: String = UUID().uuidString, binding: String? = nil, token: String? = nil) async throws -> Reply {
        try await req(e, .POST, "/v1/tasks/\(task)/pipeline/execution", ["id": id, "bindingID": binding ?? e.bindingID], token: token)
    }

    private func resume(_ e: Env, _ task: String, version: Int? = nil, token: String? = nil) async throws -> Reply {
        try await req(e, .POST, "/v1/tasks/\(task)/pipeline/execution/continue", version.map { ["planVersion": $0] } ?? [:], token: token)
    }

    private func stop(_ e: Env, _ task: String, token: String? = nil) async throws -> Reply {
        try await req(e, .POST, "/v1/tasks/\(task)/pipeline/execution/stop", [:], token: token)
    }

    private func pipeline(_ e: Env, _ task: String, token: String? = nil) async throws -> Reply {
        try await req(e, .GET, "/v1/tasks/\(task)/pipeline", token: token)
    }

    private func putPlan(_ e: Env, _ task: String, _ text: String, token: String? = nil) async throws -> Reply {
        try await req(e, .PUT, "/v1/tasks/\(task)/plan", ["body": text], token: token)
    }

    private func decide(_ e: Env, _ task: String, version: Int = 1, comment: String? = nil, token: String? = nil) async throws -> Reply {
        var body: [String: Any] = ["decision": comment == nil ? "approve" : "request_changes", "version": version]
        if let comment { body["comment"] = comment }
        return try await req(e, .POST, "/v1/tasks/\(task)/plan/decision", body, token: token)
    }

    private func settings(_ e: Env, _ body: [String: Any], revision: Int = 0) async throws {
        var body = body
        body["revision"] = revision
        expect(try await req(e, .PATCH, "/v1/projects/\(e.pid)/pipeline-settings", body), .ok)
    }

    private func queued(_ e: Env, pipeline: Bool = true) async throws -> [[String: Any]] {
        let r = try await req(e, .GET, "/v1/runner/jobs\(pipeline ? "?pipeline=1" : "")", token: e.runner)
        XCTAssertEqual(r.status, .ok)
        return r.list
    }

    /// The only queued pipeline job and its step.
    private func queuedJob(_ e: Env, _ step: String, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let jobs = try await queued(e)
        XCTAssertEqual(jobs.map { $0["pipelineStep"] as? String ?? "?" }, [step], file: file, line: line)
        return try XCTUnwrap(jobs.first?["id"] as? String, "no queued \(step) job", file: file, line: line)
    }

    private func claimReply(_ e: Env, _ job: String, pipeline: Bool = true) async throws -> Reply {
        try await req(e, .POST, "/v1/runner/jobs/\(job)/claim\(pipeline ? "?pipeline=1" : "")", token: e.runner)
    }

    private func claim(_ e: Env, _ job: String, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let r = try await claimReply(e, job)
        expect(r, .ok, file: file, line: line)
        return try XCTUnwrap(r.body?["id"] as? String, file: file, line: line)
    }

    private func command(_ e: Env, _ run: String, _ action: String, _ body: [String: Any] = [:]) async throws -> Reply {
        var body = body
        if body["generation"] == nil { body["generation"] = 1 }
        return try await req(e, .POST, "/v1/runner/runs/\(run)/\(action)", body, token: e.runner)
    }

    private func submit(_ e: Env, _ run: String, _ outcome: String?, plan: String? = nil, summary: String = "Done") async throws -> Reply {
        var body: [String: Any] = ["result": ["summary": summary, "references": [String](), "checks": [String](), "limitations": [String]()]]
        if let outcome { body["outcome"] = outcome }
        if let plan { body["plan"] = plan }
        return try await command(e, run, "submit", body)
    }

    /// Claims the queued job of `step` and submits it.
    @discardableResult
    private func work(_ e: Env, _ step: String, _ outcome: String = "passed", plan: String? = nil, summary: String = "Done",
                      file: StaticString = #filePath, line: UInt = #line) async throws -> (job: String, run: String) {
        let job = try await queuedJob(e, step, file: file, line: line)
        let run = try await claim(e, job, file: file, line: line)
        expect(try await submit(e, run, outcome, plan: plan, summary: summary), .ok, file: file, line: line)
        return (job, run)
    }

    private func detail(_ e: Env, _ job: String) async throws -> [String: Any] {
        let r = try await req(e, .GET, "/v1/runner/jobs/\(job)", token: e.runner)
        expect(r, .ok)
        return r.body?["pipeline"] as? [String: Any] ?? [:]
    }

    private func jobState(_ job: String, _ e: Env) async throws -> String? {
        try await AgentJob.find(UUID(uuidString: job), on: e.db)?.state
    }

    private func execution(_ r: Reply) -> [String: Any] { r.body?["execution"] as? [String: Any] ?? [:] }
    private func execState(_ e: Env, _ task: String) async throws -> [String?] {
        let x = execution(try await pipeline(e, task))
        return [x["state"] as? String, x["reason"] as? String, x["step"] as? String]
    }
    private func step(_ r: Reply, _ name: String) -> [String: Any] {
        (r.body?["steps"] as? [[String: Any]] ?? []).first { $0["step"] as? String == name } ?? [:]
    }
    private func stepState(_ e: Env, _ task: String, _ name: String) async throws -> String? {
        step(try await pipeline(e, task), name)["state"] as? String
    }
    private func events(_ r: Reply) -> [[String: Any]] { r.body?["events"] as? [[String: Any]] ?? [] }
    private func actions(_ r: Reply) -> [String] { events(r).map { $0["action"] as? String ?? "?" } }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        guard let result = r.body?["result"] as? [String: Any],
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String else { return (true, "no_result \(r.body ?? [:])", nil) }
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    private func jobCount(_ e: Env) async throws -> Int { try await AgentJob.query(on: e.db).count() }

    /// Execution with an approved plan v1, the developer job queued.
    private func started(_ e: Env) async throws -> String {
        let task = try await newTask(e)
        expect(try await putPlan(e, task, "Plan"), .ok)
        expect(try await decide(e, task), .ok)
        expect(try await start(e, task), .ok)
        return task
    }

    // MARK: Full flow

    func testFullFlowFromStartToReview() async throws {
        try await run { e in
            let task = try await newTask(e)
            try await settings(e, ["roles": ["planner": ["model": "opus", "effort": "high"], "developer": ["model": "sonnet"]]])
            let id = UUID().uuidString
            let first = try await start(e, task, id: id)
            expect(first, .ok)
            var x = execution(first)
            XCTAssertEqual(x["id"] as? String, id)
            XCTAssertEqual(x["state"] as? String, "running")
            XCTAssertEqual(x["step"] as? String, "planner")
            XCTAssertEqual(x["jobState"] as? String, "queued")
            XCTAssertEqual(x["bindingID"] as? String, e.bindingID)
            XCTAssertEqual(x["bindingLabel"] as? String, "Checkout")
            XCTAssertEqual(x["deviceLabel"] as? String, "Mac")
            XCTAssertEqual(x["runnerSupportsPipeline"] as? Bool, false)
            XCTAssertNil(x["reason"]); XCTAssertNil(x["jobProgress"])
            XCTAssertNotNil(x["createdAt"]); XCTAssertNotNil(x["updatedAt"])

            let planner = try await queuedJob(e, "planner")
            x = execution(try await pipeline(e, task))
            XCTAssertEqual(x["jobID"] as? String, planner)
            XCTAssertEqual(x["runnerSupportsPipeline"] as? Bool, true)
            let listed = try await queued(e)
            XCTAssertEqual(listed.first?["mode"] as? String, "clarify")
            XCTAssertEqual(listed.first?["pipelineExecutionID"] as? String, id)

            let plannerRun = try await claim(e, planner)
            var current = try await stepState(e, task, "planner")
            XCTAssertEqual(current, "running")
            var info = try await detail(e, planner)
            XCTAssertEqual(info["step"] as? String, "planner")
            XCTAssertEqual(info["model"] as? String, "opus")
            XCTAssertEqual(info["effort"] as? String, "high")
            XCTAssertNil(info["resumeSessionReference"]); XCTAssertNil(info["planBody"])
            let session = UUID().uuidString
            expect(try await command(e, plannerRun, "checkpoint", ["checkpoint": ["contextRevision": 1, "sessionReference": session, "nextStep": "Plan"]]), .ok)
            expect(try await submit(e, plannerRun, "passed", plan: "1. Build it", summary: "Planned"), .ok)
            let plannerState = try await jobState(planner, e)
            XCTAssertEqual(plannerState, "succeeded")
            var state = try await pipeline(e, task)
            XCTAssertEqual((state.body?["plan"] as? [String: Any])?["body"] as? String, "1. Build it")
            XCTAssertEqual((state.body?["plan"] as? [String: Any])?["authorType"] as? String, "run")
            XCTAssertEqual((state.body?["plan"] as? [String: Any])?["authorLabel"] as? String, "Runner")
            XCTAssertEqual(execution(state)["state"] as? String, "waiting_approval")
            var waiting = try await queued(e)
            XCTAssertTrue(waiting.isEmpty)

            expect(try await decide(e, task), .ok)
            let developer = try await queuedJob(e, "developer")
            var jobs = try await queued(e)
            XCTAssertEqual(jobs.first?["mode"] as? String, "implement")
            let developerRun = try await claim(e, developer)
            info = try await detail(e, developer)
            XCTAssertEqual(info["planBody"] as? String, "1. Build it")
            XCTAssertEqual(info["planVersion"] as? Int, 1)
            XCTAssertEqual(info["model"] as? String, "sonnet")
            XCTAssertEqual(info["resumeSessionReference"] as? String, session)
            expect(try await submit(e, developerRun, "passed", summary: "Built with token ghp_abcdefghijklmnopqrstuvwxyz0123456789 " + String(repeating: "x", count: 3000)), .ok)
            state = try await pipeline(e, task)
            let note = try XCTUnwrap(step(state, "developer")["note"] as? String)
            XCTAssertEqual(step(state, "developer")["state"] as? String, "done")
            XCTAssertEqual(step(state, "developer")["actorLabel"] as? String, "Runner")
            XCTAssertLessThanOrEqual(note.count, 2000)
            XCTAssertFalse(note.contains("ghp_abcdefghij"))

            let validation = try await queuedJob(e, "validation")
            jobs = try await queued(e)
            XCTAssertEqual(jobs.first?["mode"] as? String, "clarify")
            let validationRun = try await claim(e, validation)
            info = try await detail(e, validation)
            XCTAssertNil(info["resumeSessionReference"])
            expect(try await submit(e, validationRun, "passed", summary: "Exit 0"), .ok)

            try await work(e, "tester", "failed", summary: "Two tests fail")
            var now = try await execState(e, task)
            XCTAssertEqual(now, ["blocked", "step_failed", "tester"])
            current = try await stepState(e, task, "tester")
            XCTAssertEqual(current, "failed")
            waiting = try await queued(e)
            XCTAssertTrue(waiting.isEmpty, "no automatic retry")

            expect(try await req(e, .POST, "/v1/tasks/\(task)/pipeline/steps/tester/retry", ["note": "Check the second test"]), .ok)
            let tester = try await queuedJob(e, "tester")
            let testerRun = try await claim(e, tester)
            info = try await detail(e, tester)
            XCTAssertEqual(info["feedback"] as? String, "Check the second test")
            XCTAssertNil(info["resumeSessionReference"])
            expect(try await submit(e, testerRun, "passed"), .ok)
            current = try await stepState(e, task, "developer")
            XCTAssertEqual(current, "done", "only the tester ran again")

            let last = try await work(e, "review", summary: "Looks good")
            let lastState = try await jobState(last.job, e)
            XCTAssertEqual(lastState, "awaiting_review")
            state = try await pipeline(e, task)
            XCTAssertEqual(execution(state)["state"] as? String, "completed")
            let reviews = try await TaskReview.query(on: e.db).filter(\.$taskID == UUID(uuidString: task)!).all()
            XCTAssertEqual(reviews.map(\.state), ["pending"])
            XCTAssertEqual(reviews.first?.agentJobID?.uuidString, last.job)
            XCTAssertEqual(actions(state).filter { $0.hasPrefix("execution_") }.reversed(), ["execution_started", "execution_completed"])
            let stepEvents = events(state).filter { $0["action"] as? String == "step_changed" && $0["actorType"] as? String == "run" }
            XCTAssertFalse(stepEvents.isEmpty)
            XCTAssertTrue(stepEvents.allSatisfy { $0["actorLabel"] as? String == "Runner" })
            let activity = try await ActivityEvent.query(on: e.db).filter(\.$taskID == UUID(uuidString: task)!).all().map(\.kind)
            XCTAssertTrue(activity.contains("pipeline.execution"))
            let reviewed = try await req(e, .POST, "/v1/agents/jobs/\(last.job)/review", ["decision": "accept"])
            XCTAssertEqual(reviewed.body?["state"] as? String, "succeeded")
            now = try await execState(e, task)
            XCTAssertEqual(now.first, "completed")
        }
    }

    func testPlannerChangesRequestedResumesWithFeedbackAndPlanIsRequired() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await start(e, task), .ok)
            let job = try await queuedJob(e, "planner")
            let run = try await claim(e, job)
            let session = UUID().uuidString
            expect(try await command(e, run, "checkpoint", ["checkpoint": ["contextRevision": 1, "sessionReference": session, "nextStep": "Plan"]]), .ok)
            expect(try await submit(e, run, nil, plan: "x"), .badRequest, "outcome_required")
            expect(try await submit(e, run, "maybe", plan: "x"), .badRequest, "outcome_required")
            expect(try await submit(e, run, "passed"), .badRequest, "plan_required")
            expect(try await submit(e, run, "passed", plan: String(repeating: "a", count: 20_001)), .badRequest, "plan_required")
            expect(try await submit(e, run, "passed", plan: "First"), .ok)
            expect(try await decide(e, task, comment: "Smaller please"), .ok)
            let again = try await queuedJob(e, "planner")
            _ = try await claim(e, again)
            let info = try await detail(e, again)
            XCTAssertEqual(info["feedback"] as? String, "Smaller please")
            XCTAssertEqual(info["planBody"] as? String, "First")
            XCTAssertEqual(info["resumeSessionReference"] as? String, session)
        }
    }

    // MARK: Fix rounds, failure, stop

    func testFixRoundLimitBlocksFurtherRetries() async throws {
        try await run { e in
            try await settings(e, ["maxFixRounds": 1])
            let task = try await started(e)
            try await work(e, "developer", "failed")
            var now = try await execState(e, task)
            XCTAssertEqual(now, ["blocked", "step_failed", "developer"])
            expect(try await req(e, .POST, "/v1/tasks/\(task)/pipeline/steps/developer/retry", [:]), .ok)
            try await work(e, "developer", "failed")
            now = try await execState(e, task)
            XCTAssertEqual(now, ["blocked", "fix_rounds_exhausted", "developer"])
            expect(try await req(e, .POST, "/v1/tasks/\(task)/pipeline/steps/developer/retry", [:]), .conflict, "fix_rounds_exhausted")
            let waiting = try await queued(e)
            XCTAssertTrue(waiting.isEmpty)
        }
    }

    func testRunnerFailAndReconcileStoppedBlockTheExecution() async throws {
        try await run { e in
            let task = try await started(e)
            var job = try await queuedJob(e, "developer")
            var run = try await claim(e, job)
            expect(try await command(e, run, "fail"), .ok)
            var now = try await execState(e, task)
            XCTAssertEqual(now, ["blocked", "step_failed", "developer"])
            var state = try await pipeline(e, task)
            XCTAssertEqual(step(state, "developer")["note"] as? String, "Lauf abgebrochen oder fehlgeschlagen")
            expect(try await req(e, .POST, "/v1/tasks/\(task)/pipeline/steps/developer/retry", [:]), .ok)
            job = try await queuedJob(e, "developer")
            run = try await claim(e, job)
            expect(try await command(e, run, "reconcile", ["observation": "stopped"]), .ok)
            now = try await execState(e, task)
            XCTAssertEqual(now, ["blocked", "step_failed", "developer"])
            state = try await pipeline(e, task)
            XCTAssertEqual(step(state, "developer")["state"] as? String, "failed")
        }
    }

    func testStopByPersonRunnerAndOldStopRoute() async throws {
        try await run { e in
            let task = try await started(e)
            var job = try await queuedJob(e, "developer")
            var run = try await claim(e, job)
            let stopped = try await stop(e, task)
            expect(stopped, .ok)
            XCTAssertEqual(execution(stopped)["state"] as? String, "stopped")
            XCTAssertEqual(step(stopped, "developer")["state"] as? String, "pending")
            XCTAssertEqual((stopped.body?["fixRounds"] as? [String: Any])?["used"] as? Int, 0)
            XCTAssertTrue(actions(stopped).contains("execution_stopped"))
            var state = try await jobState(job, e)
            XCTAssertEqual(state, "cancelled")
            expect(try await command(e, run, "progress", ["progress": "late"]), .conflict, "stale_generation")
            expect(try await stop(e, task), .conflict, "no_execution")
            expect(try await resume(e, task), .conflict, "no_execution")
            expect(try await command(e, run, "reconcile", ["generation": 2, "observation": "stopped"]), .ok)
            var now = try await execState(e, task)
            XCTAssertEqual(now.first, "stopped", "confirming the end does not change a stopped execution")

            // A new start replaces the ended execution; stop by the runner.
            expect(try await start(e, task), .ok)
            job = try await queuedJob(e, "developer")
            run = try await claim(e, job)
            expect(try await command(e, run, "stop"), .ok)
            now = try await execState(e, task)
            XCTAssertEqual(now.first, "stopped")
            var current = try await stepState(e, task, "developer")
            XCTAssertEqual(current, "pending")

            // The existing stop of a job stops the execution too.
            expect(try await start(e, task), .ok)
            job = try await queuedJob(e, "developer")
            expect(try await req(e, .POST, "/v1/agents/jobs/\(job)/stop"), .ok)
            now = try await execState(e, task)
            XCTAssertEqual(now.first, "stopped")
            current = try await stepState(e, task, "developer")
            XCTAssertEqual(current, "pending")
            state = try await jobState(job, e)
            XCTAssertEqual(state, "cancelled")
        }
    }

    func testOwnerTransferAndDeviceRevokeStopTheExecution() async throws {
        try await run { e in
            let task = try await started(e)
            expect(try await req(e, .DELETE, "/v1/agents/devices/\(e.deviceID)"), .noContent)
            let now = try await execState(e, task)
            XCTAssertEqual(now.first, "stopped")
            let waiting = try await AgentJob.query(on: e.db).filter(\.$state == "queued").count()
            XCTAssertEqual(waiting, 0)
        }
        try await run { e in
            let task = try await started(e)
            let other = User(displayName: "New Owner", isAdmin: false)
            try await other.save(on: e.db)
            try await e.db.transaction { db in
                let project = try await Project.find(UUID(uuidString: e.pid), on: db)!
                project.ownerID = try other.requireID()
                try await project.save(on: db)
                try await AgentService.revokeRunnerAccess(projectID: project.requireID(), on: db)
            }
            let stored = try await TaskPipelineExecution.query(on: e.db).filter(\.$taskID == UUID(uuidString: task)!).first()
            XCTAssertEqual(stored?.state, "stopped")
        }
    }

    // MARK: Paused

    func testPlanWrittenByAnEditorNeedsTheOwnerAndContinueChecksTheVersion() async throws {
        try await run { e in
            let editor = try await person(e, name: "Editor", role: .edit)
            let task = try await newTask(e)
            expect(try await start(e, task), .ok)
            let planner = try await queuedJob(e, "planner")
            let run = try await claim(e, planner)
            expect(try await submit(e, run, "passed", plan: "Runner plan"), .ok)
            expect(try await decide(e, task, token: editor), .ok)
            var now = try await execState(e, task)
            XCTAssertEqual(now, ["paused", "plan_needs_owner", "developer"])
            var waiting = try await queued(e)
            XCTAssertTrue(waiting.isEmpty)
            expect(try await resume(e, task, version: 7), .conflict, "plan_changed")
            expect(try await resume(e, task, version: 1, token: editor), .forbidden)
            // Without a plan version nothing new is accepted.
            expect(try await resume(e, task), .ok)
            now = try await execState(e, task)
            XCTAssertEqual(now.prefix(2), ["paused", "plan_needs_owner"])
            let continued = try await resume(e, task, version: 1)
            expect(continued, .ok)
            XCTAssertEqual(execution(continued)["state"] as? String, "running")
            XCTAssertTrue(actions(continued).contains("execution_continued"))
            _ = try await queuedJob(e, "developer")
            waiting = try await queued(e)
            XCTAssertEqual(waiting.count, 1)
        }
    }

    func testEditorPlanWithoutApprovalStepNeedsTheOwnerButOwnersOwnPlanRuns() async throws {
        try await run { e in
            try await settings(e, ["steps": ["approval": false]])
            let editor = try await person(e, name: "Editor", role: .edit)
            let task = try await newTask(e)
            expect(try await putPlan(e, task, "Owner plan"), .ok)
            expect(try await start(e, task), .ok)
            let job = try await queuedJob(e, "developer")
            // An editor replaces the plan while the job waits: the runner must never see it.
            expect(try await putPlan(e, task, "Editor plan", token: editor), .ok)
            expect(try await claimReply(e, job), .conflict, "plan_changed")
            let cancelled = try await jobState(job, e)
            XCTAssertEqual(cancelled, "cancelled")
            var now = try await execState(e, task)
            XCTAssertEqual(now.prefix(2), ["paused", "plan_needs_owner"])
            expect(try await putPlan(e, task, "Owner again"), .ok)
            now = try await execState(e, task)
            XCTAssertEqual(now.first, "running")
            _ = try await queuedJob(e, "developer")
        }
    }

    func testPlannerWithoutApprovalContinuesAtOnceAndPlannerOffNeedsNoPlan() async throws {
        try await run { e in
            try await settings(e, ["steps": ["approval": false]])
            let task = try await newTask(e)
            expect(try await start(e, task), .ok)
            try await work(e, "planner", plan: "Auto")
            _ = try await queuedJob(e, "developer")
        }
        try await run { e in
            try await settings(e, ["steps": ["planner": false, "validation": false, "tester": false]])
            let editor = try await person(e, name: "Editor", role: .edit)
            let task = try await newTask(e)
            expect(try await putPlan(e, task, "Not trusted", token: editor), .ok)
            expect(try await start(e, task), .ok)
            let job = try await queuedJob(e, "developer")
            let run = try await claim(e, job)
            let info = try await detail(e, job)
            XCTAssertNil(info["planBody"], "without a planner no plan text reaches the agent")
            expect(try await submit(e, run, "passed"), .ok)
            let review = try await work(e, "review")
            let state = try await jobState(review.job, e)
            XCTAssertEqual(state, "awaiting_review")
        }
    }

    func testChangedCardPausesAtClaimAndBeforeTheNextStep() async throws {
        try await run { e in
            let task = try await started(e)
            let job = try await queuedJob(e, "developer")
            let stored = try await TodoTask.find(UUID(uuidString: task), on: e.db)
            let card = try XCTUnwrap(stored)
            card.title = "Do something else"; card.version += 1
            try await card.save(on: e.db)
            expect(try await claimReply(e, job), .conflict, "task_changed")
            let cancelled = try await jobState(job, e)
            XCTAssertEqual(cancelled, "cancelled")
            var now = try await execState(e, task)
            XCTAssertEqual(now, ["paused", "task_changed", "developer"])
            expect(try await resume(e, task, version: 1), .ok)
            let next = try await queuedJob(e, "developer")
            // A change that is not part of the content (status) does not matter; the revision is taken over at the claim.
            card.status = "in_progress"; card.version += 1
            try await card.save(on: e.db)
            let claimed = try await claimReply(e, next)
            expect(claimed, .ok)
            XCTAssertEqual((claimed.body?["job"] as? [String: Any])?["taskRevision"] as? Int, card.version)
            // Content changes while the step runs: the result counts, the next step waits.
            card.details = "New details"; card.version += 1
            try await card.save(on: e.db)
            expect(try await submit(e, try XCTUnwrap(claimed.body?["id"] as? String), "passed"), .ok)
            now = try await execState(e, task)
            XCTAssertEqual(now, ["paused", "task_changed", "validation"])
        }
    }

    func testRetryByEditorOrConnectionStartsNothing() async throws {
        try await run { e in
            let editor = try await person(e, name: "Editor", role: .edit)
            let task = try await started(e)
            try await work(e, "developer", "failed")
            let before = try await jobCount(e)
            expect(try await req(e, .POST, "/v1/tasks/\(task)/pipeline/steps/developer/retry", [:], token: editor), .ok)
            var now = try await execState(e, task)
            XCTAssertEqual(now, ["paused", "continue_required", "developer"])
            var count = try await jobCount(e)
            XCTAssertEqual(count, before)
            expect(try await resume(e, task, version: 1), .ok)
            try await work(e, "developer", "failed")
            count = try await jobCount(e)
            let retried = try await call(e, e.agent, "retry_pipeline_step", ["taskID": task, "step": "developer"])
            XCTAssertFalse(retried.isError, retried.text)
            now = try await execState(e, task)
            XCTAssertEqual(now, ["paused", "continue_required", "developer"])
            let after = try await jobCount(e)
            XCTAssertEqual(after, count)
        }
    }

    func testEditRightsNeverStartAnAgent() async throws {
        try await run { e in
            let editor = try await person(e, name: "Editor", role: .edit)
            let manager = try await person(e, name: "Manager", role: .manage)
            let fresh = try await newTask(e)
            for token in [editor, manager] {
                expect(try await start(e, fresh, token: token), .forbidden)
            }
            var count = try await jobCount(e)
            XCTAssertEqual(count, 0)

            let task = try await newTask(e)
            expect(try await start(e, task), .ok)
            try await work(e, "planner", plan: "Plan")
            count = try await jobCount(e)
            for token in [editor, manager] {
                expect(try await stop(e, task, token: token), .forbidden)
                expect(try await resume(e, task, version: 1, token: token), .forbidden)
            }
            // Requesting changes would start the planner again.
            expect(try await decide(e, task, comment: "Again", token: editor), .ok)
            var now = try await execState(e, task)
            XCTAssertEqual(now.prefix(2), ["paused", "continue_required"])
            var after = try await jobCount(e)
            XCTAssertEqual(after, count)

            // Resetting a finished step while a later one runs must not start it again.
            let other = try await started(e)
            try await work(e, "developer")
            expect(try await req(e, .PUT, "/v1/tasks/\(other)/pipeline/steps/developer", ["state": "pending"], token: editor), .ok)
            count = try await jobCount(e)
            try await work(e, "validation")
            now = try await execState(e, other)
            XCTAssertEqual(now, ["paused", "continue_required", "developer"])
            after = try await jobCount(e)
            XCTAssertEqual(after, count)
        }
    }

    // MARK: Start checks and idempotency

    func testStartChecksAndIdempotency() async throws {
        try await run { e in
            let task = try await newTask(e)
            let id = UUID().uuidString
            expect(try await start(e, task, id: id, binding: UUID().uuidString), .notFound)
            expect(try await start(e, UUID().uuidString), .notFound)
            let other = try await newTask(e)
            // An open manual job on the card does not matter.
            expect(try await req(e, .POST, "/v1/agents/jobs", ["id": UUID().uuidString, "taskID": task, "bindingID": e.bindingID,
                "taskRevision": 1, "mode": "implement", "scope": "Manual"]), .ok)
            expect(try await start(e, task, id: id), .ok)
            expect(try await start(e, task, id: id), .ok)
            var count = try await jobCount(e)
            XCTAssertEqual(count, 2)
            expect(try await start(e, other, id: id), .conflict, "execution_id_conflict")
            expect(try await start(e, task), .conflict, "execution_active")
            expect(try await putPlan(e, other, "Plan"), .ok)
            expect(try await decide(e, other), .ok)
            for name in ["developer", "validation", "tester", "review"] {
                expect(try await req(e, .PUT, "/v1/tasks/\(other)/pipeline/steps/\(name)", ["state": "done"]), .ok)
            }
            expect(try await start(e, other), .conflict, "nothing_to_run")
            count = try await jobCount(e)
            XCTAssertEqual(count, 2)
            let none = try await pipeline(e, other)
            XCTAssertNil(none.body?["execution"])
        }
    }

    // MARK: Hold and old runners

    func testHoldSetsProgressOnQueuedJobsOnly() async throws {
        try await run { e in
            let task = try await started(e)
            let job = try await queuedJob(e, "developer")
            let held = try await req(e, .POST, "/v1/runner/jobs/\(job)/hold", ["reason": "Kontingent-Bremse: rot"], token: e.runner)
            expect(held, .ok)
            XCTAssertEqual(held.body?["progress"] as? String, "Kontingent-Bremse: rot")
            XCTAssertEqual(held.body?["state"] as? String, "queued")
            expect(try await req(e, .POST, "/v1/runner/jobs/\(job)/hold", ["reason": "Kontingent-Bremse: rot"], token: e.runner), .ok)
            let count = try await AgentEvent.query(on: e.db).filter(\.$jobID == UUID(uuidString: job)!).filter(\.$kind == "held").count()
            XCTAssertEqual(count, 1)
            expect(try await req(e, .POST, "/v1/runner/jobs/\(job)/hold", ["reason": String(repeating: "a", count: 201)], token: e.runner), .badRequest)
            expect(try await req(e, .POST, "/v1/runner/jobs/\(job)/hold", ["reason": "x"], token: e.session), .unauthorized)
            let shown = execution(try await pipeline(e, task))
            XCTAssertEqual(shown["jobProgress"] as? String, "Kontingent-Bremse: rot")
            let claimed = try await claimReply(e, job)
            XCTAssertEqual((claimed.body?["job"] as? [String: Any])?["progress"] as? String, "")
            expect(try await req(e, .POST, "/v1/runner/jobs/\(job)/hold", ["reason": "x"], token: e.runner), .conflict, "job_not_queued")
        }
    }

    func testOldRunnerAndManualJobsStayAsBefore() async throws {
        try await run { e in
            _ = try await started(e)
            let task = try await newTask(e)
            let manual = UUID().uuidString
            expect(try await req(e, .POST, "/v1/agents/jobs", ["id": manual, "taskID": task, "bindingID": e.bindingID,
                "taskRevision": 1, "mode": "implement", "scope": "Manual"]), .ok)
            let old = try await queued(e, pipeline: false)
            XCTAssertEqual(old.map { $0["id"] as? String }, [manual])
            XCTAssertNil(old.first?["pipelineStep"]); XCTAssertNil(old.first?["pipelineExecutionID"])
            let device = try await RunnerDevice.find(UUID(uuidString: e.deviceID), on: e.db)
            XCTAssertNil(device?.pipelineSeenAt)
            let all = try await queued(e)
            XCTAssertEqual(all.count, 2)
            let pipelineJob = try XCTUnwrap(all.first { $0["pipelineStep"] != nil }?["id"] as? String)
            expect(try await claimReply(e, pipelineJob, pipeline: false), .conflict, "pipeline_runner_required")
            let still = try await jobState(pipelineJob, e)
            XCTAssertEqual(still, "queued")
            let claimed = try await claimReply(e, manual, pipeline: false)
            expect(claimed, .ok)
            let run = try XCTUnwrap(claimed.body?["id"] as? String)
            let detail = try await req(e, .GET, "/v1/runner/jobs/\(manual)", token: e.runner)
            XCTAssertNil(detail.body?["pipeline"])
            // The old submit without outcome.
            let submitted = try await command(e, run, "submit", ["result": ["summary": "Ready", "references": [String](), "checks": [String](), "limitations": [String]()]])
            expect(submitted, .ok)
            XCTAssertEqual((submitted.body?["job"] as? [String: Any])?["state"] as? String, "awaiting_review")
        }
    }

    // MARK: MCP

    func testMCPStartAndRead() async throws {
        try await run { e in
            let task = try await newTask(e)
            XCTAssertEqual(MCPController.tools.first { $0.name == "start_pipeline_execution" }?.scope, "runs:write")
            let readOnly = try await e.f.tokens(scope: "projects:read tasks:read tasks:write").access
            let refused = try await call(e, readOnly, "start_pipeline_execution", ["taskID": task, "bindingID": e.bindingID])
            XCTAssertTrue(refused.isError, refused.text)
            let id = UUID().uuidString
            let started = try await call(e, e.agent, "start_pipeline_execution", ["taskID": task, "bindingID": e.bindingID, "executionID": id])
            XCTAssertFalse(started.isError, started.text)
            XCTAssertEqual((started.json?["execution"] as? [String: Any])?["id"] as? String, id)
            let read = try await call(e, e.agent, "get_task_pipeline", ["taskID": task])
            XCTAssertEqual((read.json?["execution"] as? [String: Any])?["state"] as? String, "running")
            let again = try await call(e, e.agent, "start_pipeline_execution", ["taskID": task, "bindingID": e.bindingID])
            XCTAssertTrue(again.text.contains("execution_active"), again.text)
            let activity = try await ActivityEvent.query(on: e.db).filter(\.$taskID == UUID(uuidString: task)!)
                .filter(\.$kind == "pipeline.execution").first()
            XCTAssertEqual(activity?.actorType, .integration)
            // A connection writing a plan never starts a step.
            try await work(e, "planner", plan: "Plan")
            let written = try await call(e, e.agent, "set_task_plan", ["taskID": task, "plan": "Agent plan"])
            XCTAssertFalse(written.isError, written.text)
            let waiting = try await queued(e)
            XCTAssertTrue(waiting.isEmpty)
        }
    }

    // MARK: Contracts

    func testContractsAndManualDescribeStageThree() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let pipeline = read("contracts/pipeline.yaml")
        XCTAssertTrue(pipeline.contains("version: 1.2.0"))
        for word in ["/v1/tasks/{taskID}/pipeline/execution:", "/v1/tasks/{taskID}/pipeline/execution/continue:",
                     "/v1/tasks/{taskID}/pipeline/execution/stop:", "execution_active", "execution_id_conflict", "nothing_to_run",
                     "no_execution", "plan_needs_owner", "task_changed", "continue_required", "start_pipeline_execution"] {
            XCTAssertTrue(pipeline.contains(word), word)
        }
        let agents = read("contracts/agents.yaml")
        XCTAssertTrue(agents.contains("version: 1.3.0"))
        for word in ["/v1/runner/jobs/{id}/hold:", "pipeline_runner_required", "outcome_required", "plan_required", "pipelineStep", "resumeSessionReference"] {
            XCTAssertTrue(agents.contains(word), word)
        }
        XCTAssertTrue(read("contracts/oauth-mcp.yaml").contains("version: 1.10.0"))
        XCTAssertTrue(read("contracts/oauth-mcp.yaml").contains("start_pipeline_execution"))
        XCTAssertEqual(AgentManual.version, "1.45.0")
        XCTAssertTrue(AgentManual.markdown.contains("`start_pipeline_execution`"))
        XCTAssertTrue(read("docs/MCP-PARITAET.md").contains("start_pipeline_execution"))
    }
}
