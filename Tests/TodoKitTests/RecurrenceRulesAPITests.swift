import Fluent
import XCTVapor
@testable import TodoKit

/// REST, sync and MCP behaviour of the extended recurrence rules (weekdays, basis, monthDay). Only JSON surfaces, no internal types.
final class RecurrenceRulesAPITests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func date(_ text: String) -> Date { iso.date(from: text)! }

    private func newTask(_ f: OAuthFixture) async throws -> String {
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Recurring", details: "")
        try await task.save(on: f.test.app.db)
        return try task.requireID().uuidString
    }

    private func put(_ f: OAuthFixture, _ id: String, rule: Any?, due: String? = "2026-11-23T09:00:00Z", planned: String? = nil, reminders: [String] = []) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var body: [String: Any] = ["priority": 1, "reminders": reminders]
        if let due { body["dueAt"] = due }
        if let planned { body["plannedAt"] = planned }
        if let rule { body["recurrence"] = rule }
        let r = try await f.test.json(.PUT, "/v1/planning/tasks/\(id)", body, token: f.session)
        return (r.status, r.body)
    }

    private func read(_ f: OAuthFixture, _ id: String) async throws -> [String: Any] {
        let r = try await f.test.json(.GET, "/v1/planning/tasks/\(id)", token: f.session)
        XCTAssertEqual(r.status, .ok)
        return try XCTUnwrap(r.body)
    }

    private func taskVersion(_ f: OAuthFixture, _ id: String) async throws -> Int {
        let planning = try await read(f, id)
        return try XCTUnwrap((planning["task"] as? [String: Any])?["version"] as? Int)
    }

    private func complete(_ f: OAuthFixture, _ id: String) async throws {
        let version = try await taskVersion(f, id)
        let r = try await f.test.json(.PATCH, "/v1/tasks/\(id)", ["version": version, "status": "done"], token: f.session)
        XCTAssertEqual(r.status, .ok, "\(String(describing: r.body))")
    }

    /// Planning JSON of the successor created for `id`.
    private func successor(_ f: OAuthFixture, of id: String) async throws -> (id: String, planning: [String: Any]) {
        let receipt = try await PlanningOccurrence.find(UUID(uuidString: id)!, on: f.test.app.db)
        let nextID = try XCTUnwrap(receipt?.nextTaskID).uuidString
        let planning = try await read(f, nextID)
        return (nextID, planning)
    }

    private func recurrence(_ body: [String: Any]?) -> [String: Any]? { body?["recurrence"] as? [String: Any] }

    /// Keys of the rule as it is stored in the planning row (the JSON column).
    private func storedKeys(_ row: TaskPlanning?) -> Set<String> {
        guard let rule = row?.recurrence, let data = try? JSONEncoder().encode(rule),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(object.keys)
    }

    /// JSON equality that works for nested arrays and numbers (`[String: Any]` is not Equatable).
    private func assertSame(_ actual: Any?, _ expected: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = actual as? [String: Any] else { return XCTFail("not an object: \(String(describing: actual))", file: file, line: line) }
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected), "\(actual) != \(expected)", file: file, line: line)
    }

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ token: String) async throws -> (Bool, String, Any?) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    // MARK: REST

    func testRestWeekdaysRuleRoundTripsAndSpawnsTheNextWeekday() async throws {
        let f = try await OAuthFixture.make()
        do {
            let id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "weekly", "interval": 1, "timeZone": "Europe/Berlin", "weekdays": [4, 1]]
            // 2026-03-27 is a Friday: 09:00 CET. Monday 2026-03-30 is after the switch to CEST.
            let set = try await put(f, id, rule: rule, due: "2026-03-27T08:00:00Z", reminders: ["2026-03-27T07:00:00Z"])
            XCTAssertEqual(set.status, .ok, "\(String(describing: set.body))")
            XCTAssertEqual(recurrence(set.body)?["weekdays"] as? [Int], [4, 1])
            let stored = try await read(f, id)
            XCTAssertEqual(Set(try XCTUnwrap(recurrence(stored)).keys), ["frequency", "interval", "timeZone", "weekdays"])
            XCTAssertEqual(recurrence(stored)?["weekdays"] as? [Int], [4, 1])
            try await complete(f, id)
            let next = try await successor(f, of: id)
            XCTAssertEqual(next.planning["dueAt"] as? String, "2026-03-30T07:00:00Z")
            // Reminder moves by the same distance as the due date.
            XCTAssertEqual(next.planning["reminders"] as? [String], ["2026-03-30T06:00:00Z"])
            XCTAssertEqual(Set(try XCTUnwrap(recurrence(next.planning)).keys), ["frequency", "interval", "timeZone", "weekdays"])
            XCTAssertEqual(recurrence(next.planning)?["weekdays"] as? [Int], [4, 1])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRestMonthDay31WalksThroughShortMonths() async throws {
        let f = try await OAuthFixture.make()
        do {
            var id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 31]
            let set = try await put(f, id, rule: rule, due: "2027-01-31T09:00:00Z", reminders: ["2027-01-30T09:00:00Z"])
            XCTAssertEqual(set.status, .ok, "\(String(describing: set.body))")
            var seen: [String] = []
            var reminders: [String] = []
            for _ in 0..<3 {
                try await complete(f, id)
                let next = try await successor(f, of: id)
                seen.append(try XCTUnwrap(next.planning["dueAt"] as? String))
                reminders.append(contentsOf: try XCTUnwrap(next.planning["reminders"] as? [String]))
                XCTAssertEqual(recurrence(next.planning)?["monthDay"] as? Int, 31)
                id = next.id
            }
            XCTAssertEqual(seen, ["2027-02-28T09:00:00Z", "2027-03-31T09:00:00Z", "2027-04-30T09:00:00Z"])
            XCTAssertEqual(reminders, ["2027-02-27T09:00:00Z", "2027-03-30T09:00:00Z", "2027-04-29T09:00:00Z"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRestCompletionBasisCountsFromTheDayOfCompletion() async throws {
        let f = try await OAuthFixture.make()
        do {
            let id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "daily", "interval": 3, "timeZone": "UTC", "basis": "completion"]
            // Long overdue: the successor must not be anchored in 2026-11-02.
            let set = try await put(f, id, rule: rule, due: "2026-11-02T09:00:00Z", planned: "2026-11-02T08:00:00Z", reminders: ["2026-11-02T07:30:00Z"])
            XCTAssertEqual(set.status, .ok, "\(String(describing: set.body))")
            XCTAssertEqual(recurrence(set.body)?["basis"] as? String, "completion")
            let before = Date()
            try await complete(f, id)
            let after = Date()
            let next = try await successor(f, of: id)
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            func expected(_ completed: Date, hour: Int) -> String {
                let day = utc.date(byAdding: .day, value: 3, to: utc.startOfDay(for: completed))!
                return iso.string(from: utc.date(bySettingHour: hour, minute: 0, second: 0, of: day)!)
            }
            // The test may straddle midnight UTC; either day is a correct answer then.
            XCTAssertTrue([expected(before, hour: 9), expected(after, hour: 9)].contains(try XCTUnwrap(next.planning["dueAt"] as? String)), "\(next.planning)")
            XCTAssertTrue([expected(before, hour: 8), expected(after, hour: 8)].contains(try XCTUnwrap(next.planning["plannedAt"] as? String)), "\(next.planning)")
            // Reminder keeps its 90 minute distance to the due date.
            let due = date(try XCTUnwrap(next.planning["dueAt"] as? String))
            XCTAssertEqual((next.planning["reminders"] as? [String])?.map { date($0) }, [due.addingTimeInterval(-90 * 60)])
            XCTAssertEqual(recurrence(next.planning)?["basis"] as? String, "completion")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRestOldRuleKeepsItsJSONAndItsSuccessor() async throws {
        let f = try await OAuthFixture.make()
        do {
            let id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "weekly", "interval": 2, "timeZone": "Europe/Berlin", "until": "2030-01-01T00:00:00Z"]
            let set = try await put(f, id, rule: rule, due: "2026-03-20T08:00:00Z", reminders: ["2026-03-20T07:00:00Z"])
            XCTAssertEqual(set.status, .ok)
            let storedPlanning = try await read(f, id)
            let stored = try XCTUnwrap(recurrence(storedPlanning))
            XCTAssertEqual(Set(stored.keys), ["frequency", "interval", "timeZone", "until"])
            // Row as stored: no new keys appear in the database either.
            let row = try await TaskPlanning.find(UUID(uuidString: id)!, on: f.test.app.db)
            XCTAssertEqual(storedKeys(row), ["frequency", "interval", "timeZone", "until"])
            try await complete(f, id)
            let next = try await successor(f, of: id)
            // Two weeks later at the same wall-clock time (09:00 CET both days).
            XCTAssertEqual(next.planning["dueAt"] as? String, "2026-04-03T07:00:00Z")
            XCTAssertEqual(next.planning["reminders"] as? [String], ["2026-04-03T06:00:00Z"])
            XCTAssertEqual(Set(try XCTUnwrap(recurrence(next.planning)).keys), ["frequency", "interval", "timeZone", "until"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRestInvalidCombinationsAreRefusedAndNothingIsStored() async throws {
        let f = try await OAuthFixture.make()
        do {
            let id = try await newTask(f)
            let cases: [[String: Any]] = [
                ["frequency": "daily", "interval": 1, "timeZone": "UTC", "weekdays": [1]],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "weekdays": [1]],
                ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": []],
                ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [2, 2]],
                ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [0]],
                ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [8]],
                ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "monthDay": 5],
                ["frequency": "daily", "interval": 1, "timeZone": "UTC", "monthDay": 5],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 0],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 32],
                ["frequency": "daily", "interval": 1, "timeZone": "UTC", "basis": "yesterday"],
                ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [1], "basis": ""],
            ]
            for rule in cases {
                let r = try await put(f, id, rule: rule)
                XCTAssertEqual(r.status, .badRequest, "\(rule)")
                XCTAssertEqual(r.body?["reason"] as? String, "invalid_recurrence", "\(rule)")
            }
            let untouched = try await read(f, id)
            XCTAssertNil(recurrence(untouched))
            // Sync takes the same road.
            let bad = try await f.test.json(.POST, "/v1/sync/mutations", ["mutationID": UUID().uuidString, "type": "task.planning", "id": id, "version": 1, "priority": 0,
                "dueAt": "2026-11-23T09:00:00Z", "recurrence": ["frequency": "daily", "interval": 1, "timeZone": "UTC", "weekdays": [1]]], token: f.session)
            XCTAssertEqual(bad.status, .badRequest)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSyncAndCalendarDragCarryTheNewFieldsUnchanged() async throws {
        let f = try await OAuthFixture.make()
        do {
            let id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "weekly", "interval": 2, "timeZone": "Pacific/Auckland", "weekdays": [2, 6], "basis": "completion"]
            let mutation = try await f.test.json(.POST, "/v1/sync/mutations", ["mutationID": UUID().uuidString, "type": "task.planning", "id": id, "version": 1, "priority": 2,
                "dueAt": "2026-11-23T09:00:00Z", "recurrence": rule], token: f.session)
            XCTAssertEqual(mutation.status, .ok, "\(String(describing: mutation.body))")
            let planning = try XCTUnwrap(mutation.body?["planning"] as? [String: Any])
            assertSame(planning["recurrence"], rule)
            // Feed.
            let feed = try await f.test.json(.GET, "/v1/sync/changes?cursor=c0&limit=500", token: f.session)
            let changes = try XCTUnwrap(feed.body?["changes"] as? [[String: Any]])
            let mine = try XCTUnwrap(changes.last { ($0["entityID"] as? String)?.lowercased() == id.lowercased() && $0["planning"] != nil })
            assertSame((mine["planning"] as? [String: Any])?["recurrence"], rule)
            // Calendar drag rewrites only the start and keeps the rule.
            let version = try await taskVersion(f, id)
            let drag = try await f.test.json(.PATCH, "/v1/tasks/\(id)/schedule", ["version": version, "plannedAt": "2026-11-23T07:00:00Z", "plannedMinutes": 30], token: f.session)
            XCTAssertEqual(drag.status, .ok, "\(String(describing: drag.body))")
            assertSame(drag.body?["recurrence"], rule)
            let afterDrag = try await read(f, id)
            assertSame(recurrence(afterDrag), rule)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: MCP

    func testMcpSetsChangesAndClearsTheNewFields() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access
            let id = try await newTask(f)
            let weekly: [String: Any] = ["frequency": "weekly", "interval": 1, "timeZone": "Europe/Berlin", "weekdays": [1, 3, 5], "basis": "completion"]
            let set = try await call(f, "update_task_planning", ["taskID": id, "dueAt": "2026-11-23T09:00:00Z", "recurrence": weekly], token)
            XCTAssertFalse(set.0, set.1)
            XCTAssertEqual(recurrence(set.2 as? [String: Any])?["weekdays"] as? [Int], [1, 3, 5])
            XCTAssertEqual(recurrence(set.2 as? [String: Any])?["basis"] as? String, "completion")
            let get = try await call(f, "get_task_planning", ["taskID": id], token)
            assertSame(recurrence(get.2 as? [String: Any]), weekly)
            // Unrelated patches keep the rule.
            let other = try await call(f, "update_task_planning", ["taskID": id, "priority": 2], token)
            assertSame(recurrence(other.2 as? [String: Any]), weekly)
            // Change to a monthly rule: the weekday list is gone with the replaced rule.
            let monthly: [String: Any] = ["frequency": "monthly", "interval": 2, "timeZone": "UTC", "monthDay": 31]
            let changed = try await call(f, "update_task_planning", ["taskID": id, "recurrence": monthly], token)
            XCTAssertFalse(changed.0, changed.1)
            assertSame(recurrence(changed.2 as? [String: Any]), monthly)
            let row = try await TaskPlanning.find(UUID(uuidString: id)!, on: f.test.app.db)
            XCTAssertEqual(storedKeys(row), ["frequency", "interval", "timeZone", "monthDay"])
            // Old form: no new keys in the answer.
            let old = try await call(f, "update_task_planning", ["taskID": id, "recurrence": ["frequency": "daily", "interval": 2, "timeZone": "UTC"]], token)
            XCTAssertFalse(old.0, old.1)
            XCTAssertEqual(Set(try XCTUnwrap(recurrence(old.2 as? [String: Any])).keys), ["frequency", "interval", "timeZone"])
            // Clearing.
            let cleared = try await call(f, "update_task_planning", ["taskID": id, "recurrence": NSNull()], token)
            XCTAssertFalse(cleared.0, cleared.1)
            XCTAssertNil(recurrence(cleared.2 as? [String: Any]))
            let afterRow = try await TaskPlanning.find(UUID(uuidString: id)!, on: f.test.app.db)
            XCTAssertNil(afterRow?.recurrence)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMcpRefusesInvalidNewFieldsAndKeepsTheStoredRule() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access
            let id = try await newTask(f)
            let good: [String: Any] = ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [2]]
            let set = try await call(f, "update_task_planning", ["taskID": id, "dueAt": "2026-11-23T09:00:00Z", "recurrence": good], token)
            XCTAssertFalse(set.0, set.1)
            let base: [String: Any] = ["frequency": "weekly", "interval": 1, "timeZone": "UTC"]
            let bad: [[String: Any]] = [
                base.merging(["weekdays": []]) { $1 },
                base.merging(["weekdays": [1, 1]]) { $1 },
                base.merging(["weekdays": [0]]) { $1 },
                base.merging(["weekdays": [8]]) { $1 },
                base.merging(["weekdays": [1.5]]) { $1 },
                base.merging(["weekdays": ["mon"]]) { $1 },
                base.merging(["weekdays": "1"]) { $1 },
                base.merging(["monthDay": 5]) { $1 },
                base.merging(["basis": "yesterday"]) { $1 },
                base.merging(["basis": 1]) { $1 },
                ["frequency": "daily", "interval": 1, "timeZone": "UTC", "weekdays": [1]],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "weekdays": [1]],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 0],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 32],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 1.5],
                ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": "5"],
                ["frequency": "daily", "interval": 1, "timeZone": "UTC", "monthDay": 5],
                ["frequency": "daily", "interval": 1, "timeZone": "UTC", "unknown": 1],
            ]
            for rule in bad {
                let r = try await call(f, "update_task_planning", ["taskID": id, "recurrence": rule], token)
                XCTAssertTrue(r.0, "\(rule)")
                XCTAssertEqual(r.1, "invalid_recurrence", "\(rule)")
            }
            let row = try await TaskPlanning.find(UUID(uuidString: id)!, on: f.test.app.db)
            XCTAssertEqual(storedKeys(row), ["frequency", "interval", "timeZone", "weekdays"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMcpAcceptsNullForTheNewFieldsLikeAbsent() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access
            let id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "daily", "interval": 1, "timeZone": "UTC", "weekdays": NSNull(), "basis": NSNull(), "monthDay": NSNull()]
            let set = try await call(f, "update_task_planning", ["taskID": id, "dueAt": "2026-11-23T09:00:00Z", "recurrence": rule], token)
            XCTAssertFalse(set.0, set.1)
            XCTAssertEqual(Set(try XCTUnwrap(recurrence(set.2 as? [String: Any])).keys), ["frequency", "interval", "timeZone"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMcpRuleSpawnsTheSuccessorWhenTheCardIsDone() async throws {
        let f = try await OAuthFixture.make()
        do {
            let token = try await f.tokens().access
            let id = try await newTask(f)
            let rule: [String: Any] = ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [1, 4]]
            let set = try await call(f, "update_task_planning", ["taskID": id, "dueAt": "2026-11-23T09:00:00Z", "reminders": ["2026-11-23T08:00:00Z"], "recurrence": rule], token)
            XCTAssertFalse(set.0, set.1)
            let version = try await taskVersion(f, id)
            let done = try await call(f, "update_task", ["id": id, "version": version, "status": "done"], token)
            XCTAssertFalse(done.0, done.1)
            let next = try await successor(f, of: id)
            XCTAssertEqual(next.planning["dueAt"] as? String, "2026-11-26T09:00:00Z")
            XCTAssertEqual(next.planning["reminders"] as? [String], ["2026-11-26T08:00:00Z"])
            XCTAssertEqual(recurrence(next.planning)?["weekdays"] as? [Int], [1, 4])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMcpToolSchemaDescribesTheNewFields() throws {
        let tool = try XCTUnwrap(MCPController.tools.first { $0.name == "update_task_planning" })
        let schema = String(describing: tool.properties["recurrence"] as Any)
        for word in ["weekdays", "basis", "monthDay", "completion"] { XCTAssertTrue(schema.contains(word), word) }
        XCTAssertTrue(tool.description.contains("weekdays") && tool.description.contains("monthDay") && tool.description.contains("completion"), tool.description)
    }
}
