import Fluent
import XCTVapor
@testable import TodoKit

/// Stapel 1 (docs/MCP-PARITAET.md): create_task/update_task on the shared services, move_project, set_project_position,
/// update_criterion, and delete_column/delete_criterion as confirmation requests.
final class MCPProjectToolsTests: XCTestCase {
    private struct Called { let isError: Bool; let json: [String: Any]?; let text: String }

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, json: (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], text: text)
    }

    private func expect(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String, _ code: String,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let c = try await call(f, name, args, access)
        XCTAssertEqual(c.text, code, file: file, line: line)
    }

    private let all = "projects:read projects:write tasks:read tasks:write"

    /// Adds projects to the (single) grant of the fixture.
    private func extend(_ f: OAuthFixture, _ projects: [Project]) async throws {
        let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: f.test.app.db).first())
        g.projects.append(contentsOf: try projects.map { try $0.requireID() })
        try await g.save(on: f.test.app.db)
    }

    private func newProject(_ f: OAuthFixture, _ name: String, parent: Project? = nil, owner: User? = nil) async throws -> Project {
        let p = Project(ownerID: try (owner ?? f.user).requireID(), parentID: try parent?.requireID(), name: name)
        try await p.save(on: f.test.app.db)
        return p
    }

    // MARK: create_task

    func testCreateTaskUsesSharedServices() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let pid = try f.project.requireID()
            let done = ProjectColumn(projectID: pid, name: "Done", color: nil, isDone: true, position: 0)
            try await done.save(on: f.test.app.db)
            let plain = try await call(f, "create_task", ["projectID": pid.uuidString, "title": " Plain "], t.access)
            XCTAssertFalse(plain.isError, plain.text)
            XCTAssertEqual(plain.json?["title"] as? String, "Plain")
            XCTAssertEqual(plain.json?["status"] as? String, "open")
            // Activity entry like REST.
            let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(plain.json?["id"] as? String)))
            let events = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == taskID).all()
            XCTAssertEqual(events.map(\.kind), ["task.created"])
            // Column, description, planning.
            let rich = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "Rich", "description": "d",
                "columnID": try done.requireID().uuidString, "dueDate": "2026-12-24", "priority": 2], t.access)
            XCTAssertFalse(rich.isError, rich.text)
            XCTAssertEqual(rich.json?["status"] as? String, "done")
            XCTAssertEqual(rich.json?["columnID"] as? String, try done.requireID().uuidString)
            XCTAssertEqual(rich.json?["description"] as? String, "d")
            let richID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(rich.json?["id"] as? String)))
            let planning = try await TaskPlanning.find(richID, on: f.test.app.db)
            XCTAssertEqual(planning?.priority, 2)
            XCTAssertNotNil(planning?.dueAt)
            // Errors.
            let outside = try await call(f, "create_task", ["projectID": f.other.requireID().uuidString, "title": "x"], t.access)
            XCTAssertEqual(outside.text, "not_found")
            let foreignColumn = ProjectColumn(projectID: try f.other.requireID(), name: "X", color: nil, isDone: false, position: 0)
            try await foreignColumn.save(on: f.test.app.db)
            let wrongColumn = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "x", "columnID": foreignColumn.requireID().uuidString], t.access)
            XCTAssertEqual(wrongColumn.text, "not_found")
            let badPriority = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "x", "priority": 9], t.access)
            XCTAssertEqual(badPriority.text, "invalid_priority")
            let fractional = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "x", "priority": 1.5], t.access)
            XCTAssertEqual(fractional.text, "invalid_priority")
            let badDate = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "x", "dueDate": "tomorrow"], t.access)
            XCTAssertEqual(badDate.text, "invalid_due_date")
            let badTitle = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "   "], t.access)
            XCTAssertEqual(badTitle.text, "invalid_title")
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let noScope = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "x"], readOnly.access)
            XCTAssertEqual(noScope.text, "insufficient_scope")
            // Rights: a project of another account in the grant is still invisible.
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = try await newProject(f, "Foreign", owner: stranger)
            try await extend(f, [foreign])
            let noRole = try await call(f, "create_task", ["projectID": foreign.requireID().uuidString, "title": "x"], t.access)
            XCTAssertEqual(noRole.text, "not_found")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: update_task

    func testUpdateTaskActivityRecurrenceAndMoveCleanup() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let target = try await newProject(f, "Target")
            try await extend(f, [target])
            let pid = try f.project.requireID()
            let a = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "A"], t.access)
            let b = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "B"], t.access)
            let aID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(a.json?["id"] as? String)))
            let bID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(b.json?["id"] as? String)))
            try await PlanningDependency(aID, bID).save(on: f.test.app.db)
            // Status change: activity + version.
            let done = try await call(f, "update_task", ["id": aID.uuidString, "version": 1, "status": "in_progress"], t.access)
            XCTAssertFalse(done.isError, done.text)
            XCTAssertEqual(done.json?["version"] as? Int, 2)
            let kinds = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == aID).all().map(\.kind)
            XCTAssertTrue(kinds.contains("task.status_changed"), "\(kinds)")
            // Stale version.
            let stale = try await call(f, "update_task", ["id": aID.uuidString, "version": 1, "title": "Z"], t.access)
            XCTAssertEqual(stale.text, "version_conflict")
            // Moving to another project removes the dependency link.
            let moved = try await call(f, "update_task", ["id": aID.uuidString, "version": 2, "projectID": target.requireID().uuidString], t.access)
            XCTAssertFalse(moved.isError, moved.text)
            XCTAssertEqual(moved.json?["projectID"] as? String, try target.requireID().uuidString)
            let edges = try await PlanningDependency.query(on: f.test.app.db).count()
            XCTAssertEqual(edges, 0)
            // Target outside the grant.
            let escape = try await call(f, "update_task", ["id": bID.uuidString, "version": 1, "projectID": f.other.requireID().uuidString], t.access)
            XCTAssertEqual(escape.text, "not_found")
            let badStatus = try await call(f, "update_task", ["id": bID.uuidString, "version": 1, "status": "weird"], t.access)
            XCTAssertEqual(badStatus.text, "invalid_status")
            // Completing a recurring task creates the next one.
            let rec = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "Weekly", "dueDate": "2026-12-01T09:00:00Z"], t.access)
            let recID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(rec.json?["id"] as? String)))
            let p = try await XCTUnwrapAsync(try await TaskPlanning.find(recID, on: f.test.app.db))
            p.recurrence = RecurrenceRule(frequency: "weekly", interval: 1, timeZone: "UTC", until: nil)
            try await p.save(on: f.test.app.db)
            let before = try await TodoTask.query(on: f.test.app.db).filter(\.$title == "Weekly").count()
            let finish = try await call(f, "update_task", ["id": recID.uuidString, "version": 1, "status": "done"], t.access)
            XCTAssertFalse(finish.isError, finish.text)
            let after = try await TodoTask.query(on: f.test.app.db).filter(\.$title == "Weekly").count()
            XCTAssertEqual(after, before + 1)
            // Scope.
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let noScope = try await call(f, "update_task", ["id": bID.uuidString, "version": 1, "title": "N"], readOnly.access)
            XCTAssertEqual(noScope.text, "insufficient_scope")
            // Foreign project in the grant: no role.
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = try await newProject(f, "Foreign", owner: stranger)
            let ft = TodoTask(ownerID: try stranger.requireID(), projectID: try foreign.requireID(), title: "F", details: "")
            try await ft.save(on: f.test.app.db)
            try await extend(f, [foreign])
            let noRole = try await call(f, "update_task", ["id": ft.requireID().uuidString, "version": 1, "title": "N"], t.access)
            XCTAssertEqual(noRole.text, "not_found")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: move_project / set_project_position

    func testMoveProject() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let a = f.project
            let child = try await newProject(f, "Child", parent: a)
            let sibling = try await newProject(f, "Sibling")
            try await extend(f, [child, sibling])
            let cid = try child.requireID().uuidString, aid = try a.requireID().uuidString, sid = try sibling.requireID().uuidString
            // Cycle: a below its own child.
            let cycle = try await call(f, "move_project", ["projectID": aid, "version": 1, "parentID": cid], t.access)
            XCTAssertEqual(cycle.text, "project_cycle")
            // Child to the top level.
            let root = try await call(f, "move_project", ["projectID": cid, "version": 1, "parentID": NSNull()], t.access)
            XCTAssertFalse(root.isError, root.text)
            XCTAssertTrue(root.json?["parentID"] is NSNull)
            XCTAssertEqual(root.json?["version"] as? Int, 2)
            // Child below sibling.
            let below = try await call(f, "move_project", ["projectID": cid, "version": 2, "parentID": sid], t.access)
            XCTAssertFalse(below.isError, below.text)
            XCTAssertEqual(below.json?["parentID"] as? String, sid)
            let stored = try await XCTUnwrapAsync(try await Project.find(child.requireID(), on: f.test.app.db))
            XCTAssertEqual(stored.parentID, try sibling.requireID())
            // Stale version, target outside the grant, source outside the grant, bad input, scope.
            try await expect(f, "move_project", ["projectID": cid, "version": 1, "parentID": aid], t.access, "version_conflict")
            try await expect(f, "move_project", ["projectID": cid, "version": 3, "parentID": f.other.requireID().uuidString], t.access, "not_found")
            try await expect(f, "move_project", ["projectID": f.other.requireID().uuidString, "version": 1, "parentID": aid], t.access, "not_found")
            try await expect(f, "move_project", ["projectID": cid, "version": 1.5, "parentID": aid], t.access, "invalid_version")
            try await expect(f, "move_project", ["projectID": cid, "version": 3, "parentID": "nope"], t.access, "invalid_parentID")
            let readOnly = try await f.tokens(scope: "projects:read")
            try await expect(f, "move_project", ["projectID": cid, "version": 3, "parentID": NSNull()], readOnly.access, "insufficient_scope")
            // Role: a foreign project in the grant (read-only share) cannot be moved.
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = try await newProject(f, "Foreign", owner: stranger)
            try await extend(f, [foreign])
            try await expect(f, "move_project", ["projectID": foreign.requireID().uuidString, "version": 1, "parentID": NSNull()], t.access, "not_found")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSetProjectPosition() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let p2 = try await newProject(f, "P2"), p3 = try await newProject(f, "P3")
            try await extend(f, [p2, p3])
            let ids = [try f.project.requireID(), try p2.requireID(), try p3.requireID()].map(\.uuidString)
            func order() async throws -> [String] {
                let r = try await f.test.json(.GET, "/v1/projects", token: f.session)
                let rows = try XCTUnwrap(r.list)
                func pos(_ x: [String: Any]) -> Int { x["position"] as? Int ?? Int.max }
                return rows.filter { ids.contains($0["id"] as? String ?? "") }.sorted { pos($0) < pos($1) }.compactMap { $0["id"] as? String }
            }
            let first = try await call(f, "set_project_position", ["projectID": ids[2], "afterProjectID": NSNull()], t.access)
            XCTAssertFalse(first.isError, first.text)
            XCTAssertEqual(first.json?["position"] as? Int, 0)
            let o1 = try await order()
            XCTAssertEqual(o1.first, ids[2])
            let after = try await call(f, "set_project_position", ["projectID": ids[2], "afterProjectID": ids[0]], t.access)
            XCTAssertFalse(after.isError, after.text)
            let o2 = try await order()
            XCTAssertEqual(Array(o2.prefix(2)), [ids[0], ids[2]])
            try await expect(f, "set_project_position", ["projectID": ids[0], "afterProjectID": ids[0]], t.access, "invalid_after_project")
            try await expect(f, "set_project_position", ["projectID": ids[0], "afterProjectID": f.other.requireID().uuidString], t.access, "not_found")
            try await expect(f, "set_project_position", ["projectID": f.other.requireID().uuidString, "afterProjectID": NSNull()], t.access, "not_found")
            try await expect(f, "set_project_position", ["projectID": ids[0], "afterProjectID": 5], t.access, "invalid_afterProjectID")
            let readOnly = try await f.tokens(scope: "projects:read")
            try await expect(f, "set_project_position", ["projectID": ids[0], "afterProjectID": NSNull()], readOnly.access, "insufficient_scope")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: delete_column (class C)

    func testDeleteColumnIsAConfirmationRequest() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let pid = try f.project.requireID()
            let c1 = ProjectColumn(projectID: pid, name: "Todo", color: nil, isDone: false, position: 0)
            let c2 = ProjectColumn(projectID: pid, name: "Doing", color: nil, isDone: false, position: 1)
            try await c1.save(on: f.test.app.db); try await c2.save(on: f.test.app.db)
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: pid, title: "T", details: "")
            task.columnID = try c2.requireID()
            try await task.save(on: f.test.app.db)
            let res = try await call(f, "delete_column", ["id": c2.requireID().uuidString], t.access)
            XCTAssertTrue(res.isError)
            XCTAssertEqual(res.json?["error"] as? String, "confirmation_required")
            let rid = try XCTUnwrap(res.json?["actionRequestID"] as? String)
            let still = try await ProjectColumn.find(c2.requireID(), on: f.test.app.db)
            XCTAssertNotNil(still)
            let row = try await XCTUnwrapAsync(try await ActionRequest.find(UUID(uuidString: rid), on: f.test.app.db))
            XCTAssertEqual(row.impact.tasks, 1)
            XCTAssertTrue(row.summary.contains("Doing"), row.summary)
            // Same call, same request.
            let again = try await call(f, "delete_column", ["id": c2.requireID().uuidString], t.access)
            XCTAssertEqual(again.json?["actionRequestID"] as? String, rid)
            let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(rid)/confirm", token: f.session)
            XCTAssertEqual(confirmed.body?["state"] as? String, "executed", "\(String(describing: confirmed.body))")
            let gone = try await ProjectColumn.find(c2.requireID(), on: f.test.app.db)
            XCTAssertNil(gone)
            let moved = try await XCTUnwrapAsync(try await TodoTask.find(task.requireID(), on: f.test.app.db))
            XCTAssertEqual(moved.columnID, try c1.requireID())
            // Errors: foreign column, bad moveTo, scope, stale version at request time.
            let foreign = ProjectColumn(projectID: try f.other.requireID(), name: "F", color: nil, isDone: false, position: 0)
            try await foreign.save(on: f.test.app.db)
            try await expect(f, "delete_column", ["id": foreign.requireID().uuidString], t.access, "not_found")
            try await expect(f, "delete_column", ["id": c1.requireID().uuidString, "moveTo": "x"], t.access, "invalid_move_to")
            try await expect(f, "delete_column", ["id": c1.requireID().uuidString, "version": 99], t.access, "version_conflict")
            try await expect(f, "delete_column", ["id": c1.requireID().uuidString, "version": 1.5], t.access, "invalid_arguments")
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            try await expect(f, "delete_column", ["id": c1.requireID().uuidString], readOnly.access, "insufficient_scope")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: criteria

    func testUpdateAndDeleteCriterion() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "T", details: "")
            try await task.save(on: f.test.app.db)
            let c = AcceptanceCriterion(taskID: try task.requireID(), text: "old")
            try await c.save(on: f.test.app.db)
            let cid = try c.requireID().uuidString
            let upd = try await call(f, "update_criterion", ["criterionID": cid, "text": " new "], t.access)
            XCTAssertFalse(upd.isError, upd.text)
            XCTAssertEqual(upd.json?["text"] as? String, "new")
            XCTAssertEqual(upd.json?["version"] as? Int, 2)
            try await expect(f, "update_criterion", ["criterionID": cid, "text": "x", "version": 1], t.access, "version_conflict")
            try await expect(f, "update_criterion", ["criterionID": cid, "text": "  "], t.access, "invalid_text")
            try await expect(f, "update_criterion", ["criterionID": cid, "text": "x", "version": 2.5], t.access, "invalid_version")
            let otherTask = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "O", details: "")
            try await otherTask.save(on: f.test.app.db)
            let oc = AcceptanceCriterion(taskID: try otherTask.requireID(), text: "o")
            try await oc.save(on: f.test.app.db)
            try await expect(f, "update_criterion", ["criterionID": oc.requireID().uuidString, "text": "x"], t.access, "not_found")
            try await expect(f, "delete_criterion", ["criterionID": oc.requireID().uuidString], t.access, "not_found")
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            try await expect(f, "update_criterion", ["criterionID": cid, "text": "x"], readOnly.access, "insufficient_scope")
            try await expect(f, "delete_criterion", ["criterionID": cid], readOnly.access, "insufficient_scope")
            // Delete is a request; nothing happens until it is confirmed.
            try await expect(f, "delete_criterion", ["criterionID": cid, "version": 1], t.access, "version_conflict")
            let del = try await call(f, "delete_criterion", ["criterionID": cid], t.access)
            XCTAssertEqual(del.json?["error"] as? String, "confirmation_required")
            let rid = try XCTUnwrap(del.json?["actionRequestID"] as? String)
            let kept = try await AcceptanceCriterion.find(c.requireID(), on: f.test.app.db)
            XCTAssertNotNil(kept)
            let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(rid)/confirm", token: f.session)
            XCTAssertEqual(confirmed.body?["state"] as? String, "executed", "\(String(describing: confirmed.body))")
            let gone = try await AcceptanceCriterion.find(c.requireID(), on: f.test.app.db)
            XCTAssertNil(gone)
            let kinds = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == task.requireID()).all().map(\.kind)
            XCTAssertTrue(kinds.contains("criterion.deleted") && kinds.contains("criterion.updated"), "\(kinds)")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: done withdraws open reviews

    func testSettingTaskDoneWithdrawsPendingReview() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: all)
            let pid = try f.project.requireID()
            let a = try await call(f, "create_task", ["projectID": pid.uuidString, "title": "A"], t.access)
            let aID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(a.json?["id"] as? String)))
            let review = try await call(f, "request_review", ["taskID": aID.uuidString, "summary": "Ready"], t.access)
            XCTAssertFalse(review.isError, review.text)
            let task = try await XCTUnwrapAsync(try await TodoTask.find(aID, on: f.test.app.db))
            let done = try await call(f, "update_task", ["id": aID.uuidString, "version": task.version, "status": "done"], t.access)
            XCTAssertFalse(done.isError, done.text)
            let reviews = try await TaskReview.query(on: f.test.app.db).filter(\.$taskID == aID).all()
            XCTAssertEqual(reviews.map(\.state), ["withdrawn"])
            XCTAssertNotNil(reviews.first?.decisionNote)
            let pending = try await call(f, "list_pending_reviews", [:], t.access)
            XCTAssertEqual((pending.json?["items"] as? [[String: Any]])?.count, 0, pending.text)
            let kinds = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == aID).all().map(\.kind)
            XCTAssertTrue(kinds.contains("review.withdrawn"), "\(kinds)")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
