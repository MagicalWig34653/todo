import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card B926E7D8, pipeline stage 2 (docs/PLAN-PIPELINE-STUFE-2.md sections 1 to 4): project settings, the wider pipeline
/// answer, step switches, retry and the plan version on steps. Stage 1 behaviour is covered by `PipelineTests`.
final class PipelineStage2Tests: XCTestCase {
    private static let scope = "projects:read projects:write tasks:read tasks:write"

    struct Env {
        let f: OAuthFixture
        let agent: String, brain: String, readOnly: String
        let brainGrant: UUID
        var pid: String { f.project.id!.uuidString }
        var session: String { f.session }
        var db: any Database { f.test.app.db }
    }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let a = try await f.tokens(scope: Self.scope)
            let first = try await OAuthGrant.query(on: f.test.app.db).first()?.id
            let gA = try XCTUnwrap(first)
            let b = try await f.tokens(scope: Self.scope)
            let second = try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gA).first()?.id
            let gB = try XCTUnwrap(second)
            let ro = try await f.tokens(scope: "projects:read tasks:read")
            try await body(Env(f: f, agent: a.access, brain: b.access, readOnly: ro.access, brainGrant: gB))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: Helpers

    private typealias Reply = (status: HTTPStatus, body: [String: Any]?)

    private func newTask(_ e: Env, project: Project? = nil, title: String = "Task") async throws -> String {
        let t = TodoTask(ownerID: try e.f.user.requireID(), projectID: try (project ?? e.f.project).requireID(), title: title, details: "")
        try await t.save(on: e.db)
        return try t.requireID().uuidString
    }

    private func req(_ e: Env, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) async throws -> Reply {
        let r = try await e.f.test.json(method, path, body, token: token ?? e.session)
        return (r.status, r.body)
    }

    private func settings(_ e: Env, token: String? = nil, project: String? = nil) async throws -> Reply {
        try await req(e, .GET, "/v1/projects/\(project ?? e.pid)/pipeline-settings", token: token)
    }

    private func patch(_ e: Env, _ body: [String: Any], token: String? = nil, project: String? = nil) async throws -> Reply {
        try await req(e, .PATCH, "/v1/projects/\(project ?? e.pid)/pipeline-settings", body, token: token)
    }

    private func pipeline(_ e: Env, _ task: String, token: String? = nil) async throws -> Reply {
        try await req(e, .GET, "/v1/tasks/\(task)/pipeline", token: token)
    }
    private func putPlan(_ e: Env, _ task: String, _ text: String = "Plan", token: String? = nil) async throws -> Reply {
        try await req(e, .PUT, "/v1/tasks/\(task)/plan", ["body": text], token: token)
    }
    private func approve(_ e: Env, _ task: String, version: Int = 1, token: String? = nil) async throws -> Reply {
        try await req(e, .POST, "/v1/tasks/\(task)/plan/decision", ["decision": "approve", "version": version], token: token)
    }
    private func putStep(_ e: Env, _ task: String, _ step: String, _ body: [String: Any], token: String? = nil) async throws -> Reply {
        try await req(e, .PUT, "/v1/tasks/\(task)/pipeline/steps/\(step)", body, token: token)
    }
    private func retry(_ e: Env, _ task: String, _ step: String, _ body: [String: Any] = [:], token: String? = nil) async throws -> Reply {
        try await req(e, .POST, "/v1/tasks/\(task)/pipeline/steps/\(step)/retry", body, token: token)
    }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        guard let result = r.body?["result"] as? [String: Any],
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String else { return (true, "no_result \(r.body ?? [:])", nil) }
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    private func expect(_ r: Reply, _ status: HTTPStatus, _ reason: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.status, status, "\(r.body ?? [:])", file: file, line: line)
        if let reason { XCTAssertEqual(r.body?["reason"] as? String, reason, file: file, line: line) }
    }

    private func steps(_ body: [String: Any]?) -> [[String: Any]] { body?["steps"] as? [[String: Any]] ?? [] }
    private func step(_ body: [String: Any]?, _ name: String) -> [String: Any]? { steps(body).first { $0["step"] as? String == name } }
    private func state(_ body: [String: Any]?, _ name: String) -> String? { step(body, name)?["state"] as? String }
    private func events(_ body: [String: Any]?) -> [[String: Any]] { body?["events"] as? [[String: Any]] ?? [] }
    private func actions(_ body: [String: Any]?) -> [String] { events(body).map { $0["action"] as? String ?? "?" } }
    private func plan(_ body: [String: Any]?) -> [String: Any]? { body?["plan"] as? [String: Any] }
    private func fix(_ body: [String: Any]?) -> [String: Int] { (body?["fixRounds"] as? [String: Int]) ?? [:] }
    private func stepSettings(_ body: [String: Any]?) -> [String: Bool] { (body?["steps"] as? [String: Bool]) ?? [:] }
    private func role(_ body: [String: Any]?, _ name: String) -> [String: Any]? { (body?["roles"] as? [String: Any])?[name] as? [String: Any] }

    private func rows(_ e: Env, _ table: String) async throws -> Int {
        let sql = try XCTUnwrap(e.db as? any SQLDatabase)
        let row = try await sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table)").first()
        return try XCTUnwrap(row).decode(column: "c", as: Int.self)
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

    private func activityKinds(_ e: Env, _ task: String) async throws -> [String] {
        try await ActivityEvent.query(on: e.db).filter(\.$taskID == XCTUnwrap(UUID(uuidString: task))).sort(\.$sequence).all().map(\.kind)
    }

    /// An approved plan v1 on a fresh task.
    private func approvedTask(_ e: Env) async throws -> String {
        let task = try await newTask(e)
        expect(try await putPlan(e, task), .ok)
        expect(try await approve(e, task), .ok)
        return task
    }

    // MARK: 1. Settings: reading and rights

    func testSettingsWithoutRowAnswerWithDefaults() async throws {
        try await run { e in
            let r = try await settings(e)
            expect(r, .ok)
            XCTAssertEqual(r.body?["projectID"] as? String, e.pid)
            XCTAssertEqual(r.body?["revision"] as? Int, 0)
            XCTAssertEqual(stepSettings(r.body), ["planner": true, "approval": true, "developer": true, "validation": true, "tester": true, "review": true])
            for name in ["planner", "developer", "tester", "reviewer"] {
                let value = try XCTUnwrap(role(r.body, name), name)
                XCTAssertTrue(value.isEmpty, "model and effort are missing while null: \(value)")
            }
            XCTAssertEqual(r.body?["maxFixRounds"] as? Int, 3)
            XCTAssertEqual(r.body?["notifyOnWaitingApproval"] as? Bool, true)
            XCTAssertNil(r.body?["updatedAt"]); XCTAssertNil(r.body?["updatedByLabel"])
            XCTAssertEqual(r.body?["history"] as? [Any] as? [Int], [])
            let stored = try await rows(e, "project_pipeline_settings")
            XCTAssertEqual(stored, 0, "reading writes nothing")
        }
    }

    func testSettingsRights() async throws {
        try await run { e in
            let stranger = try await person(e, name: "Stranger")
            expect(try await settings(e, token: stranger.token), .notFound)
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 2], token: stranger.token), .notFound)
            expect(try await settings(e, project: UUID().uuidString), .notFound)
            for role in [ProjectRole.read, .comment, .edit] {
                let p = try await person(e, name: "P \(role.rawValue)", role: role)
                expect(try await settings(e, token: p.token), .ok)
                expect(try await patch(e, ["revision": 0, "maxFixRounds": 2], token: p.token), .forbidden)
            }
            for method in [HTTPMethod.GET, .PATCH] {
                let r = try await e.f.test.json(method, "/v1/projects/\(e.pid)/pipeline-settings", method == .PATCH ? ["revision": 0, "maxFixRounds": 1] : nil)
                XCTAssertEqual(r.status, .unauthorized, method.rawValue)
            }
            let manager = try await person(e, name: "Manager Person", role: .manage)
            let ok = try await patch(e, ["revision": 0, "maxFixRounds": 5], token: manager.token)
            expect(ok, .ok)
            XCTAssertEqual(ok.body?["maxFixRounds"] as? Int, 5)
            XCTAssertEqual(ok.body?["updatedByLabel"] as? String, "Manager Person")
            let stored = try await rows(e, "project_pipeline_settings")
            XCTAssertEqual(stored, 1, "only the permitted write was stored")
        }
    }

    // MARK: 1. Settings: partial updates, revision, history

    func testPartialUpdatesRevisionHistoryAndRepetition() async throws {
        try await run { e in
            let first = try await patch(e, ["revision": 0, "steps": ["tester": false],
                                            "roles": ["developer": ["model": "sonnet", "effort": "high"]]])
            expect(first, .ok)
            XCTAssertEqual(first.body?["revision"] as? Int, 1)
            XCTAssertEqual(stepSettings(first.body)["tester"], false)
            XCTAssertEqual(stepSettings(first.body).filter { $0.value }.count, 5)
            XCTAssertEqual(role(first.body, "developer")?["model"] as? String, "sonnet")
            XCTAssertEqual(role(first.body, "developer")?["effort"] as? String, "high")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: first.body?["updatedAt"] as? String ?? ""))
            XCTAssertEqual(first.body?["updatedByLabel"] as? String, "OAuth User")
            let history = first.body?["history"] as? [[String: Any]] ?? []
            XCTAssertEqual(history.count, 1)
            let summary = history.first?["summary"] as? String ?? ""
            XCTAssertTrue(summary.contains("steps.tester") && summary.contains("roles.developer.model") && summary.contains("sonnet"), summary)
            XCTAssertEqual(history.first?["actorType"] as? String, "person")
            XCTAssertEqual(history.first?["actorLabel"] as? String, "OAuth User")
            XCTAssertNotNil(UUID(uuidString: history.first?["id"] as? String ?? ""))

            // Field level merge: null clears one field, the effort stays.
            let second = try await patch(e, ["revision": 1, "roles": ["developer": ["model": NSNull()]], "notifyOnWaitingApproval": false])
            expect(second, .ok)
            XCTAssertEqual(second.body?["revision"] as? Int, 2)
            XCTAssertNil(role(second.body, "developer")?["model"])
            XCTAssertEqual(role(second.body, "developer")?["effort"] as? String, "high")
            XCTAssertEqual(stepSettings(second.body)["tester"], false, "untouched fields stay")
            XCTAssertEqual(second.body?["notifyOnWaitingApproval"] as? Bool, false)
            let history2 = second.body?["history"] as? [[String: Any]] ?? []
            XCTAssertEqual(history2.count, 2)
            XCTAssertEqual(history2.first?["id"] as? String != history.first?["id"] as? String, true, "newest first")

            // Stale revision with a real change: conflict, nothing stored.
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 9]), .conflict, "revision_conflict")
            expect(try await patch(e, ["revision": 5, "maxFixRounds": 9]), .conflict, "revision_conflict")
            let afterConflict = try await settings(e)
            XCTAssertEqual(afterConflict.body?["revision"] as? Int, 2)
            XCTAssertEqual(afterConflict.body?["maxFixRounds"] as? Int, 3)

            // Same content changes neither revision nor history (also for a retry that carries an older revision).
            for revision in [2, 1] {
                let again = try await patch(e, ["revision": revision, "steps": ["tester": false], "roles": ["developer": ["model": NSNull()]]])
                expect(again, .ok)
                XCTAssertEqual(again.body?["revision"] as? Int, 2)
                XCTAssertEqual((again.body?["history"] as? [Any])?.count, 2)
            }
            let events = try await rows(e, "project_pipeline_settings_events")
            XCTAssertEqual(events, 2)
        }
    }

    func testSettingsValidationAndLimits() async throws {
        try await run { e in
            let bad: [([String: Any], String)] = [
                ([:], "invalid_pipeline_settings"),
                (["maxFixRounds": 2], "invalid_pipeline_settings"),
                (["revision": 0], "invalid_pipeline_settings"),
                (["revision": -1, "maxFixRounds": 2], "invalid_pipeline_settings"),
                (["revision": "0", "maxFixRounds": 2], "invalid_pipeline_settings"),
                (["revision": 0, "steps": [:] as [String: Any]], "invalid_pipeline_settings"),
                (["revision": 0, "unknown": 1], "invalid_pipeline_settings"),
                (["revision": 0, "steps": ["deploy": true]], "invalid_pipeline_settings"),
                (["revision": 0, "steps": ["tester": "no"]], "invalid_pipeline_settings"),
                (["revision": 0, "steps": ["tester": NSNull()]], "invalid_pipeline_settings"),
                (["revision": 0, "roles": ["validation": ["model": "x"]]], "invalid_pipeline_settings"),
                (["revision": 0, "roles": ["developer": ["speed": "x"]]], "invalid_pipeline_settings"),
                (["revision": 0, "roles": ["developer": [:] as [String: Any]]], "invalid_pipeline_settings"),
                (["revision": 0, "maxFixRounds": -1], "invalid_pipeline_settings"),
                (["revision": 0, "maxFixRounds": 11], "invalid_pipeline_settings"),
                (["revision": 0, "maxFixRounds": 2.5], "invalid_pipeline_settings"),
                (["revision": 0, "maxFixRounds": "3"], "invalid_pipeline_settings"),
                (["revision": 0, "notifyOnWaitingApproval": "yes"], "invalid_pipeline_settings"),
                (["revision": 0, "roles": ["developer": ["model": "has space"]]], "invalid_model"),
                (["revision": 0, "roles": ["developer": ["model": "a$b"]]], "invalid_model"),
                (["revision": 0, "roles": ["developer": ["model": "  "]]], "invalid_model"),
                (["revision": 0, "roles": ["developer": ["model": String(repeating: "m", count: 101)]]], "invalid_model"),
                (["revision": 0, "roles": ["developer": ["model": 5]]], "invalid_model"),
                (["revision": 0, "roles": ["developer": ["effort": "ultra"]]], "invalid_effort"),
                (["revision": 0, "roles": ["developer": ["effort": "HIGH"]]], "invalid_effort"),
                (["revision": 0, "roles": ["developer": ["effort": 3]]], "invalid_effort"),
            ]
            for (body, reason) in bad { expect(try await patch(e, body), .badRequest, reason) }
            let none = try await rows(e, "project_pipeline_settings")
            XCTAssertEqual(none, 0, "refused bodies store nothing")
            let events = try await rows(e, "project_pipeline_settings_events")
            XCTAssertEqual(events, 0)

            // Boundaries that are fine: 0 and 10, model of 100 characters, all efforts, a trimmed model.
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 0]), .ok)
            expect(try await patch(e, ["revision": 1, "maxFixRounds": 10]), .ok)
            var revision = 2
            for effort in ["low", "medium", "high", "xhigh", "max"] {
                let r = try await patch(e, ["revision": revision, "roles": ["reviewer": ["effort": effort]]])
                expect(r, .ok)
                XCTAssertEqual(role(r.body, "reviewer")?["effort"] as? String, effort)
                revision += 1
            }
            let long = String(repeating: "m", count: 100)
            let r = try await patch(e, ["revision": revision, "roles": ["planner": ["model": "  gpt-6.1-sol  "], "tester": ["model": long]]])
            expect(r, .ok)
            XCTAssertEqual(role(r.body, "planner")?["model"] as? String, "gpt-6.1-sol")
            XCTAssertEqual(role(r.body, "tester")?["model"] as? String, long)
            for ok in ["sonnet", "claude-sonnet-4.5", "a/b:c_d"] {
                let x = try await patch(e, ["revision": revision + 1, "roles": ["planner": ["model": ok]]])
                expect(x, .ok)
                revision += 1
            }
        }
    }

    func testDeletingTheProjectRemovesSettingsAndHistory() async throws {
        try await run { e in
            let other = e.f.other.id!.uuidString
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 1], project: other), .ok)
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 2]), .ok)
            try await e.f.other.delete(on: e.db)
            let settingsLeft = try await rows(e, "project_pipeline_settings")
            let eventsLeft = try await rows(e, "project_pipeline_settings_events")
            XCTAssertEqual(settingsLeft, 1)
            XCTAssertEqual(eventsLeft, 1)
        }
    }

    // MARK: 1. Settings over MCP

    func testMCPSettingsReadAndBrainMandate() async throws {
        try await run { e in
            let list = try await e.f.rpc("tools/list", access: e.agent)
            let tools = (list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            for name in ["get_pipeline_settings", "update_pipeline_settings", "retry_pipeline_step"] {
                XCTAssertTrue(tools.contains { $0["name"] as? String == name }, name)
            }
            let read = try await call(e, e.agent, "get_pipeline_settings", ["projectID": e.pid])
            XCTAssertFalse(read.isError, read.text)
            XCTAssertEqual(read.json?["revision"] as? Int, 0)
            XCTAssertEqual(read.json?["maxFixRounds"] as? Int, 3)
            let readOnly = try await call(e, e.readOnly, "get_pipeline_settings", ["projectID": e.pid])
            XCTAssertFalse(readOnly.isError, readOnly.text)
            let outside = try await call(e, e.agent, "get_pipeline_settings", ["projectID": e.f.other.id!.uuidString])
            XCTAssertEqual(outside.text, "not_found")
            let unknownProject = try await call(e, e.agent, "get_pipeline_settings", ["projectID": UUID().uuidString])
            XCTAssertEqual(unknownProject.text, "not_found")
            let extra = try await call(e, e.agent, "get_pipeline_settings", ["projectID": e.pid, "x": 1])
            XCTAssertEqual(extra.text, "invalid_arguments")

            var args: [String: Any] = ["projectID": e.pid, "revision": 0, "roles": ["developer": ["model": "haiku"]], "quote": "ja, haiku"]
            let scope = try await call(e, e.readOnly, "update_pipeline_settings", args)
            XCTAssertEqual(scope.text, "insufficient_scope")
            // No mandate, even for the person's own connection.
            let none = try await call(e, e.brain, "update_pipeline_settings", args)
            XCTAssertEqual(none.text, "brain_mandate_required")
            let noneAgent = try await call(e, e.agent, "update_pipeline_settings", args)
            XCTAssertEqual(noneAgent.text, "brain_mandate_required")
            try await mandate(e, projects: [e.f.other.id!.uuidString])
            let outsideMandate = try await call(e, e.brain, "update_pipeline_settings", args)
            XCTAssertEqual(outsideMandate.text, "outside_brain_mandate")
            try await mandate(e)
            var noQuote = args; noQuote["quote"] = nil
            let missing = try await call(e, e.brain, "update_pipeline_settings", noQuote)
            XCTAssertEqual(missing.text, "quote_required")
            var longQuote = args; longQuote["quote"] = String(repeating: "q", count: 2001)
            let tooLong = try await call(e, e.brain, "update_pipeline_settings", longQuote)
            XCTAssertEqual(tooLong.text, "invalid_quote")
            let agentStill = try await call(e, e.agent, "update_pipeline_settings", args)
            XCTAssertEqual(agentStill.text, "brain_mandate_required", "a mandate of another connection does not help")
            let stored = try await rows(e, "project_pipeline_settings")
            XCTAssertEqual(stored, 0)
            let audits0 = try await BrainConnectionAudit.query(on: e.db).count()
            XCTAssertEqual(audits0, 0)

            var badModel = args; badModel["roles"] = ["developer": ["model": "no good"]]
            let invalid = try await call(e, e.brain, "update_pipeline_settings", badModel)
            XCTAssertEqual(invalid.text, "invalid_model")
            var noSetting = args; noSetting["roles"] = nil
            let empty = try await call(e, e.brain, "update_pipeline_settings", noSetting)
            XCTAssertEqual(empty.text, "invalid_pipeline_settings")

            let ok = try await call(e, e.brain, "update_pipeline_settings", args)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(ok.json?["revision"] as? Int, 1)
            XCTAssertEqual(role(ok.json, "developer")?["model"] as? String, "haiku")
            let history = ok.json?["history"] as? [[String: Any]] ?? []
            XCTAssertEqual(history.first?["actorType"] as? String, "integration")
            XCTAssertEqual(history.first?["actorLabel"] as? String, "Test Client")
            // The decision is part of the mandate log (kind pipeline.settings).
            let audit = try await req(e, .GET, "/v1/settings/brain-mandate/audit")
            let items = audit.body?["items"] as? [[String: Any]] ?? []
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["kind"] as? String, "pipeline.settings")
            XCTAssertEqual(items.first?["quote"] as? String, "ja, haiku")
            XCTAssertEqual(items.first?["projectID"] as? String, e.pid)
            XCTAssertNil(items.first?["taskID"])
            // Stale revision, then a repetition (no second log entry, no revision change).
            args["roles"] = ["developer": ["model": "opus"]]
            let stale = try await call(e, e.brain, "update_pipeline_settings", args)
            XCTAssertEqual(stale.text, "revision_conflict")
            args["roles"] = ["developer": ["model": "haiku"]]
            let same = try await call(e, e.brain, "update_pipeline_settings", args)
            XCTAssertFalse(same.isError, same.text)
            XCTAssertEqual(same.json?["revision"] as? Int, 1)
            let audits = try await BrainConnectionAudit.query(on: e.db).count()
            XCTAssertEqual(audits, 1)
            // Revoking the mandate takes effect with the next call.
            _ = try await req(e, .DELETE, "/v1/settings/brain-mandate/\(e.brainGrant.uuidString)")
            args["revision"] = 1; args["maxFixRounds"] = 7
            let revoked = try await call(e, e.brain, "update_pipeline_settings", args)
            XCTAssertEqual(revoked.text, "brain_mandate_required")
        }
    }

    // MARK: 2. Wider pipeline answer and switched off steps

    func testPipelineAnswerGetsSettingsAndPerStepFieldsAdditively() async throws {
        try await run { e in
            let task = try await newTask(e)
            let fresh = try await pipeline(e, task)
            expect(fresh, .ok)
            let s = try XCTUnwrap(fresh.body?["settings"] as? [String: Any])
            XCTAssertEqual(s["revision"] as? Int, 0)
            XCTAssertEqual(s["maxFixRounds"] as? Int, 3)
            XCTAssertEqual(s["notifyOnWaitingApproval"] as? Bool, true)
            XCTAssertNil(s["history"]); XCTAssertNil(s["projectID"]); XCTAssertNil(s["updatedAt"])
            XCTAssertEqual(stepSettings(s).count, 6)
            XCTAssertEqual(steps(fresh.body).map { $0["step"] as? String ?? "?" }, ["planner", "approval", "developer", "validation", "tester", "review"])
            XCTAssertTrue(steps(fresh.body).allSatisfy { $0["enabled"] as? Bool == true && $0["state"] as? String == "pending" && $0["planVersion"] == nil })
            for (name, hasRole) in [("planner", true), ("approval", false), ("developer", true), ("validation", false), ("tester", true), ("review", true)] {
                XCTAssertEqual(step(fresh.body, name)?["role"] != nil, hasRole, name)
            }
            XCTAssertEqual(fix(fresh.body), ["used": 0, "max": 3, "remaining": 3])
            XCTAssertEqual(fresh.body?["waitingApproval"] as? Bool, false)
            XCTAssertNil(fresh.body?["plan"] as? [String: Any])

            expect(try await patch(e, ["revision": 0, "roles": ["reviewer": ["model": "sonnet", "effort": "low"]], "maxFixRounds": 5]), .ok)
            expect(try await putPlan(e, task), .ok)
            let written = try await pipeline(e, task)
            XCTAssertEqual(written.body?["waitingApproval"] as? Bool, true)
            XCTAssertEqual(step(written.body, "planner")?["planVersion"] as? Int, 1)
            XCTAssertEqual(step(written.body, "approval")?["planVersion"] as? Int, 1)
            XCTAssertNil(step(written.body, "developer")?["planVersion"])
            XCTAssertEqual((step(written.body, "review")?["role"] as? [String: Any])?["model"] as? String, "sonnet")
            XCTAssertEqual((step(written.body, "review")?["role"] as? [String: Any])?["effort"] as? String, "low")
            XCTAssertEqual(((written.body?["settings"] as? [String: Any])?["revision"]) as? Int, 1)
            XCTAssertEqual(fix(written.body), ["used": 0, "max": 5, "remaining": 5])
            expect(try await approve(e, task), .ok)
            let decided = try await pipeline(e, task)
            XCTAssertEqual(decided.body?["waitingApproval"] as? Bool, false)
            XCTAssertEqual(step(decided.body, "approval")?["planVersion"] as? Int, 1)
            // The same answer comes from MCP.
            let viaMCP = try await call(e, e.agent, "get_task_pipeline", ["taskID": task])
            XCTAssertNotNil(viaMCP.json?["settings"]); XCTAssertNotNil(viaMCP.json?["fixRounds"])
            XCTAssertEqual(steps(viaMCP.json).count, 6)
        }
    }

    func testStepRowsWithoutPlanVersionStayValid() async throws {
        try await run { e in
            let task = try await newTask(e)
            let row = TaskPipelineStep()
            row.taskID = try XCTUnwrap(UUID(uuidString: task)); row.step = "planner"; row.state = "running"
            row.actorType = .integration; row.actorID = UUID(); row.actorLabel = "old"; row.updatedAt = Date()
            try await row.save(on: e.db)
            let r = try await pipeline(e, task)
            expect(r, .ok)
            XCTAssertEqual(state(r.body, "planner"), "running")
            XCTAssertNil(step(r.body, "planner")?["planVersion"], "rows from stage 1 carry no version")
            XCTAssertEqual(step(r.body, "planner")?["enabled"] as? Bool, true)
        }
    }

    func testPlannerOffSkipsPlannerApprovalAndTheGate() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await patch(e, ["revision": 0, "steps": ["planner": false]]), .ok)
            let r = try await pipeline(e, task)
            for name in ["planner", "approval"] {
                XCTAssertEqual(step(r.body, name)?["enabled"] as? Bool, false, name)
                XCTAssertEqual(state(r.body, name), "skipped", name)
            }
            for name in ["developer", "validation", "tester", "review"] {
                XCTAssertEqual(step(r.body, name)?["enabled"] as? Bool, true, name)
                XCTAssertEqual(state(r.body, name), "pending", name)
            }
            XCTAssertEqual(r.body?["waitingApproval"] as? Bool, false)
            // No plan needed for the work steps.
            let running = try await putStep(e, task, "developer", ["state": "running"])
            expect(running, .ok)
            XCTAssertEqual(state(running.body, "developer"), "running")
            // A plan written anyway is approved normally.
            let written = try await putPlan(e, task)
            expect(written, .ok)
            XCTAssertEqual(plan(written.body)?["state"] as? String, "proposed")
            expect(try await approve(e, task), .ok)
            let hoisted1 = try await pipeline(e, task)
            XCTAssertEqual(plan(hoisted1.body)?["state"] as? String, "approved")
        }
    }

    func testApprovalOffApprovesTheWrittenPlanAtOnce() async throws {
        try await run { e in
            expect(try await patch(e, ["revision": 0, "steps": ["approval": false]]), .ok)
            let task = try await newTask(e)
            let r = try await putPlan(e, task, "# Plan\nrest")
            expect(r, .ok)
            let p = try XCTUnwrap(plan(r.body))
            XCTAssertEqual(p["state"] as? String, "approved")
            XCTAssertEqual(p["decidedByType"] as? String, "system")
            XCTAssertNil(p["decidedByLabel"])
            XCTAssertNotNil(p["decidedAt"])
            XCTAssertEqual(state(r.body, "planner"), "done")
            XCTAssertEqual(state(r.body, "approval"), "skipped")
            XCTAssertEqual(step(r.body, "approval")?["enabled"] as? Bool, false)
            XCTAssertEqual(r.body?["waitingApproval"] as? Bool, false)
            expect(try await putStep(e, task, "developer", ["state": "running"]), .ok)
            expect(try await approve(e, task), .conflict, "plan_not_pending")
            // A person's approval of an earlier, normal plan is unaffected by switching it back on.
            expect(try await patch(e, ["revision": 1, "steps": ["approval": true]]), .ok)
            let second = try await putPlan(e, task, "Other")
            XCTAssertEqual(plan(second.body)?["state"] as? String, "proposed")
            XCTAssertEqual(second.body?["waitingApproval"] as? Bool, true)
        }
    }

    /// A plan that was still waiting when the approval step was switched off must not stay stuck: writing it again approves it.
    func testSwitchingApprovalOffDoesNotLeaveAWaitingPlanStuck() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putPlan(e, task, "Same"), .ok)
            expect(try await patch(e, ["revision": 0, "steps": ["approval": false]]), .ok)
            let again = try await putPlan(e, task, "Same")
            expect(again, .ok)
            XCTAssertEqual(plan(again.body)?["state"] as? String, "approved")
            XCTAssertEqual(plan(again.body)?["decidedByType"] as? String, "system")
            XCTAssertEqual(plan(again.body)?["version"] as? Int, 2)
            // Repeating it once more changes nothing.
            let third = try await putPlan(e, task, "Same")
            XCTAssertEqual(plan(third.body)?["version"] as? Int, 2)
        }
    }

    func testWorkStepsOffAreSkippedRefusedAndKeepStoredState() async throws {
        try await run { e in
            let task = try await approvedTask(e)
            expect(try await putStep(e, task, "tester", ["state": "done"]), .ok)
            expect(try await patch(e, ["revision": 0, "steps": ["tester": false, "validation": false, "review": false]]), .ok)
            let r = try await pipeline(e, task)
            XCTAssertEqual(state(r.body, "tester"), "done", "the stored state stays")
            XCTAssertEqual(step(r.body, "tester")?["enabled"] as? Bool, false)
            for name in ["validation", "review"] {
                XCTAssertEqual(state(r.body, name), "skipped", name)
                XCTAssertEqual(step(r.body, name)?["enabled"] as? Bool, false, name)
            }
            XCTAssertEqual(step(r.body, "developer")?["enabled"] as? Bool, true)
            let before = events(r.body).count
            for name in ["tester", "validation", "review"] {
                for state in ["running", "pending", "done"] {
                    expect(try await putStep(e, task, name, ["state": state]), .conflict, "step_disabled")
                }
                expect(try await retry(e, task, name), .conflict, "step_disabled")
            }
            let after = try await pipeline(e, task)
            XCTAssertEqual(events(after.body).count, before, "nothing was written")
            expect(try await putStep(e, task, "developer", ["state": "running"]), .ok)
            // Switching it on again shows the stored state.
            expect(try await patch(e, ["revision": 1, "steps": ["tester": true]]), .ok)
            let hoisted2 = try await pipeline(e, task)
            XCTAssertEqual(step(hoisted2.body, "tester")?["enabled"] as? Bool, true)
        }
    }

    // MARK: 4. Plan version on steps

    func testSetStepBoundToThePlanVersion() async throws {
        try await run { e in
            let task = try await newTask(e)
            expect(try await putStep(e, task, "planner", ["state": "running", "planVersion": 1]), .conflict, "plan_changed")
            expect(try await putPlan(e, task), .ok)
            expect(try await approve(e, task), .ok)
            for bad in [0, -1] {
                expect(try await putStep(e, task, "developer", ["state": "running", "planVersion": bad]), .badRequest, "invalid_plan_version")
            }
            expect(try await putStep(e, task, "developer", ["state": "running", "planVersion": 2]), .conflict, "plan_changed")
            let count = events(try await pipeline(e, task).body).count
            let ok = try await putStep(e, task, "developer", ["state": "running", "planVersion": 1])
            expect(ok, .ok)
            XCTAssertEqual(step(ok.body, "developer")?["planVersion"] as? Int, 1)
            XCTAssertEqual(events(ok.body).count, count + 1)
            // Old callers: no planVersion, the current one is stored.
            let old = try await putStep(e, task, "validation", ["state": "running"])
            expect(old, .ok)
            XCTAssertEqual(step(old.body, "validation")?["planVersion"] as? Int, 1)
            // A new plan: an agent still working on version 1 cannot touch the new steps.
            expect(try await putPlan(e, task, "Second plan"), .ok)
            expect(try await approve(e, task, version: 2), .ok)
            let written = events(try await pipeline(e, task).body).count
            expect(try await putStep(e, task, "developer", ["state": "done", "planVersion": 1]), .conflict, "plan_changed")
            let hoisted3 = try await pipeline(e, task)
            XCTAssertEqual(events(hoisted3.body).count, written)
            let hoisted4 = try await pipeline(e, task)
            XCTAssertEqual(state(hoisted4.body, "developer"), "pending")
            let viaMCP = try await call(e, e.agent, "set_pipeline_step", ["taskID": task, "step": "developer", "state": "running", "planVersion": 2])
            XCTAssertFalse(viaMCP.isError, viaMCP.text)
            XCTAssertEqual(step(viaMCP.json, "developer")?["planVersion"] as? Int, 2)
            let stale = try await call(e, e.agent, "set_pipeline_step", ["taskID": task, "step": "developer", "state": "done", "planVersion": 1])
            XCTAssertEqual(stale.text, "plan_changed")
            let fraction = try await call(e, e.agent, "set_pipeline_step", ["taskID": task, "step": "developer", "state": "done", "planVersion": 1.5])
            XCTAssertEqual(fraction.text, "invalid_planVersion")
        }
    }

    // MARK: 3. Retry

    func testRetryOnlyForAFailedStepAndCountsFixRounds() async throws {
        try await run { e in
            let task = try await approvedTask(e)
            expect(try await putStep(e, task, "developer", ["state": "done"]), .ok)
            expect(try await putStep(e, task, "tester", ["state": "failed", "note": "Test rot"]), .ok)
            expect(try await putStep(e, task, "review", ["state": "running"]), .ok)
            expect(try await retry(e, task, "developer"), .conflict, "step_not_failed")
            expect(try await retry(e, task, "validation"), .conflict, "step_not_failed")
            expect(try await retry(e, task, "approval"), .conflict, "step_managed")
            expect(try await retry(e, task, "deploy"), .badRequest, "invalid_step")
            expect(try await retry(e, task, "tester", ["planVersion": 2]), .conflict, "plan_changed")
            expect(try await retry(e, task, "tester", ["planVersion": 0]), .badRequest, "invalid_plan_version")
            expect(try await retry(e, task, "tester", ["note": String(repeating: "n", count: 2001)]), .badRequest, "invalid_note")
            let before = try await pipeline(e, task)
            XCTAssertEqual(fix(before.body)["used"], 0)

            let r = try await retry(e, task, "tester", ["planVersion": 1, "note": "Neuer Versuch mit password=hunter2secret", "agentName": "runner@mac"])
            expect(r, .ok)
            XCTAssertEqual(state(r.body, "tester"), "pending")
            XCTAssertEqual(step(r.body, "tester")?["note"] as? String, "Neuer Versuch mit password=[gefiltert]")
            XCTAssertEqual(step(r.body, "tester")?["actorLabel"] as? String, "runner@mac")
            XCTAssertEqual(step(r.body, "tester")?["planVersion"] as? Int, 1)
            XCTAssertEqual(state(r.body, "developer"), "done", "other steps stay")
            XCTAssertEqual(state(r.body, "review"), "running")
            XCTAssertEqual(state(r.body, "approval"), "done")
            let event = try XCTUnwrap(events(r.body).first)
            XCTAssertEqual(event["action"] as? String, "step_retried")
            XCTAssertEqual(event["step"] as? String, "tester")
            XCTAssertEqual(event["planVersion"] as? Int, 1)
            XCTAssertEqual(fix(r.body), ["used": 1, "max": 3, "remaining": 2])
            let kinds = try await activityKinds(e, task)
            XCTAssertEqual(kinds.filter { $0 == "pipeline.step" }.count, 4)
            // The step is pending now: nothing to retry, no second round counted.
            expect(try await retry(e, task, "tester"), .conflict, "step_not_failed")
            let hoisted5 = try await pipeline(e, task)
            XCTAssertEqual(fix(hoisted5.body)["used"], 1)

            // The note is cleared when the retry carries none.
            expect(try await putStep(e, task, "tester", ["state": "failed", "note": "wieder rot"]), .ok)
            let cleared = try await retry(e, task, "tester")
            XCTAssertNil(step(cleared.body, "tester")?["note"])
            XCTAssertEqual(fix(cleared.body), ["used": 2, "max": 3, "remaining": 1])
            // A direct `pending` through set_pipeline_step is allowed but is not a round.
            expect(try await putStep(e, task, "tester", ["state": "failed"]), .ok)
            expect(try await putStep(e, task, "tester", ["state": "pending"]), .ok)
            let hoisted6 = try await pipeline(e, task)
            XCTAssertEqual(fix(hoisted6.body)["used"], 2)

            expect(try await putStep(e, task, "tester", ["state": "failed"]), .ok)
            expect(try await retry(e, task, "tester"), .ok)
            let hoisted7 = try await pipeline(e, task)
            XCTAssertEqual(fix(hoisted7.body), ["used": 3, "max": 3, "remaining": 0])
            expect(try await putStep(e, task, "tester", ["state": "failed"]), .ok)
            let exhausted = try await retry(e, task, "tester")
            expect(exhausted, .conflict, "fix_rounds_exhausted")
            let hoisted8 = try await pipeline(e, task)
            XCTAssertEqual(state(hoisted8.body, "tester"), "failed", "nothing changed")
            let hoisted9 = try await pipeline(e, task)
            XCTAssertEqual(actions(hoisted9.body).filter { $0 == "step_retried" }.count, 3)

            // A new plan version starts again at 0; raising the maximum allows more rounds.
            expect(try await putPlan(e, task, "Version two"), .ok)
            expect(try await approve(e, task, version: 2), .ok)
            let fresh = try await pipeline(e, task)
            XCTAssertEqual(fix(fresh.body), ["used": 0, "max": 3, "remaining": 3])
            expect(try await putStep(e, task, "validation", ["state": "failed", "planVersion": 2]), .ok)
            expect(try await retry(e, task, "validation", ["planVersion": 1]), .conflict, "plan_changed")
            expect(try await retry(e, task, "validation", ["planVersion": 2]), .ok)
            let hoisted10 = try await pipeline(e, task)
            XCTAssertEqual(fix(hoisted10.body)["used"], 1)
        }
    }

    func testRetryBoundariesOfTheMaximum() async throws {
        try await run { e in
            let task = try await approvedTask(e)
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 0]), .ok)
            expect(try await putStep(e, task, "developer", ["state": "failed"]), .ok)
            expect(try await retry(e, task, "developer"), .conflict, "fix_rounds_exhausted")
            let hoisted11 = try await pipeline(e, task)
            XCTAssertEqual(fix(hoisted11.body), ["used": 0, "max": 0, "remaining": 0])
            expect(try await patch(e, ["revision": 1, "maxFixRounds": 10]), .ok)
            for round in 1...10 {
                expect(try await retry(e, task, "developer"), .ok)
                let hoisted12 = try await pipeline(e, task)
                XCTAssertEqual(fix(hoisted12.body)["used"], round)
                expect(try await putStep(e, task, "developer", ["state": "failed"]), .ok)
            }
            expect(try await retry(e, task, "developer"), .conflict, "fix_rounds_exhausted")
            // Lowering the maximum below the rounds used never shows a negative rest.
            expect(try await patch(e, ["revision": 2, "maxFixRounds": 2]), .ok)
            let hoisted13 = try await pipeline(e, task)
            XCTAssertEqual(fix(hoisted13.body), ["used": 10, "max": 2, "remaining": 0])
        }
    }

    func testRetryNeedsAnApprovedPlanUnlessThePlannerIsOffAndPlannerCanBeRetried() async throws {
        try await run { e in
            let task = try await newTask(e)
            // The planner itself needs no plan; the work steps do.
            expect(try await putStep(e, task, "planner", ["state": "failed"]), .ok)
            expect(try await retry(e, task, "developer"), .conflict, "step_not_failed")
            let planner = try await retry(e, task, "planner")
            expect(planner, .ok)
            XCTAssertEqual(state(planner.body, "planner"), "pending")
            // Work step failed under an approved plan, then a new proposal blocks retrying.
            expect(try await putPlan(e, task), .ok)
            expect(try await approve(e, task), .ok)
            expect(try await putStep(e, task, "developer", ["state": "failed"]), .ok)
            expect(try await putPlan(e, task, "Changed"), .ok)
            expect(try await retry(e, task, "developer"), .conflict, "step_not_failed")
            // Without any plan (planner off) the gate does not apply.
            let other = try await newTask(e)
            expect(try await patch(e, ["revision": 0, "steps": ["planner": false]]), .ok)
            expect(try await putStep(e, other, "review", ["state": "failed"]), .ok)
            expect(try await retry(e, other, "review"), .ok)
        }
    }

    func testRetryRightsAndMCP() async throws {
        try await run { e in
            let task = try await approvedTask(e)
            expect(try await putStep(e, task, "developer", ["state": "failed"]), .ok)
            let stranger = try await person(e, name: "Stranger")
            expect(try await retry(e, task, "developer", token: stranger.token), .notFound)
            for role in [ProjectRole.read, .comment] {
                let p = try await person(e, name: "R \(role.rawValue)", role: role)
                expect(try await retry(e, task, "developer", token: p.token), .forbidden)
            }
            let anonymous = try await e.f.test.json(.POST, "/v1/tasks/\(task)/pipeline/steps/developer/retry", [:])
            XCTAssertEqual(anonymous.status, .unauthorized)
            let hoisted14 = try await pipeline(e, task)
            XCTAssertEqual(state(hoisted14.body, "developer"), "failed", "refused calls changed nothing")
            // MCP: scope, project list, then the round trip with an integration actor and no mandate.
            let ro = try await call(e, e.readOnly, "retry_pipeline_step", ["taskID": task, "step": "developer"])
            XCTAssertEqual(ro.text, "insufficient_scope")
            let outside = try await newTask(e, project: e.f.other)
            let denied = try await call(e, e.agent, "retry_pipeline_step", ["taskID": outside, "step": "developer"])
            XCTAssertEqual(denied.text, "not_found")
            let unknown = try await call(e, e.agent, "retry_pipeline_step", ["taskID": task, "step": "developer", "state": "pending"])
            XCTAssertEqual(unknown.text, "invalid_arguments")
            let ok = try await call(e, e.agent, "retry_pipeline_step",
                ["taskID": task, "step": "developer", "planVersion": 1, "note": "weiter", "agentName": "runner@mac"])
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(state(ok.json, "developer"), "pending")
            XCTAssertEqual(events(ok.json).first?["action"] as? String, "step_retried")
            XCTAssertEqual(events(ok.json).first?["actorType"] as? String, "integration")
            let again = try await call(e, e.agent, "retry_pipeline_step", ["taskID": task, "step": "developer"])
            XCTAssertEqual(again.text, "step_not_failed")
            let editor = try await person(e, name: "Editor", role: .edit)
            expect(try await putStep(e, task, "developer", ["state": "failed"], token: editor.token), .ok)
            expect(try await retry(e, task, "developer", token: editor.token), .ok)
        }
    }

    // MARK: Migrations

    func testMigrationsAreAdditiveAndRepeatable() async throws {
        try await run { e in
            let sql = try XCTUnwrap(e.db as? any SQLDatabase)
            for table in ["project_pipeline_settings", "project_pipeline_settings_events"] {
                let count = try await rows(e, table)
                XCTAssertEqual(count, 0, table)
            }
            if sql.dialect.name == "sqlite" {
                let columns = try await sql.raw("SELECT name FROM pragma_table_info('task_pipeline_steps')").all().map { try $0.decode(column: "name", as: String.self) }
                XCTAssertTrue(columns.contains("plan_version"))
            } else {
                let columns = try await sql.raw("SELECT column_name AS name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'task_pipeline_steps'")
                    .all().map { try $0.decode(column: "name", as: String.self) }
                XCTAssertTrue(columns.contains("plan_version"))
            }
            // Reverting and applying the settings migration again works on an empty database.
            try await CreateProjectPipelineSettings().revert(on: e.db)
            try await CreateProjectPipelineSettings().prepare(on: e.db)
            expect(try await patch(e, ["revision": 0, "maxFixRounds": 4]), .ok)
            let stored = try await rows(e, "project_pipeline_settings")
            XCTAssertEqual(stored, 1)
        }
    }

    // MARK: Contract and manual

    func testContractsAndManualDescribeStageTwo() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent("contracts/\(name)"), encoding: .utf8)) ?? "" }
        let pipeline = read("pipeline.yaml")
        XCTAssertTrue(pipeline.contains("version: 1.2.0"))
        for path in ["/v1/projects/{projectID}/pipeline-settings:", "/v1/tasks/{taskID}/pipeline/steps/{step}/retry:"] {
            XCTAssertTrue(pipeline.contains("  \(path)"), path)
        }
        for word in ["invalid_pipeline_settings", "invalid_model", "invalid_effort", "revision_conflict", "step_disabled", "step_not_failed",
                     "fix_rounds_exhausted", "plan_changed", "invalid_plan_version", "step_retried", "fixRounds", "waitingApproval", "planVersion",
                     "get_pipeline_settings", "update_pipeline_settings", "retry_pipeline_step", "pipeline.settings", "maxFixRounds"] {
            XCTAssertTrue(pipeline.contains(word), word)
        }
        XCTAssertTrue(read("oauth-mcp.yaml").contains("version: 1.12.0"))
        XCTAssertTrue(read("oauth-mcp.yaml").contains("retry_pipeline_step"))
        XCTAssertTrue(read("feed.yaml").contains("plan.written") && read("feed.yaml").contains("kind=question|review|plan"))
        XCTAssertTrue(read("command-center.yaml").contains("planWaiting") && read("command-center.yaml").contains("plansWaiting"))
        XCTAssertTrue(read("connections.yaml").contains("pipeline.settings"))
        XCTAssertEqual(AgentManual.version, "1.48.0")
        for tool in ["get_pipeline_settings", "update_pipeline_settings", "retry_pipeline_step"] {
            XCTAssertTrue(AgentManual.markdown.contains("`\(tool)`"), tool)
        }
        let parity = (try? String(contentsOf: root.appendingPathComponent("docs/MCP-PARITAET.md"), encoding: .utf8)) ?? ""
        for tool in ["get_pipeline_settings", "update_pipeline_settings", "retry_pipeline_step"] {
            XCTAssertTrue(parity.contains(tool), tool)
        }
        let app = try await Application.make(.testing)
        do { try routes(app) } catch { try? await app.asyncShutdown(); throw error }
        let registered = Set(app.routes.all.map { r in r.method.rawValue + " /" + r.path.map(\.description).joined(separator: "/") })
        try await app.asyncShutdown()
        XCTAssertTrue(registered.contains("GET /v1/projects/:id/pipeline-settings"))
        XCTAssertTrue(registered.contains("PATCH /v1/projects/:id/pipeline-settings"))
        XCTAssertTrue(registered.contains("POST /v1/tasks/:id/pipeline/steps/:step/retry"))
    }
}
