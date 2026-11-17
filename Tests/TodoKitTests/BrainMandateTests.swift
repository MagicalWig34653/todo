import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0032: only a connection with an active brain mandate may decide reviews and answer questions as an agent.
final class BrainMandateTests: XCTestCase {
    struct Env {
        let f: OAuthFixture
        let agent: String, brain: String
        let agentGrant: UUID, brainGrant: UUID
        var pid: String { f.project.id!.uuidString }
    }

    private func env() async throws -> Env {
        let f = try await OAuthFixture.make()
        let a = try await f.tokens(scope: CommandCenterTests.scopes)
        let gA = try XCTUnwrap(try await OAuthGrant.query(on: f.test.app.db).first()?.id)
        let b = try await f.tokens(scope: CommandCenterTests.scopes)
        let gB = try XCTUnwrap(try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gA).first()?.id)
        return Env(f: f, agent: a.access, brain: b.access, agentGrant: gA, brainGrant: gB)
    }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    @discardableResult
    private func mandate(_ e: Env, grant: UUID? = nil, projects: [String]? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
            ["grantID": (grant ?? e.brainGrant).uuidString, "projectIDs": projects ?? [e.pid]], token: e.f.session)
        return (r.status, r.body)
    }

    private func newTask(_ e: Env, project: Project? = nil, _ title: String = "Task") async throws -> String {
        let t = TodoTask(ownerID: try e.f.user.requireID(), projectID: try (project ?? e.f.project).requireID(), title: title, details: "")
        try await t.save(on: e.f.test.app.db)
        return try t.requireID().uuidString
    }

    /// Task with a pending review requested by `token`'s connection.
    private func review(_ e: Env, by token: String? = nil, project: Project? = nil) async throws -> String {
        let task = try await newTask(e, project: project)
        let r = try await call(e, token ?? e.agent, "request_review", ["taskID": task, "summary": "Done"])
        XCTAssertFalse(r.isError, r.text)
        return task
    }

    private func question(_ e: Env, by token: String? = nil) async throws -> (task: String, id: String) {
        let task = try await newTask(e)
        let r = try await call(e, token ?? e.agent, "ask_question", ["taskID": task, "prompt": "A or B?", "options": ["A", "B"]])
        XCTAssertFalse(r.isError, r.text)
        return (task, try XCTUnwrap(r.json?["id"] as? String))
    }

    private func taskStatus(_ e: Env, _ id: String) async throws -> String? {
        try await TodoTask.find(UUID(uuidString: id), on: e.f.test.app.db)?.status
    }

    private func audit(_ e: Env) async throws -> [[String: Any]] {
        let r = try await e.f.test.json(.GET, "/v1/settings/brain-mandate/audit", token: e.f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.body?["items"] as? [[String: Any]] ?? []
    }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let e = try await env()
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    // MARK: Reviews

    func testMandatedBrainAcceptsReviewOfAnotherConnectionWithAuditAndChatComment() async throws {
        try await run { e in
            let put = try await mandate(e)
            XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
            let task = try await review(e)
            let r = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "Lino: ja, nimm an"])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(r.json?["state"] as? String, "accepted")
            try await assertEqual(try await taskStatus(e, task), "done")
            let rows = try await audit(e)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["kind"] as? String, "review.accepted")
            XCTAssertEqual(rows.first?["quote"] as? String, "Lino: ja, nimm an")
            XCTAssertEqual(rows.first?["taskID"] as? String, task)
            let comments = try await TaskComment.query(on: e.f.test.app.db).filter(\.$taskID == UUID(uuidString: task)!).all()
            let c = try XCTUnwrap(comments.first { $0.authorLabel == "Brain im Auftrag von OAuth User" })
            XCTAssertEqual(c.authorKind, "agent")
            XCTAssertNotNil(c.reviewID)
            XCTAssertTrue(c.body.contains("Lino: ja, nimm an"), c.body)
        }
    }

    func testMandatedBrainCanRequestChanges() async throws {
        try await run { e in
            try await mandate(e)
            let task = try await review(e)
            let r = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "request_changes", "note": "Test fehlt", "quote": "Lino: nacharbeiten"])
            XCTAssertFalse(r.isError, r.text)
            try await assertEqual(try await taskStatus(e, task), "in_progress")
            XCTAssertEqual(try await audit(e).first?["kind"] as? String, "review.changes_requested")
        }
    }

    func testDecideReviewNeedsAQuote() async throws {
        try await run { e in
            try await mandate(e)
            let task = try await review(e)
            for args in [[:], ["quote": "   "]] as [[String: Any]] {
                var a: [String: Any] = ["taskID": task, "decision": "accept"]; a.merge(args) { $1 }
                let r = try await call(e, e.brain, "decide_review", a)
                XCTAssertEqual(r.text, "quote_required")
            }
            let long = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": String(repeating: "x", count: 2001)])
            XCTAssertEqual(long.text, "invalid_quote")
            try await assertEqual(try await taskStatus(e, task), "in_review")
            XCTAssertEqual(try await audit(e).count, 0)
        }
    }

    func testBrainCannotDecideItsOwnReviewEvenWithMandate() async throws {
        try await run { e in
            try await mandate(e)
            let task = try await review(e, by: e.brain)
            let r = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja"])
            XCTAssertEqual(r.text, "cannot_decide_own_review")
        }
    }

    func testRevokedMandateAndMissingMandateRefuseDecisions() async throws {
        try await run { e in
            let task = try await review(e)
            let none = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja"])
            XCTAssertEqual(none.text, "brain_mandate_required")
            try await mandate(e)
            // The asking connection itself holds no mandate.
            let other = try await review(e, by: e.brain)
            let notMandated = try await call(e, e.agent, "decide_review", ["taskID": other, "decision": "accept", "quote": "ja"])
            XCTAssertEqual(notMandated.text, "brain_mandate_required")
            let del = try await e.f.test.json(.DELETE, "/v1/settings/brain-mandate", token: e.f.session)
            XCTAssertEqual(del.status, .noContent)
            let revoked = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja"])
            XCTAssertEqual(revoked.text, "brain_mandate_required")
            try await assertEqual(try await taskStatus(e, task), "in_review")
            // Revoking the grant itself makes the mandate void too.
            try await mandate(e)
            let grant = try XCTUnwrap(try await OAuthGrant.find(e.brainGrant, on: e.f.test.app.db))
            grant.revoked = true; try await grant.save(on: e.f.test.app.db)
            let gone = try await e.f.rpc("tools/list", access: e.brain)
            XCTAssertEqual(gone.status, .unauthorized)
        }
    }

    func testProjectOutsideMandateIsRefused() async throws {
        try await run { e in
            for g in [e.agentGrant, e.brainGrant] {
                let grant = try XCTUnwrap(try await OAuthGrant.find(g, on: e.f.test.app.db))
                grant.projects.append(try e.f.other.requireID()); try await grant.save(on: e.f.test.app.db)
            }
            try await mandate(e)
            let task = try await review(e, project: e.f.other)
            let r = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja"])
            XCTAssertEqual(r.text, "outside_brain_mandate")
            let inside = try await review(e)
            let ok = try await call(e, e.brain, "decide_review", ["taskID": inside, "decision": "accept", "quote": "ja"])
            XCTAssertFalse(ok.isError, ok.text)
        }
    }

    // MARK: Questions

    func testMandatedBrainAnswersQuestionWithAuditAndChatComment() async throws {
        try await run { e in
            try await mandate(e)
            let q = try await question(e)
            let r = try await call(e, e.brain, "answer_question", ["questionID": q.id, "answer": "B", "quote": "Lino: B"])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(r.json?["state"] as? String, "answered")
            let rows = try await audit(e)
            XCTAssertEqual(rows.first?["kind"] as? String, "question.answered")
            XCTAssertEqual(rows.first?["note"] as? String, "B")
            let comments = try await TaskComment.query(on: e.f.test.app.db).filter(\.$taskID == UUID(uuidString: q.task)!).all()
            let c = try XCTUnwrap(comments.first { $0.authorLabel == "Brain im Auftrag von OAuth User" })
            XCTAssertEqual(c.questionID?.uuidString, q.id)
        }
    }

    func testAnswerQuestionRules() async throws {
        try await run { e in
            let q = try await question(e)
            let none = try await call(e, e.brain, "answer_question", ["questionID": q.id, "answer": "A", "quote": "ja"])
            XCTAssertEqual(none.text, "brain_mandate_required")
            try await mandate(e)
            let noQuote = try await call(e, e.brain, "answer_question", ["questionID": q.id, "answer": "A"])
            XCTAssertEqual(noQuote.text, "quote_required")
            let own = try await question(e, by: e.brain)
            let ownAnswer = try await call(e, e.brain, "answer_question", ["questionID": own.id, "answer": "A", "quote": "ja"])
            XCTAssertEqual(ownAnswer.text, "cannot_answer_own_question")
            let wrongConnection = try await call(e, e.agent, "answer_question", ["questionID": own.id, "answer": "A", "quote": "ja"])
            XCTAssertEqual(wrongConnection.text, "brain_mandate_required")
            let del = try await e.f.test.json(.DELETE, "/v1/settings/brain-mandate", token: e.f.session)
            XCTAssertEqual(del.status, .noContent)
            let revoked = try await call(e, e.brain, "answer_question", ["questionID": q.id, "answer": "A", "quote": "ja"])
            XCTAssertEqual(revoked.text, "brain_mandate_required")
            try await assertEqual(try await TaskQuestion.find(UUID(uuidString: q.id), on: e.f.test.app.db)?.state, "open")
        }
    }

    func testAnswerOutsideMandateProject() async throws {
        try await run { e in
            for g in [e.agentGrant, e.brainGrant] {
                let grant = try XCTUnwrap(try await OAuthGrant.find(g, on: e.f.test.app.db))
                grant.projects.append(try e.f.other.requireID()); try await grant.save(on: e.f.test.app.db)
            }
            try await mandate(e)
            let task = try await newTask(e, project: e.f.other)
            let ask = try await call(e, e.agent, "ask_question", ["taskID": task, "prompt": "Q?"])
            let qid = try XCTUnwrap(ask.json?["id"] as? String)
            let r = try await call(e, e.brain, "answer_question", ["questionID": qid, "answer": "x", "quote": "ja"])
            XCTAssertEqual(r.text, "outside_brain_mandate")
        }
    }

    // MARK: Runner-backed paths

    func testRunnerBackedReviewAndQuestionAlsoRequireTheMandate() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let db = f.app.app.db
        let client = OAuthClient(name: "Brain", redirects: []); try await client.save(on: db)
        let grant = OAuthGrant(userID: try f.user.requireID(), clientID: try client.requireID(), resource: "r", scopes: ["tasks:write"],
            projects: [UUID(uuidString: f.projectID)!], name: "Brain")
        try await grant.save(on: db)
        let service = WorkflowService(user: f.user, db: db, allowedProjects: [UUID(uuidString: f.projectID)!])
        let actor = WorkflowActor.integration(grantID: try grant.requireID(), label: nil)

        let job = try await f.release()
        let run = try await f.claim(job)
        var status = try await f.command(run, "question", ["generation": 1, "prompt": "Which option?", "options": ["A", "B"]])
        XCTAssertEqual(status, .ok)
        let qid = try XCTUnwrap(try await f.app.json(.GET, "/v1/questions?projectID=\(f.projectID)", token: f.human).list?.first?["id"] as? String)
        await assertThrowsReason("brain_mandate_required") { _ = try await service.answer(UUID(uuidString: qid)!, value: "A", quote: "ja", actor: actor) }
        let put = try await f.app.json(.PUT, "/v1/settings/brain-mandate", ["grantID": try grant.requireID().uuidString, "projectIDs": [f.projectID]], token: f.human)
        XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
        await assertThrowsReason("quote_required") { _ = try await service.answer(UUID(uuidString: qid)!, value: "A", actor: actor) }
        let answered = try await service.answer(UUID(uuidString: qid)!, value: "A", quote: "Lino: A", actor: actor)
        XCTAssertEqual(answered.state, "answered")
        status = try await f.command(run, "resume")
        status = try await f.command(run, "submit", ["generation": 1, "result": ["summary": "Done", "references": [String](), "checks": [String](), "limitations": [String]()]])
        XCTAssertEqual(status, .ok)

        let del = try await f.app.json(.DELETE, "/v1/settings/brain-mandate", token: f.human)
        XCTAssertEqual(del.status, .noContent)
        let taskID = UUID(uuidString: f.taskID)!
        await assertThrowsReason("brain_mandate_required") { _ = try await service.decideReview(taskID, decision: "accept", note: nil, quote: "ja", actor: actor) }
        _ = try await f.app.json(.PUT, "/v1/settings/brain-mandate", ["grantID": try grant.requireID().uuidString, "projectIDs": [f.projectID]], token: f.human)
        let decided = try await service.decideReview(taskID, decision: "accept", note: nil, quote: "Lino: passt", actor: actor)
        XCTAssertEqual(decided.state, "accepted")
        let jobState = try await f.app.json(.GET, "/v1/agents/jobs/\(job)", token: f.human)
        XCTAssertEqual((jobState.body?["job"] as? [String: Any])?["state"] as? String, "succeeded")
        let rows = try await f.app.json(.GET, "/v1/settings/brain-mandate/audit", token: f.human)
        XCTAssertEqual((rows.body?["items"] as? [[String: Any]])?.map { $0["kind"] as? String }.sorted(), ["question.answered", "review.accepted"])
    }

    private func assertThrowsReason(_ reason: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(reason)", file: file, line: line) }
        catch let e as Abort { XCTAssertEqual(e.reason, reason, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    // MARK: Mandate endpoints

    func testMandateEndpointsValidateGrantAndProjectsAndRejectOAuthTokens() async throws {
        try await run { e in
            let db = e.f.test.app.db
            // Nothing yet.
            let empty = try await e.f.test.json(.GET, "/v1/settings/brain-mandate", token: e.f.session)
            XCTAssertEqual(empty.status, .ok)
            XCTAssertTrue(empty.body?["mandate"] is NSNull, "\(empty.body ?? [:])")
            // Foreign grant.
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: db)
            let foreign = OAuthGrant(userID: try stranger.requireID(), clientID: UUID(uuidString: e.f.clientID)!, resource: "r", scopes: [], projects: [], name: "x")
            try await foreign.save(on: db)
            let r1 = try await mandate(e, grant: try foreign.requireID())
            XCTAssertEqual(r1.status, .notFound)
            // Revoked grant.
            let own = OAuthGrant(userID: try e.f.user.requireID(), clientID: UUID(uuidString: e.f.clientID)!, resource: "r", scopes: [], projects: [], name: "old")
            own.revoked = true; try await own.save(on: db)
            let r2 = try await mandate(e, grant: try own.requireID())
            XCTAssertEqual(r2.status, .conflict)
            XCTAssertEqual(r2.body?["reason"] as? String, "grant_revoked")
            // Unreadable project, empty list.
            let theirs = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Theirs"); try await theirs.save(on: db)
            let r3 = try await mandate(e, projects: [try theirs.requireID().uuidString])
            XCTAssertEqual(r3.status, .notFound)
            let r4 = try await mandate(e, projects: [])
            XCTAssertEqual(r4.status, .badRequest)
            // Valid, then read back; a second PUT overwrites (one mandate per person).
            let ok = try await mandate(e)
            XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
            let got = try await e.f.test.json(.GET, "/v1/settings/brain-mandate", token: e.f.session)
            let m = try XCTUnwrap(got.body?["mandate"] as? [String: Any])
            XCTAssertEqual(m["grantID"] as? String, e.brainGrant.uuidString)
            XCTAssertEqual(m["projectIDs"] as? [String], [e.pid])
            XCTAssertEqual(m["active"] as? Bool, true)
            let again = try await mandate(e, grant: e.agentGrant, projects: [e.pid, try e.f.other.requireID().uuidString])
            XCTAssertEqual(again.status, .ok)
            try await assertEqual(try await BrainMandate.query(on: db).count(), 1)
            // OAuth bearer tokens never manage mandates.
            for (method, path) in [(HTTPMethod.GET, "/v1/settings/brain-mandate"), (.PUT, "/v1/settings/brain-mandate"),
                                   (.DELETE, "/v1/settings/brain-mandate"), (.GET, "/v1/settings/brain-mandate/audit")] {
                let r = try await e.f.test.json(method, path, ["grantID": e.brainGrant.uuidString, "projectIDs": [e.pid]], token: e.brain)
                XCTAssertEqual(r.status, .unauthorized, "\(method) \(path)")
            }
            let anon = try await e.f.test.json(.GET, "/v1/settings/brain-mandate")
            XCTAssertEqual(anon.status, .unauthorized)
        }
    }

    func testGetConnectionReportsMandate() async throws {
        try await run { e in
            let before = try await call(e, e.brain, "get_connection", [:])
            XCTAssertEqual((before.json?["brainMandate"] as? [String: Any])?["active"] as? Bool, false)
            try await mandate(e)
            let after = try await call(e, e.brain, "get_connection", [:])
            let m = try XCTUnwrap(after.json?["brainMandate"] as? [String: Any])
            XCTAssertEqual(m["active"] as? Bool, true)
            XCTAssertEqual(m["projectIDs"] as? [String], [e.pid])
            let other = try await call(e, e.agent, "get_connection", [:])
            XCTAssertEqual((other.json?["brainMandate"] as? [String: Any])?["active"] as? Bool, false)
        }
    }

    // MARK: brainRecommended

    func testBrainRecommendedIsBoundToTheMandatedConnection() async throws {
        try await run { e in
            try await mandate(e)
            let fake = try await review(e), real = try await review(e), labelOnlyBrain = try await review(e, by: e.brain)
            // Another connection calling itself "brain" does not count; the mandated connection does, whatever its label.
            _ = try await call(e, e.agent, "add_comment", ["taskID": fake, "body": "Empfehlung: annehmen", "agentName": "brain",
                "reviewID": try await reviewID(e, fake)])
            _ = try await call(e, e.brain, "add_comment", ["taskID": real, "body": "Empfehlung: annehmen", "agentName": "brain",
                "reviewID": try await reviewID(e, real)])
            _ = labelOnlyBrain
            let list = try await e.f.test.json(.GET, "/v1/reviews", token: e.f.session)
            let flags = Dictionary(uniqueKeysWithValues: try XCTUnwrap(list.list).map { ($0["taskID"] as! String, $0["brainRecommended"] as? Bool) })
            XCTAssertEqual(flags[fake], false)
            XCTAssertEqual(flags[real], true)
            let only = try await e.f.test.json(.GET, "/v1/reviews?brainRecommended=true", token: e.f.session)
            XCTAssertEqual(only.list?.compactMap { $0["taskID"] as? String }, [real])
            // Without a mandate the marker disappears again.
            _ = try await e.f.test.json(.DELETE, "/v1/settings/brain-mandate", token: e.f.session)
            let after = try await e.f.test.json(.GET, "/v1/reviews?brainRecommended=true", token: e.f.session)
            XCTAssertEqual(after.list?.count, 0)
        }
    }

    private func reviewID(_ e: Env, _ task: String) async throws -> String {
        try XCTUnwrap(try await TaskReview.query(on: e.f.test.app.db).filter(\.$taskID == UUID(uuidString: task)!).first()?.requireID().uuidString)
    }
}
