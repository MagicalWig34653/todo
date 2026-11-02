import Fluent
import XCTVapor
@testable import TodoKit

final class MCPPlanningToolsTests: XCTestCase {
    let names = ["get_task_planning", "update_task_planning", "list_planned_tasks", "set_dependencies", "list_dependencies", "remove_dependency", "list_milestones", "create_milestone", "assign_milestone", "unassign_milestone", "delete_milestone"]

    func testToolsRegistered() {
        for name in names { XCTAssertTrue(MCPController.tools.contains { $0.name == name }, name) }
    }

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ token: String) async throws -> (Bool, String, Any?) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testPlanningPatchVersionAndValidation() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Plan", details: "")
            try await task.save(on: f.test.app.db)
            let id = try task.requireID().uuidString
            let updated = try await call(f, "update_task_planning", ["taskID": id, "version": 1, "dueDate": "2026-11-03", "dueTime": "12:30", "priority": 3], token)
            XCTAssertFalse(updated.0, updated.1)
            let read = try await call(f, "get_task_planning", ["taskID": id], token)
            XCTAssertEqual((read.2 as? [String: Any])?["priority"] as? Int, 3)
            let stale = try await call(f, "update_task_planning", ["taskID": id, "version": 1, "priority": 0], token)
            XCTAssertTrue(stale.0); XCTAssertEqual(stale.1, "version_conflict")
            for bad: [String: Any] in [["priority": 4], ["priority": 1.5], ["version": -1], ["dueDate": "2026-02-30"], ["dueTime": "25:00"], ["reminders": Array(repeating: "2026-11-03T12:00:00Z", count: 101)], ["recurrence": ["frequency": "bad", "interval": 1, "timeZone": "UTC"]]] {
                let r = try await call(f, "update_task_planning", bad.merging(["taskID": id]) { $1 }, token)
                XCTAssertTrue(r.0, r.1)
            }
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    func testDependencyReplacementCycleRemovalAndGrant() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access
            let db = f.test.app.db
            let a = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "A", details: "")
            let b = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "B", details: "")
            let hidden = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Hidden", details: "")
            try await a.save(on: db); try await b.save(on: db); try await hidden.save(on: db)
            let aid = try a.requireID().uuidString, bid = try b.requireID().uuidString, hid = try hidden.requireID().uuidString
            let set = try await call(f, "set_dependencies", ["taskID": aid, "blockedBy": [bid]], token)
            XCTAssertFalse(set.0, set.1)
            let list = try await call(f, "list_dependencies", ["taskID": aid], token)
            XCTAssertEqual((list.2 as? [[String: Any]])?.count, 1)
            let cycle = try await call(f, "set_dependencies", ["taskID": bid, "blockedBy": [aid]], token)
            XCTAssertTrue(cycle.0); XCTAssertEqual(cycle.1, "dependency_cycle")
            let hiddenSet = try await call(f, "set_dependencies", ["taskID": aid, "blockedBy": [hid]], token)
            XCTAssertTrue(hiddenSet.0); XCTAssertEqual(hiddenSet.1, "not_found")
            let preserved = try await call(f, "list_dependencies", ["taskID": aid], token)
            XCTAssertEqual((preserved.2 as? [[String: Any]])?.count, 1)
            let hiddenRemove = try await call(f, "remove_dependency", ["taskID": aid, "otherTaskID": hid], token)
            XCTAssertTrue(hiddenRemove.0); XCTAssertEqual(hiddenRemove.1, "not_found")
            let removed = try await call(f, "remove_dependency", ["taskID": aid, "otherTaskID": bid], token)
            XCTAssertFalse(removed.0, removed.1)
            let clear = try await call(f, "set_dependencies", ["taskID": aid, "blockedBy": []], token)
            XCTAssertFalse(clear.0, clear.1)
            let notes = try await ActivityEvent.query(on: db).filter(\.$taskID == a.requireID()).all()
            XCTAssertTrue(notes.contains { $0.kind == "task.dependency_added" })
            XCTAssertTrue(notes.contains { $0.kind == "task.dependency_removed" })
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMilestoneLifecycleRequiresConfirmation() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access, db = f.test.app.db
            let pid = try f.project.requireID().uuidString
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Task", details: "")
            try await task.save(on: db)
            let tid = try task.requireID().uuidString
            let created = try await call(f, "create_milestone", ["projectID": pid, "title": "Release", "dueDate": "2026-12-01"], token)
            XCTAssertFalse(created.0, created.1)
            let mid = try XCTUnwrap((created.2 as? [String: Any])?["id"] as? String)
            let args = ["taskID": tid, "milestoneID": mid]
            let assigned = try await call(f, "assign_milestone", args, token)
            XCTAssertFalse(assigned.0, assigned.1)
            let list = try await call(f, "list_milestones", ["projectID": pid], token)
            let milestone = try XCTUnwrap((list.2 as? [[String: Any]])?.first)
            XCTAssertEqual((milestone["tasks"] as? [[String: Any]])?.count, 1)
            let unassigned = try await call(f, "unassign_milestone", args, token)
            XCTAssertFalse(unassigned.0, unassigned.1)
            let deletion = try await call(f, "delete_milestone", ["milestoneID": mid], token)
            XCTAssertTrue(deletion.0)
            let pending = try XCTUnwrap(deletion.2 as? [String: Any])
            XCTAssertEqual(pending["error"] as? String, "confirmation_required")
            let stored = try await PlanningMilestone.find(UUID(uuidString: mid)!, on: db)
            XCTAssertNotNil(stored)
            let again = try await call(f, "delete_milestone", ["milestoneID": mid], token)
            XCTAssertEqual((again.2 as? [String: Any])?["actionRequestID"] as? String, pending["actionRequestID"] as? String)
            let requestID = try XCTUnwrap((pending["actionRequestID"] as? String).flatMap(UUID.init(uuidString:)))
            let confirmed = try await ActionRequestService(user: f.user, db: db).confirm(requestID)
            XCTAssertEqual(confirmed.state, "executed")
            let gone = try await PlanningMilestone.find(UUID(uuidString: mid)!, on: db)
            XCTAssertNil(gone)
            let remaining = try await TodoTask.find(task.requireID(), on: db)
            XCTAssertNotNil(remaining)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testEveryToolScopeGrantRoleAndInvalidArguments() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let writer = try await f.tokens().access
            let noScope = try await f.tokens(scope: "projects:read").access
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Task", details: "")
            let hidden = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Hidden", details: "")
            try await task.save(on: db); try await hidden.save(on: db)
            let m = try await PlanningService(user: f.user, db: db).createMilestone(projectID: f.project.requireID(), title: "M", dueAt: nil)
            let hm = try await PlanningService(user: f.user, db: db).createMilestone(projectID: f.other.requireID(), title: "H", dueAt: nil)
            func args(_ name: String, hidden outside: Bool) throws -> [String: Any] {
                let tid = try (outside ? hidden : task).requireID().uuidString
                let pid = try (outside ? f.other : f.project).requireID().uuidString
                let mid = try (outside ? hm : m).requireID().uuidString
                switch name {
                case "list_planned_tasks": return ["view": "today", "projectID": pid]
                case "list_milestones": return ["projectID": pid]
                case "create_milestone": return ["projectID": pid, "title": "New"]
                case "delete_milestone": return ["milestoneID": mid]
                case "assign_milestone", "unassign_milestone": return ["taskID": tid, "milestoneID": mid]
                case "set_dependencies": return ["taskID": tid, "blockedBy": []]
                case "remove_dependency": return ["taskID": tid, "otherTaskID": tid]
                default: return ["taskID": tid]
                }
            }
            for name in names {
                let scope = try await call(f, name, args(name, hidden: false), noScope)
                XCTAssertTrue(scope.0, name); XCTAssertEqual(scope.1, "insufficient_scope", name)
                let grant = try await call(f, name, args(name, hidden: true), writer)
                XCTAssertTrue(grant.0, name); XCTAssertEqual(grant.1, "not_found", name)
                let invalid = try await call(f, name, [:], writer)
                XCTAssertTrue(invalid.0, name)
            }
            // Remove current rights while retaining the OAuth connection and its project list.
            let owner = User(displayName: "New owner", isAdmin: false); try await owner.save(on: db)
            let sharing = try await ProjectSharing.query(on: db).filter(\.$projectID == f.project.requireID()).first() ?? ProjectSharing(project: f.project)
            sharing.ownerType = "person"; sharing.ownerID = try owner.requireID(); try await sharing.save(on: db)
            f.project.ownerID = try owner.requireID(); try await f.project.save(on: db)
            for name in names {
                let role = try await call(f, name, args(name, hidden: false), writer)
                XCTAssertTrue(role.0, name)
            }
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testPlannedViewsAndLimitsMatchRESTAndExcludeHiddenProjects() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access, db = f.test.app.db
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let today = cal.startOfDay(for: Date()).addingTimeInterval(3600)
            for project in [f.project, f.other] {
                for offset in [0, 2] {
                    let task = TodoTask(ownerID: try f.user.requireID(), projectID: try project.requireID(), title: "Due", details: "")
                    try await task.save(on: db)
                    _ = try await db.transaction { tx in
                        try await PlanningService(user: f.user, db: tx).put(task.requireID(), data: PlanningData(dueAt: today.addingTimeInterval(Double(offset) * 86400), priority: 2, reminders: []))
                    }
                }
            }
            for (view, path) in [("today", "today"), ("upcoming", "upcoming"), ("up_next", "up-next")] {
                let result = try await call(f, "list_planned_tasks", ["view": view], token)
                XCTAssertFalse(result.0, result.1)
                let rows = try XCTUnwrap(result.2 as? [[String: Any]])
                XCTAssertEqual(rows.count, view == "up_next" ? 2 : 1)
                let rest = try await f.test.json(.GET, "/v1/planning/" + path, token: f.session)
                let visible = rest.list?.filter { ($0["task"] as? [String: Any])?["projectID"] as? String == (try? f.project.requireID().uuidString) }
                XCTAssertEqual(rows.map { ($0["task"] as? [String: Any])?["id"] as? String }, visible?.map { ($0["task"] as? [String: Any])?["id"] as? String })
                let limited = try await call(f, "list_planned_tasks", ["view": view, "limit": 1], token)
                XCTAssertEqual((limited.2 as? [[String: Any]])?.count, 1)
            }
            for limit in [0, -1, 201] {
                let invalid = try await call(f, "list_planned_tasks", ["view": "today", "limit": limit], token)
                XCTAssertTrue(invalid.0)
            }
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testPlanningPatchPreservesFieldsClearsAndWritesSync() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access, db = f.test.app.db
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Recurring", details: "")
            try await task.save(on: db)
            let tid = try task.requireID().uuidString
            let before = try await SyncChange.query(on: db).filter(\.$entityID == task.requireID()).count()
            let first = try await call(f, "update_task_planning", ["taskID": tid, "version": 1, "dueAt": "2026-11-03T12:30:00Z", "plannedAt": "2026-11-02T08:00:00Z", "recurrence": ["frequency": "daily", "interval": 2, "timeZone": "Europe/Berlin"], "reminders": ["2026-11-03T12:00:00.123Z"]], token)
            XCTAssertFalse(first.0, first.1)
            let second = try await call(f, "update_task_planning", ["taskID": tid, "version": 2, "priority": 2], token)
            XCTAssertFalse(second.0, second.1)
            let value = try XCTUnwrap(second.2 as? [String: Any])
            XCTAssertEqual(value["dueAt"] as? String, "2026-11-03T12:30:00Z")
            XCTAssertEqual((value["reminders"] as? [String])?.count, 1)
            XCTAssertEqual((value["recurrence"] as? [String: Any])?["interval"] as? Int, 2)
            let clear = try await call(f, "update_task_planning", ["taskID": tid, "dueDate": NSNull(), "plannedAt": NSNull(), "recurrence": NSNull(), "reminders": []], token)
            XCTAssertFalse(clear.0, clear.1)
            let row = try await TaskPlanning.find(task.requireID(), on: db)
            XCTAssertNil(row?.dueAt); XCTAssertNil(row?.plannedAt); XCTAssertNil(row?.recurrence); XCTAssertEqual(row?.reminders.count, 0)
            let after = try await SyncChange.query(on: db).filter(\.$entityID == task.requireID()).count()
            XCTAssertEqual(after, before + 3)
            // Existing task tools still work.
            let get = try await call(f, "get_task", ["id": tid], token)
            XCTAssertFalse(get.0, get.1)
            let list = try await call(f, "list_tasks", ["projectID": try f.project.requireID().uuidString], token)
            XCTAssertFalse(list.0, list.1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testConfirmationRechecksGrantAndKeepsMilestone() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access, db = f.test.app.db
            let m = try await PlanningService(user: f.user, db: db).createMilestone(projectID: f.project.requireID(), title: "M", dueAt: nil)
            let deletion = try await call(f, "delete_milestone", ["milestoneID": try m.requireID().uuidString], token)
            let rid = try XCTUnwrap((deletion.2 as? [String: Any])?["actionRequestID"] as? String)
            let request = try await ActionRequest.find(UUID(uuidString: rid)!, on: db)
            let grant = try await OAuthGrant.find(XCTUnwrap(request?.grantID), on: db)
            grant?.projects = []; try await grant?.save(on: db)
            let result = try await ActionRequestService(user: f.user, db: db).confirm(UUID(uuidString: rid)!)
            XCTAssertEqual(result.state, "failed"); XCTAssertEqual(result.result?.code, "not_found")
            let stillPresent = try await PlanningMilestone.find(m.requireID(), on: db)
            XCTAssertNotNil(stillPresent)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testReadOnlyRoleCannotWritePlanningDependenciesOrMilestones() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access, db = f.test.app.db
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Task", details: "")
            try await task.save(on: db)
            let m = try await PlanningService(user: f.user, db: db).createMilestone(projectID: f.project.requireID(), title: "M", dueAt: nil)
            let owner = User(displayName: "Owner", isAdmin: false); try await owner.save(on: db)
            let policy = try await ProjectSharing.query(on: db).filter(\.$projectID == f.project.requireID()).first() ?? ProjectSharing(project: f.project)
            policy.ownerType = "person"; policy.ownerID = try owner.requireID(); try await policy.save(on: db)
            f.project.ownerID = try owner.requireID(); try await f.project.save(on: db)
            try await ProjectGrant(projectID: f.project.requireID(), principalType: "person", principalID: f.user.requireID(), role: .read).save(on: db)
            let tid = try task.requireID().uuidString, mid = try m.requireID().uuidString
            let cases: [(String, [String: Any])] = [
                ("update_task_planning", ["taskID": tid, "priority": 1]),
                ("set_dependencies", ["taskID": tid, "blockedBy": []]),
                ("remove_dependency", ["taskID": tid, "otherTaskID": tid]),
                ("create_milestone", ["projectID": try f.project.requireID().uuidString, "title": "New"]),
                ("assign_milestone", ["taskID": tid, "milestoneID": mid]),
                ("unassign_milestone", ["taskID": tid, "milestoneID": mid]),
                ("delete_milestone", ["milestoneID": mid])]
            for (name, args) in cases {
                let result = try await call(f, name, args, token)
                XCTAssertTrue(result.0, name)
            }
            let read = try await call(f, "get_task_planning", ["taskID": tid], token)
            XCTAssertFalse(read.0, read.1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMilestoneMembersOutsideGrantAreHiddenAndPreventDeletionRequest() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access, db = f.test.app.db
            let child = Project(ownerID: try f.user.requireID(), parentID: try f.project.requireID(), name: "Unselected child")
            try await child.save(on: db)
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try child.requireID(), title: "Private member", details: "")
            try await task.save(on: db)
            let s = PlanningService(user: f.user, db: db)
            let m = try await s.createMilestone(projectID: f.project.requireID(), title: "Parent milestone", dueAt: nil)
            try await db.transaction { tx in try await PlanningService(user: f.user, db: tx).milestoneMembership(m.requireID(), taskID: task.requireID(), remove: false) }
            let mid = try m.requireID().uuidString
            let list = try await call(f, "list_milestones", ["projectID": try f.project.requireID().uuidString], token)
            XCTAssertFalse(list.0, list.1)
            XCTAssertFalse(list.1.contains("Private member"))
            XCTAssertEqual(((list.2 as? [[String: Any]])?.first?["tasks"] as? [[String: Any]])?.count, 0)
            for name in ["assign_milestone", "unassign_milestone"] {
                let result = try await call(f, name, ["taskID": try task.requireID().uuidString, "milestoneID": mid], token)
                XCTAssertTrue(result.0); XCTAssertEqual(result.1, "not_found")
            }
            let deletion = try await call(f, "delete_milestone", ["milestoneID": mid], token)
            XCTAssertTrue(deletion.0); XCTAssertEqual(deletion.1, "not_found")
            let requests = try await ActionRequest.query(on: db).count()
            XCTAssertEqual(requests, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

}
