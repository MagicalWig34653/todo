import Fluent
import XCTVapor
@testable import TodoKit

final class ReviewBatchTests: XCTestCase {
    struct Person { let id: String; let token: String }

    private func person(_ t: TestApp, _ name: String = "Person") async throws -> Person {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return Person(id: try user.requireID().uuidString, token: token)
    }

    private func project(_ t: TestApp, _ owner: Person) async throws -> String {
        let r = try await t.json(.POST, "/v1/projects", ["name": "Project"], token: owner.token)
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    /// A task in review; returns (taskID, reviewID).
    private func review(_ t: TestApp, _ owner: Person, project: String, reviewer: String? = nil, n: Int = 0) async throws -> (task: String, review: String) {
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": project, "title": "Task \(n)"], token: owner.token)
        let taskID = try XCTUnwrap(task.body?["id"] as? String)
        var body: [String: Any] = ["summary": "Done \(n)"]
        if let reviewer { body["reviewerID"] = reviewer }
        let r = try await t.json(.POST, "/v1/tasks/\(taskID)/review", body, token: owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return (taskID, try XCTUnwrap(r.body?["id"] as? String))
    }

    private func grant(_ t: TestApp, _ owner: Person, _ project: String, to p: Person, role: String) async throws {
        let r = try await t.json(.PUT, "/v1/projects/\(project)/grants",
            ["principalType": "person", "principalID": p.id, "role": role], token: owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func batch(_ t: TestApp, _ p: Person, _ ids: [String], _ decision: String = "accept", note: String? = nil)
        async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var body: [String: Any] = ["decisions": ids.map { ["reviewID": $0] }, "decision": decision]
        if let note { body["note"] = note }
        let r = try await t.json(.POST, "/v1/reviews/decisions", body, token: p.token)
        return (r.status, r.body)
    }

    private func reviewRow(_ t: TestApp, _ id: String) async throws -> TaskReview {
        let row = try await TaskReview.find(UUID(uuidString: id), on: t.app.db)
        return try XCTUnwrap(row)
    }

    private func taskRow(_ t: TestApp, _ id: String) async throws -> TodoTask {
        let row = try await TodoTask.find(UUID(uuidString: id), on: t.app.db)
        return try XCTUnwrap(row)
    }

    private func results(_ body: [String: Any]?) throws -> [[String: Any]] {
        try XCTUnwrap(body?["results"] as? [[String: Any]])
    }

    func testBatchAcceptsEveryReviewThroughTheSinglePathWithAuditPerReview() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), pid = try await project(t, owner)
        var ids: [String] = [], tasks: [String] = []
        for n in 0..<3 { let r = try await review(t, owner, project: pid, n: n); ids.append(r.review); tasks.append(r.task) }

        let r = try await batch(t, owner, ids, note: "Mündlich freigegeben")
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let items = try results(r.body)
        XCTAssertEqual(items.map { $0["reviewID"] as? String }, ids)
        XCTAssertEqual(items.map { $0["result"] as? String }, ["ok", "ok", "ok"])
        XCTAssertEqual((items[0]["review"] as? [String: Any])?["state"] as? String, "accepted")
        let summary = try XCTUnwrap(r.body?["summary"] as? [String: Int])
        XCTAssertEqual(summary["ok"], 3)
        XCTAssertEqual(summary["forbidden"], 0)

        for (i, id) in ids.enumerated() {
            let row = try await reviewRow(t, id)
            XCTAssertEqual(row.state, "accepted")
            XCTAssertEqual(row.decisionNote, "Mündlich freigegeben")
            XCTAssertEqual(row.decidedBy?.uuidString, owner.id)
            let task = try await taskRow(t, tasks[i])
            XCTAssertEqual(task.status, "done")
            let events = try await ActivityEvent.query(on: t.app.db).filter(\.$taskID == task.requireID())
                .filter(\.$kind == "review.accepted").all()
            XCTAssertEqual(events.count, 1, "one review.accepted event per review")
            XCTAssertEqual(events.first?.actorID.uuidString, owner.id)
        }
    }

    func testChangesRequestedAndLegacyAlias() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), pid = try await project(t, owner)
        let a = try await review(t, owner, project: pid, n: 1), b = try await review(t, owner, project: pid, n: 2)
        let one = try await batch(t, owner, [a.review], "changes_requested", note: "Bitte nacharbeiten")
        XCTAssertEqual(try results(one.body).first?["result"] as? String, "ok")
        let two = try await batch(t, owner, [b.review], "request_changes")
        XCTAssertEqual(try results(two.body).first?["result"] as? String, "ok")
        for pair in [a, b] {
            let row = try await reviewRow(t, pair.review)
            XCTAssertEqual(row.state, "changes_requested")
            let task = try await taskRow(t, pair.task)
            XCTAssertEqual(task.status, "in_progress")
        }
        let events = try await ActivityEvent.query(on: t.app.db).filter(\.$kind == "review.changes_requested").count()
        XCTAssertEqual(events, 2)
    }

    func testPartialResultsWithStableCodesAndNoRollback() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), stranger = try await person(t), reader = try await person(t)
        let pid = try await project(t, owner), foreignPID = try await project(t, stranger)
        try await grant(t, owner, pid, to: reader, role: "read")
        let good = try await review(t, owner, project: pid, n: 1)
        let readOnly = try await review(t, owner, project: pid, n: 2)
        let decided = try await review(t, owner, project: pid, n: 3)
        let foreign = try await review(t, stranger, project: foreignPID, n: 4)
        _ = try await t.json(.POST, "/v1/tasks/\(decided.task)/review/decision", ["decision": "accept"], token: owner.token)

        // The reader sees the project (read) but may not decide: forbidden; the foreign review is invisible: not_found.
        let asReader = try await batch(t, reader, [readOnly.review, foreign.review, UUID().uuidString, "not-a-uuid", decided.review])
        XCTAssertEqual(asReader.status, .ok)
        XCTAssertEqual(try results(asReader.body).map { $0["result"] as? String },
            ["forbidden", "not_found", "not_found", "invalid", "already_decided"])

        // Owner: one ok, one already decided, one invisible, one unknown, in one call; the ok one stays decided.
        let mixed = try await batch(t, owner, [good.review, decided.review, foreign.review, UUID().uuidString])
        XCTAssertEqual(try results(mixed.body).map { $0["result"] as? String }, ["ok", "already_decided", "not_found", "not_found"])
        let summary = try XCTUnwrap(mixed.body?["summary"] as? [String: Int])
        XCTAssertEqual(summary["ok"], 1); XCTAssertEqual(summary["alreadyDecided"], 1); XCTAssertEqual(summary["notFound"], 2)
        let row = try await reviewRow(t, good.review)
        XCTAssertEqual(row.state, "accepted")
        let untouched = try await reviewRow(t, foreign.review)
        XCTAssertEqual(untouched.state, "pending")
        let readOnlyRow = try await reviewRow(t, readOnly.review)
        XCTAssertEqual(readOnlyRow.state, "pending")
    }

    func testForeignAccountCannotEnumerateOrDecide() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), stranger = try await person(t)
        let pid = try await project(t, owner)
        let r = try await review(t, owner, project: pid)
        let theirs = try await batch(t, stranger, [r.review, UUID().uuidString])
        let items = try results(theirs.body)
        XCTAssertEqual(items.map { $0["result"] as? String }, ["not_found", "not_found"])
        XCTAssertEqual(items[0].keys.sorted(), items[1].keys.sorted(), "an invisible review looks exactly like an unknown one")
        XCTAssertNil(items[0]["review"])
        let row = try await reviewRow(t, r.review)
        XCTAssertEqual(row.state, "pending")
        let anonymous = try await t.json(.POST, "/v1/reviews/decisions", ["decisions": [["reviewID": r.review]], "decision": "accept"])
        XCTAssertEqual(anonymous.status, .unauthorized)
    }

    func testDesignatedReviewerRuleStillApplies() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), editor = try await person(t)
        let pid = try await project(t, owner)
        try await grant(t, owner, pid, to: editor, role: "edit")
        let assignedToOwner = try await review(t, owner, project: pid, reviewer: owner.id, n: 1)
        let denied = try await batch(t, editor, [assignedToOwner.review])
        let item = try XCTUnwrap(try results(denied.body).first)
        XCTAssertEqual(item["result"] as? String, "forbidden")
        XCTAssertEqual(item["reason"] as? String, "not_the_reviewer")
        let ok = try await batch(t, owner, [assignedToOwner.review])
        XCTAssertEqual(try results(ok.body).first?["result"] as? String, "ok")
    }

    func testRepeatIsIdempotentAndWritesNoSecondAudit() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), pid = try await project(t, owner)
        let a = try await review(t, owner, project: pid, n: 1), b = try await review(t, owner, project: pid, n: 2)
        _ = try await batch(t, owner, [a.review, b.review])
        let before = try await ActivityEvent.query(on: t.app.db).count()
        // Even with the opposite decision a decided review stays as it is.
        let again = try await batch(t, owner, [a.review, b.review], "changes_requested", note: "x")
        XCTAssertEqual(try results(again.body).map { $0["result"] as? String }, ["already_decided", "already_decided"])
        let after = try await ActivityEvent.query(on: t.app.db).count()
        XCTAssertEqual(before, after)
        let row = try await reviewRow(t, a.review)
        XCTAssertEqual(row.state, "accepted")
    }

    func testDuplicateIDsAreDecidedOnceAndReportedOnce() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), pid = try await project(t, owner)
        let a = try await review(t, owner, project: pid)
        let r = try await batch(t, owner, [a.review, a.review])
        XCTAssertEqual(try results(r.body).map { $0["result"] as? String }, ["ok"])
    }

    func testLimitsAndValidation() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t)
        let fifty = (0..<50).map { _ in UUID().uuidString }
        let atLimit = try await batch(t, owner, fifty)
        XCTAssertEqual(atLimit.status, .ok)
        XCTAssertEqual(try results(atLimit.body).count, 50)
        let over = try await batch(t, owner, fifty + [UUID().uuidString])
        XCTAssertEqual(over.status, .badRequest)
        XCTAssertEqual(over.body?["reason"] as? String, "too_many_reviews")
        let empty = try await batch(t, owner, [])
        XCTAssertEqual(empty.body?["reason"] as? String, "no_reviews")
        let badDecision = try await batch(t, owner, [UUID().uuidString], "approve")
        XCTAssertEqual(badDecision.status, .badRequest)
        XCTAssertEqual(badDecision.body?["reason"] as? String, "invalid_decision")
        let longNote = try await batch(t, owner, [UUID().uuidString], note: String(repeating: "x", count: WorkflowLimits.maxText + 1))
        XCTAssertEqual(longNote.body?["reason"] as? String, "invalid_note")
    }

    func testBatchRequestsAreRateLimitedPerAccount() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), other = try await person(t)
        var last: HTTPStatus = .ok
        for _ in 0..<WorkflowLimits.reviewBatchRequestsPerWindow { last = try await batch(t, owner, [UUID().uuidString]).status }
        XCTAssertEqual(last, .ok)
        let limited = try await batch(t, owner, [UUID().uuidString])
        XCTAssertEqual(limited.status, .tooManyRequests)
        let unaffected = try await batch(t, other, [UUID().uuidString])
        XCTAssertEqual(unaffected.status, .ok)
    }

    func testBrainRecommendedIsDerivedFromABrainAgentCommentAndFilterable() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await person(t), pid = try await project(t, owner)
        let rec = try await review(t, owner, project: pid, n: 1)
        let plain = try await review(t, owner, project: pid, n: 2)
        let otherAgent = try await review(t, owner, project: pid, n: 3)
        let personFaking = try await review(t, owner, project: pid, n: 4)
        func comment(_ task: String, _ review: String, kind: String?, label: String?) async throws {
            let c = TaskComment(taskID: UUID(uuidString: task)!, authorID: UUID(uuidString: owner.id)!, body: "Empfehlung: annehmen")
            c.reviewID = UUID(uuidString: review); c.authorKind = kind; c.authorLabel = label
            try await c.save(on: t.app.db)
        }
        try await comment(rec.task, rec.review, kind: "agent", label: " Brain ")
        try await comment(otherAgent.task, otherAgent.review, kind: "agent", label: "codex")
        try await comment(personFaking.task, personFaking.review, kind: "person", label: "brain")

        let all = try await t.json(.GET, "/v1/reviews", token: owner.token)
        let flags = Dictionary(uniqueKeysWithValues: try XCTUnwrap(all.list).map { ($0["id"] as! String, $0["brainRecommended"] as? Bool) })
        XCTAssertEqual(flags[rec.review], true)
        XCTAssertEqual(flags[plain.review], false)
        XCTAssertEqual(flags[otherAgent.review], false)
        XCTAssertEqual(flags[personFaking.review], false)

        let only = try await t.json(.GET, "/v1/reviews?brainRecommended=true", token: owner.token)
        XCTAssertEqual(only.list?.compactMap { $0["id"] as? String }, [rec.review])
        let rest = try await t.json(.GET, "/v1/reviews?brainRecommended=false", token: owner.token)
        XCTAssertEqual(Set(rest.list?.compactMap { $0["id"] as? String } ?? []), [plain.review, otherAgent.review, personFaking.review])
        let bad = try await t.json(.GET, "/v1/reviews?brainRecommended=yes", token: owner.token)
        XCTAssertEqual(bad.status, .badRequest)
    }
}
