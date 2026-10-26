import Fluent
import XCTVapor
@testable import TodoKit

final class PlanningExtTests: XCTestCase {
    struct Fixture {
        let t: TestApp
        let token: String
        let foreignToken: String
        let project: String
        let child: String
        let tasks: [String]
        let foreignTask: String
    }

    private func fixture() async throws -> Fixture {
        let t = try await TestApp.make()
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let invitation = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: invitation.body!["token"] as! String, name: "Bob")
        let p = try await t.json(.POST, "/v1/projects", ["name": "Root"], token: a.session)
        let pid = try XCTUnwrap(p.body?["id"] as? String)
        let child = try await t.json(.POST, "/v1/projects", ["name": "Child", "parentID": pid], token: a.session)
        let childID = try XCTUnwrap(child.body?["id"] as? String)
        var tasks: [String] = []
        for title in ["A", "B", "C"] {
            let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": title], token: a.session)
            tasks.append(try XCTUnwrap(task.body?["id"] as? String))
        }
        let foreign = try await t.json(.POST, "/v1/projects", ["name": "Private title"], token: b.session)
        let foreignTask = try await t.json(.POST, "/v1/tasks", ["projectID": foreign.body!["id"]!, "title": "Private task"], token: b.session)
        return Fixture(t: t, token: a.session, foreignToken: b.session, project: pid, child: childID,
                       tasks: tasks, foreignTask: try XCTUnwrap(foreignTask.body?["id"] as? String))
    }

    private func put(_ f: Fixture, _ id: String, _ data: [String: Any]) async throws -> HTTPStatus {
        try await f.t.json(.PUT, "/v1/planning/tasks/\(id)", data, token: f.token).status
    }

    func testSeparateDatesDueViewsAndVisibility() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let format = ISO8601DateFormatter()
        let now = format.string(from: Date()), future = format.string(from: Date().addingTimeInterval(3 * 86400))
        let a = try await put(f, f.tasks[0], ["dueAt": now, "plannedAt": future, "priority": 3, "reminders": [now]])
        XCTAssertEqual(a, .ok)
        let b = try await put(f, f.tasks[1], ["plannedAt": now, "priority": 0, "reminders": []])
        XCTAssertEqual(b, .ok)
        _ = try await put(f, f.tasks[2], ["dueAt": future, "priority": 1, "reminders": []])
        _ = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.foreignTask)", ["dueAt": now, "priority": 3, "reminders": []], token: f.foreignToken)
        let today = try await f.t.json(.GET, "/v1/planning/today", token: f.token)
        XCTAssertEqual(today.list?.count, 1)
        XCTAssertEqual((today.list?.first?["task"] as? [String: Any])?["id"] as? String, f.tasks[0])
        XCTAssertEqual(today.list?.first?["plannedAt"] as? String, future)
        let upcoming = try await f.t.json(.GET, "/v1/planning/upcoming", token: f.token)
        XCTAssertEqual(upcoming.list?.count, 1)
        let next = try await f.t.json(.GET, "/v1/planning/up-next", token: f.token)
        XCTAssertEqual(next.list?.count, 3)
        let denied = try await f.t.json(.GET, "/v1/planning/tasks/\(f.tasks[0])", token: f.foreignToken)
        XCTAssertEqual(denied.status, .notFound)
        let noAuth = try await f.t.json(.GET, "/v1/planning/today")
        XCTAssertEqual(noAuth.status, .unauthorized)
        let invalid = try await put(f, f.tasks[0], ["priority": 4, "reminders": []])
        XCTAssertEqual(invalid, .badRequest)
        let cleared = try await put(f, f.tasks[0], ["priority": 0, "reminders": []])
        XCTAssertEqual(cleared, .ok)
        let read = try await f.t.json(.GET, "/v1/planning/tasks/\(f.tasks[0])", token: f.token)
        XCTAssertNil(read.body?["dueAt"])
        XCTAssertEqual((read.body?["reminders"] as? [String])?.count, 0)
    }

    func testDependencyCyclesPermissionsAndBlockedView() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        func edge(_ a: String, _ b: String) async throws -> HTTPStatus {
            try await f.t.json(.PUT, "/v1/planning/tasks/\(a)/dependencies", ["prerequisiteID": b], token: f.token).status
        }
        let ab = try await edge(f.tasks[0], f.tasks[1]); XCTAssertEqual(ab, .noContent)
        let bc = try await edge(f.tasks[1], f.tasks[2]); XCTAssertEqual(bc, .noContent)
        let ca = try await edge(f.tasks[2], f.tasks[0]); XCTAssertEqual(ca, .unprocessableEntity)
        let selfEdge = try await edge(f.tasks[0], f.tasks[0]); XCTAssertEqual(selfEdge, .unprocessableEntity)
        let duplicate = try await edge(f.tasks[0], f.tasks[1]); XCTAssertEqual(duplicate, .noContent)
        let foreign = try await edge(f.tasks[0], f.foreignTask); XCTAssertEqual(foreign, .notFound)
        let next = try await f.t.json(.GET, "/v1/planning/up-next", token: f.token)
        XCTAssertEqual(next.list?.count, 1)
        // Simulate a previously permitted link whose target is no longer visible.
        try await PlanningDependency(UUID(uuidString: f.tasks[2])!, UUID(uuidString: f.foreignTask)!).save(on: f.t.app.db)
        let dependencies = try await f.t.json(.GET, "/v1/planning/tasks/\(f.tasks[2])/dependencies", token: f.token)
        XCTAssertEqual(dependencies.list?.count, 0)
        let blocked = try await f.t.json(.GET, "/v1/planning/up-next", token: f.token)
        XCTAssertEqual(blocked.list?.count, 0)
        let done = try await f.t.json(.PATCH, "/v1/tasks/\(f.tasks[1])", ["version": 1, "status": "done"], token: f.token)
        XCTAssertEqual(done.status, .ok)
        let unblocked = try await f.t.json(.GET, "/v1/planning/up-next", token: f.token)
        XCTAssertEqual(unblocked.list?.count, 1)
        let removed = try await f.t.json(.DELETE, "/v1/planning/tasks/\(f.tasks[0])/dependencies/\(f.tasks[1])", token: f.token)
        XCTAssertEqual(removed.status, .noContent)
    }

    func testBoardReorderAndMilestonesAcrossDescendants() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let order = Array(f.tasks.reversed())
        let reorder = try await f.t.json(.PUT, "/v1/planning/board/reorder", ["projectID": f.project, "status": "open", "taskIDs": order], token: f.token)
        XCTAssertEqual(reorder.status, .noContent)
        let board = try await f.t.json(.GET, "/v1/planning/board?projectID=\(f.project)&status=open", token: f.token)
        XCTAssertEqual(board.list?.compactMap { ($0["task"] as? [String: Any])?["id"] as? String }, order)
        let bad = try await f.t.json(.PUT, "/v1/planning/board/reorder", ["projectID": f.project, "status": "open", "taskIDs": [f.foreignTask]], token: f.token)
        XCTAssertEqual(bad.status, .conflict)
        let forbidden = try await f.t.json(.GET, "/v1/planning/board?projectID=\(f.project)&status=open", token: f.foreignToken)
        XCTAssertEqual(forbidden.status, .notFound)
        let m = try await f.t.json(.POST, "/v1/planning/milestones", ["projectID": f.project, "title": "Release"], token: f.token)
        XCTAssertEqual(m.status, .ok)
        let mid = try XCTUnwrap(m.body?["id"] as? String)
        let childTask = try await f.t.json(.POST, "/v1/tasks", ["projectID": f.child, "title": "Deliver"], token: f.token)
        let tid = try XCTUnwrap(childTask.body?["id"] as? String)
        let attach = try await f.t.json(.PUT, "/v1/planning/milestones/\(mid)/tasks/\(tid)", token: f.token)
        XCTAssertEqual(attach.status, .noContent)
        let foreign = try await f.t.json(.PUT, "/v1/planning/milestones/\(mid)/tasks/\(f.foreignTask)", token: f.token)
        XCTAssertEqual(foreign.status, .notFound)
        let list = try await f.t.json(.GET, "/v1/planning/milestones?projectID=\(f.project)", token: f.token)
        XCTAssertEqual((list.list?.first?["tasks"] as? [[String: Any]])?.count, 1)
        let denied = try await f.t.json(.DELETE, "/v1/planning/milestones/\(mid)", token: f.foreignToken)
        XCTAssertEqual(denied.status, .notFound)
        let detach = try await f.t.json(.DELETE, "/v1/planning/milestones/\(mid)/tasks/\(tid)", token: f.token)
        XCTAssertEqual(detach.status, .noContent)
        let delete = try await f.t.json(.DELETE, "/v1/planning/milestones/\(mid)", token: f.token)
        XCTAssertEqual(delete.status, .noContent)
    }

    func testRecurrenceAtomicCompletionRetryAndNextGeneration() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        let data: [String: Any] = ["dueAt": "2026-03-28T09:00:00Z", "plannedAt": "2026-03-27T09:00:00Z", "priority": 2,
                                   "reminders": ["2026-03-28T08:00:00Z"],
                                   "recurrence": ["frequency": "daily", "interval": 1, "timeZone": "Europe/Berlin"]]
        let setup = try await put(f, id, data); XCTAssertEqual(setup, .ok)
        let done = try await f.t.json(.PATCH, "/v1/tasks/\(id)", ["version": 1, "status": "done"], token: f.token)
        XCTAssertEqual(done.status, .ok)
        let receipt = try await PlanningOccurrence.find(UUID(uuidString: id)!, on: f.t.app.db)
        let nextID = try XCTUnwrap(receipt?.nextTaskID)
        let next = try await TaskPlanning.find(nextID, on: f.t.app.db)
        XCTAssertEqual(next?.dueAt, ISO8601DateFormatter().date(from: "2026-03-29T08:00:00Z"))
        XCTAssertEqual(next?.plannedAt, ISO8601DateFormatter().date(from: "2026-03-28T09:00:00Z"))
        XCTAssertEqual(next?.priority, 2)
        XCTAssertEqual(next?.reminders.first, ISO8601DateFormatter().date(from: "2026-03-29T07:00:00Z"))
        let stale = try await f.t.json(.PATCH, "/v1/tasks/\(id)", ["version": 1, "status": "done"], token: f.token)
        XCTAssertEqual(stale.status, .conflict)
        for (version, status) in [(2, "open"), (3, "done"), (4, "done")] {
            let response = try await f.t.json(.PATCH, "/v1/tasks/\(id)", ["version": version, "status": status], token: f.token)
            XCTAssertEqual(response.status, .ok)
        }
        let count = try await PlanningOccurrence.query(on: f.t.app.db).count(); XCTAssertEqual(count, 1)
        let nextDone = try await f.t.json(.PATCH, "/v1/tasks/\(nextID)", ["version": 1, "status": "done"], token: f.token)
        XCTAssertEqual(nextDone.status, .ok)
        let count2 = try await PlanningOccurrence.query(on: f.t.app.db).count(); XCTAssertEqual(count2, 2)
    }

    func testRecurrenceValidationAndUntil() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let missing = try await put(f, f.tasks[0], ["priority": 0, "reminders": [], "recurrence": ["frequency": "daily", "interval": 1, "timeZone": "UTC"]])
        XCTAssertEqual(missing, .badRequest)
        let invalid = try await put(f, f.tasks[0], ["dueAt": "2026-01-01T00:00:00Z", "priority": 0, "reminders": [], "recurrence": ["frequency": "daily", "interval": 0, "timeZone": "UTC"]])
        XCTAssertEqual(invalid, .badRequest)
        let setup = try await put(f, f.tasks[0], ["dueAt": "2026-01-01T00:00:00Z", "priority": 0, "reminders": [], "recurrence": ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "until": "2026-01-31T00:00:00Z"]])
        XCTAssertEqual(setup, .ok)
        let response = try await f.t.json(.PATCH, "/v1/tasks/\(f.tasks[0])", ["version": 1, "status": "done"], token: f.token)
        XCTAssertEqual(response.status, .ok)
        let receipt = try await PlanningOccurrence.find(UUID(uuidString: f.tasks[0])!, on: f.t.app.db)
        XCTAssertNotNil(receipt); XCTAssertNil(receipt?.nextTaskID)
    }

    func testSharedAndTeamRightsGovernPlanningViewsAndWrites() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let guest = User(displayName: "Guest", isAdmin: false)
        try await guest.save(on: f.t.app.db)
        let gtoken = AuthSupport.randomToken()
        try await UserSession(userID: guest.requireID(), tokenHash: AuthSupport.hash(gtoken),
            expiresAt: Date().addingTimeInterval(3600)).save(on: f.t.app.db)
        let gid = try guest.requireID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await put(f, f.tasks[0], ["dueAt": now, "priority": 2, "reminders": []])
        // Without any grant the owner's tasks are invisible and absent from lists.
        let none = try await f.t.json(.GET, "/v1/planning/up-next", token: gtoken)
        XCTAssertEqual(none.list?.count, 0)
        let hidden = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[0])/dependencies", ["prerequisiteID": f.tasks[1]], token: gtoken)
        XCTAssertEqual(hidden.status, .notFound)
        // Team membership grants read access through the team principal.
        let team = try await f.t.json(.POST, "/v1/teams", ["name": "T"], token: f.token)
        let tid = try XCTUnwrap(team.body?["id"] as? String)
        _ = try await f.t.json(.PUT, "/v1/teams/\(tid)/members", ["userID": gid, "isAdmin": false], token: f.token)
        _ = try await f.t.json(.POST, "/v1/teams/\(tid)/accept", token: gtoken)
        let grant = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants",
            ["principalType": "team", "principalID": tid, "role": "read"], token: f.token)
        XCTAssertEqual(grant.status, .ok)
        let today = try await f.t.json(.GET, "/v1/planning/today", token: gtoken)
        XCTAssertEqual(today.list?.count, 1)
        let next = try await f.t.json(.GET, "/v1/planning/up-next", token: gtoken)
        XCTAssertEqual(next.list?.count, 3)
        let write = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[0])", ["priority": 3, "reminders": []], token: gtoken)
        XCTAssertEqual(write.status, .forbidden)
        let reorder = try await f.t.json(.PUT, "/v1/planning/board/reorder",
            ["projectID": f.project, "status": "open", "taskIDs": f.tasks], token: gtoken)
        XCTAssertEqual(reorder.status, .forbidden)
        // Upgrading to edit allows writes.
        _ = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants",
            ["principalType": "team", "principalID": tid, "role": "edit"], token: f.token)
        let ok = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[0])", ["priority": 3, "reminders": []], token: gtoken)
        XCTAssertEqual(ok.status, .ok)
        // A dependency onto a task the guest cannot see is a 404 and never leaks.
        let leak = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[0])/dependencies", ["prerequisiteID": f.foreignTask], token: gtoken)
        XCTAssertEqual(leak.status, .notFound)
    }

    func testMariaDBParallelCompletionAcrossReplicas() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "Requires MariaDB and TODO_TEST_DB")
        let f = try await fixture(), replica = try await f.t.replica()
        defer { Task { await f.t.shutdown(); await replica.shutdown() } }
        let setup = try await put(f, f.tasks[0], ["dueAt": "2026-01-01T00:00:00Z", "priority": 1, "reminders": [], "recurrence": ["frequency": "weekly", "interval": 2, "timeZone": "UTC"]])
        XCTAssertEqual(setup, .ok)
        let body = try JSONSerialization.data(withJSONObject: ["version": 1, "status": "done"])
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<12 {
                let app = i.isMultiple(of: 2) ? f.t : replica
                let path = "/v1/tasks/\(f.tasks[0])", token = f.token
                group.addTask { try await app.rawStatus(.PATCH, path, body: body, token: token) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 11)
        let count = try await PlanningOccurrence.query(on: f.t.app.db).count(); XCTAssertEqual(count, 1)
        let tasks = try await TodoTask.query(on: f.t.app.db).filter(\.$projectID == UUID(uuidString: f.project)!).count()
        XCTAssertEqual(tasks, 4)
    }

    func testMariaDBOpposingDependencyRace() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "Requires MariaDB and TODO_TEST_DB")
        let f = try await fixture(), replica = try await f.t.replica()
        defer { Task { await f.t.shutdown(); await replica.shutdown() } }
        let bodyA = try JSONSerialization.data(withJSONObject: ["prerequisiteID": f.tasks[1]])
        let bodyB = try JSONSerialization.data(withJSONObject: ["prerequisiteID": f.tasks[0]])
        async let a = f.t.rawStatus(.PUT, "/v1/planning/tasks/\(f.tasks[0])/dependencies", body: bodyA, token: f.token)
        async let b = replica.rawStatus(.PUT, "/v1/planning/tasks/\(f.tasks[1])/dependencies", body: bodyB, token: f.token)
        let statuses = try await [a, b]
        XCTAssertEqual(statuses.filter { $0 == .noContent }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .unprocessableEntity }.count, 1)
    }
}
