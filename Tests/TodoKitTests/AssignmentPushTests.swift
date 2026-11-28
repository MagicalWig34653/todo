import Fluent
import XCTVapor
@testable import TodoKit

/// Push recipients with and without a responsible person (card 8B4BAC2E, ADR 0043).
final class AssignmentPushTests: XCTestCase {
    private struct Push {
        var f: AssignmentFixture
        let mock: MockAPNs
        let sender: APNsSender
        var people: [PushTests.Account] { [f.owner, f.designer, f.editor, f.commenter, f.reader, f.stranger] }
        var worker: PushWorker { PushWorker(app: f.t.app, sender: sender, interval: 0) }

        static func make() async throws -> Push {
            let f = try await AssignmentFixture.make()
            let cfg = PushTests.config()
            f.t.app.settings.apns = cfg
            let mock = MockAPNs()
            let push = Push(f: f, mock: mock, sender: try APNsSender(config: cfg, transport: mock))
            for (index, who) in push.people.enumerated() {
                let r = try await f.t.json(.POST, "/v1/push/devices", ["token": String(format: "%064x", index + 1), "platform": "ios",
                    "environment": "sandbox", "bundleId": "de.linolaske.todo"], token: who.token)
                XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
            }
            return push
        }

        /// Names of the accounts whose device received a notification of `kind` for `subject` (id of question or review).
        func recipients(_ kind: String, subject: String? = nil) throws -> Set<String> {
            let names = ["Owner", "Designer", "Editor", "Commenter", "Reader", "Stranger"]
            var result = Set<String>()
            for request in mock.requests {
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                guard payload["kind"] as? String == kind,
                      subject == nil || (payload["subjectID"] as? String)?.lowercased() == subject?.lowercased() else { continue }
                let index = try XCTUnwrap((0..<names.count).first { request.deviceToken == String(format: "%064x", $0 + 1) })
                result.insert(names[index])
            }
            return result
        }
    }

    private func id(_ r: (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)) throws -> String {
        try XCTUnwrap(r.body?["id"] as? String, "\(r.body ?? [:])")
    }

    /// Today's behaviour, pinned: without any assignment questions reach everybody who may answer, reviews everybody who may decide.
    func testWithoutResponsibilityRecipientsAreUnchanged() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card))
        let v = try id(try await p.f.review(card))
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Designer", "Editor", "Commenter"])
        XCTAssertEqual(try p.recipients("review", subject: v), ["Designer", "Editor"])
    }

    func testOnlyTheAssigneeIsNotified() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card, assignee: p.f.commenter.id))
        let v = try id(try await p.f.review(card, assignee: p.f.designer.id))
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Commenter"])
        XCTAssertEqual(try p.recipients("review", subject: v), ["Designer"])
    }

    func testCardAssigneeIsResponsibleUnlessTheItemNamesSomebodyElse() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task(), second = try await p.f.task("Second")
        try await p.f.assign(card, to: p.f.designer.id)
        try await p.f.assign(second, to: p.f.designer.id)
        let inherited = try id(try await p.f.ask(card))
        let named = try id(try await p.f.ask(card, assignee: p.f.editor.id, prompt: "Named"))
        let v = try id(try await p.f.review(card))
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: inherited), ["Designer"])
        XCTAssertEqual(try p.recipients("question", subject: named), ["Editor"])
        XCTAssertEqual(try p.recipients("review", subject: v), ["Designer"])
    }

    /// A reader may own a card but cannot answer or decide: for questions and reviews nobody is responsible then.
    func testCardAssigneeWithoutTheNeededRightLeavesRecipientsUnchanged() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        try await p.f.assign(card, to: p.f.reader.id)
        let q = try id(try await p.f.ask(card))
        let v = try id(try await p.f.review(card))
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Designer", "Editor", "Commenter"])
        XCTAssertEqual(try p.recipients("review", subject: v), ["Designer", "Editor"])
    }

    func testRevokedAssigneeGetsNothingAndTheOthersAreNotifiedAsBefore() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card, assignee: p.f.designer.id))
        let v = try id(try await p.f.review(card, assignee: p.f.designer.id, by: p.f.editor))
        try await p.f.revoke(p.f.designer)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Editor", "Commenter"])
        // A named reviewer without access: deciding stays with the project management (rule unchanged), so only they are told.
        let denied = try await p.f.t.json(.POST, "/v1/tasks/\(card)/review/decision", ["decision": "accept"], token: p.f.editor.token)
        XCTAssertEqual(AssignmentFixture.reason(denied), "not_the_reviewer")
        XCTAssertEqual(try p.recipients("review", subject: v), ["Owner"])
    }

    /// The send step checks again: a notification queued before the reassignment does not reach the old person.
    func testQueuedNotificationIsDroppedAfterReassignment() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card))
        let db = p.f.t.app.db
        let queued = try await PushTriggers(db: db, candidates: try await Candidate.load(on: db), since: Date().addingTimeInterval(-3600), now: Date()).run()
        XCTAssertEqual(queued, 3)
        let moved = try await p.f.t.json(.PUT, "/v1/questions/\(q)/assignee", ["assigneeID": p.f.commenter.id.uuidString], token: p.f.owner.token)
        XCTAssertEqual(moved.status, .ok, "\(moved.body ?? [:])")
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Commenter"])
    }

    /// Assigning an older open item notifies the new person, although the item itself is outside the lookback window.
    func testAssigningAnOlderOpenItemNotifiesTheNewPerson() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card))
        let v = try id(try await p.f.review(card))
        let db = p.f.t.app.db
        let old = Date().addingTimeInterval(-48 * 3600)
        let question = try await XCTUnwrapAsync(try await TaskQuestion.find(UUID(uuidString: q), on: db))
        question.createdAt = old; try await question.save(on: db)
        let review = try await XCTUnwrapAsync(try await TaskReview.find(UUID(uuidString: v), on: db))
        review.createdAt = old; try await review.save(on: db)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question"), [])
        XCTAssertEqual(try p.recipients("review"), [])
        _ = try await p.f.t.json(.PUT, "/v1/questions/\(q)/assignee", ["assigneeID": p.f.commenter.id.uuidString], token: p.f.owner.token)
        _ = try await p.f.t.json(.PUT, "/v1/reviews/\(v)/assignee", ["assigneeID": p.f.designer.id.uuidString], token: p.f.owner.token)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Commenter"])
        XCTAssertEqual(try p.recipients("review", subject: v), ["Designer"])
    }

    /// Handing an item back and forth, or clearing it, must not flood anybody: one notification per person and item.
    func testRepeatedReassignmentNotifiesEachPersonOnce() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card, assignee: p.f.commenter.id))
        _ = await p.worker.runIfDue()
        func move(_ to: UUID?) async throws {
            let r = try await p.f.t.json(.PUT, "/v1/questions/\(q)/assignee", ["assigneeID": to.map { $0.uuidString as Any } ?? NSNull()], token: p.f.owner.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            // Dedupe keys must not depend on the clock: wait for a new second between two hand-overs.
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = await p.worker.runIfDue()
        }
        try await move(p.f.designer.id)
        let afterFirst = p.mock.requests.count
        try await move(p.f.commenter.id)
        try await move(p.f.designer.id)
        try await move(p.f.commenter.id)
        XCTAssertEqual(p.mock.requests.count, afterFirst + 1, "the commenter hears once about getting it back, nobody again")
        // Clearing tells the people who have not heard of it yet, once.
        try await move(nil)
        let afterClear = p.mock.requests.count
        try await move(p.f.designer.id)
        try await move(nil)
        XCTAssertEqual(p.mock.requests.count, afterClear)
    }

    /// A notification dropped because the item had moved on is sent after all when the item comes back.
    func testDroppedNotificationIsSentWhenTheItemComesBack() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let q = try id(try await p.f.ask(card, assignee: p.f.owner.id, by: p.f.editor))
        let db = p.f.t.app.db
        func move(_ to: UUID) async throws {
            let r = try await p.f.t.json(.PUT, "/v1/questions/\(q)/assignee", ["assigneeID": to.uuidString], token: p.f.owner.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        }
        try await move(p.f.designer.id)
        _ = try await PushTriggers(db: db, candidates: try await Candidate.load(on: db), since: Date().addingTimeInterval(-3600), now: Date()).run()
        try await move(p.f.commenter.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Commenter"])
        try await move(p.f.designer.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients("question", subject: q), ["Commenter", "Designer"])
    }

    func testRemindersGoToTheCardAssignee() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let plain = try await p.f.task("plain"), assigned = try await p.f.task("assigned")
        try await p.f.assign(assigned, to: p.f.designer.id)
        for card in [plain, assigned] {
            let r = try await p.f.t.json(.PUT, "/v1/planning/tasks/\(card)", ["priority": 0, "reminders": [at]], token: p.f.owner.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        }
        _ = await p.worker.runIfDue()
        var byTask: [String: Set<String>] = [:]
        for request in p.mock.requests {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            guard payload["kind"] as? String == "reminder", let task = payload["taskID"] as? String else { continue }
            byTask[task.lowercased(), default: []].insert(request.deviceToken == String(format: "%064x", 1) ? "Owner"
                : request.deviceToken == String(format: "%064x", 2) ? "Designer" : "other")
        }
        XCTAssertEqual(byTask[plain.lowercased()], ["Owner"])
        XCTAssertEqual(byTask[assigned.lowercased()], ["Designer"])
    }

    /// The badge counts what still concerns the account: items that somebody else is responsible for drop out.
    func testBadgeLeavesOutItemsOfOtherPeople() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        _ = try await p.f.ask(card, assignee: p.f.commenter.id)
        _ = try await p.f.ask(card, prompt: "Anybody")
        _ = try await p.f.review(card, assignee: p.f.designer.id)
        let db = p.f.t.app.db
        let delivery = PushDelivery(db: db, sender: p.sender)
        let designer = try await XCTUnwrapAsync(try await User.find(p.f.designer.id, on: db))
        let editor = try await XCTUnwrapAsync(try await User.find(p.f.editor.id, on: db))
        let designerBadge = await delivery.badge(for: designer), editorBadge = await delivery.badge(for: editor)
        XCTAssertEqual(designerBadge, 2)
        XCTAssertEqual(editorBadge, 1)
    }
}
