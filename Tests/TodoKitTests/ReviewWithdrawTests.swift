import Fluent
import XCTVapor
@testable import TodoKit

/// Card 6515CAFA: open reviews must not stay pending when their card is settled. Closing a card withdraws its open review
/// (import_plan and column moves too, with the same ownership rule as update_task), and the requesting connection can take
/// its own review back with `withdraw_review`. Decided reviews are never changed.
final class ReviewWithdrawTests: XCTestCase {
    struct Env {
        let f: OAuthFixture
        let agent: String, other: String
        let agentGrant: UUID, otherGrant: UUID
        var db: any Database { f.test.app.db }
    }

    private func env() async throws -> Env {
        let f = try await OAuthFixture.make()
        let a = try await f.tokens(scope: CommandCenterTests.scopes)
        let gA = try unwrap(try await OAuthGrant.query(on: f.test.app.db).first()?.id)
        let b = try await f.tokens(scope: CommandCenterTests.scopes)
        let gB = try unwrap(try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gA).first()?.id)
        return Env(f: f, agent: a.access, other: b.access, agentGrant: gA, otherGrant: gB)
    }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let e = try await env()
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], "\(name): \(r.body ?? [:])")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    /// Standard workflow board on the fixture project.
    private func columns(_ e: Env) async throws -> [ColumnRole: UUID] {
        let r = try await call(e, e.agent, "apply_agent_workflow_columns", ["projectID": e.f.project.requireID().uuidString])
        XCTAssertFalse(r.isError, r.text)
        var result: [ColumnRole: UUID] = [:]
        for c in try await ProjectColumn.query(on: e.db).filter(\.$projectID == e.f.project.requireID()).all() {
            if let role = ColumnRole.of(c) { result[role] = try c.requireID() }
        }
        return result
    }

    private func newTask(_ e: Env, project: Project? = nil, _ title: String = "Task") async throws -> UUID {
        let t = TodoTask(ownerID: try e.f.user.requireID(), projectID: try (project ?? e.f.project).requireID(), title: title, details: "")
        try await t.save(on: e.db)
        return try t.requireID()
    }

    /// Task with a pending review requested by `token`'s connection (default: the agent).
    private func reviewTask(_ e: Env, by token: String? = nil, _ title: String = "Task") async throws -> UUID {
        let id = try await newTask(e, title)
        let r = try await call(e, token ?? e.agent, "request_review", ["taskID": id.uuidString, "summary": "Done"])
        XCTAssertFalse(r.isError, r.text)
        return id
    }

    /// A pending review mirrored from a runner job (never withdrawn by anything but its job).
    private func makeRunnerBacked(_ e: Env, _ taskID: UUID) async throws {
        let r = try await review(e, taskID)
        r.agentJobID = UUID(); r.requestedByType = .run
        try await r.save(on: e.db)
    }

    private func task(_ e: Env, _ id: UUID) async throws -> TodoTask { try await XCTUnwrapAsync(try await TodoTask.find(id, on: e.db)) }

    private func review(_ e: Env, _ taskID: UUID) async throws -> TaskReview {
        try await XCTUnwrapAsync(try await TaskReview.query(on: e.db).filter(\.$taskID == taskID).first())
    }

    private func withdrawals(_ e: Env, _ taskID: UUID) async throws -> [ActivityEvent] {
        try await ActivityEvent.query(on: e.db).filter(\.$taskID == taskID).filter(\.$kind == "review.withdrawn").all()
    }

    private func assertStillPending(_ e: Env, _ taskID: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await review(e, taskID)
        XCTAssertEqual(r.state, "pending", file: file, line: line)
        XCTAssertNil(r.decidedAt, file: file, line: line)
        let events = try await withdrawals(e, taskID)
        XCTAssertEqual(events.count, 0, file: file, line: line)
    }

    private func assertWithdrawn(_ e: Env, _ taskID: UUID, by type: ActivityActorType, _ actorID: UUID, note: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await review(e, taskID)
        XCTAssertEqual(r.state, "withdrawn", file: file, line: line)
        XCTAssertNotNil(r.decidedAt, file: file, line: line)
        XCTAssertNil(r.decidedBy, file: file, line: line)
        XCTAssertEqual(r.decisionNote, note, file: file, line: line)
        XCTAssertEqual(r.version, 2, file: file, line: line)
        let events = try await withdrawals(e, taskID)
        XCTAssertEqual(events.map(\.actorType), [type], file: file, line: line)
        XCTAssertEqual(events.map(\.actorID), [actorID], file: file, line: line)
        XCTAssertEqual(events.map(\.subjectID), [r.id], file: file, line: line)
    }

    // MARK: A) import_plan

    /// Gives the task a plan key, so `import_plan` finds it.
    private func key(_ e: Env, _ taskID: UUID, _ key: String) async throws {
        try await TaskExternalKey(taskID: taskID, projectID: e.f.project.requireID(), externalKey: key).save(on: e.db)
    }

    private func importPlan(_ e: Env, _ items: [[String: Any]]) async throws -> [String: [String: Any]] {
        let r = try await call(e, e.agent, "import_plan", ["projectID": e.f.project.requireID().uuidString, "items": items])
        XCTAssertFalse(r.isError, r.text)
        let list = try unwrap(r.json?["items"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: try list.map { (try unwrap($0["externalKey"] as? String), $0) })
    }

    func testImportPlanByAgentSettlesItsOwnReview() async throws {
        try await run { e in
            let id = try await reviewTask(e, "Own")
            try await key(e, id, "own")
            let result = try await importPlan(e, [["externalKey": "own", "title": "Own", "status": "done"]])
            XCTAssertEqual(result["own"]?["changes"] as? [String], ["status"])
            let status = try await task(e, id).status
            XCTAssertEqual(status, "done")
            try await assertWithdrawn(e, id, by: .integration, e.agentGrant, note: "Karte auf erledigt gesetzt")
        }
    }

    func testImportPlanByAgentKeepsTheStatusOfCardsWithForeignOrRunnerReviews() async throws {
        try await run { e in
            let foreign = try await reviewTask(e, by: e.other, "Foreign")
            let renamed = try await reviewTask(e, by: e.other, "Old title")
            let runner = try await reviewTask(e, "Runner")
            try await makeRunnerBacked(e, runner)
            let plain = try await newTask(e, "Plain")
            for (id, k) in [(foreign, "foreign"), (renamed, "renamed"), (runner, "runner"), (plain, "plain")] { try await key(e, id, k) }
            let before = try await task(e, foreign)
            let result = try await importPlan(e, [
                ["externalKey": "foreign", "title": "Foreign", "status": "done"],
                ["externalKey": "renamed", "title": "New title", "status": "done", "criteria": ["Proof"]],
                ["externalKey": "runner", "title": "Runner", "status": "done"],
                ["externalKey": "plain", "title": "Plain", "status": "done"],
            ])
            // The marker alone does not make an item "updated".
            XCTAssertEqual(result["foreign"]?["changes"] as? [String], ["status_skipped_open_review"])
            XCTAssertEqual(result["foreign"]?["outcome"] as? String, "unchanged")
            XCTAssertEqual(result["runner"]?["changes"] as? [String], ["status_skipped_open_review"])
            XCTAssertEqual(result["runner"]?["outcome"] as? String, "unchanged")
            // The rest of the import still applies.
            XCTAssertEqual(result["renamed"]?["changes"] as? [String], ["title", "status_skipped_open_review", "criteria:+1"])
            XCTAssertEqual(result["renamed"]?["outcome"] as? String, "updated")
            XCTAssertEqual(result["plain"]?["changes"] as? [String], ["status"])
            for id in [foreign, renamed, runner] {
                let status = try await task(e, id).status
                XCTAssertEqual(status, "in_review")
                try await assertStillPending(e, id)
            }
            let after = try await task(e, foreign)
            XCTAssertEqual(after.version, before.version)
            let title = try await task(e, renamed).title
            XCTAssertEqual(title, "New title")
            let done = try await task(e, plain).status
            XCTAssertEqual(done, "done")
        }
    }

    func testImportPlanByThePersonSettlesEveryNonRunnerReview() async throws {
        try await run { e in
            let foreign = try await reviewTask(e, by: e.other, "Foreign")
            let runner = try await reviewTask(e, "Runner")
            try await makeRunnerBacked(e, runner)
            try await key(e, foreign, "foreign"); try await key(e, runner, "runner")
            let items = [PlanItem(externalKey: "foreign", title: "Foreign", description: nil, status: "done", blockedReason: nil, criteria: nil, backlog: nil, children: nil),
                         PlanItem(externalKey: "runner", title: "Runner", description: nil, status: "done", blockedReason: nil, criteria: nil, backlog: nil, children: nil)]
            let result = try await ProjectSyncService(user: e.f.user, db: e.db).importPlan(e.f.project.requireID(),
                ImportPlanRequest(items: items, applyWorkflowColumns: nil, dryRun: nil), actor: .person(e.f.user))
            XCTAssertEqual(result.items.map(\.changes), [["status"], ["status"]])
            try await assertWithdrawn(e, foreign, by: .person, e.f.user.requireID(), note: "Karte auf erledigt gesetzt")
            // The runner review stays: its job transition is authoritative.
            try await assertStillPending(e, runner)
        }
    }

    // MARK: B) move_task_to_column

    func testMovingTheCardIntoTheDoneColumnWithdrawsTheOwnReviewAsTheIntegration() async throws {
        try await run { e in
            let board = try await columns(e)
            let id = try await reviewTask(e)
            let version = try await task(e, id).version
            let r = try await call(e, e.agent, "move_task_to_column",
                ["id": id.uuidString, "version": version, "columnID": try unwrap(board[.done]).uuidString])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(r.json?["status"] as? String, "done")
            try await assertWithdrawn(e, id, by: .integration, e.agentGrant, note: "Karte auf erledigt gesetzt")
            let changes = try await ActivityEvent.query(on: e.db).filter(\.$taskID == id).filter(\.$kind == "task.status_changed").all()
            XCTAssertEqual(changes.last?.actorType, .integration)
        }
    }

    func testMovingTheCardIntoTheDoneColumnCannotSettleAForeignReview() async throws {
        try await run { e in
            let board = try await columns(e)
            let id = try await reviewTask(e, by: e.other)
            let before = try await task(e, id)
            let r = try await call(e, e.agent, "move_task_to_column",
                ["id": id.uuidString, "version": before.version, "columnID": try unwrap(board[.done]).uuidString])
            XCTAssertEqual(r.text, "brain_mandate_required")
            let after = try await task(e, id)
            XCTAssertEqual(after.status, "in_review")
            XCTAssertEqual(after.version, before.version)
            XCTAssertEqual(after.columnID, before.columnID)
            XCTAssertEqual(after.boardPosition, before.boardPosition)
            try await assertStillPending(e, id)
        }
    }

    func testThePersonMovingTheCardIntoTheDoneColumnStillWithdrawsTheReview() async throws {
        try await run { e in
            let board = try await columns(e)
            let id = try await reviewTask(e)
            let version = try await task(e, id).version
            let r = try await e.f.test.json(.PUT, "/v1/tasks/\(id.uuidString)/column",
                ["version": version, "columnID": try unwrap(board[.done]).uuidString], token: e.f.session)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            try await assertWithdrawn(e, id, by: .person, e.f.user.requireID(), note: "Karte auf erledigt gesetzt")
        }
    }

    // MARK: C) withdraw_review

    func testWithdrawReviewTakesTheOwnReviewBackAndReturnsTheCardToWork() async throws {
        try await run { e in
            let board = try await columns(e)
            let id = try await reviewTask(e)
            let version = try await task(e, id).version
            let note = "Doppelt angefragt:\n- neuer Stand folgt"
            let r = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString, "note": note])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(r.json?["state"] as? String, "withdrawn")
            XCTAssertEqual(r.json?["decisionNote"] as? String, note)
            try await assertWithdrawn(e, id, by: .integration, e.agentGrant, note: note)
            let after = try await task(e, id)
            XCTAssertEqual(after.status, "in_progress")
            XCTAssertEqual(after.columnID, board[.working])
            XCTAssertEqual(after.version, version + 1)
            let changes = try await ActivityEvent.query(on: e.db).filter(\.$taskID == id).filter(\.$kind == "task.status_changed").all()
            XCTAssertEqual(changes.map(\.actorType), [.integration, .integration])
            let pending = try await call(e, e.agent, "list_pending_reviews", [:])
            XCTAssertEqual((pending.json?["items"] as? [[String: Any]])?.count, 0, pending.text)
            // Nothing left to take back; a new review can be requested.
            let again = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString])
            XCTAssertEqual(again.text, "no_pending_review")
            let next = try await call(e, e.agent, "request_review", ["taskID": id.uuidString, "summary": "New"])
            XCTAssertFalse(next.isError, next.text)
        }
    }

    func testWithdrawReviewWithoutANoteSaysWhoTookItBack() async throws {
        try await run { e in
            let id = try await reviewTask(e)
            let r = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString, "note": "  "])
            XCTAssertFalse(r.isError, r.text)
            try await assertWithdrawn(e, id, by: .integration, e.agentGrant, note: "Von der anfragenden Verbindung zurückgezogen")
        }
    }

    func testWithdrawReviewIsOnlyForTheRequestingConnection() async throws {
        try await run { e in
            let foreign = try await reviewTask(e, by: e.other, "Foreign")
            let runner = try await reviewTask(e, "Runner")
            try await makeRunnerBacked(e, runner)
            // A person's review is not the connection's either.
            let person = try await newTask(e, "Person")
            let asked = try await e.f.test.json(.POST, "/v1/tasks/\(person.uuidString)/review", ["summary": "Mine"], token: e.f.session)
            XCTAssertLessThan(asked.status.code, 300, "\(asked.body ?? [:])")
            for id in [foreign, runner, person] {
                let before = try await task(e, id)
                let r = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString])
                XCTAssertEqual(r.text, "not_review_requester")
                try await assertStillPending(e, id)
                let after = try await task(e, id)
                XCTAssertEqual(after.status, before.status)
                XCTAssertEqual(after.version, before.version)
            }
        }
    }

    func testWithdrawReviewNeverChangesADecidedReview() async throws {
        try await run { e in
            for decision in ["accept", "request_changes"] {
                let id = try await reviewTask(e, decision)
                let decided = try await e.f.test.json(.POST, "/v1/tasks/\(id.uuidString)/review/decision",
                    ["decision": decision, "note": "Meine Entscheidung"], token: e.f.session)
                XCTAssertEqual(decided.status, .ok, "\(decided.body ?? [:])")
                let before = try await review(e, id)
                let r = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString])
                XCTAssertEqual(r.text, "no_pending_review")
                let after = try await review(e, id)
                XCTAssertEqual(after.state, before.state)
                XCTAssertEqual(after.version, before.version)
                XCTAssertEqual(after.decisionNote, "Meine Entscheidung")
            }
        }
    }

    func testSettingTheCardDoneLeavesDecidedReviewsUnchanged() async throws {
        try await run { e in
            let board = try await columns(e)
            let changes = try await reviewTask(e, "Changes")
            let decided = try await e.f.test.json(.POST, "/v1/tasks/\(changes.uuidString)/review/decision",
                ["decision": "request_changes", "note": "Bitte nacharbeiten"], token: e.f.session)
            XCTAssertEqual(decided.status, .ok, "\(decided.body ?? [:])")
            let accepted = try await reviewTask(e, "Accepted")
            let ok = try await e.f.test.json(.POST, "/v1/tasks/\(accepted.uuidString)/review/decision", ["decision": "accept"], token: e.f.session)
            XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
            let reopened = try await call(e, e.agent, "update_task",
                ["id": accepted.uuidString, "version": try await task(e, accepted).version, "status": "open"])
            XCTAssertFalse(reopened.isError, reopened.text)
            let versions = [try await review(e, changes).version, try await review(e, accepted).version]
            let done = try await call(e, e.agent, "update_task",
                ["id": changes.uuidString, "version": try await task(e, changes).version, "status": "done"])
            XCTAssertFalse(done.isError, done.text)
            let moved = try await call(e, e.agent, "move_task_to_column",
                ["id": accepted.uuidString, "version": try await task(e, accepted).version, "columnID": try unwrap(board[.done]).uuidString])
            XCTAssertFalse(moved.isError, moved.text)
            for (id, state, version) in [(changes, "changes_requested", versions[0]), (accepted, "accepted", versions[1])] {
                let r = try await review(e, id)
                XCTAssertEqual(r.state, state)
                XCTAssertEqual(r.version, version)
                let events = try await withdrawals(e, id)
                XCTAssertEqual(events.count, 0)
            }
        }
    }

    /// Reviews left over from before the automatic withdrawal: the card is done already and must stay exactly as it is.
    func testWithdrawReviewClearsAStaleReviewWithoutTouchingTheDoneCard() async throws {
        try await run { e in
            let board = try await columns(e)
            let id = try await reviewTask(e)
            let stale = try await task(e, id)
            stale.status = "done"; stale.columnID = board[.done]
            try await stale.save(on: e.db)
            let r = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString, "note": "Altlast"])
            XCTAssertFalse(r.isError, r.text)
            try await assertWithdrawn(e, id, by: .integration, e.agentGrant, note: "Altlast")
            let after = try await task(e, id)
            XCTAssertEqual(after.status, "done")
            XCTAssertEqual(after.version, stale.version)
            XCTAssertEqual(after.columnID, board[.done])
        }
    }

    func testWithdrawReviewKeepsGrantScopeAndInputRules() async throws {
        try await run { e in
            let id = try await reviewTask(e)
            let bad = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString, "note": "a\u{7}b"])
            XCTAssertEqual(bad.text, "invalid_note")
            let long = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString, "note": String(repeating: "x", count: 4001)])
            XCTAssertEqual(long.text, "invalid_note")
            let readOnly = try await e.f.tokens(scope: "projects:read tasks:read")
            let noScope = try await call(e, readOnly.access, "withdraw_review", ["taskID": id.uuidString])
            XCTAssertEqual(noScope.text, "insufficient_scope")
            // The card leaves the granted projects: invisible, even for the connection that asked.
            let moved = try await task(e, id)
            moved.projectID = try e.f.other.requireID()
            try await moved.save(on: e.db)
            let outside = try await call(e, e.agent, "withdraw_review", ["taskID": id.uuidString])
            XCTAssertEqual(outside.text, "not_found")
            try await assertStillPending(e, id)
        }
    }
}
