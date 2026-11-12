import Fluent
import XCTVapor
@testable import TodoKit

/// Decision journal (record_decision, list_decisions, review_decision, REST /v1/decisions) and its morning view in the daily brief.
final class DecisionJournalTests: XCTestCase {
    private func run(_ f: OAuthFixture, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func task(_ f: OAuthFixture, _ title: String = "Card", project: Project? = nil, owner: User? = nil) async throws -> TodoTask {
        let t = TodoTask(ownerID: try (owner ?? f.user).requireID(), projectID: try (project ?? f.project).requireID(), title: title, details: "")
        try await t.save(on: f.test.app.db)
        return t
    }

    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    private func args(_ t: TodoTask, _ extra: [String: Any] = [:]) throws -> [String: Any] {
        ["taskID": try t.requireID().uuidString, "decision": "Use SQLite for the cache", "rationale": "No second service at night",
         "criterion": "Tests green and no new container", "rollbackRef": "abc1234"].merging(extra) { _, new in new }
    }

    func testAgentRecordsDecisionAndListsIt() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let t = try await task(f)
            let tok = try await f.tokens()
            let rec = try await call(f, "record_decision", try args(t, ["agentName": "night-agent"]), tok.access)
            XCTAssertFalse(rec.isError, rec.text)
            let dto = try XCTUnwrap(rec.json as? [String: Any])
            XCTAssertEqual(dto["state"] as? String, "open")
            XCTAssertEqual(dto["rollbackRef"] as? String, "abc1234")
            XCTAssertEqual(dto["actorLabel"] as? String, "night-agent")
            let list = try await call(f, "list_decisions", ["state": "open"], tok.access)
            let items = try XCTUnwrap(list.json as? [[String: Any]], list.text)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["taskTitle"] as? String, "Card")
            XCTAssertEqual(items.first?["criterion"] as? String, "Tests green and no new container")
        }
    }

    func testValidation() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let t = try await task(f)
            let tok = try await f.tokens()
            for bad in [["decision": "  "], ["rationale": ""], ["criterion": " "], ["rollbackRef": "has space"], ["rollbackRef": "-rf"], ["rollbackRef": "a;b"]] {
                let r = try await call(f, "record_decision", try args(t, bad), tok.access)
                XCTAssertTrue(r.isError, "\(bad)")
            }
            let noRef = try await call(f, "record_decision", try args(t, ["rollbackRef": ""]), tok.access)
            XCTAssertFalse(noRef.isError, noRef.text)
            XCTAssertTrue(((noRef.json as? [String: Any])?["rollbackRef"]).map { $0 is NSNull } ?? true)
        }
    }

    func testPersonReviewsOkAndRollbackNeedsReasonAndBecomesPrecedent() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let t = try await task(f)
            let tok = try await f.tokens()
            let ra = try await call(f, "record_decision", try args(t), tok.access)
            let rb = try await call(f, "record_decision", try args(t, ["decision": "Drop the retry loop"]), tok.access)
            let a = try XCTUnwrap(ra.json as? [String: Any]), b = try XCTUnwrap(rb.json as? [String: Any])
            let aID = try XCTUnwrap(a["id"] as? String), bID = try XCTUnwrap(b["id"] as? String)

            let noNote = try await f.test.json(.POST, "/v1/decisions/\(aID)/review", ["verdict": "rollback"], token: f.session)
            XCTAssertEqual(noNote.status, .badRequest)
            let badVerdict = try await f.test.json(.POST, "/v1/decisions/\(aID)/review", ["verdict": "maybe"], token: f.session)
            XCTAssertEqual(badVerdict.status, .badRequest)

            let ok = try await f.test.json(.POST, "/v1/decisions/\(bID)/review", ["verdict": "ok"], token: f.session)
            XCTAssertEqual(ok.status, .ok)
            XCTAssertEqual(ok.body?["state"] as? String, "ok")
            let back = try await f.test.json(.POST, "/v1/decisions/\(aID)/review", ["verdict": "rollback", "note": "Cache must survive restarts, use MariaDB"], token: f.session)
            XCTAssertEqual(back.status, .ok)
            XCTAssertEqual(back.body?["state"] as? String, "rolled_back")
            XCTAssertNotNil(back.body?["reviewedAt"])

            // Precedent: found by state and by text in the review note.
            let hit = try await call(f, "list_decisions", ["state": "rolled_back", "query": "MARIADB"], tok.access)
            XCTAssertEqual((hit.json as? [[String: Any]])?.map { $0["id"] as? String }, [aID])
            let miss = try await call(f, "list_decisions", ["state": "rolled_back", "query": "retry"], tok.access)
            XCTAssertEqual((miss.json as? [[String: Any]])?.count, 0)
            let rest = try await f.test.json(.GET, "/v1/decisions?state=rolled_back", token: f.session)
            XCTAssertEqual(rest.list?.count, 1)
            let perTask = try await f.test.json(.GET, "/v1/tasks/\(try t.requireID().uuidString)/decisions", token: f.session)
            XCTAssertEqual(perTask.list?.count, 2)
        }
    }

    func testConnectionCannotReviewItsOwnDecision() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let t = try await task(f)
            let tok = try await f.tokens()
            let recorded = try await call(f, "record_decision", try args(t), tok.access)
            let id = try XCTUnwrap((recorded.json as? [String: Any])?["id"] as? String)
            let own = try await call(f, "review_decision", ["decisionID": id, "verdict": "ok"], tok.access)
            XCTAssertTrue(own.isError)
            XCTAssertTrue(own.text.contains("cannot_review_own_decision"), own.text)
        }
    }

    func testRightsAndProjectGrantAreRespected() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let t = try await task(f)
            let tok = try await f.tokens()
            let recorded = try await call(f, "record_decision", try args(t), tok.access)
            let id = try XCTUnwrap((recorded.json as? [String: Any])?["id"] as? String)
            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: f.test.app.db)
            let hidden = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Hidden")
            try await hidden.save(on: f.test.app.db)
            let foreign = try await task(f, "Foreign", project: hidden, owner: stranger)
            let denied = try await call(f, "record_decision", try args(foreign), tok.access)
            XCTAssertTrue(denied.isError)
            let svc = WorkflowService(user: stranger, db: f.test.app.db)
            let none = try await svc.decisions(projectID: nil, taskID: nil, since: nil, state: "all", query: nil)
            XCTAssertTrue(none.isEmpty, "a stranger sees nothing of other accounts")
            do { _ = try await svc.reviewDecision(UUID(uuidString: id)!, DecisionVerdictRequest(verdict: "ok", note: nil), actor: .person(stranger)); XCTFail("must be refused") }
            catch let e as Abort { XCTAssertTrue([.notFound, .forbidden].contains(e.status)) }
            let read = try await call(f, "list_decisions", ["state": "bogus"], tok.access)
            XCTAssertTrue(read.isError)
        }
    }

    func testDailyBriefListsOpenDecisionsSinceYesterday() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let t = try await task(f)
            let svc = WorkflowService(user: f.user, db: f.test.app.db)
            let actor = WorkflowActor.integration(grantID: UUID(), label: "night")
            let fresh = try await svc.recordDecision(try t.requireID(), RecordDecisionRequest(decision: "Fresh", rationale: "r", criterion: "c", rollbackRef: nil, agentName: nil), actor: actor)
            let reviewed = try await svc.recordDecision(try t.requireID(), RecordDecisionRequest(decision: "Reviewed", rationale: "r", criterion: "c", rollbackRef: nil, agentName: nil), actor: actor)
            let old = try await svc.recordDecision(try t.requireID(), RecordDecisionRequest(decision: "Old", rationale: "r", criterion: "c", rollbackRef: nil, agentName: nil), actor: actor)
            _ = try await svc.reviewDecision(reviewed.id, DecisionVerdictRequest(verdict: "ok", note: nil), actor: .person(f.user))
            try await TaskDecision.query(on: f.test.app.db).filter(\.$id == old.id).set(\.$createdAt, to: Date().addingTimeInterval(-5 * 86_400)).update()

            let brief = try await DailyBriefService(user: f.user, db: f.test.app.db).build()
            XCTAssertEqual(brief.summary?.decisionsToReview, 1)
            let section = try XCTUnwrap(brief.sections?.first { $0.key == "decisions" })
            XCTAssertEqual(section.items, [DailyBriefItem(id: fresh.id, title: "Fresh", projectID: try f.project.requireID(), kind: "decision")])
            XCTAssertTrue(brief.line.contains("1 Entscheidung zu prüfen"), brief.line)

        }
    }
}
