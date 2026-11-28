import Fluent
import XCTVapor
@testable import TodoKit

/// Shared fixture of the responsibility tests (card 8B4BAC2E): an owner, a designer, a commenter, a reader and a stranger.
struct AssignmentFixture {
    typealias Account = PushTests.Account
    let t: TestApp
    let owner, designer, editor, commenter, reader, stranger: Account
    let project: String
    var grants: [UUID: String] = [:]

    static func make() async throws -> AssignmentFixture {
        let t = try await TestApp.make()
        var people: [PushTests.Account] = []
        for name in ["Owner", "Designer", "Editor", "Commenter", "Reader", "Stranger"] { people.append(try await PushTests.account(t, name)) }
        let p = try await t.json(.POST, "/v1/projects", ["name": "Shared"], token: people[0].token)
        var f = AssignmentFixture(t: t, owner: people[0], designer: people[1], editor: people[2], commenter: people[3],
                                  reader: people[4], stranger: people[5], project: try XCTUnwrap(p.body?["id"] as? String))
        try await f.grant(f.designer, "edit"); try await f.grant(f.editor, "edit")
        try await f.grant(f.commenter, "comment"); try await f.grant(f.reader, "read")
        return f
    }

    mutating func grant(_ a: Account, _ role: String, project override: String? = nil) async throws {
        let r = try await t.json(.PUT, "/v1/projects/\(override ?? project)/grants",
            ["principalType": "person", "principalID": a.id.uuidString, "role": role], token: owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        if override == nil { grants[a.id] = try XCTUnwrap(r.body?["id"] as? String) }
    }

    func revoke(_ a: Account) async throws {
        let id = try XCTUnwrap(grants[a.id])
        let r = try await t.json(.DELETE, "/v1/projects/\(project)/grants/\(id)", token: owner.token)
        XCTAssertEqual(r.status, .noContent, "\(r.body ?? [:])")
    }

    func task(_ title: String = "Card", in override: String? = nil) async throws -> String {
        let r = try await t.json(.POST, "/v1/tasks", ["projectID": override ?? project, "title": title], token: owner.token)
        return try XCTUnwrap(r.body?["id"] as? String, "\(r.body ?? [:])")
    }

    @discardableResult
    func assign(_ task: String, to a: UUID?, by: Account? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        try await t.json(.PUT, "/v1/tasks/\(task)/assignee", ["assigneeID": a.map { $0.uuidString as Any } ?? NSNull()], token: (by ?? owner).token)
    }

    func ask(_ task: String, assignee: UUID? = nil, by: Account? = nil, prompt: String = "Which colour?") async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        var body: [String: Any] = ["prompt": prompt]
        if let assignee { body["assigneeID"] = assignee.uuidString }
        return try await t.json(.POST, "/v1/tasks/\(task)/questions", body, token: (by ?? owner).token)
    }

    func review(_ task: String, assignee: UUID? = nil, by: Account? = nil, key: String = "assigneeID") async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        var body: [String: Any] = ["summary": "Please look at it"]
        if let assignee { body[key] = assignee.uuidString }
        return try await t.json(.POST, "/v1/tasks/\(task)/review", body, token: (by ?? owner).token)
    }

    struct ForMe { let tasks: Set<String>; let questions: Set<String>; let reviews: Set<String> }
    func forMe(_ a: Account, query: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> ForMe {
        let r = try await t.json(.GET, "/v1/for-me\(query)", token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
        func ids(_ key: String) throws -> Set<String> {
            Set(try XCTUnwrap(r.body?[key] as? [[String: Any]], "\(key) missing in \(r.body ?? [:])", file: file, line: line).compactMap { $0["id"] as? String })
        }
        return ForMe(tasks: try ids("tasks"), questions: try ids("questions"), reviews: try ids("reviews"))
    }

    static func reason(_ r: (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)) -> String? { r.body?["reason"] as? String }
}

/// Rights of responsibility: who may be assigned, who may reassign, and what "for me" returns (ADR 0043).
final class AssignmentTests: XCTestCase {
    func testOnlyPersonsWithProjectAccessCanBeAssigned() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        // A stranger, an unknown id and a locked account get the same answer: no hint whether an account exists.
        for id in [f.stranger.id, UUID()] {
            let r = try await f.assign(card, to: id)
            XCTAssertEqual(r.status, .badRequest, "\(r.body ?? [:])")
            XCTAssertEqual(AssignmentFixture.reason(r), "invalid_assignee")
            let q = try await f.ask(card, assignee: id)
            XCTAssertEqual(q.status, .badRequest, "\(q.body ?? [:])")
            XCTAssertEqual(AssignmentFixture.reason(q), "invalid_assignee")
            let v = try await f.review(card, assignee: id)
            XCTAssertEqual(v.status, .badRequest, "\(v.body ?? [:])")
            XCTAssertEqual(AssignmentFixture.reason(v), "invalid_assignee")
        }
        let user = try await XCTUnwrapAsync(try await User.find(f.editor.id, on: f.t.app.db))
        user.disabledAt = Date(); try await user.save(on: f.t.app.db)
        let locked = try await f.assign(card, to: f.editor.id)
        XCTAssertEqual(AssignmentFixture.reason(locked), "invalid_assignee")
        // A card may belong to anyone who can see it; a question needs somebody who can answer, a review somebody who can decide.
        let reader = try await f.assign(card, to: f.reader.id)
        XCTAssertEqual(reader.status, .ok, "\(reader.body ?? [:])")
        XCTAssertEqual((reader.body?["assigneeID"] as? String)?.uppercased(), f.reader.id.uuidString)
        let readerQuestion = try await f.ask(card, assignee: f.reader.id)
        XCTAssertEqual(AssignmentFixture.reason(readerQuestion), "invalid_assignee")
        let commenterReview = try await f.review(card, assignee: f.commenter.id)
        XCTAssertEqual(AssignmentFixture.reason(commenterReview), "invalid_assignee")
        let legacyName = try await f.review(card, assignee: f.stranger.id, key: "reviewerID")
        XCTAssertEqual(AssignmentFixture.reason(legacyName), "invalid_reviewer")
        let commenterQuestion = try await f.ask(card, assignee: f.commenter.id)
        XCTAssertEqual(commenterQuestion.status, .created, "\(commenterQuestion.body ?? [:])")
        XCTAssertEqual((commenterQuestion.body?["assigneeID"] as? String)?.uppercased(), f.commenter.id.uuidString)
        let designerReview = try await f.review(card, assignee: f.designer.id)
        XCTAssertEqual(designerReview.status, .ok, "\(designerReview.body ?? [:])")
        XCTAssertEqual((designerReview.body?["assigneeID"] as? String)?.uppercased(), f.designer.id.uuidString)
        XCTAssertEqual((designerReview.body?["reviewerID"] as? String)?.uppercased(), f.designer.id.uuidString)
    }

    func testReviewRejectsTwoDifferentAssignees() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        let r = try await f.t.json(.POST, "/v1/tasks/\(card)/review",
            ["summary": "s", "assigneeID": f.designer.id.uuidString, "reviewerID": f.editor.id.uuidString], token: f.owner.token)
        XCTAssertEqual(r.status, .badRequest, "\(r.body ?? [:])")
        XCTAssertEqual(AssignmentFixture.reason(r), "conflicting_assignee")
    }

    func testReassigningNeedsEditAndANamedReviewCannotBeTakenOver() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        for who in [f.reader, f.commenter] {
            let r = try await f.assign(card, to: f.designer.id, by: who)
            XCTAssertEqual(r.status, .forbidden, "\(r.body ?? [:])")
        }
        let outsider = try await f.assign(card, to: f.designer.id, by: f.stranger)
        XCTAssertEqual(outsider.status, .notFound)
        let q = try await f.ask(card, assignee: f.designer.id)
        let qid = try XCTUnwrap(q.body?["id"] as? String, "\(q.body ?? [:])")
        let qDenied = try await f.t.json(.PUT, "/v1/questions/\(qid)/assignee", ["assigneeID": f.commenter.id.uuidString], token: f.commenter.token)
        XCTAssertEqual(qDenied.status, .forbidden, "\(qDenied.body ?? [:])")
        let qMoved = try await f.t.json(.PUT, "/v1/questions/\(qid)/assignee", ["assigneeID": f.commenter.id.uuidString], token: f.editor.token)
        XCTAssertEqual(qMoved.status, .ok, "\(qMoved.body ?? [:])")
        XCTAssertEqual((qMoved.body?["assigneeID"] as? String)?.uppercased(), f.commenter.id.uuidString)

        let v = try await f.review(card, assignee: f.designer.id)
        let vid = try XCTUnwrap(v.body?["id"] as? String, "\(v.body ?? [:])")
        // Another editor must not redirect (or clear) a named review: that would lift "only the reviewer or a manager decides".
        let target: [Any] = [f.editor.id.uuidString, NSNull()]
        for value in target {
            let r = try await f.t.json(.PUT, "/v1/reviews/\(vid)/assignee", ["assigneeID": value], token: f.editor.token)
            XCTAssertEqual(r.status, .forbidden, "\(r.body ?? [:])")
            XCTAssertEqual(AssignmentFixture.reason(r), "not_the_reviewer")
        }
        let byReviewer = try await f.t.json(.PUT, "/v1/reviews/\(vid)/assignee", ["assigneeID": f.editor.id.uuidString], token: f.designer.token)
        XCTAssertEqual(byReviewer.status, .ok, "\(byReviewer.body ?? [:])")
        let byManager = try await f.t.json(.PUT, "/v1/reviews/\(vid)/assignee", ["assigneeID": f.designer.id.uuidString], token: f.owner.token)
        XCTAssertEqual(byManager.status, .ok, "\(byManager.body ?? [:])")

        // A closed question keeps its history.
        let answered = try await f.t.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "blue"], token: f.owner.token)
        XCTAssertEqual(answered.status, .ok, "\(answered.body ?? [:])")
        let late = try await f.t.json(.PUT, "/v1/questions/\(qid)/assignee", ["assigneeID": f.editor.id.uuidString], token: f.owner.token)
        XCTAssertEqual(late.status, .conflict, "\(late.body ?? [:])")
        XCTAssertEqual(AssignmentFixture.reason(late), "question_not_open")
    }

    func testForMeReturnsOnlyOpenItemsOfTheCaller() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let mine = try await f.task("Designer card"), done = try await f.task("Done card"), free = try await f.task("Unassigned")
        try await f.assign(mine, to: f.designer.id)
        try await f.assign(done, to: f.designer.id)
        let finished = try await f.t.json(.PATCH, "/v1/tasks/\(done)", ["version": 2, "status": "done"], token: f.owner.token)
        XCTAssertEqual(finished.status, .ok, "\(finished.body ?? [:])")
        // Explicit question on an unassigned card, and one inherited from the card's assignee.
        let explicit = try await f.ask(free, assignee: f.designer.id)
        let inherited = try await f.ask(mine, prompt: "Inherited?")
        // Nobody is responsible for this one: it is in nobody's "for me".
        _ = try await f.ask(free, prompt: "For anybody")
        // The review on the designer's card is explicitly for the owner.
        let forOwner = try await f.review(mine, assignee: f.owner.id, by: f.editor)
        let explicitID = try XCTUnwrap(explicit.body?["id"] as? String, "\(explicit.body ?? [:])")
        let inheritedID = try XCTUnwrap(inherited.body?["id"] as? String)
        let reviewID = try XCTUnwrap(forOwner.body?["id"] as? String, "\(forOwner.body ?? [:])")

        let designer = try await f.forMe(f.designer)
        XCTAssertEqual(designer.tasks, [mine])
        XCTAssertEqual(designer.questions, [explicitID, inheritedID])
        XCTAssertEqual(designer.reviews, [])
        let owner = try await f.forMe(f.owner)
        XCTAssertEqual(owner.tasks, [])
        XCTAssertEqual(owner.questions, [])
        XCTAssertEqual(owner.reviews, [reviewID])
        for other in [f.editor, f.commenter, f.reader, f.stranger] {
            let list = try await f.forMe(other)
            XCTAssertTrue(list.tasks.isEmpty && list.questions.isEmpty && list.reviews.isEmpty)
        }
        _ = try await f.t.json(.POST, "/v1/questions/\(explicitID)/answer", ["answer": "yes"], token: f.designer.token)
        let after = try await f.forMe(f.designer)
        XCTAssertEqual(after.questions, [inheritedID])
        let foreign = try await f.t.json(.GET, "/v1/for-me?projectID=\(f.project)", token: f.stranger.token)
        XCTAssertEqual(foreign.status, .notFound)
        let anonymous = try await f.t.json(.GET, "/v1/for-me")
        XCTAssertEqual(anonymous.status, .unauthorized)
    }

    /// The card assignee who asks does not receive the own question: it still waits for somebody else.
    func testOwnQuestionOnOwnCardIsNotInheritedByTheAuthor() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        try await f.assign(card, to: f.designer.id)
        let asked = try await f.ask(card, by: f.designer)
        XCTAssertEqual(asked.status, .created)
        let list = try await f.forMe(f.designer)
        XCTAssertEqual(list.tasks, [card])
        XCTAssertEqual(list.questions, [])
    }

    func testRevokedAccessEmptiesForMeAndRefusesNewAssignments() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        try await f.assign(card, to: f.designer.id)
        let q = try await f.ask(card, assignee: f.designer.id)
        XCTAssertEqual(q.status, .created, "\(q.body ?? [:])")
        let v = try await f.review(card, assignee: f.designer.id)
        XCTAssertEqual(v.status, .ok, "\(v.body ?? [:])")
        let before = try await f.forMe(f.designer)
        XCTAssertEqual([before.tasks.count, before.questions.count, before.reviews.count], [1, 1, 1])

        try await f.revoke(f.designer)
        let after = try await f.forMe(f.designer)
        XCTAssertEqual([after.tasks.count, after.questions.count, after.reviews.count], [0, 0, 0])
        let again = try await f.assign(card, to: f.designer.id)
        XCTAssertEqual(AssignmentFixture.reason(again), "invalid_assignee")
        let other = try await f.task("Second")
        let newQuestion = try await f.ask(other, assignee: f.designer.id)
        XCTAssertEqual(AssignmentFixture.reason(newQuestion), "invalid_assignee")
    }

    func testDowngradedRoleHidesItemsTheCallerCanNoLongerActOn() async throws {
        var f = try await AssignmentFixture.make()
        let t = f.t; defer { Task { await t.shutdown() } }
        let card = try await f.task()
        try await f.assign(card, to: f.designer.id)
        _ = try await f.ask(card, assignee: f.designer.id)
        _ = try await f.review(card, assignee: f.designer.id)
        try await f.grant(f.designer, "read")
        let list = try await f.forMe(f.designer)
        XCTAssertEqual(list.tasks, [card])
        XCTAssertEqual(list.questions, [])
        XCTAssertEqual(list.reviews, [])
    }

    func testMovingACardDropsAnAssigneeWithoutAccessToTheTarget() async throws {
        var f = try await AssignmentFixture.make()
        let t = f.t; defer { Task { await t.shutdown() } }
        let other = try await f.t.json(.POST, "/v1/projects", ["name": "Elsewhere"], token: f.owner.token)
        let otherID = try XCTUnwrap(other.body?["id"] as? String)
        try await f.grant(f.editor, "edit", project: otherID)
        let loses = try await f.task("loses"), keeps = try await f.task("keeps")
        try await f.assign(loses, to: f.designer.id)
        try await f.assign(keeps, to: f.editor.id)
        for (card, expected) in [(loses, nil), (keeps, f.editor.id)] as [(String, UUID?)] {
            let moved = try await f.t.json(.PATCH, "/v1/tasks/\(card)", ["version": 2, "projectID": otherID], token: f.owner.token)
            XCTAssertEqual(moved.status, .ok, "\(moved.body ?? [:])")
            XCTAssertEqual((moved.body?["assigneeID"] as? String)?.uppercased(), expected?.uuidString)
        }
    }

    func testAssigneeListIsForEditorsAndShowsOnlyNameAndID() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        // A team member counts through the team grant.
        let teamMember = try await PushTests.account(f.t, "Teammate")
        let team = try await f.t.json(.POST, "/v1/teams", ["name": "Crew"], token: f.owner.token)
        let teamID = try XCTUnwrap(team.body?["id"] as? String, "\(team.body ?? [:])")
        try await TeamMembership(teamID: try XCTUnwrap(UUID(uuidString: teamID)), userID: teamMember.id, isAdmin: false, accepted: true).save(on: f.t.app.db)
        let invited = try await PushTests.account(f.t, "Invited")
        try await TeamMembership(teamID: try XCTUnwrap(UUID(uuidString: teamID)), userID: invited.id, isAdmin: false, accepted: false).save(on: f.t.app.db)
        let grant = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants", ["principalType": "team", "principalID": teamID, "role": "comment"], token: f.owner.token)
        XCTAssertEqual(grant.status, .ok, "\(grant.body ?? [:])")

        let r = try await f.t.json(.GET, "/v1/projects/\(f.project)/assignees", token: f.editor.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let rows = try XCTUnwrap(r.list)
        XCTAssertEqual(Set(rows.compactMap { $0["displayName"] as? String }), ["Owner", "Designer", "Editor", "Commenter", "Reader", "Teammate"])
        for row in rows { XCTAssertEqual(Set(row.keys), ["userID", "displayName", "assignableTo", "isMe"]) }
        func kinds(_ name: String) -> [String]? { rows.first { $0["displayName"] as? String == name }?["assignableTo"] as? [String] }
        XCTAssertEqual(kinds("Reader"), ["task"])
        XCTAssertEqual(kinds("Teammate"), ["task", "question"])
        XCTAssertEqual(kinds("Designer"), ["task", "question", "review"])
        XCTAssertEqual(rows.first { $0["isMe"] as? Bool == true }?["displayName"] as? String, "Editor")
        for who in [f.reader, f.commenter] {
            let denied = try await f.t.json(.GET, "/v1/projects/\(f.project)/assignees", token: who.token)
            XCTAssertEqual(denied.status, .forbidden)
        }
        let hidden = try await f.t.json(.GET, "/v1/projects/\(f.project)/assignees", token: f.stranger.token)
        XCTAssertEqual(hidden.status, .notFound)
    }

    func testDeletingAnAccountClearsItsAssignments() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task()
        try await f.assign(card, to: f.designer.id)
        _ = try await f.ask(card, assignee: f.designer.id)
        _ = try await f.review(card, assignee: f.designer.id)
        let before = try await f.forMe(f.designer)
        XCTAssertEqual([before.tasks.count, before.questions.count, before.reviews.count], [1, 1, 1])
        try await AccountDeletion.delete(userID: f.designer.id, on: f.t.app.db)
        let r = try await f.t.json(.GET, "/v1/tasks/\(card)/context", token: f.owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertNil((r.body?["task"] as? [String: Any])?["assigneeID"])
        XCTAssertNil((r.body?["questions"] as? [[String: Any]])?.first?["assigneeID"])
        XCTAssertNil((r.body?["review"] as? [String: Any])?["assigneeID"])
        XCTAssertNil((r.body?["review"] as? [String: Any])?["reviewerID"])
    }
}
