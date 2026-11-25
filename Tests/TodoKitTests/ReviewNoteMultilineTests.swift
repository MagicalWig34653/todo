import XCTVapor
@testable import TodoKit

/// Bug DA09D11A: notes a person types on a review (card, bulk bar) or on a journal decision are free text. Line breaks and
/// tabs must be stored; other control characters stay refused.
final class ReviewNoteMultilineTests: XCTestCase {
    private let note = "Regen\n- Deutschland: Radar reicht\r\n\t- Ausland: keine Karte\n\nKartenwahl 👨\u{200D}👩\u{200D}👧"

    private func setup(_ t: TestApp) async throws -> (token: String, project: String) {
        let user = User(displayName: "Person", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        let project = try await t.json(.POST, "/v1/projects", ["name": "Project"], token: token)
        return (token, try XCTUnwrap(project.body?["id"] as? String))
    }

    private func review(_ t: TestApp, _ s: (token: String, project: String)) async throws -> (task: String, review: String) {
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": s.project, "title": "Task"], token: s.token)
        let taskID = try XCTUnwrap(task.body?["id"] as? String)
        let r = try await t.json(.POST, "/v1/tasks/\(taskID)/review", ["summary": "Done"], token: s.token)
        return (taskID, try XCTUnwrap(r.body?["id"] as? String))
    }

    func testSingleDecisionKeepsLineBreaksInTheNote() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let s = try await setup(t)
        for decision in ["request_changes", "accept"] {
            let a = try await review(t, s)
            let r = try await t.json(.POST, "/v1/tasks/\(a.task)/review/decision", ["decision": decision, "note": note], token: s.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            XCTAssertEqual(r.body?["decisionNote"] as? String, note)
        }
    }

    func testBatchDecisionKeepsLineBreaksInTheNote() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let s = try await setup(t)
        let a = try await review(t, s)
        let r = try await t.json(.POST, "/v1/reviews/decisions",
            ["decisions": [["reviewID": a.review]], "decision": "changes_requested", "note": note], token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let item = try XCTUnwrap((r.body?["results"] as? [[String: Any]])?.first)
        XCTAssertEqual((item["review"] as? [String: Any])?["decisionNote"] as? String, note, "\(item)")
    }

    func testOtherControlCharactersAndOverlongNotesStayRefused() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let s = try await setup(t)
        let a = try await review(t, s)
        for bad in ["a\u{0}b", "a\u{7}b", "a\u{1B}[31mb", String(repeating: "x", count: WorkflowLimits.maxText + 1)] {
            let r = try await t.json(.POST, "/v1/tasks/\(a.task)/review/decision", ["decision": "request_changes", "note": bad], token: s.token)
            XCTAssertEqual(r.status, .badRequest)
            XCTAssertEqual(r.body?["reason"] as? String, "invalid_note")
        }
    }

    func testDecisionJournalVerdictKeepsLineBreaksInTheNote() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let s = try await setup(t)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": s.project, "title": "Task"], token: s.token)
        let taskID = try XCTUnwrap(task.body?["id"] as? String)
        let d = try await t.json(.POST, "/v1/tasks/\(taskID)/decisions",
            ["decision": "D", "rationale": "R", "criterion": "C"], token: s.token)
        let id = try XCTUnwrap(d.body?["id"] as? String, "\(d.body ?? [:])")
        let r = try await t.json(.POST, "/v1/decisions/\(id)/review", ["verdict": "rollback", "note": note], token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["reviewNote"] as? String, note)
    }
}
