import Fluent
import XCTVapor
@testable import TodoKit

final class ReviewUndoTests: XCTestCase {
    private func requested(_ f: AgentFixture) async throws {
        let r = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review", ["summary": "Please check"], token: f.human)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func task(_ f: AgentFixture) async throws -> TodoTask {
        let found = try await TodoTask.find(UUID(uuidString: f.taskID), on: f.app.app.db)
        return try XCTUnwrap(found)
    }

    func testUndoRestoresPendingAndPreviousState() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        try await requested(f)
        let before = try await task(f)
        XCTAssertEqual(before.status, "in_review")
        let decided = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "accept"], token: f.human)
        XCTAssertEqual(decided.body?["state"] as? String, "accepted")
        XCTAssertNotNil(decided.body?["undoUntil"] as? String)
        let doneTask = try await task(f)
        XCTAssertEqual(doneTask.status, "done")

        let undone = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(undone.status, .ok, "\(undone.body ?? [:])")
        XCTAssertEqual(undone.body?["state"] as? String, "pending")
        XCTAssertNil(undone.body?["undoUntil"] as? String)
        let after = try await task(f)
        XCTAssertEqual(after.status, "in_review")
        XCTAssertEqual(after.columnID, before.columnID)
        let pending = try await f.app.json(.GET, "/v1/reviews", token: f.human)
        XCTAssertEqual(pending.list?.count, 1)
        let kinds = try await ActivityEvent.query(on: f.app.app.db).all().map(\.kind)
        XCTAssertTrue(kinds.contains("review.undone"))
        let notes = try await TaskComment.query(on: f.app.app.db).filter(\.$taskID == UUID(uuidString: f.taskID)!).all()
        XCTAssertTrue(notes.contains { $0.body.contains("zurückgenommen") })
        // A second undo has nothing to undo; the review can be decided again and undone again.
        let again = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(again.status, .conflict)
        let redo = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "request_changes", "note": "later"], token: f.human)
        XCTAssertEqual(redo.body?["state"] as? String, "changes_requested")
        let working = try await task(f)
        XCTAssertEqual(working.status, "in_progress")
        let undoChanges = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(undoChanges.status, .ok)
        let restored = try await task(f)
        XCTAssertEqual(restored.status, "in_review")
    }

    func testUndoRefusedAfterWindow() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        try await requested(f)
        _ = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "accept"], token: f.human)
        let first = try await TaskReview.query(on: f.app.app.db).first()
        let review = try XCTUnwrap(first)
        review.decidedAt = Date().addingTimeInterval(-WorkflowLimits.reviewUndoWindow - 5)
        try await review.save(on: f.app.app.db)
        let r = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(r.status, .conflict)
        XCTAssertEqual(r.body?["reason"] as? String, "undo_window_expired")
        let t = try await task(f)
        XCTAssertEqual(t.status, "done")
    }

    func testUndoRefusedWhenAgentAlreadyActed() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        try await requested(f)
        _ = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "request_changes", "note": "fix"], token: f.human)
        try await appendActivity(taskID: UUID(uuidString: f.taskID)!, actorType: .integration, actorID: UUID(), kind: "progress.posted", subjectID: nil, on: f.app.app.db)
        let r = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(r.status, .conflict)
        XCTAssertEqual(r.body?["reason"] as? String, "already_acted_on")
        let t = try await task(f)
        XCTAssertEqual(t.status, "in_progress")
    }

    func testUndoRefusedWhenTaskChangedAndForOtherUsers() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        try await requested(f)
        _ = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "accept"], token: f.human)
        let other = User(displayName: "Other", isAdmin: false)
        try await other.save(on: f.app.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: other.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.app.db)
        let foreign = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: token)
        XCTAssertEqual(foreign.status, .notFound)
        let t = try await task(f)
        t.version += 1
        try await t.save(on: f.app.app.db)
        let r = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(r.status, .conflict)
        XCTAssertEqual(r.body?["reason"] as? String, "already_acted_on")
    }

    func testRunnerBackedReviewIsNotUndoable() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let run = try await f.claim(job)
        _ = try await f.command(run, "submit", ["generation": 1, "result": ["summary": "Done", "references": [String](), "checks": [String](), "limitations": [String]()]])
        let decided = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "accept"], token: f.human)
        XCTAssertEqual(decided.status, .ok, "\(decided.body ?? [:])")
        XCTAssertNil(decided.body?["undoUntil"] as? String)
        let r = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/undo", token: f.human)
        XCTAssertEqual(r.status, .conflict)
    }
}
