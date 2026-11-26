import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card 74EC341D, stage 1: a plan per card, its approval and the status of the six pipeline steps (REST and MCP).
final class PipelineTests: XCTestCase {
    private static let order = ["planner", "approval", "developer", "validation", "tester", "review"]
    private static let tables = ["task_plans", "task_pipeline_steps", "task_pipeline_events"]

    private struct Env {
        let f: OAuthFixture
        let agent: String, brain: String
        let agentGrant: UUID, brainGrant: UUID
        var pid: String { f.project.id!.uuidString }
        var session: String { f.session }
        var db: any Database { f.test.app.db }
    }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let a = try await f.tokens(scope: CommandCenterTests.scopes)
            let first = try await OAuthGrant.query(on: f.test.app.db).first()?.id
            let gA = try XCTUnwrap(first)
            let b = try await f.tokens(scope: CommandCenterTests.scopes)
            let second = try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gA).first()?.id
            let gB = try XCTUnwrap(second)
            try await body(Env(f: f, agent: a.access, brain: b.access, agentGrant: gA, brainGrant: gB))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: Helpers

    private typealias Reply = (status: HTTPStatus, body: [String: Any]?)

    private func newTask(_ e: Env, project: Project? = nil) async throws -> String {
        let t = TodoTask(ownerID: try e.f.user.requireID(), projectID: try (project ?? e.f.project).requireID(), title: "Task", details: "")
        try await t.save(on: e.db)
        return try t.requireID().uuidString
    }

    private func get(_ e: Env, _ task: String, token: String? = nil) async throws -> Reply {
        let r = try await e.f.test.json(.GET, "/v1/tasks/\(task)/pipeline", token: token ?? e.session)
        return (r.status, r.body)
    }

    private func putPlan(_ e: Env, _ task: String, _ body: [String: Any], token: String? = nil) async throws -> Reply {
        let r = try await e.f.test.json(.PUT, "/v1/tasks/\(task)/plan", body, token: token ?? e.session)
        return (r.status, r.body)
    }

    private func decide(_ e: Env, _ task: String, _ body: [String: Any], token: String? = nil) async throws -> Reply {
        let r = try await e.f.test.json(.POST, "/v1/tasks/\(task)/plan/decision", body, token: token ?? e.session)
        return (r.status, r.body)
    }

    private func putStep(_ e: Env, _ task: String, _ step: String, _ body: [String: Any], token: String? = nil) async throws -> Reply {
        let r = try await e.f.test.json(.PUT, "/v1/tasks/\(task)/pipeline/steps/\(step)", body, token: token ?? e.session)
        return (r.status, r.body)
    }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        guard let result = r.body?["result"] as? [String: Any],
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String else { return (true, "no_result \(r.body ?? [:])", nil) }
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    private func plan(_ r: Reply) -> [String: Any]? { r.body?["plan"] as? [String: Any] }
    private func steps(_ body: [String: Any]?) -> [[String: Any]] { body?["steps"] as? [[String: Any]] ?? [] }
    private func events(_ body: [String: Any]?) -> [[String: Any]] { body?["events"] as? [[String: Any]] ?? [] }
    private func states(_ body: [String: Any]?) -> [String] { steps(body).map { $0["state"] as? String ?? "?" } }
    private func step(_ body: [String: Any]?, _ name: String) -> [String: Any]? { steps(body).first { $0["step"] as? String == name } }
    private func actions(_ body: [String: Any]?) -> [String] { events(body).map { $0["action"] as? String ?? "?" } }

    private func expect(_ r: Reply, _ status: HTTPStatus, _ reason: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.status, status, "\(r.body ?? [:])", file: file, line: line)
        if let reason { XCTAssertEqual(r.body?["reason"] as? String, reason, file: file, line: line) }
    }

    private func rows(_ e: Env, _ table: String) async throws -> Int {
        let sql = try XCTUnwrap(e.db as? any SQLDatabase)
        let row = try await sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table)").first()
        return try XCTUnwrap(row).decode(column: "c", as: Int.self)
    }

    private func activityKinds(_ e: Env, _ task: String) async throws -> [String] {
        try await ActivityEvent.query(on: e.db).filter(\.$taskID == XCTUnwrap(UUID(uuidString: task))).sort(\.$sequence).all().map(\.kind)
    }

    private func person(_ e: Env, name: String, role: ProjectRole? = nil) async throws -> (user: User, token: String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: e.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: e.db)
        if let role {
            try await ProjectGrant(projectID: e.f.project.requireID(), principalType: "person", principalID: user.requireID(), role: role).save(on: e.db)
        }
        return (user, token)
    }

    private func mandate(_ e: Env, projects: [String]? = nil) async throws {
        let r = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
            ["grantID": e.brainGrant.uuidString, "projectIDs": projects ?? [e.pid]], token: e.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    // MARK: Reading

    func testEmptyPipelineListsSixPendingSteps() async throws {
        try await run { e in
            let task = try await newTask(e)
            let r = try await get(e, task)
            expect(r, .ok)
            XCTAssertEqual(r.body?["taskID"] as? String, task)
            XCTAssertNil(plan(r))
            XCTAssertEqual(steps(r.body).map { $0["step"] as? String ?? "?" }, Self.order)
            XCTAssertEqual(states(r.body), Array(repeating: "pending", count: 6))
            XCTAssertTrue(steps(r.body).allSatisfy { $0["note"] == nil && $0["actorLabel"] == nil && $0["updatedAt"] == nil })
            XCTAssertEqual(r.body?["events"] as? [String], [])
            let written = try await rows(e, "task_pipeline_steps")
            XCTAssertEqual(written, 0, "reading writes nothing")
        }
    }

    // MARK: Rights

    func testRightsForForeignAccountsReadersAndAnonymousCallers() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putPlan(e, task, ["body": "Plan"]), .ok)
            let stranger = try await person(e, name: "Stranger")
            expect(try await get(e, task, token: stranger.token), .notFound)
            expect(try await putPlan(e, task, ["body": "Mine"], token: stranger.token), .notFound)
            expect(try await decide(e, task, ["decision": "approve", "version": 1], token: stranger.token), .notFound)
            expect(try await putStep(e, task, "planner", ["state": "running"], token: stranger.token), .notFound)
            for role in [ProjectRole.read, .comment] {
                let reader = try await person(e, name: "Reader", role: role)
                expect(try await get(e, task, token: reader.token), .ok)
                expect(try await putPlan(e, task, ["body": "Mine"], token: reader.token), .forbidden)
                expect(try await decide(e, task, ["decision": "approve", "version": 1], token: reader.token), .forbidden)
                expect(try await putStep(e, task, "planner", ["state": "running"], token: reader.token), .forbidden)
            }
            for (method, path) in [(HTTPMethod.GET, "pipeline"), (.PUT, "plan"), (.POST, "plan/decision"), (.PUT, "pipeline/steps/planner")] {
                let r = try await e.f.test.json(method, "/v1/tasks/\(task)/\(path)")
                XCTAssertEqual(r.status, .unauthorized, path)
            }
            expect(try await get(e, UUID().uuidString), .notFound)
            // Nothing of the refused calls was stored.
            let after = try await get(e, task)
            XCTAssertEqual(plan(after)?["version"] as? Int, 1)
            XCTAssertEqual(plan(after)?["state"] as? String, "proposed")
            XCTAssertEqual(actions(after.body), ["plan_written"])
            let editor = try await person(e, name: "Editor Person", role: .edit)
            let approved = try await decide(e, task, ["decision": "approve", "version": 1], token: editor.token)
            expect(approved, .ok)
            XCTAssertEqual(plan(approved)?["decidedByLabel"] as? String, "Editor Person")
        }
    }

    func testMCPRespectsScopeProjectListAndMandateProjects() async throws {
        try await run { e in
            let outside = try await newTask(e, project: e.f.other)
            for (name, args) in [("get_task_pipeline", [:]), ("set_task_plan", ["plan": "P"]),
                                 ("decide_plan", ["decision": "approve", "version": 1, "quote": "ja"]),
                                 ("set_pipeline_step", ["step": "planner", "state": "running"])] as [(String, [String: Any])] {
                var a = args; a["taskID"] = outside
                let r = try await call(e, e.brain, name, a)
                XCTAssertEqual(r.text, "not_found", name)
            }
            let readOnly = try await e.f.tokens(scope: "tasks:read").access
            let task = try await newTask(e)
            let ok = try await call(e, readOnly, "get_task_pipeline", ["taskID": task])
            XCTAssertFalse(ok.isError, ok.text)
            for (name, args) in [("set_task_plan", ["plan": "P"]), ("decide_plan", ["decision": "approve", "version": 1]),
                                 ("set_pipeline_step", ["step": "planner", "state": "running"])] as [(String, [String: Any])] {
                var a = args; a["taskID"] = task
                let r = try await call(e, readOnly, name, a)
                XCTAssertEqual(r.text, "insufficient_scope", name)
            }
            let written = try await rows(e, "task_plans")
            XCTAssertEqual(written, 0)
        }
    }

    // MARK: Writing a plan

    func testWritingAPlanSetsStepsAuditAndActivityButNotTheCard() async throws {
        try await run { e in
            let task = try await newTask(e)
            let before = try await TodoTask.find(UUID(uuidString: task), on: e.db)
            let r = try await putPlan(e, task, ["body": "  # Plan\n\n- one\n\t- two  \n", "agentName": "claude-code"])
            expect(r, .ok)
            let p = try XCTUnwrap(plan(r))
            XCTAssertEqual(p["version"] as? Int, 1)
            XCTAssertEqual(p["body"] as? String, "# Plan\n\n- one\n\t- two")
            XCTAssertEqual(p["state"] as? String, "proposed")
            XCTAssertEqual(p["authorType"] as? String, "person")
            XCTAssertEqual(p["authorLabel"] as? String, "claude-code")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: p["writtenAt"] as? String ?? ""))
            XCTAssertNil(p["decidedAt"]); XCTAssertNil(p["decidedByLabel"]); XCTAssertNil(p["decisionComment"])
            XCTAssertEqual(states(r.body), ["done", "waiting", "pending", "pending", "pending", "pending"])
            XCTAssertEqual(step(r.body, "planner")?["actorLabel"] as? String, "claude-code")
            XCTAssertNotNil(step(r.body, "approval")?["updatedAt"])
            let event = try XCTUnwrap(events(r.body).first)
            XCTAssertEqual(events(r.body).count, 1)
            XCTAssertEqual(event["action"] as? String, "plan_written")
            XCTAssertEqual(event["planVersion"] as? Int, 1)
            XCTAssertEqual(event["actorType"] as? String, "person")
            XCTAssertEqual(event["actorLabel"] as? String, "claude-code")
            XCTAssertNotNil(UUID(uuidString: event["id"] as? String ?? ""))
            XCTAssertNotNil(event["createdAt"])
            let after = try await TodoTask.find(UUID(uuidString: task), on: e.db)
            XCTAssertEqual(after?.status, before?.status); XCTAssertEqual(after?.columnID, before?.columnID); XCTAssertEqual(after?.version, before?.version)
            let kinds = try await activityKinds(e, task)
            XCTAssertEqual(kinds, ["plan.written"])
            // Without agentName a person is named by the account.
            let second = try await putPlan(e, task, ["body": "Other"])
            XCTAssertEqual(plan(second)?["authorLabel"] as? String, "OAuth User")
        }
    }

    func testPlanTextIsChecked() async throws {
        try await run { e in
            let task = try await newTask(e)
            for bad in ["", "  \n\t ", "a\u{0}b", "a\u{1B}[31mb", String(repeating: "x ", count: 10_000) + "yz"] {
                expect(try await putPlan(e, task, ["body": bad]), .badRequest, "invalid_plan")
            }
            expect(try await putPlan(e, task, ["body": "P", "agentName": String(repeating: "n", count: 101)]), .badRequest, "invalid_agent_name")
            // The full length is stored without being cut (long lines, many lines, emoji joiners).
            let line = "Schritt mit Umlauten äöü und 👨\u{200D}👩\u{200D}👧 … ½\n"
            var long = String(repeating: line, count: 200) + String(repeating: "w ", count: 4000)
            long = long.trimmingCharacters(in: .whitespacesAndNewlines)
            let full = long + String(repeating: "z", count: 20_000 - long.count)
            XCTAssertEqual(full.count, 20_000)
            let r = try await putPlan(e, task, ["body": full])
            expect(r, .ok)
            XCTAssertEqual(plan(r)?["body"] as? String, full)
        }
    }

    func testSecretsAreMaskedInPlanCommentAndNote() async throws {
        try await run { e in
            let task = try await newTask(e)
            let filler = String(repeating: "harmless words in a line\n", count: 150)
            let r = try await putPlan(e, task, ["body": filler + "password=hunter2secret\n-----BEGIN PRIVATE KEY-----\nMIIabc\n-----END PRIVATE KEY-----\nend"])
            expect(r, .ok)
            let body = plan(r)?["body"] as? String ?? ""
            XCTAssertFalse(body.contains("hunter2secret"), String(body.suffix(200)))
            XCTAssertFalse(body.contains("MIIabc"))
            XCTAssertTrue(body.contains("password=[gefiltert]"))
            XCTAssertTrue(body.hasSuffix("end"))
            let step = try await putStep(e, task, "planner", ["state": "failed", "note": "token: abc123secret"])
            XCTAssertEqual(self.step(step.body, "planner")?["note"] as? String, "token: [gefiltert]")
            let d = try await decide(e, task, ["decision": "request_changes", "version": 1, "comment": "api_key=zzz999secret"])
            XCTAssertEqual(plan(d)?["decisionComment"] as? String, "api_key=[gefiltert]")
            XCTAssertFalse("\(events(d.body))".contains("secret"))
        }
    }

    /// Masking and compatibility folding lengthen text after the input check; MariaDB refuses what exceeds its columns.
    func testStoredTextAndNamesStayInsideTheirColumnsAfterMasking() async throws {
        try await run { e in
            let task = try await newTask(e)
            // Every short secret grows from 5 to 15 characters.
            func swelling(_ max: Int) -> String { String(String(repeating: "pwd=a\n", count: max / 6).dropLast()) }
            expect(try await putPlan(e, task, ["body": swelling(20_000)]), .badRequest, "invalid_plan")
            expect(try await putStep(e, task, "planner", ["state": "running", "note": swelling(2000)]), .badRequest, "invalid_note")
            // U+FDFA folds into 18 characters.
            let folding = String(repeating: "\u{FDFA}", count: 1990) + " pwd=a"
            expect(try await putStep(e, task, "planner", ["state": "running", "note": folding]), .badRequest, "invalid_note")
            let written = try await rows(e, "task_pipeline_steps")
            XCTAssertEqual(written, 0)
            expect(try await putPlan(e, task, ["body": "A"]), .ok)
            expect(try await decide(e, task, ["decision": "request_changes", "version": 1, "comment": swelling(4000)]), .badRequest, "invalid_comment")
            let names = [String(repeating: "\u{FDFA}", count: 100), "a" + String(repeating: "\u{301}", count: 600),
                         String(String(repeating: "pwd=a ", count: 17).prefix(100))]
            for (n, name) in names.enumerated() {
                let r = try await putPlan(e, task, ["body": "Plan \(n)", "agentName": name])
                expect(r, .ok)
                let label = try XCTUnwrap(plan(r)?["authorLabel"] as? String)
                XCTAssertLessThanOrEqual(label.count, 100, "name \(n)")
                XCTAssertLessThanOrEqual(label.unicodeScalars.count, 255, "name \(n)")
                XCTAssertFalse(label.contains("pwd=a"))
            }
            // Folding must not produce the reserved label after it was checked.
            expect(try await putPlan(e, task, ["body": "B", "agentName": "\u{FF22}rain im Auftrag von OAuth User"]), .badRequest, "invalid_agent_name")
        }
    }

    func testVersionConflictAndIdempotentRetry() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putPlan(e, task, ["body": "A", "expectedVersion": 1]), .conflict, "plan_changed")
            let first = try await putPlan(e, task, ["body": "A", "expectedVersion": 0])
            expect(first, .ok)
            for retry in [["body": "A"], ["body": " A \n", "expectedVersion": 0], ["body": "A", "expectedVersion": 1]] as [[String: Any]] {
                let r = try await putPlan(e, task, retry)
                expect(r, .ok)
                XCTAssertEqual(plan(r)?["version"] as? Int, 1)
                XCTAssertEqual(actions(r.body), ["plan_written"])
            }
            let kinds = try await activityKinds(e, task)
            XCTAssertEqual(kinds, ["plan.written"])
            expect(try await putPlan(e, task, ["body": "B", "expectedVersion": 0]), .conflict, "plan_changed")
            let second = try await putPlan(e, task, ["body": "B", "expectedVersion": 1])
            XCTAssertEqual(plan(second)?["version"] as? Int, 2)
            XCTAssertEqual(actions(second.body), ["plan_written", "plan_written"])
            XCTAssertEqual(events(second.body).first?["planVersion"] as? Int, 2)
            // The same text after a decision is a new proposal.
            expect(try await decide(e, task, ["decision": "request_changes", "version": 2, "comment": "no"]), .ok)
            let third = try await putPlan(e, task, ["body": "B"])
            XCTAssertEqual(plan(third)?["version"] as? Int, 3)
            XCTAssertEqual(plan(third)?["state"] as? String, "proposed")
        }
    }

    func testConcurrentWritesWithTheSameExpectedVersionHaveOneWinner() async throws {
        try await run { e in
            let task = try await newTask(e)
            let app = e.f.test, token = e.session
            let statuses = try await withThrowingTaskGroup(of: UInt.self) { group in
                for n in 0..<4 {
                    let data = try JSONSerialization.data(withJSONObject: ["body": "Plan \(n)", "expectedVersion": 0])
                    group.addTask { try await app.rawStatus(.PUT, "/v1/tasks/\(task)/plan", body: data, token: token).code }
                }
                var all: [UInt] = []
                for try await s in group { all.append(s) }
                return all.sorted()
            }
            XCTAssertEqual(statuses, [200, 409, 409, 409])
            let r = try await get(e, task)
            XCTAssertEqual(events(r.body).count, 1)
        }
    }

    // MARK: Decisions

    func testDecisionRefusals() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await decide(e, task, ["decision": "approve", "version": 1]), .conflict, "no_plan")
            expect(try await putPlan(e, task, ["body": "A"]), .ok)
            expect(try await decide(e, task, ["decision": "maybe", "version": 1]), .badRequest, "invalid_decision")
            expect(try await decide(e, task, ["decision": "approve"]), .badRequest, "invalid_version")
            expect(try await decide(e, task, ["decision": "approve", "version": 2]), .conflict, "plan_changed")
            for empty in [[:], ["comment": "  \n "]] as [[String: Any]] {
                var body: [String: Any] = ["decision": "request_changes", "version": 1]; body.merge(empty) { $1 }
                expect(try await decide(e, task, body), .badRequest, "comment_required")
            }
            for bad in [String(repeating: "c", count: 4001), "a\u{7}b"] {
                expect(try await decide(e, task, ["decision": "approve", "version": 1, "comment": bad]), .badRequest, "invalid_comment")
            }
            let r = try await get(e, task)
            XCTAssertEqual(plan(r)?["state"] as? String, "proposed")
            XCTAssertEqual(actions(r.body), ["plan_written"])
        }
    }

    func testRequestChangesThenNewPlanThenApprove() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putPlan(e, task, ["body": "A"]), .ok)
            let before = try await TodoTask.find(UUID(uuidString: task), on: e.db)
            let changes = try await decide(e, task, ["decision": "request_changes", "version": 1, "comment": "Tests fehlen:\n- E2E"])
            expect(changes, .ok)
            XCTAssertEqual(plan(changes)?["state"] as? String, "changes_requested")
            XCTAssertEqual(plan(changes)?["decisionComment"] as? String, "Tests fehlen:\n- E2E")
            XCTAssertEqual(plan(changes)?["decidedByLabel"] as? String, "OAuth User")
            XCTAssertNotNil(plan(changes)?["decidedAt"])
            XCTAssertEqual(states(changes.body), ["pending", "changes_requested", "pending", "pending", "pending", "pending"])
            XCTAssertEqual(step(changes.body, "approval")?["note"] as? String, "Tests fehlen:\n- E2E")
            XCTAssertEqual(actions(changes.body), ["plan_changes_requested", "plan_written"])
            XCTAssertEqual(events(changes.body).first?["note"] as? String, "Tests fehlen:\n- E2E")
            expect(try await decide(e, task, ["decision": "approve", "version": 1]), .conflict, "plan_not_pending")

            let next = try await putPlan(e, task, ["body": "B"])
            XCTAssertEqual(states(next.body), ["done", "waiting", "pending", "pending", "pending", "pending"])
            XCTAssertNil(plan(next)?["decisionComment"]); XCTAssertNil(plan(next)?["decidedAt"]); XCTAssertNil(plan(next)?["decidedByLabel"])
            XCTAssertNil(step(next.body, "approval")?["note"])
            expect(try await decide(e, task, ["decision": "approve", "version": 1]), .conflict, "plan_changed")
            let ok = try await decide(e, task, ["decision": "approve", "version": 2])
            expect(ok, .ok)
            XCTAssertEqual(plan(ok)?["state"] as? String, "approved")
            XCTAssertNil(plan(ok)?["decisionComment"])
            XCTAssertEqual(states(ok.body), ["done", "done", "pending", "pending", "pending", "pending"])
            XCTAssertEqual(actions(ok.body).first, "plan_approved")
            expect(try await decide(e, task, ["decision": "request_changes", "version": 2, "comment": "late"]), .conflict, "plan_not_pending")
            let after = try await TodoTask.find(UUID(uuidString: task), on: e.db)
            XCTAssertEqual(after?.status, before?.status); XCTAssertEqual(after?.columnID, before?.columnID); XCTAssertEqual(after?.version, before?.version)
            let kinds = try await activityKinds(e, task)
            XCTAssertEqual(kinds, ["plan.written", "plan.changes_requested", "plan.written", "plan.approved"])
        }
    }

    func testIntegrationDecisionsFollowTheBrainMandateRules() async throws {
        try await run { e in
            let task = try await newTask(e)
            let none = try await call(e, e.brain, "decide_plan", ["taskID": task, "decision": "approve", "version": 1, "quote": "ja"])
            XCTAssertEqual(none.text, "no_plan")
            let written = try await call(e, e.agent, "set_task_plan", ["taskID": task, "plan": "A", "agentName": "planner@mac"])
            XCTAssertFalse(written.isError, written.text)
            // Own plan first, with or without a mandate.
            let own = try await call(e, e.agent, "decide_plan", ["taskID": task, "decision": "approve", "version": 1, "quote": "ja"])
            XCTAssertEqual(own.text, "cannot_decide_own_plan")
            let noMandate = try await call(e, e.brain, "decide_plan", ["taskID": task, "decision": "approve", "version": 7, "quote": "ja"])
            XCTAssertEqual(noMandate.text, "brain_mandate_required")
            try await mandate(e)
            for (args, reason) in [([:], "quote_required"), (["quote": "  "], "quote_required"), (["quote": String(repeating: "q", count: 2001)], "invalid_quote")] as [([String: Any], String)] {
                var a: [String: Any] = ["taskID": task, "decision": "approve", "version": 1]; a.merge(args) { $1 }
                let r = try await call(e, e.brain, "decide_plan", a)
                XCTAssertEqual(r.text, reason)
            }
            let stale = try await call(e, e.brain, "decide_plan", ["taskID": task, "decision": "approve", "version": 2, "quote": "ja"])
            XCTAssertEqual(stale.text, "plan_changed")
            let untouched = try await get(e, task)
            XCTAssertEqual(plan(untouched)?["state"] as? String, "proposed")
            let audits = try await BrainDecisionAudit.query(on: e.db).count()
            XCTAssertEqual(audits, 0)

            let ok = try await call(e, e.brain, "decide_plan", ["taskID": task, "decision": "approve", "version": 1, "quote": "Lino: freigeben"])
            XCTAssertFalse(ok.isError, ok.text)
            let p = ok.json?["plan"] as? [String: Any]
            XCTAssertEqual(p?["state"] as? String, "approved")
            XCTAssertEqual(p?["authorType"] as? String, "integration")
            XCTAssertEqual(p?["authorLabel"] as? String, "planner@mac")
            XCTAssertEqual(p?["decidedByLabel"] as? String, "Test Client")
            let audit = try await e.f.test.json(.GET, "/v1/settings/brain-mandate/audit", token: e.session)
            let items = audit.body?["items"] as? [[String: Any]] ?? []
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["kind"] as? String, "plan.approved")
            XCTAssertEqual(items.first?["quote"] as? String, "Lino: freigeben")
            XCTAssertEqual(items.first?["taskID"] as? String, task)
            let comments = try await TaskComment.query(on: e.db).filter(\.$taskID == XCTUnwrap(UUID(uuidString: task))).all()
            let c = try XCTUnwrap(comments.first { $0.authorLabel == "Brain im Auftrag von OAuth User" })
            XCTAssertNil(c.reviewID); XCTAssertNil(c.questionID)
            XCTAssertTrue(c.body.contains("Lino: freigeben"), c.body)
        }
    }

    func testMandatedBrainCannotDecideItsOwnPlanAndStaysInsideTheMandate() async throws {
        try await run { e in
            try await mandate(e)
            let task = try await newTask(e)
            _ = try await call(e, e.brain, "set_task_plan", ["taskID": task, "plan": "A"])
            let own = try await call(e, e.brain, "decide_plan", ["taskID": task, "decision": "approve", "version": 1, "quote": "ja"])
            XCTAssertEqual(own.text, "cannot_decide_own_plan")
            for g in [e.agentGrant, e.brainGrant] {
                let grant = try await OAuthGrant.find(g, on: e.db)
                grant?.explicitProjects.append(try e.f.other.requireID()); try await grant?.save(on: e.db)
            }
            let other = try await newTask(e, project: e.f.other)
            _ = try await call(e, e.agent, "set_task_plan", ["taskID": other, "plan": "A"])
            let outside = try await call(e, e.brain, "decide_plan", ["taskID": other, "decision": "approve", "version": 1, "quote": "ja"])
            XCTAssertEqual(outside.text, "outside_brain_mandate")
            // A person's plan: the mandated connection requests changes in the person's words.
            let third = try await newTask(e)
            expect(try await putPlan(e, third, ["body": "P"]), .ok)
            let changes = try await call(e, e.brain, "decide_plan", ["taskID": third, "decision": "request_changes", "version": 1, "comment": "kleiner", "quote": "Lino: kleiner"])
            XCTAssertFalse(changes.isError, changes.text)
            let rows = try await BrainDecisionAudit.query(on: e.db).all()
            XCTAssertEqual(rows.map(\.kind), ["plan.changes_requested"])
            XCTAssertEqual(rows.first?.note, "kleiner")
        }
    }

    /// No HTTP route reaches the service as a runner; the rule is checked on the shared method.
    func testRunnerActorsNeverDecideAndTheBrainLabelIsReserved() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putPlan(e, task, ["body": "A", "agentName": "Brain im Auftrag von OAuth User"]), .badRequest, "invalid_agent_name")
            expect(try await putPlan(e, task, ["body": "A"]), .ok)
            try await mandate(e)
            let runner = WorkflowActor(type: .run, id: e.brainGrant, label: "runner", via: "runner")
            do {
                _ = try await WorkflowService(user: e.f.user, db: e.db).decidePlan(XCTUnwrap(UUID(uuidString: task)),
                    PlanDecisionRequest(decision: "approve", version: 1), quote: "ja", actor: runner)
                XCTFail("a runner must not decide")
            } catch let error as any AbortError {
                XCTAssertEqual(error.reason, "brain_mandate_required")
            }
            let r = try await get(e, task)
            XCTAssertEqual(plan(r)?["state"] as? String, "proposed")
        }
    }

    // MARK: Steps

    func testStepRulesAndLocks() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putStep(e, task, "deploy", ["state": "running"]), .badRequest, "invalid_step")
            expect(try await putStep(e, task, "approval", ["state": "done"]), .conflict, "step_managed")
            for state in ["waiting", "changes_requested", "nonsense", ""] {
                expect(try await putStep(e, task, "developer", ["state": state]), .badRequest, "invalid_state")
            }
            for state in ["done", "skipped"] {
                expect(try await putStep(e, task, "planner", ["state": state]), .conflict, "step_managed")
            }
            for bad in [String(repeating: "n", count: 2001), "a\u{0}b", "a" + String(repeating: "\u{301}", count: 40_000)] {
                expect(try await putStep(e, task, "planner", ["state": "running", "note": bad]), .badRequest, "invalid_note")
            }
            for name in ["developer", "validation", "tester", "review"] {
                for state in ["running", "done", "failed", "skipped"] {
                    expect(try await putStep(e, task, name, ["state": state]), .conflict, "plan_not_approved")
                }
            }
            // Setting the default state again changes nothing.
            let same = try await putStep(e, task, "developer", ["state": "pending"])
            expect(same, .ok)
            XCTAssertEqual(actions(same.body), [])
            let planning = try await putStep(e, task, "planner", ["state": "running", "agentName": "claude-code"])
            expect(planning, .ok)
            XCTAssertEqual(step(planning.body, "planner")?["actorLabel"] as? String, "claude-code")
            expect(try await putPlan(e, task, ["body": "A"]), .ok)
            expect(try await putStep(e, task, "developer", ["state": "running"]), .conflict, "plan_not_approved")
            expect(try await decide(e, task, ["decision": "request_changes", "version": 1, "comment": "no"]), .ok)
            expect(try await putStep(e, task, "developer", ["state": "running"]), .conflict, "plan_not_approved")
            expect(try await putPlan(e, task, ["body": "B"]), .ok)
            expect(try await decide(e, task, ["decision": "approve", "version": 2]), .ok)

            let before = try await get(e, task)
            let running = try await putStep(e, task, "developer", ["state": "running", "note": "Zeile 1\nZeile 2"])
            expect(running, .ok)
            XCTAssertEqual(step(running.body, "developer")?["state"] as? String, "running")
            XCTAssertEqual(step(running.body, "developer")?["note"] as? String, "Zeile 1\nZeile 2")
            XCTAssertNotNil(step(running.body, "developer")?["updatedAt"])
            XCTAssertEqual(events(running.body).count, events(before.body).count + 1)
            let event = try XCTUnwrap(events(running.body).first)
            XCTAssertEqual(event["action"] as? String, "step_changed")
            XCTAssertEqual(event["step"] as? String, "developer")
            XCTAssertEqual(event["state"] as? String, "running")
            XCTAssertEqual(event["note"] as? String, "Zeile 1\nZeile 2")
            XCTAssertEqual(event["planVersion"] as? Int, 2)
            let repeated = try await putStep(e, task, "developer", ["state": "running", "note": " Zeile 1\nZeile 2 ", "agentName": "other"])
            XCTAssertEqual(events(repeated.body).count, events(running.body).count)
            XCTAssertNil((step(repeated.body, "developer")?["actorLabel"] as? String).flatMap { $0 == "other" ? $0 : nil })
            // A missing note clears it and is a change.
            let cleared = try await putStep(e, task, "developer", ["state": "running"])
            XCTAssertNil(step(cleared.body, "developer")?["note"])
            XCTAssertEqual(events(cleared.body).count, events(running.body).count + 1)
            for (name, state) in [("developer", "done"), ("validation", "failed"), ("tester", "skipped"), ("review", "running")] {
                expect(try await putStep(e, task, name, ["state": state]), .ok)
            }
            let all = try await get(e, task)
            XCTAssertEqual(states(all.body), ["done", "done", "done", "failed", "skipped", "running"])
            let kinds = try await activityKinds(e, task)
            XCTAssertEqual(kinds.filter { $0 == "pipeline.step" }.count, 7)

            // A new version needs a new approval and resets the work steps with their notes.
            _ = try await putStep(e, task, "developer", ["state": "done", "note": "fertig"])
            let next = try await putPlan(e, task, ["body": "C"])
            XCTAssertEqual(states(next.body), ["done", "waiting", "pending", "pending", "pending", "pending"])
            XCTAssertTrue(steps(next.body).allSatisfy { $0["note"] == nil })
            expect(try await putStep(e, task, "developer", ["state": "running"]), .conflict, "plan_not_approved")
        }
    }

    func testEventsAreNewestFirstAndLimitedToFifty() async throws {
        try await run { e in
            let task = try await newTask(e)
            for n in 1...55 { expect(try await putStep(e, task, "planner", ["state": "running", "note": "n\(n)"]), .ok) }
            let r = try await get(e, task)
            XCTAssertEqual(events(r.body).count, 50)
            XCTAssertEqual(events(r.body).first?["note"] as? String, "n55")
            XCTAssertEqual(events(r.body).last?["note"] as? String, "n6")
        }
    }

    // MARK: MCP

    func testMCPToolsRoundTrip() async throws {
        try await run { e in
            let list = try await e.f.rpc("tools/list", access: e.agent)
            let tools = (list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            for name in ["get_task_pipeline", "set_task_plan", "decide_plan", "set_pipeline_step"] {
                XCTAssertTrue(tools.contains { $0["name"] as? String == name }, name)
            }
            let task = try await newTask(e)
            let empty = try await call(e, e.agent, "get_task_pipeline", ["taskID": task])
            XCTAssertEqual(steps(empty.json).count, 6, empty.text)
            let unknown = try await call(e, e.agent, "set_task_plan", ["taskID": task, "body": "A"])
            XCTAssertEqual(unknown.text, "invalid_arguments")
            let stale = try await call(e, e.agent, "set_task_plan", ["taskID": task, "plan": "A", "expectedVersion": 3])
            XCTAssertEqual(stale.text, "plan_changed")
            let fraction = try await call(e, e.agent, "set_task_plan", ["taskID": task, "plan": "A", "expectedVersion": 0.5])
            XCTAssertEqual(fraction.text, "invalid_expectedVersion")
            let long = try await call(e, e.agent, "set_task_plan", ["taskID": task, "plan": String(repeating: "x", count: 20_001)])
            XCTAssertEqual(long.text, "invalid_plan")
            let written = try await call(e, e.agent, "set_task_plan", ["taskID": task, "plan": "# A", "expectedVersion": 0])
            XCTAssertFalse(written.isError, written.text)
            XCTAssertEqual((written.json?["plan"] as? [String: Any])?["authorLabel"] as? String, "Test Client")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: (written.json?["plan"] as? [String: Any])?["writtenAt"] as? String ?? ""))
            let locked = try await call(e, e.agent, "set_pipeline_step", ["taskID": task, "step": "developer", "state": "running"])
            XCTAssertEqual(locked.text, "plan_not_approved")
            expect(try await decide(e, task, ["decision": "approve", "version": 1]), .ok)
            let running = try await call(e, e.agent, "set_pipeline_step", ["taskID": task, "step": "developer", "state": "running", "note": "baue", "agentName": "dev@mac"])
            XCTAssertFalse(running.isError, running.text)
            XCTAssertEqual(step(running.json, "developer")?["actorLabel"] as? String, "dev@mac")
            XCTAssertEqual(events(running.json).first?["actorType"] as? String, "integration")
            let read = try await get(e, task)
            XCTAssertEqual(step(read.body, "developer")?["note"] as? String, "baue")
        }
    }

    func testWaitForEventsReportsPlanAndStepChanges() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putPlan(e, task, ["body": "A"]), .ok)
            let start = try await call(e, e.agent, "wait_for_events", [:])
            let token = try XCTUnwrap(start.json?["token"] as? String, start.text)
            expect(try await decide(e, task, ["decision": "approve", "version": 1]), .ok)
            expect(try await putStep(e, task, "developer", ["state": "running"]), .ok)
            let r = try await call(e, e.agent, "wait_for_events", ["since": token, "timeoutSeconds": 1])
            let hints = r.json?["hints"] as? [[String: Any]] ?? []
            let mine = Set(hints.filter { $0["taskID"] as? String == task }.compactMap { $0["kind"] as? String })
            XCTAssertTrue(mine.isSuperset(of: ["plan", "pipeline"]), r.text)
        }
    }

    // MARK: Deletion

    func testDeletingTaskOrProjectRemovesThePipeline() async throws {
        try await run { e in
            let task = try await newTask(e)
            let other = try await newTask(e, project: e.f.other)
            for id in [task, other] {
                expect(try await putPlan(e, id, ["body": "A"]), .ok)
            }
            try await TodoTask.find(UUID(uuidString: task), on: e.db)?.delete(on: e.db)
            for table in Self.tables {
                let left = try await rows(e, table)
                XCTAssertGreaterThan(left, 0, table)
            }
            let plans = try await rows(e, "task_plans")
            XCTAssertEqual(plans, 1)
            try await e.f.other.delete(on: e.db)
            for table in Self.tables {
                let left = try await rows(e, table)
                XCTAssertEqual(left, 0, table)
            }
        }
    }

    func testAccountDeletionKeepsThePlanOnASurvivingCardWithoutTheName() async throws {
        try await run { e in
            let task = try await newTask(e)
            let author = try await person(e, name: "Leaving", role: .edit)
            expect(try await putPlan(e, task, ["body": "A"], token: author.token), .ok)
            expect(try await decide(e, task, ["decision": "approve", "version": 1], token: author.token), .ok)
            expect(try await putStep(e, task, "developer", ["state": "running"], token: author.token), .ok)
            expect(try await putStep(e, task, "tester", ["state": "running", "agentName": "tester@mac"], token: author.token), .ok)
            // No copy of the account name is stored; it is read from the account.
            let id = try XCTUnwrap(UUID(uuidString: task))
            let storedPlan = try await TaskPlan.query(on: e.db).filter(\.$taskID == id).first()
            XCTAssertNil(storedPlan?.authorLabel); XCTAssertNil(storedPlan?.decidedByLabel)
            let storedSteps = try await TaskPipelineStep.query(on: e.db).filter(\.$taskID == id).all()
            XCTAssertEqual(storedSteps.compactMap(\.actorLabel), ["tester@mac"])
            let storedEvents = try await TaskPipelineEvent.query(on: e.db).filter(\.$taskID == id).all()
            XCTAssertEqual(storedEvents.compactMap(\.actorLabel), ["tester@mac"])

            author.user.displayName = "Renamed"
            try await author.user.save(on: e.db)
            let named = try await get(e, task)
            XCTAssertEqual(plan(named)?["authorLabel"] as? String, "Renamed")
            XCTAssertEqual(plan(named)?["decidedByLabel"] as? String, "Renamed")
            XCTAssertEqual(step(named.body, "developer")?["actorLabel"] as? String, "Renamed")
            XCTAssertEqual(events(named.body).map { $0["actorLabel"] as? String ?? "?" }, ["tester@mac", "Renamed", "Renamed", "Renamed"])

            try await AccountDeletion.delete(userID: author.user.requireID(), on: e.db)
            let r = try await get(e, task)
            XCTAssertEqual(plan(r)?["state"] as? String, "approved")
            XCTAssertNil(plan(r)?["authorLabel"]); XCTAssertNil(plan(r)?["decidedByLabel"])
            XCTAssertNil(step(r.body, "developer")?["actorLabel"])
            XCTAssertEqual(step(r.body, "tester")?["actorLabel"] as? String, "tester@mac")
            XCTAssertEqual(events(r.body).count, 4)
            XCTAssertEqual(events(r.body).compactMap { $0["actorLabel"] as? String }, ["tester@mac"])
            XCTAssertFalse("\(r.body ?? [:])".contains("Renamed"))
        }
    }

    // MARK: Contract and manual

    func testContractAndManualDescribeThePipeline() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contract = (try? String(contentsOf: root.appendingPathComponent("contracts/pipeline.yaml"), encoding: .utf8)) ?? ""
        XCTAssertTrue(contract.contains("version: 1.2.0"))
        let app = try await Application.make(.testing)
        do { try routes(app) } catch { try? await app.asyncShutdown(); throw error }
        let registered = Set(app.routes.all.map { r in r.method.rawValue + " /" + r.path.map(\.description).joined(separator: "/") })
        try await app.asyncShutdown()
        for (method, path, contractPath) in [("GET", "/v1/tasks/:id/pipeline", "/v1/tasks/{taskID}/pipeline"), ("PUT", "/v1/tasks/:id/plan", "/v1/tasks/{taskID}/plan"),
            ("POST", "/v1/tasks/:id/plan/decision", "/v1/tasks/{taskID}/plan/decision"), ("PUT", "/v1/tasks/:id/pipeline/steps/:step", "/v1/tasks/{taskID}/pipeline/steps/{step}")] {
            XCTAssertTrue(registered.contains("\(method) \(path)"), "\(method) \(path)")
            XCTAssertTrue(contract.contains("  \(contractPath):"), contractPath)
        }
        for reason in ["invalid_plan", "plan_changed", "invalid_decision", "invalid_version", "no_plan", "plan_not_pending", "comment_required", "invalid_comment",
                       "cannot_decide_own_plan", "brain_mandate_required", "invalid_step", "step_managed", "invalid_state", "plan_not_approved", "invalid_note"] {
            XCTAssertTrue(contract.contains(reason), reason)
        }
        XCTAssertEqual(AgentManual.version, "1.49.0")
        for tool in ["get_task_pipeline", "set_task_plan", "decide_plan", "set_pipeline_step"] {
            XCTAssertTrue(AgentManual.markdown.contains("`\(tool)`"), tool)
        }
    }
}
