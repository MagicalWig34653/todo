import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Agents set the responsible person over MCP and read "for me" (card 8B4BAC2E, ADR 0043).
final class AssignmentMCPTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: [String: Any]? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text,
                      json: (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    private func with(_ body: (OAuthFixture, String, User, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let designer = User(displayName: "Designer", isAdmin: false)
            designer.username = "designer-login"
            try await designer.save(on: db)
            try await ProjectGrant(projectID: f.project.requireID(), principalType: "person", principalID: designer.requireID(), role: .edit).save(on: db)
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Card")
            try await task.save(on: db)
            let access = try await f.tokens(scope: "projects:read tasks:read tasks:write").access
            try await body(f, access, designer, try task.requireID().uuidString)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testAgentAssignsAndForMeShowsItOnlyToThatPerson() async throws {
        try await with { f, access, designer, task in
            let me = try f.user.requireID().uuidString, other = try designer.requireID().uuidString
            let pid = try f.project.requireID().uuidString

            let listed = try await call(f, "list_assignees", ["projectID": pid], access)
            XCTAssertFalse(listed.isError, listed.text)
            let people = try XCTUnwrap(listed.json?["items"] as? [[String: Any]], listed.text)
            XCTAssertEqual(Set(people.compactMap { $0["displayName"] as? String }), ["OAuth User", "Designer"])
            for p in people { XCTAssertEqual(Set(p.keys), ["userID", "displayName", "assignableTo", "isMe"]) }
            XCTAssertFalse(listed.text.contains("designer-login"), "no login names for agents")

            let card = try await call(f, "set_assignee", ["taskID": task, "assigneeID": other], access)
            XCTAssertFalse(card.isError, card.text)
            XCTAssertEqual((card.json?["assigneeID"] as? String)?.uppercased(), other)
            let asked = try await call(f, "ask_question", ["taskID": task, "prompt": "For me?", "assigneeID": me], access)
            XCTAssertFalse(asked.isError, asked.text)
            XCTAssertEqual((asked.json?["assigneeID"] as? String)?.uppercased(), me)
            let review = try await call(f, "request_review", ["taskID": task, "summary": "Design", "assigneeID": other], access)
            XCTAssertFalse(review.isError, review.text)
            XCTAssertEqual((review.json?["assigneeID"] as? String)?.uppercased(), other)

            // "For me" is the person of the connection: only the question assigned to them.
            let mine = try await call(f, "list_for_me", ["projectID": pid], access)
            XCTAssertFalse(mine.isError, mine.text)
            XCTAssertEqual((mine.json?["questions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [asked.json?["id"] as? String].compactMap { $0 })
            XCTAssertEqual((mine.json?["tasks"] as? [[String: Any]])?.count, 0, mine.text)
            XCTAssertEqual((mine.json?["reviews"] as? [[String: Any]])?.count, 0, mine.text)
            XCTAssertEqual((mine.json?["currentProject"] as? [String: Any])?["id"] as? String, pid)
            let theirs = try await f.test.json(.GET, "/v1/for-me", token: try await session(f, designer))
            XCTAssertEqual((theirs.body?["tasks"] as? [[String: Any]])?.count, 1, "\(theirs.body ?? [:])")
            XCTAssertEqual((theirs.body?["reviews"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((theirs.body?["questions"] as? [[String: Any]])?.count, 0)

            let qid = try XCTUnwrap(asked.json?["id"] as? String)
            let moved = try await call(f, "set_assignee", ["questionID": qid, "assigneeID": other], access)
            XCTAssertFalse(moved.isError, moved.text)
            // The connection's person manages the project, so the named review may be redirected and cleared.
            let rid = try XCTUnwrap(review.json?["id"] as? String)
            let cleared = try await call(f, "set_assignee", ["reviewID": rid, "assigneeID": NSNull()], access)
            XCTAssertFalse(cleared.isError, cleared.text)
            XCTAssertNil(cleared.json?["assigneeID"])
        }
    }

    /// A connection may name somebody on an open review, but it redirects or clears a named one only on its own request:
    /// otherwise an agent without the brain mandate could lift the binding a person relies on.
    func testConnectionCannotLiftTheNamedReviewerOfAForeignRequest() async throws {
        try await with { f, access, designer, task in
            let me = try f.user.requireID().uuidString, other = try designer.requireID().uuidString
            let named = try await f.test.json(.POST, "/v1/tasks/\(task)/review", ["summary": "by the person", "assigneeID": other], token: f.session)
            let rid = try XCTUnwrap(named.body?["id"] as? String, "\(named.body ?? [:])")
            for value: Any in [NSNull(), me] {
                let r = try await call(f, "set_assignee", ["reviewID": rid, "assigneeID": value], access)
                XCTAssertTrue(r.isError, r.text)
                XCTAssertEqual(r.text, "not_review_requester")
            }
            // Naming somebody on a review nobody is named for stays possible; changing it afterwards does not.
            let cleared = try await f.test.json(.PUT, "/v1/reviews/\(rid)/assignee", ["assigneeID": NSNull()], token: f.session)
            XCTAssertEqual(cleared.status, .ok, "\(cleared.body ?? [:])")
            let first = try await call(f, "set_assignee", ["reviewID": rid, "assigneeID": other], access)
            XCTAssertFalse(first.isError, first.text)
            let again = try await call(f, "set_assignee", ["reviewID": rid, "assigneeID": NSNull()], access)
            XCTAssertEqual(again.text, "not_review_requester")
        }
    }

    func testStrangerOutsideGrantAndAmbiguousTargetsAreRefused() async throws {
        try await with { f, access, designer, task in
            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: f.test.app.db)
            let bad = try await call(f, "set_assignee", ["taskID": task, "assigneeID": try stranger.requireID().uuidString], access)
            XCTAssertTrue(bad.isError); XCTAssertEqual(bad.text, "invalid_assignee")
            for tool in ["ask_question", "request_review"] {
                var args: [String: Any] = ["taskID": task, "assigneeID": try stranger.requireID().uuidString]
                args[tool == "ask_question" ? "prompt" : "summary"] = "x"
                let r = try await call(f, tool, args, access)
                XCTAssertTrue(r.isError, r.text); XCTAssertEqual(r.text, "invalid_assignee", tool)
            }
            let none = try await call(f, "set_assignee", ["assigneeID": NSNull()], access)
            XCTAssertEqual(none.text, "invalid_target")
            let two = try await call(f, "set_assignee", ["taskID": task, "questionID": UUID().uuidString, "assigneeID": NSNull()], access)
            XCTAssertEqual(two.text, "invalid_target")
            let missing = try await call(f, "set_assignee", ["taskID": task], access)
            XCTAssertTrue(missing.isError, "assigneeID is required (null clears)")

            // A project of the same person outside the grant stays invisible.
            let hidden = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Hidden")
            try await hidden.save(on: f.test.app.db)
            _ = try await f.test.json(.PUT, "/v1/tasks/\(try hidden.requireID().uuidString)/assignee",
                ["assigneeID": try f.user.requireID().uuidString], token: f.session)
            let people = try await call(f, "list_assignees", ["projectID": try f.other.requireID().uuidString], access)
            XCTAssertEqual(people.text, "not_found")
            let set = try await call(f, "set_assignee", ["taskID": try hidden.requireID().uuidString, "assigneeID": NSNull()], access)
            XCTAssertEqual(set.text, "not_found")
            let mine = try await call(f, "list_for_me", [:], access)
            XCTAssertEqual((mine.json?["tasks"] as? [[String: Any]])?.count, 0, mine.text)
        }
    }

    private func session(_ f: OAuthFixture, _ user: User) async throws -> String {
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
        return token
    }
}

/// Waiting plans and recurring cards follow the card's responsible person.
final class AssignmentFollowUpTests: XCTestCase {
    func testPlanPushGoesToTheCardAssigneeOnly() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let cfg = PushTests.config()
        f.t.app.settings.apns = cfg
        let mock = MockAPNs()
        let sender = try APNsSender(config: cfg, transport: mock)
        for (index, who) in [f.designer, f.editor].enumerated() {
            let r = try await f.t.json(.POST, "/v1/push/devices", ["token": String(format: "%064x", index + 1), "platform": "ios",
                "environment": "sandbox", "bundleId": "de.linolaske.todo"], token: who.token)
            XCTAssertEqual(r.status, .created)
        }
        let plain = try await f.task("plain"), assigned = try await f.task("assigned")
        try await f.assign(assigned, to: f.designer.id)
        for card in [plain, assigned] {
            let r = try await f.t.json(.PUT, "/v1/tasks/\(card)/plan", ["body": "# Plan"], token: f.owner.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        }
        _ = await PushWorker(app: f.t.app, sender: sender, interval: 0).runIfDue()
        var byTask: [String: Set<String>] = [:]
        for request in mock.requests {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            guard payload["kind"] as? String == "plan", let task = payload["taskID"] as? String else { continue }
            byTask[task.lowercased(), default: []].insert(request.deviceToken == String(format: "%064x", 1) ? "Designer" : "Editor")
        }
        XCTAssertEqual(byTask[plain.lowercased()], ["Designer", "Editor"])
        XCTAssertEqual(byTask[assigned.lowercased()], ["Designer"])
    }

    func testRecurringCardKeepsItsAssignee() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let card = try await f.task("Weekly")
        let due = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let plan = try await f.t.json(.PUT, "/v1/planning/tasks/\(card)",
            ["priority": 0, "reminders": [String](), "dueAt": due, "recurrence": ["frequency": "weekly", "interval": 1, "timeZone": "UTC"]], token: f.owner.token)
        XCTAssertEqual(plan.status, .ok, "\(plan.body ?? [:])")
        try await f.assign(card, to: f.designer.id)
        let done = try await f.t.json(.PATCH, "/v1/tasks/\(card)", ["version": 2, "status": "done"], token: f.owner.token)
        XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
        let list = try await f.forMe(f.designer)
        XCTAssertEqual(list.tasks.count, 1)
        XCTAssertFalse(list.tasks.contains(card))
    }
}

/// Additive migration of the responsibility columns; runs on SQLite and, with TODO_TEST_MARIADB=1, on MariaDB.
final class AssignmentMigrationTests: XCTestCase {
    /// Upgrade of a database with data: the new migrations are taken back and applied again; every old row stays, the new
    /// fields are empty and an old named reviewer keeps its place.
    func testUpgradeKeepsExistingCardsQuestionsAndReviews() async throws {
        let f = try await AssignmentFixture.make()
        do {
            let card = try await f.task("Existing")
            let asked = try await f.ask(card)
            XCTAssertEqual(asked.status, .created, "\(asked.body ?? [:])")
            let requested = try await f.review(card, assignee: f.designer.id, key: "reviewerID")
            XCTAssertEqual(requested.status, .ok, "\(requested.body ?? [:])")
            let db = f.t.app.db
            try await AddQuestionAndReviewAssignment().revert(on: db)
            try await AddTaskAssignee().revert(on: db)
            let sql = try XCTUnwrap(db as? any SQLDatabase)
            do {
                _ = try await sql.raw("SELECT assignee_id FROM tasks LIMIT 1").all()
                XCTFail("revert must remove the column")
            } catch {}
            try await AddTaskAssignee().prepare(on: db)
            try await AddQuestionAndReviewAssignment().prepare(on: db)

            let tasks = try await TodoTask.query(on: db).all()
            XCTAssertEqual(tasks.map(\.title), ["Existing"])
            XCTAssertNil(tasks.first?.assigneeID)
            let questions = try await TaskQuestion.query(on: db).all()
            XCTAssertEqual(questions.map(\.prompt), ["Which colour?"])
            XCTAssertNil(questions.first?.assigneeID); XCTAssertNil(questions.first?.assignedAt)
            let reviews = try await TaskReview.query(on: db).all()
            XCTAssertEqual(reviews.map(\.reviewerID), [f.designer.id])
            XCTAssertNil(reviews.first?.assignedAt)
            // The upgraded database takes assignments.
            let set = try await f.assign(card, to: f.editor.id)
            XCTAssertEqual(set.status, .ok, "\(set.body ?? [:])")
            let mine = try await f.forMe(f.editor)
            XCTAssertEqual(mine.tasks, [card])
        } catch { await f.t.shutdown(); throw error }
        await f.t.shutdown()
    }

    func testMigratedSchemaHasTheColumnsAndIndexes() async throws {
        let t = try await TestApp.make()
        do {
            let sql = try XCTUnwrap(t.app.db as? any SQLDatabase)
            _ = try await sql.raw("SELECT assignee_id FROM tasks LIMIT 1").all()
            _ = try await sql.raw("SELECT assignee_id, assigned_at FROM task_questions LIMIT 1").all()
            _ = try await sql.raw("SELECT reviewer_id, assigned_at FROM task_reviews LIMIT 1").all()
            let catalog = sql.dialect.name == "sqlite"
                ? "SELECT name AS n FROM sqlite_master WHERE type = 'index'"
                : "SELECT DISTINCT index_name AS n FROM information_schema.statistics WHERE table_schema = DATABASE()"
            let names = Set(try await sql.raw(SQLQueryString(catalog)).all().map { try $0.decode(column: "n", as: String.self) })
            for index in ["assign_tasks_assignee", "assign_questions_assignee", "assign_reviews_reviewer"] {
                XCTAssertTrue(names.contains(index), "\(index) missing")
            }
        } catch { await t.shutdown(); throw error }
        await t.shutdown()
    }
}
