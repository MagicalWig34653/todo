import Fluent
import XCTVapor
@testable import TodoKit

/// The notification for being made responsible for a card (card E9300901, category `assignments`, off by default).
final class AssignmentNotificationTests: XCTestCase {
    private struct Push {
        var f: AssignmentFixture
        let mock: MockAPNs
        let sender: APNsSender
        static let names = ["Owner", "Designer", "Editor", "Commenter", "Reader", "Stranger"]
        var people: [AssignmentFixture.Account] { [f.owner, f.designer, f.editor, f.commenter, f.reader, f.stranger] }
        var worker: PushWorker { PushWorker(app: f.t.app, sender: sender, interval: 0) }

        /// Every account has one device and, unless `optIn` is false, the category switched on.
        static func make(optIn: Bool = true, locale: String? = nil) async throws -> Push {
            let f = try await AssignmentFixture.make()
            let cfg = PushTests.config()
            f.t.app.settings.apns = cfg
            let mock = MockAPNs()
            let push = Push(f: f, mock: mock, sender: try APNsSender(config: cfg, transport: mock))
            for (index, who) in push.people.enumerated() {
                var device: [String: Any] = ["token": String(format: "%064x", index + 1), "platform": "ios",
                    "environment": "sandbox", "bundleId": "de.linolaske.todo"]
                if let locale { device["locale"] = locale }
                let r = try await f.t.json(.POST, "/v1/push/devices", device, token: who.token)
                XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
                if optIn { try await push.prefs(who, ["categories": ["assignments": true]]) }
            }
            return push
        }

        func prefs(_ who: AssignmentFixture.Account, _ body: [String: Any]) async throws {
            let r = try await f.t.json(.POST, "/v1/me/push-prefs", body, token: who.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        }

        /// Queues the triggers without sending, so that a test can change something in between.
        @discardableResult
        func enqueue() async throws -> Int {
            let db = f.t.app.db
            return try await PushTriggers(db: db, candidates: try await Candidate.load(on: db), since: Date().addingTimeInterval(-3600), now: Date()).run()
        }

        /// Assignment notifications as (account, payload), in sending order.
        func received() throws -> [(String, [String: Any])] {
            try mock.requests.compactMap { request in
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                guard payload["kind"] as? String == "assignment" else { return nil }
                let index = try XCTUnwrap((0..<Self.names.count).first { request.deviceToken == String(format: "%064x", $0 + 1) })
                return (Self.names[index], payload)
            }
        }
        func recipients() throws -> [String] { try received().map(\.0) }
    }

    private func assign(_ p: Push, _ card: String, to who: UUID?, by: AssignmentFixture.Account? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await p.f.assign(card, to: who, by: by)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
    }

    func testTheCategoryIsOffByDefault() async throws {
        let p = try await Push.make(optIn: false); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        try await assign(p, card, to: p.f.designer.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), [])
    }

    func testOnlyTheNewPersonIsToldWithAGenericText() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task("Secret card title")
        try await assign(p, card, to: p.f.designer.id)
        _ = await p.worker.runIfDue()
        _ = await p.worker.runIfDue()
        let received = try p.received()
        XCTAssertEqual(received.map(\.0), ["Designer"])
        let payload = try XCTUnwrap(received.first?.1)
        let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "TODO_ASSIGNMENT")
        XCTAssertEqual((payload["taskID"] as? String)?.uppercased(), card.uppercased())
        XCTAssertEqual((payload["projectID"] as? String)?.uppercased(), p.f.project.uppercased())
        XCTAssertNil(payload["subjectID"])
        // The badge counts questions and reviews only, as before.
        XCTAssertEqual(aps["badge"] as? Int, 0)
        let alert = try XCTUnwrap(aps["alert"] as? [String: String])
        XCTAssertEqual(alert, ["title": "Neue Zuständigkeit", "body": "Dir wurde eine Karte zugewiesen."])
    }

    func testEnglishAndContentOptInShowOnlyTheCardTitle() async throws {
        let p = try await Push.make(locale: "en-GB"); defer { Task { await p.f.t.shutdown() } }
        try await p.prefs(p.f.editor, ["showContent": true])
        let card = try await p.f.task("Quarterly colours")
        let details = try await p.f.t.json(.PATCH, "/v1/tasks/\(card)", ["description": "never in a push", "version": 1], token: p.f.owner.token)
        XCTAssertEqual(details.status, .ok, "\(details.body ?? [:])")
        let second = try await p.f.task("Hidden")
        try await assign(p, card, to: p.f.editor.id)
        try await assign(p, second, to: p.f.designer.id)
        _ = await p.worker.runIfDue()
        var alerts: [String: [String: String]] = [:]
        for (who, payload) in try p.received() { alerts[who] = (payload["aps"] as? [String: Any])?["alert"] as? [String: String] }
        XCTAssertEqual(alerts["Editor"], ["title": "Quarterly colours", "body": "Assigned to you"])
        XCTAssertEqual(alerts["Designer"], ["title": "New assignment", "body": "A card was assigned to you."])
    }

    func testAssigningYourselfIsSilent() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        try await assign(p, card, to: p.f.designer.id, by: p.f.designer)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), [])
        // Somebody else handing it over later is news.
        try await assign(p, card, to: nil)
        try await assign(p, card, to: p.f.designer.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), ["Designer"])
    }

    /// Taking a card for yourself ends an announcement somebody else caused earlier and that was not sent yet.
    func testTakingItYourselfAfterAHandOverIsSilent() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        try await assign(p, card, to: p.f.designer.id)
        try await assign(p, card, to: nil)
        try await assign(p, card, to: p.f.designer.id, by: p.f.designer)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), [])
    }

    func testOncePerPersonAndCard() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task(), second = try await p.f.task("Second")
        for who in [p.f.designer, p.f.commenter, p.f.designer, p.f.commenter] {
            try await assign(p, card, to: who.id)
            _ = await p.worker.runIfDue()
        }
        XCTAssertEqual(try p.recipients(), ["Designer", "Commenter"])
        try await assign(p, second, to: p.f.designer.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), ["Designer", "Commenter", "Designer"])
    }

    func testADroppedNotificationIsSentWhenTheCardComesBack() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        try await assign(p, card, to: p.f.designer.id)
        let queued = try await p.enqueue()
        XCTAssertEqual(queued, 1)
        try await assign(p, card, to: p.f.commenter.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), ["Commenter"])
        try await assign(p, card, to: p.f.designer.id)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), ["Commenter", "Designer"])
    }

    func testCheckedAgainBeforeSending() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let done = try await p.f.task("done"), cleared = try await p.f.task("cleared"),
            muted = try await p.f.task("muted"), revoked = try await p.f.task("revoked")
        try await assign(p, done, to: p.f.designer.id)
        try await assign(p, cleared, to: p.f.editor.id)
        try await assign(p, muted, to: p.f.commenter.id)
        try await assign(p, revoked, to: p.f.reader.id)
        let queued = try await p.enqueue()
        XCTAssertEqual(queued, 4)
        let finished = try await p.f.t.json(.PATCH, "/v1/tasks/\(done)", ["status": "done", "version": 2], token: p.f.owner.token)
        XCTAssertEqual(finished.status, .ok, "\(finished.body ?? [:])")
        try await assign(p, cleared, to: nil)
        try await p.prefs(p.f.commenter, ["categories": ["assignments": false]])
        try await p.f.revoke(p.f.reader)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), [])
    }

    /// Nothing is even queued for a finished card or an account without access any more.
    func testNothingIsQueuedForFinishedCardsOrLostAccess() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let done = try await p.f.task("done"), revoked = try await p.f.task("revoked")
        try await assign(p, done, to: p.f.designer.id)
        let finished = try await p.f.t.json(.PATCH, "/v1/tasks/\(done)", ["status": "done", "version": 2], token: p.f.owner.token)
        XCTAssertEqual(finished.status, .ok, "\(finished.body ?? [:])")
        try await assign(p, revoked, to: p.f.reader.id)
        try await p.f.revoke(p.f.reader)
        let refused = try await p.f.assign(revoked, to: p.f.stranger.id)
        XCTAssertEqual(AssignmentFixture.reason(refused), "invalid_assignee")
        let queued = try await p.enqueue()
        XCTAssertEqual(queued, 0)
    }

    /// Cards stored directly, each with one newer `task.assigned` event by the owner (more than one page of events).
    private func assignedCards(_ p: Push, count: Int, to assignee: UUID?, status: String? = nil) async throws {
        let db = p.f.t.app.db
        let project = try XCTUnwrap(UUID(uuidString: p.f.project))
        for index in 0..<count {
            let task = TodoTask(ownerID: p.f.owner.id, projectID: project, title: "Bulk \(index)", details: "")
            task.assigneeID = assignee
            if let status { task.status = status }
            try await task.save(on: db)
            try await appendActivity(taskID: try task.requireID(), actorType: .person, actorID: p.f.owner.id,
                                     kind: "task.assigned", subjectID: nil, on: db)
        }
    }

    func testNewerIrrelevantEventsDoNotCrowdOutAnAssignment() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        try await p.prefs(p.f.editor, ["categories": ["assignments": false]])
        let card = try await p.f.task()
        try await assign(p, card, to: p.f.designer.id)
        // Newer than the assignment above: nobody responsible, a person without the category, finished cards.
        try await assignedCards(p, count: 70, to: nil)
        try await assignedCards(p, count: 70, to: p.f.editor.id)
        try await assignedCards(p, count: 70, to: p.f.designer.id, status: "done")
        let queued = try await p.enqueue()
        XCTAssertEqual(queued, 1)
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), ["Designer"])
    }

    func testMoreAssignmentsThanOnePageAreAllQueued() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        try await assignedCards(p, count: 205, to: p.f.designer.id)
        let queued = try await p.enqueue()
        XCTAssertEqual(queued, 205)
        let again = try await p.enqueue()
        XCTAssertEqual(again, 0)
    }

    /// An agent handing a card to the person of its own connection is not that person assigning themselves.
    func testAnAgentAssigningACardNotifiesThePerson() async throws {
        let p = try await Push.make(); defer { Task { await p.f.t.shutdown() } }
        let card = try await p.f.task()
        let user = try await XCTUnwrapAsync(try await User.find(p.f.owner.id, on: p.f.t.app.db))
        let service = WorkflowService(user: user, db: p.f.t.app.db)
        _ = try await service.assignTask(try XCTUnwrap(UUID(uuidString: card)), to: p.f.owner.id,
            actor: .integration(grantID: UUID(), label: "Agent"))
        _ = await p.worker.runIfDue()
        XCTAssertEqual(try p.recipients(), ["Owner"])
    }
}
