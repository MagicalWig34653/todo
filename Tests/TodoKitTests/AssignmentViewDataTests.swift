import Fluent
import XCTVapor
@testable import TodoKit

/// Additive data for the views of responsibility (card E9300901): names for readers, "does it concern me" in the feed and the
/// command center summary.
final class AssignmentViewDataTests: XCTestCase {
    private typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)

    private func id(_ r: Reply, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(r.body?["id"] as? String, "\(r.body ?? [:])", file: file, line: line)
    }

    private func get(_ f: AssignmentFixture, _ path: String, _ a: AssignmentFixture.Account,
                     file: StaticString = #filePath, line: UInt = #line) async throws -> Reply {
        let r = try await f.t.json(.GET, path, token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
        return r
    }

    private func row(_ rows: Any?, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap((rows as? [[String: Any]])?.first { ($0["id"] as? String) == id }, "\(id) missing in \(rows ?? "nil")", file: file, line: line)
    }

    private func cards(_ r: Reply) -> [[String: Any]] {
        (r.body?["lanes"] as? [[String: Any]] ?? []).flatMap { $0["cards"] as? [[String: Any]] ?? [] }
    }

    /// A card of the designer with one subtask, a question for the commenter and a review for the designer.
    private struct Seeded { let card, subtask, question, review: String }
    private func seed(_ f: AssignmentFixture) async throws -> Seeded {
        let card = try await f.task(), sub = try await f.task("Sub")
        let linked = try await f.t.json(.PUT, "/v1/tasks/\(sub)/structure", ["parentTaskID": card], token: f.owner.token)
        XCTAssertEqual(linked.status, .ok, "\(linked.body ?? [:])")
        try await f.assign(card, to: f.designer.id)
        try await f.assign(sub, to: f.editor.id)
        let q = try id(try await f.ask(card, assignee: f.commenter.id))
        let v = try id(try await f.review(card, assignee: f.designer.id))
        return Seeded(card: card, subtask: sub, question: q, review: v)
    }

    // MARK: assigneeName

    func testReadersSeeTheNamesInContextListsAndCommandCenter() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let s = try await seed(f)

        let context = try await get(f, "/v1/tasks/\(s.card)/context", f.reader)
        XCTAssertEqual((context.body?["task"] as? [String: Any])?["assigneeName"] as? String, "Designer", "\(context.body ?? [:])")
        XCTAssertEqual(try row(context.body?["subtasks"], s.subtask)["assigneeName"] as? String, "Editor")
        XCTAssertEqual(try row(context.body?["questions"], s.question)["assigneeName"] as? String, "Commenter")
        XCTAssertEqual((context.body?["review"] as? [String: Any])?["assigneeName"] as? String, "Designer")

        let questions = try await get(f, "/v1/questions?projectID=\(f.project)", f.reader)
        XCTAssertEqual(try row(questions.list, s.question)["assigneeName"] as? String, "Commenter")
        let ofTask = try await get(f, "/v1/tasks/\(s.card)/questions", f.reader)
        XCTAssertEqual(try row(ofTask.list, s.question)["assigneeName"] as? String, "Commenter")
        let one = try await get(f, "/v1/questions/\(s.question)", f.reader)
        XCTAssertEqual(one.body?["assigneeName"] as? String, "Commenter", "\(one.body ?? [:])")
        let reviews = try await get(f, "/v1/reviews?projectID=\(f.project)", f.reader)
        XCTAssertEqual(try row(reviews.list, s.review)["assigneeName"] as? String, "Designer")

        let center = try await get(f, "/v1/command-center?projectID=\(f.project)", f.reader)
        let card = try XCTUnwrap(cards(center).first { ($0["task"] as? [String: Any])?["id"] as? String == s.card }, "\(center.body ?? [:])")
        let question = try row(card["questions"], s.question)
        XCTAssertEqual((question["assigneeID"] as? String)?.uppercased(), f.commenter.id.uuidString)
        XCTAssertEqual(question["assigneeName"] as? String, "Commenter")
        let review = try XCTUnwrap(card["pendingReview"] as? [String: Any])
        XCTAssertEqual((review["assigneeID"] as? String)?.uppercased(), f.designer.id.uuidString)
        XCTAssertEqual((review["reviewerID"] as? String)?.uppercased(), f.designer.id.uuidString)
        XCTAssertEqual(review["assigneeName"] as? String, "Designer")
        let list = try await get(f, "/v1/command-center?projectID=\(f.project)&view=list", f.reader)
        let item = try XCTUnwrap((list.body?["items"] as? [[String: Any]])?.first { ($0["task"] as? [String: Any])?["id"] as? String == s.card })
        XCTAssertEqual((item["pendingReview"] as? [String: Any])?["assigneeName"] as? String, "Designer")
    }

    func testForMeCarriesTheNames() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let s = try await seed(f)
        let mine = try await get(f, "/v1/for-me", f.designer)
        XCTAssertEqual(try row(mine.body?["tasks"], s.card)["assigneeName"] as? String, "Designer")
        XCTAssertEqual(try row(mine.body?["reviews"], s.review)["assigneeName"] as? String, "Designer")
        let theirs = try await get(f, "/v1/for-me", f.commenter)
        XCTAssertEqual(try row(theirs.body?["questions"], s.question)["assigneeName"] as? String, "Commenter")
    }

    /// The PWA replaces its entry with the answer of a write, so those carry the name too.
    func testWriteResponsesCarryTheName() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        let task = try await f.assign(card, to: f.designer.id)
        XCTAssertEqual(task.body?["assigneeName"] as? String, "Designer", "\(task.body ?? [:])")
        let asked = try await f.ask(card, assignee: f.commenter.id)
        XCTAssertEqual(asked.body?["assigneeName"] as? String, "Commenter", "\(asked.body ?? [:])")
        let qid = try id(asked)
        let moved = try await f.t.json(.PUT, "/v1/questions/\(qid)/assignee", ["assigneeID": f.editor.id.uuidString], token: f.owner.token)
        XCTAssertEqual(moved.body?["assigneeName"] as? String, "Editor", "\(moved.body ?? [:])")
        let answered = try await f.t.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "blue"], token: f.owner.token)
        XCTAssertEqual(answered.body?["assigneeName"] as? String, "Editor", "\(answered.body ?? [:])")
        let requested = try await f.review(card, assignee: f.designer.id)
        XCTAssertEqual(requested.body?["assigneeName"] as? String, "Designer", "\(requested.body ?? [:])")
        let rid = try id(requested)
        let handed = try await f.t.json(.PUT, "/v1/reviews/\(rid)/assignee", ["assigneeID": f.editor.id.uuidString], token: f.owner.token)
        XCTAssertEqual(handed.body?["assigneeName"] as? String, "Editor", "\(handed.body ?? [:])")
        let decided = try await f.t.json(.POST, "/v1/tasks/\(card)/review/decision", ["decision": "accept"], token: f.owner.token)
        XCTAssertEqual(decided.body?["assigneeName"] as? String, "Editor", "\(decided.body ?? [:])")
        let undone = try await f.t.json(.POST, "/v1/tasks/\(card)/review/undo", token: f.owner.token)
        XCTAssertEqual(undone.body?["assigneeName"] as? String, "Editor", "\(undone.body ?? [:])")
        let batch = try await f.t.json(.POST, "/v1/reviews/decisions", ["decisions": [["reviewID": rid]], "decision": "accept"], token: f.owner.token)
        let first = (batch.body?["results"] as? [[String: Any]])?.first?["review"] as? [String: Any]
        XCTAssertEqual(first?["assigneeName"] as? String, "Editor", "\(batch.body ?? [:])")
        let claimed = try await f.t.json(.POST, "/v1/tasks/\(card)/claim", [:], token: f.owner.token)
        XCTAssertEqual((claimed.body?["task"] as? [String: Any])?["assigneeName"] as? String, "Designer", "\(claimed.body ?? [:])")
    }

    /// The stored id stays; the name only while the account still sees the project and is not locked. Nothing else about it.
    func testNameIsOmittedWithoutAccessOrWhenLocked() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let s = try await seed(f)
        let designer = try await XCTUnwrapAsync(try await User.find(f.designer.id, on: f.t.app.db))
        designer.username = "designer-login"; try await designer.save(on: f.t.app.db)
        let named = try await f.t.json(.GET, "/v1/tasks/\(s.card)/context", token: f.reader.token)
        XCTAssertFalse("\(named.body ?? [:])".contains("designer-login"))

        try await f.revoke(f.designer)
        let commenter = try await XCTUnwrapAsync(try await User.find(f.commenter.id, on: f.t.app.db))
        commenter.disabledAt = Date(); try await commenter.save(on: f.t.app.db)

        let context = try await get(f, "/v1/tasks/\(s.card)/context", f.reader)
        let task = try XCTUnwrap(context.body?["task"] as? [String: Any])
        XCTAssertEqual((task["assigneeID"] as? String)?.uppercased(), f.designer.id.uuidString)
        XCTAssertNil(task["assigneeName"])
        XCTAssertNil((context.body?["review"] as? [String: Any])?["assigneeName"])
        XCTAssertNil(try row(context.body?["questions"], s.question)["assigneeName"])
        XCTAssertEqual(try row(context.body?["subtasks"], s.subtask)["assigneeName"] as? String, "Editor")
        let center = try await get(f, "/v1/command-center?projectID=\(f.project)", f.reader)
        let card = try XCTUnwrap(cards(center).first { ($0["task"] as? [String: Any])?["id"] as? String == s.card })
        XCTAssertNil(try row(card["questions"], s.question)["assigneeName"])
        XCTAssertNil((card["pendingReview"] as? [String: Any])?["assigneeName"])
        let feed = try await get(f, "/v1/feed", f.owner)
        let need = try row(feed.body?["needsYou"], "question:\(s.question.uppercased())")
        XCTAssertNotNil(need["assigneeID"])
        XCTAssertNil(need["assigneeName"])
    }

    // MARK: Feed and summary

    /// A card of the designer: one inherited and one unassigned question, a question for the commenter, an inherited review
    /// and a waiting plan; plus an unassigned card with a review and an overdue card.
    private struct Board { let inherited, free, named, inheritedReview, freeReview, mine, other: String }
    private func board(_ f: AssignmentFixture) async throws -> Board {
        let settings = try await f.t.json(.PATCH, "/v1/projects/\(f.project)/pipeline-settings",
            ["revision": 0, "notifyOnWaitingApproval": true], token: f.owner.token)
        XCTAssertEqual(settings.status, .ok, "\(settings.body ?? [:])")
        let mine = try await f.task("Mine"), other = try await f.task("Open")
        try await f.assign(mine, to: f.designer.id)
        let inherited = try id(try await f.ask(mine, prompt: "Inherited"))
        let named = try id(try await f.ask(mine, assignee: f.commenter.id, prompt: "Named"))
        let free = try id(try await f.ask(other, prompt: "Anybody"))
        let inheritedReview = try id(try await f.review(mine))
        let freeReview = try id(try await f.review(other))
        for card in [mine, other] {
            let plan = try await f.t.json(.PUT, "/v1/tasks/\(card)/plan", ["body": "Plan"], token: f.owner.token)
            XCTAssertEqual(plan.status, .ok, "\(plan.body ?? [:])")
        }
        let due = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let planned = try await f.t.json(.PUT, "/v1/planning/tasks/\(mine)", ["priority": 0, "dueAt": due, "reminders": [String]()], token: f.owner.token)
        XCTAssertEqual(planned.status, .ok, "\(planned.body ?? [:])")
        return Board(inherited: inherited, free: free, named: named, inheritedReview: inheritedReview, freeReview: freeReview,
                     mine: mine, other: other)
    }

    func testFeedSaysWhatConcernsTheAccount() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let b = try await board(f)
        func needs(_ a: AssignmentFixture.Account) async throws -> [[String: Any]] {
            let r = try await get(f, "/v1/feed?projectID=\(f.project)", a)
            return try XCTUnwrap(r.body?["needsYou"] as? [[String: Any]])
        }
        func concern(_ rows: [[String: Any]], _ key: String, _ value: String, kind: String) throws -> Bool {
            let row = try XCTUnwrap(rows.first { $0["kind"] as? String == kind && ($0[key] as? String)?.uppercased() == value.uppercased() },
                                    "\(kind) \(value) missing in \(rows)")
            return try XCTUnwrap(row["concernsMe"] as? Bool, "\(row)")
        }
        let editor = try await needs(f.editor)
        XCTAssertFalse(try concern(editor, "questionID", b.inherited, kind: "question"))
        XCTAssertFalse(try concern(editor, "questionID", b.named, kind: "question"))
        XCTAssertTrue(try concern(editor, "questionID", b.free, kind: "question"))
        XCTAssertFalse(try concern(editor, "reviewID", b.inheritedReview, kind: "review"))
        XCTAssertTrue(try concern(editor, "reviewID", b.freeReview, kind: "review"))
        XCTAssertFalse(try concern(editor, "taskID", b.mine, kind: "plan"))
        XCTAssertTrue(try concern(editor, "taskID", b.other, kind: "plan"))

        let designer = try await needs(f.designer)
        XCTAssertTrue(try concern(designer, "questionID", b.inherited, kind: "question"))
        XCTAssertFalse(try concern(designer, "questionID", b.named, kind: "question"))
        XCTAssertTrue(try concern(designer, "reviewID", b.inheritedReview, kind: "review"))
        XCTAssertTrue(try concern(designer, "taskID", b.mine, kind: "plan"))

        // Stored on the item only: an inherited responsibility carries no id.
        let named = try XCTUnwrap(editor.first { ($0["questionID"] as? String)?.uppercased() == b.named.uppercased() })
        XCTAssertEqual((named["assigneeID"] as? String)?.uppercased(), f.commenter.id.uuidString)
        XCTAssertEqual(named["assigneeName"] as? String, "Commenter")
        let inherited = try XCTUnwrap(editor.first { ($0["questionID"] as? String)?.uppercased() == b.inherited.uppercased() })
        XCTAssertNil(inherited["assigneeID"])
        XCTAssertNil(inherited["assigneeName"])

        // A named review stays hidden from others as before and carries the name for its person.
        let moved = try await f.t.json(.PUT, "/v1/reviews/\(b.freeReview)/assignee", ["assigneeID": f.editor.id.uuidString], token: f.owner.token)
        XCTAssertEqual(moved.status, .ok, "\(moved.body ?? [:])")
        let own = try await needs(f.editor)
        let review = try XCTUnwrap(own.first { ($0["reviewID"] as? String)?.uppercased() == b.freeReview.uppercased() })
        XCTAssertEqual((review["assigneeID"] as? String)?.uppercased(), f.editor.id.uuidString)
        XCTAssertEqual(review["assigneeName"] as? String, "Editor")
        XCTAssertEqual(review["concernsMe"] as? Bool, true)
        let after = try await needs(f.designer)
        XCTAssertFalse(after.contains { ($0["reviewID"] as? String)?.uppercased() == b.freeReview.uppercased() })

        // Every other kind concerns whoever sees it.
        let owner = try await needs(f.owner)
        let due = try XCTUnwrap(owner.first { $0["kind"] as? String == "overdue" }, "\(owner)")
        XCTAssertEqual(due["concernsMe"] as? Bool, true)
    }

    func testSummaryCountsWhatConcernsTheAccount() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        _ = try await board(f)
        func summary(_ a: AssignmentFixture.Account) async throws -> [Int] {
            let r = try await get(f, "/v1/command-center?projectID=\(f.project)", a)
            let s = try XCTUnwrap(r.body?["summary"] as? [String: Any])
            return try ["openQuestions", "pendingReviews", "plansWaiting", "concerningQuestions", "concerningReviews", "concerningPlans"]
                .map { try XCTUnwrap(s[$0] as? Int, "\($0) missing in \(s)") }
        }
        // The totals stay; the concerning ones are "mine or nobody's".
        try await assertEqual(try await summary(f.designer), [3, 2, 2, 2, 2, 2])
        try await assertEqual(try await summary(f.editor), [3, 2, 2, 1, 1, 1])
        try await assertEqual(try await summary(f.commenter), [3, 2, 2, 2, 1, 1])
        // Same rule as the badge of the push notifications (questions plus reviews).
        let delivery = PushDelivery(db: f.t.app.db, sender: try APNsSender(config: PushTests.config(), transport: MockAPNs()))
        for who in [f.designer, f.editor, f.commenter] {
            let user = try await XCTUnwrapAsync(try await User.find(who.id, on: f.t.app.db))
            let badge = await delivery.badge(for: user)
            let counts = try await summary(who)
            XCTAssertEqual(badge, counts[3] + counts[4])
        }
    }

    // MARK: Contracts

    func testContractsDescribeTheAdditions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent("contracts/\(name)"), encoding: .utf8)) ?? "" }
        let assignments = read("assignments.yaml")
        XCTAssertTrue(assignments.contains("version: 1.1.0"))
        XCTAssertTrue(assignments.contains("assigneeName"))
        XCTAssertFalse(assignments.contains("assignmentNotification"))
        XCTAssertTrue(assignments.contains("commentResponsibility") && assignments.contains("reviewConsequence"))
        let push = read("push.yaml")
        XCTAssertTrue(push.contains("version: 1.4.0") && push.contains("TODO_ASSIGNMENT"))
        let feed = read("feed.yaml")
        XCTAssertTrue(feed.contains("version: 1.3.0") && feed.contains("concernsMe") && feed.contains("assigneeName"))
        let center = read("command-center.yaml")
        XCTAssertTrue(center.contains("version: 1.12.0"))
        for word in ["concerningQuestions", "concerningReviews", "concerningPlans", "assigneeName"] { XCTAssertTrue(center.contains(word), word) }
    }
}
