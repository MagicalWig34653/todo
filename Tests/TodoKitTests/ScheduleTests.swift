import Fluent
import XCTVapor
@testable import TodoKit

final class ScheduleTests: XCTestCase {
    struct Fixture {
        let t: TestApp
        let alice: String
        let bob: String
        let bobID: String
        let project: String
        let tasks: [String]
        let foreignTask: String
    }

    private let iso = ISO8601DateFormatter()
    // Fixed instant keeps the window math deterministic.
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let none: [String] = []

    private func fixture() async throws -> Fixture {
        let t = try await TestApp.make()
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let invitation = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: invitation.body!["token"] as! String, name: "Bob")
        let p = try await t.json(.POST, "/v1/projects", ["name": "Root"], token: a.session)
        let pid = try XCTUnwrap(p.body?["id"] as? String)
        var tasks: [String] = []
        for title in ["A", "B", "C"] {
            let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": title], token: a.session)
            tasks.append(try XCTUnwrap(task.body?["id"] as? String))
        }
        let foreign = try await t.json(.POST, "/v1/projects", ["name": "Private"], token: b.session)
        let ft = try await t.json(.POST, "/v1/tasks", ["projectID": foreign.body!["id"]!, "title": "Private task"], token: b.session)
        return Fixture(t: t, alice: a.session, bob: b.session, bobID: b.userID, project: pid, tasks: tasks, foreignTask: try XCTUnwrap(ft.body?["id"] as? String))
    }

    private func version(_ f: Fixture, _ id: String) async throws -> Int {
        let r = try await f.t.json(.GET, "/v1/planning/tasks/\(id)", token: f.alice)
        return try XCTUnwrap((r.body?["task"] as? [String: Any])?["version"] as? Int)
    }

    private func patch(_ f: Fixture, _ id: String, _ body: [String: Any], token: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.t.json(.PATCH, "/v1/tasks/\(id)/schedule", body, token: token ?? f.alice)
        return (r.status, r.body)
    }

    private func schedule(_ f: Fixture, from: Date, to: Date, extra: String = "", token: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.t.json(.GET, "/v1/planning/schedule?from=\(iso.string(from: from))&to=\(iso.string(from: to))\(extra)", token: token ?? f.alice)
        return (r.status, r.body)
    }

    func testPatchChangesOnlyScheduleFieldsAndBumpsVersion() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        let due = iso.string(from: base.addingTimeInterval(86400))
        let put = try await f.t.json(.PUT, "/v1/planning/tasks/\(id)", [
            "dueAt": due, "priority": 3, "reminders": [due],
            "recurrence": ["frequency": "daily", "interval": 1, "timeZone": "UTC"],
        ], token: f.alice)
        XCTAssertEqual(put.status, .ok)
        let v = try await version(f, id)
        let start = iso.string(from: base)
        let r = try await patch(f, id, ["version": v, "plannedAt": start, "plannedMinutes": 45])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["plannedAt"] as? String, start)
        XCTAssertEqual(r.body?["plannedMinutes"] as? Int, 45)
        XCTAssertEqual(r.body?["plannedAllDay"] as? Bool, false)
        XCTAssertEqual(r.body?["priority"] as? Int, 3)
        XCTAssertEqual(r.body?["dueAt"] as? String, due)
        XCTAssertEqual((r.body?["reminders"] as? [String])?.count, 1)
        XCTAssertNotNil(r.body?["recurrence"] as? [String: Any])
        XCTAssertEqual((r.body?["task"] as? [String: Any])?["version"] as? Int, v + 1)
        // Moving keeps the duration when only the start is sent.
        let moved = try await patch(f, id, ["version": v + 1, "plannedAt": iso.string(from: base.addingTimeInterval(3600))])
        XCTAssertEqual(moved.body?["plannedMinutes"] as? Int, 45)
        let events = try await ActivityEvent.query(on: f.t.app.db).filter(\.$taskID == UUID(uuidString: id)!).all()
        XCTAssertEqual(events.filter { $0.kind == "task.scheduled" }.count, 2)
    }

    func testPatchVersionConflictAndValidation() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        let v = try await version(f, id)
        let start = iso.string(from: base)
        let stale = try await patch(f, id, ["version": v + 5, "plannedAt": start])
        XCTAssertEqual(stale.status, .conflict)
        let missing = try await f.t.json(.PATCH, "/v1/tasks/\(id)/schedule", ["plannedAt": start], token: f.alice)
        XCTAssertEqual(missing.status, .badRequest)
        for bad in [4, 1441, 0, -5] {
            let r = try await patch(f, id, ["version": v, "plannedAt": start, "plannedMinutes": bad])
            XCTAssertEqual(r.status, .badRequest, "minutes \(bad)")
        }
        let allDayWithoutStart = try await patch(f, id, ["version": v, "plannedAllDay": true])
        XCTAssertEqual(allDayWithoutStart.status, .badRequest)
        let unchanged = try await version(f, id)
        XCTAssertEqual(unchanged, v)
    }

    func testClearingStartClearsDurationAndAllDay() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        var v = try await version(f, id)
        let set = try await patch(f, id, ["version": v, "plannedAt": iso.string(from: base), "plannedMinutes": 60, "plannedAllDay": true])
        XCTAssertEqual(set.status, .ok)
        XCTAssertEqual(set.body?["plannedAllDay"] as? Bool, true)
        v += 1
        let cleared = try await patch(f, id, ["version": v, "plannedAt": NSNull()])
        XCTAssertEqual(cleared.status, .ok)
        XCTAssertTrue(cleared.body?["plannedAt"] == nil || cleared.body?["plannedAt"] is NSNull)
        XCTAssertTrue(cleared.body?["plannedMinutes"] == nil || cleared.body?["plannedMinutes"] is NSNull)
        XCTAssertEqual(cleared.body?["plannedAllDay"] as? Bool, false)
    }

    func testClearingStartWithRecurrenceAndNoDueIsRejected() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        let start = iso.string(from: base)
        _ = try await f.t.json(.PUT, "/v1/planning/tasks/\(id)", [
            "plannedAt": start, "priority": 0, "reminders": none,
            "recurrence": ["frequency": "daily", "interval": 1, "timeZone": "UTC"],
        ], token: f.alice)
        let v = try await version(f, id)
        let r = try await patch(f, id, ["version": v, "plannedAt": NSNull()])
        XCTAssertEqual(r.status, .badRequest)
        XCTAssertEqual(r.body?["reason"] as? String, "recurrence_requires_date")
    }

    func testPatchRights() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0], v = try await version(f, id), start = iso.string(from: base)
        let foreign = try await patch(f, id, ["version": v, "plannedAt": start], token: f.bob)
        XCTAssertEqual(foreign.status, .notFound)
        let noAuth = try await f.t.json(.PATCH, "/v1/tasks/\(id)/schedule", ["version": v, "plannedAt": start])
        XCTAssertEqual(noAuth.status, .unauthorized)
        let grant = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants", ["principalType": "person", "principalID": f.bobID, "role": "read"], token: f.alice)
        XCTAssertEqual(grant.status, .ok)
        let readOnly = try await patch(f, id, ["version": v, "plannedAt": start], token: f.bob)
        XCTAssertEqual(readOnly.status, .forbidden)
        let edit = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants", ["principalType": "person", "principalID": f.bobID, "role": "edit"], token: f.alice)
        XCTAssertEqual(edit.status, .ok)
        let allowed = try await patch(f, id, ["version": v, "plannedAt": start], token: f.bob)
        XCTAssertEqual(allowed.status, .ok)
    }

    func testDoneTasksAreNotMoved() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        var v = try await version(f, id)
        let done = try await f.t.json(.PATCH, "/v1/tasks/\(id)", ["version": v, "status": "done"], token: f.alice)
        XCTAssertEqual(done.status, .ok)
        v = try await version(f, id)
        let r = try await patch(f, id, ["version": v, "plannedAt": iso.string(from: base)])
        XCTAssertEqual(r.status, .conflict)
        XCTAssertEqual(r.body?["reason"] as? String, "task_done")
    }

    func testScheduleWindowOverlapDueAndVisibility() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let from = base, to = base.addingTimeInterval(7 * 86400)
        // A starts inside the window; B starts 90 minutes before and runs into it; C only has a due date inside.
        var v = try await version(f, f.tasks[0])
        let a = try await patch(f, f.tasks[0], ["version": v, "plannedAt": iso.string(from: base.addingTimeInterval(3600)), "plannedMinutes": 30])
        XCTAssertEqual(a.status, .ok)
        v = try await version(f, f.tasks[1])
        let b0 = try await patch(f, f.tasks[1], ["version": v, "plannedAt": iso.string(from: base.addingTimeInterval(-90 * 60)), "plannedMinutes": 120])
        XCTAssertEqual(b0.status, .ok)
        _ = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[2])", ["dueAt": iso.string(from: base.addingTimeInterval(2 * 86400)), "priority": 0, "reminders": none], token: f.alice)
        // A foreign task inside the window must not leak.
        _ = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.foreignTask)", ["plannedAt": iso.string(from: base.addingTimeInterval(7200)), "priority": 0, "reminders": none], token: f.bob)
        let r = try await schedule(f, from: from, to: to)
        XCTAssertEqual(r.status, .ok)
        let items = try XCTUnwrap(r.body?["items"] as? [[String: Any]])
        XCTAssertEqual(Set(items.compactMap { $0["taskID"] as? String }), Set(f.tasks))
        XCTAssertEqual(r.body?["truncated"] as? Bool, false)
        let b = try XCTUnwrap(items.first { $0["taskID"] as? String == f.tasks[1] })
        XCTAssertEqual(b["plannedMinutes"] as? Int, 120)
        XCTAssertEqual(b["canEdit"] as? Bool, true)
        XCTAssertEqual(b["autoStart"] as? Bool, false)
        XCTAssertEqual(b["title"] as? String, "B")
        // Ordered by start: B (earliest), A, then C (no start, due only).
        XCTAssertEqual(items.compactMap { $0["taskID"] as? String }, [f.tasks[1], f.tasks[0], f.tasks[2]])
        // B ends 30 minutes into the window, so a window closing before A starts still shows B only.
        let narrow = try await schedule(f, from: from, to: base.addingTimeInterval(1800))
        XCTAssertEqual((narrow.body?["items"] as? [[String: Any]])?.compactMap { $0["taskID"] as? String }, [f.tasks[1]])
        let bobs = try await schedule(f, from: from, to: to, token: f.bob)
        XCTAssertEqual((bobs.body?["items"] as? [[String: Any]])?.compactMap { $0["taskID"] as? String }, [f.foreignTask])
        let limited = try await schedule(f, from: from, to: to, extra: "&limit=2")
        XCTAssertEqual((limited.body?["items"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(limited.body?["truncated"] as? Bool, true)
        let filtered = try await schedule(f, from: from, to: to, extra: "&projectID=\(f.project)")
        XCTAssertEqual((filtered.body?["items"] as? [[String: Any]])?.count, 3)
        let denied = try await schedule(f, from: from, to: to, extra: "&projectID=\(UUID().uuidString)")
        XCTAssertEqual(denied.status, .notFound)
    }

    func testScheduleWindowValidationAndAuth() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let tooLong = try await schedule(f, from: base, to: base.addingTimeInterval(63 * 86400))
        XCTAssertEqual(tooLong.status, .badRequest)
        XCTAssertEqual(tooLong.body?["reason"] as? String, "window_too_large")
        let ok = try await schedule(f, from: base, to: base.addingTimeInterval(62 * 86400))
        XCTAssertEqual(ok.status, .ok)
        let reversed = try await schedule(f, from: base, to: base)
        XCTAssertEqual(reversed.body?["reason"] as? String, "invalid_window")
        let missing = try await f.t.json(.GET, "/v1/planning/schedule", token: f.alice)
        XCTAssertEqual(missing.status, .badRequest)
        let noAuth = try await f.t.json(.GET, "/v1/planning/schedule?from=\(iso.string(from: base))&to=\(iso.string(from: base.addingTimeInterval(60)))")
        XCTAssertEqual(noAuth.status, .unauthorized)
    }

    func testReadOnlyShareShowsCanEditFalse() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let v = try await version(f, f.tasks[0])
        _ = try await patch(f, f.tasks[0], ["version": v, "plannedAt": iso.string(from: base.addingTimeInterval(60))])
        _ = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants", ["principalType": "person", "principalID": f.bobID, "role": "read"], token: f.alice)
        let r = try await schedule(f, from: base, to: base.addingTimeInterval(86400), token: f.bob)
        let item = try XCTUnwrap((r.body?["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["canEdit"] as? Bool, false)
    }

    func testConflictsAfterDueAndPrerequisites() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        // A is planned after its due date; B depends on C, which is planned later and is still open.
        _ = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[0])", [
            "dueAt": iso.string(from: base.addingTimeInterval(3600)), "plannedAt": iso.string(from: base.addingTimeInterval(7200)),
            "plannedMinutes": 30, "priority": 0, "reminders": none], token: f.alice)
        var v = try await version(f, f.tasks[1])
        _ = try await patch(f, f.tasks[1], ["version": v, "plannedAt": iso.string(from: base.addingTimeInterval(3600))])
        v = try await version(f, f.tasks[2])
        _ = try await patch(f, f.tasks[2], ["version": v, "plannedAt": iso.string(from: base.addingTimeInterval(86400))])
        let dep = try await f.t.json(.PUT, "/v1/planning/tasks/\(f.tasks[1])/dependencies", ["prerequisiteID": f.tasks[2]], token: f.alice)
        XCTAssertEqual(dep.status, .noContent)
        let r = try await schedule(f, from: base, to: base.addingTimeInterval(3 * 86400))
        let items = try XCTUnwrap(r.body?["items"] as? [[String: Any]])
        func conflicts(_ id: String) -> Set<String> { Set((items.first { $0["taskID"] as? String == id }?["conflicts"] as? [String]) ?? []) }
        XCTAssertTrue(conflicts(f.tasks[0]).contains("after_due"))
        XCTAssertTrue(conflicts(f.tasks[1]).isSuperset(of: ["prerequisite_later", "prerequisite_open"]))
        XCTAssertEqual(conflicts(f.tasks[2]), [])
        XCTAssertEqual(items.first { $0["taskID"] as? String == f.tasks[1] }?["blocked"] as? Bool, true)
    }

    func testRepositoryOverlapConflict() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let projectID = UUID(uuidString: f.project)!
        let owner = try await User.query(on: f.t.app.db).first()!
        let device = RunnerDevice(ownerID: try owner.requireID(), label: "Mac", tokenHash: nil, revokedAt: nil)
        try await device.save(on: f.t.app.db)
        let binding = ProjectRunnerBinding(projectID: projectID, deviceID: try device.requireID(), repositoryKey: "repo-1", label: "Mac")
        try await binding.save(on: f.t.app.db)
        for id in [f.tasks[0], f.tasks[1]] {
            let v = try await version(f, id)
            let r = try await patch(f, id, ["version": v, "plannedAt": iso.string(from: base.addingTimeInterval(3600)), "plannedMinutes": 60])
            XCTAssertEqual(r.status, .ok)
            try await AgentJob(taskID: UUID(uuidString: id)!, projectID: projectID, bindingID: binding.requireID(),
                               requestedBy: owner.requireID(), taskRevision: v, mode: "implement", scope: "task",
                               state: "queued", progress: "", result: nil).save(on: f.t.app.db)
        }
        let r = try await schedule(f, from: base, to: base.addingTimeInterval(86400))
        let items = try XCTUnwrap(r.body?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertEqual(item["jobState"] as? String, "queued")
            XCTAssertEqual(item["repositoryKey"] as? String, "repo-1")
            XCTAssertTrue((item["conflicts"] as? [String])?.contains("repository_overlap") ?? false)
        }
    }

    func testUnscheduledListsOpenTasksWithoutStart() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let v = try await version(f, f.tasks[0])
        _ = try await patch(f, f.tasks[0], ["version": v, "plannedAt": iso.string(from: base)])
        let done = try await version(f, f.tasks[1])
        _ = try await f.t.json(.PATCH, "/v1/tasks/\(f.tasks[1])", ["version": done, "status": "done"], token: f.alice)
        let r = try await f.t.json(.GET, "/v1/planning/unscheduled", token: f.alice)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.list?.compactMap { ($0["task"] as? [String: Any])?["id"] as? String }, [f.tasks[2]])
        let bad = try await f.t.json(.GET, "/v1/planning/unscheduled?limit=0", token: f.alice)
        XCTAssertEqual(bad.status, .badRequest)
    }

    func testPutKeepsScheduleFieldsWhenKeysAreAbsentAndClearsOnNull() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        let v = try await version(f, id)
        let start = iso.string(from: base)
        _ = try await patch(f, id, ["version": v, "plannedAt": start, "plannedMinutes": 50])
        let keep = try await f.t.json(.PUT, "/v1/planning/tasks/\(id)", ["plannedAt": start, "priority": 2, "reminders": none], token: f.alice)
        XCTAssertEqual(keep.body?["plannedMinutes"] as? Int, 50)
        let clear = try await f.t.json(.PUT, "/v1/planning/tasks/\(id)", ["plannedAt": start, "plannedMinutes": NSNull(), "priority": 2, "reminders": none], token: f.alice)
        XCTAssertTrue(clear.body?["plannedMinutes"] == nil || clear.body?["plannedMinutes"] is NSNull)
        let bad = try await f.t.json(.PUT, "/v1/planning/tasks/\(id)", ["plannedAt": start, "plannedMinutes": 2, "priority": 2, "reminders": none], token: f.alice)
        XCTAssertEqual(bad.status, .badRequest)
    }

    func testSyncPlanningCarriesDurationAndKeepsItForOldClients() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let id = f.tasks[0]
        var v = try await version(f, id)
        let start = iso.string(from: base)
        func mutate(_ fields: [String: Any]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
            var m: [String: Any] = ["mutationID": UUID().uuidString, "type": "task.planning", "id": id, "version": v]
            m.merge(fields) { $1 }
            let r = try await f.t.json(.POST, "/v1/sync/mutations", m, token: f.alice)
            return (r.status, r.body)
        }
        let withDuration = try await mutate(["plannedAt": start, "plannedMinutes": 90, "plannedAllDay": false, "priority": 1])
        XCTAssertEqual(withDuration.status, .ok, "\(String(describing: withDuration.body))")
        XCTAssertEqual((withDuration.body?["planning"] as? [String: Any])?["plannedMinutes"] as? Int, 90)
        XCTAssertEqual((withDuration.body?["planning"] as? [String: Any])?["plannedAllDay"] as? Bool, false)
        v += 1
        // A client that predates the fields sends the full replacement without them: duration stays.
        let old = try await mutate(["plannedAt": start, "priority": 2])
        XCTAssertEqual((old.body?["planning"] as? [String: Any])?["plannedMinutes"] as? Int, 90)
        XCTAssertEqual((old.body?["planning"] as? [String: Any])?["priority"] as? Int, 2)
        v += 1
        let invalid = try await mutate(["plannedAt": start, "plannedMinutes": 3, "priority": 2])
        XCTAssertEqual(invalid.status, .badRequest)
    }
}
