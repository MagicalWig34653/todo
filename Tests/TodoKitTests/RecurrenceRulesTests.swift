import Fluent
import XCTVapor
@testable import TodoKit

/// Date arithmetic of the extended recurrence rules (weekdays, basis, monthDay), with fixed dates and no clock.
final class RecurrenceRulesTests: XCTestCase {
    // MARK: Helpers

    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    /// Wall-clock "yyyy-MM-dd HH:mm" in `tz` to an instant.
    private func at(_ text: String, _ tz: String = "UTC") -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone(tz)
        f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd HH:mm"; f.isLenient = false
        return f.date(from: text)!
    }

    /// Instant to wall-clock "yyyy-MM-dd HH:mm" in `tz`.
    private func wall(_ date: Date, _ tz: String = "UTC") -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone(tz)
        f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func utc(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func rule(_ frequency: String, _ interval: Int = 1, tz: String = "UTC", weekdays: [Int]? = nil,
                      basis: String? = nil, monthDay: Int? = nil) -> RecurrenceRule {
        RecurrenceRule(frequency: frequency, interval: interval, timeZone: tz, until: nil, weekdays: weekdays, basis: basis, monthDay: monthDay)
    }

    /// Next occurrence on wall-clock terms; `completed` defaults to the due date (only matters for basis completion).
    private func next(_ r: RecurrenceRule, from text: String, completed: String? = nil) throws -> String {
        let due = at(text, r.timeZone)
        return wall(try r.successor(of: due, completedAt: completed.map { at($0, r.timeZone) } ?? due), r.timeZone)
    }

    // MARK: Weekdays

    func testWeekdaysMondayThursdayWalksTheWeek() throws {
        let r = rule("weekly", weekdays: [1, 4])
        // 2026-11-23 is a Monday.
        XCTAssertEqual(try next(r, from: "2026-11-23 09:00"), "2026-11-26 09:00")
        XCTAssertEqual(try next(r, from: "2026-11-26 09:00"), "2026-11-30 09:00")
        XCTAssertEqual(try next(r, from: "2026-11-30 09:00"), "2026-12-03 09:00")
        // A base day that is not selected moves to the next selected weekday of the same week.
        XCTAssertEqual(try next(r, from: "2026-11-24 17:45"), "2026-11-26 17:45")
        XCTAssertEqual(try next(r, from: "2026-11-27 17:45"), "2026-11-30 17:45")
    }

    func testWeekdaysOrderOfTheListDoesNotMatter() throws {
        XCTAssertEqual(try next(rule("weekly", weekdays: [4, 1]), from: "2026-11-23 09:00"), "2026-11-26 09:00")
        XCTAssertEqual(try next(rule("weekly", weekdays: [4, 1]), from: "2026-11-26 09:00"), "2026-11-30 09:00")
    }

    func testWeekdaysIntervalTwoSkipsOneWeek() throws {
        let r = rule("weekly", 2, weekdays: [1, 4])
        // Inside the same week the next chosen day still counts; only the wrap jumps `interval` weeks.
        XCTAssertEqual(try next(r, from: "2026-11-23 09:00"), "2026-11-26 09:00")
        XCTAssertEqual(try next(r, from: "2026-11-26 09:00"), "2026-12-07 09:00")
        XCTAssertEqual(try next(r, from: "2026-12-07 09:00"), "2026-12-10 09:00")
    }

    func testWeekdaysSundayEdgeCases() throws {
        // 2026-11-29 is a Sunday; the week runs Monday to Sunday.
        XCTAssertEqual(try next(rule("weekly", weekdays: [7]), from: "2026-11-29 08:00"), "2026-12-06 08:00")
        XCTAssertEqual(try next(rule("weekly", weekdays: [1, 7]), from: "2026-11-29 08:00"), "2026-11-30 08:00")
        XCTAssertEqual(try next(rule("weekly", weekdays: [1, 7]), from: "2026-11-23 08:00"), "2026-11-29 08:00")
        XCTAssertEqual(try next(rule("weekly", 3, weekdays: [3]), from: "2026-11-29 08:00"), "2026-12-16 08:00")
        // A single weekday behaves like a weekly rule on that day.
        XCTAssertEqual(try next(rule("weekly", weekdays: [5]), from: "2026-11-27 08:00"), "2026-12-04 08:00")
    }

    func testWeekdaysAcrossTheNewYear() throws {
        // 2026-12-31 is a Thursday.
        XCTAssertEqual(try next(rule("weekly", weekdays: [1, 4]), from: "2026-12-31 09:00"), "2027-01-04 09:00")
        XCTAssertEqual(try next(rule("weekly", 2, weekdays: [4]), from: "2026-12-31 09:00"), "2027-01-14 09:00")
    }

    func testWeekdaysKeepWallClockAcrossDaylightSavingInBerlin() throws {
        let r = rule("weekly", tz: "Europe/Berlin", weekdays: [1, 4])
        // 2026-03-26 (Thursday) 09:00 CET -> Monday 2026-03-30 09:00 CEST (switch on 2026-03-29).
        let spring = try r.successor(of: at("2026-03-26 09:00", "Europe/Berlin"), completedAt: .distantPast)
        XCTAssertEqual(wall(spring, "Europe/Berlin"), "2026-03-30 09:00")
        XCTAssertEqual(utc(spring), "2026-03-30T07:00:00Z")
        // 2026-10-22 (Thursday) 09:00 CEST -> Monday 2026-10-26 09:00 CET (switch on 2026-10-25).
        let autumn = try r.successor(of: at("2026-10-22 09:00", "Europe/Berlin"), completedAt: .distantPast)
        XCTAssertEqual(wall(autumn, "Europe/Berlin"), "2026-10-26 09:00")
        XCTAssertEqual(utc(autumn), "2026-10-26T08:00:00Z")
    }

    func testWeekdaysUseTheCalendarDayOfTheZoneNotUTC() throws {
        // 2026-11-26 23:30 UTC is already Friday 2026-11-27 12:30 in Auckland (UTC+13).
        let due = at("2026-11-26 23:30", "UTC")
        let auckland = try rule("weekly", tz: "Pacific/Auckland", weekdays: [1, 5]).successor(of: due, completedAt: due)
        XCTAssertEqual(wall(auckland, "Pacific/Auckland"), "2026-11-30 12:30")
        // The same instant in UTC is still Thursday, so Friday is next.
        let plain = try rule("weekly", tz: "UTC", weekdays: [1, 5]).successor(of: due, completedAt: due)
        XCTAssertEqual(wall(plain, "UTC"), "2026-11-27 23:30")
        // New York (UTC-5): 2026-11-23 03:30 UTC is still Sunday 2026-11-22 22:30 there; Monday of the next week is next.
        let ny = at("2026-11-23 03:30", "UTC")
        XCTAssertEqual(wall(try rule("weekly", tz: "America/New_York", weekdays: [1, 7]).successor(of: ny, completedAt: ny), "America/New_York"), "2026-11-23 22:30")
    }

    // MARK: Basis completion

    func testCompletionBasisDailyWeeklyMonthlyKeepsTheDueTime() throws {
        // Due 2026-11-02 09:00, finished late on Tuesday 2026-11-10 at 18:20.
        let done = "2026-11-10 18:20"
        XCTAssertEqual(try next(rule("daily", basis: "completion"), from: "2026-11-02 09:00", completed: done), "2026-11-11 09:00")
        XCTAssertEqual(try next(rule("daily", 3, basis: "completion"), from: "2026-11-02 09:00", completed: done), "2026-11-13 09:00")
        XCTAssertEqual(try next(rule("weekly", basis: "completion"), from: "2026-11-02 09:00", completed: done), "2026-11-17 09:00")
        XCTAssertEqual(try next(rule("weekly", 2, basis: "completion"), from: "2026-11-02 09:00", completed: done), "2026-11-24 09:00")
        XCTAssertEqual(try next(rule("monthly", basis: "completion"), from: "2026-11-02 09:00", completed: done), "2026-12-10 09:00")
        XCTAssertEqual(try next(rule("monthly", 2, basis: "completion"), from: "2026-11-02 09:00", completed: done), "2027-01-10 09:00")
    }

    func testCompletionBasisMonthEndIsClamped() throws {
        XCTAssertEqual(try next(rule("monthly", basis: "completion"), from: "2027-01-05 07:30", completed: "2027-01-31 12:00"), "2027-02-28 07:30")
        XCTAssertEqual(try next(rule("monthly", basis: "completion"), from: "2028-01-05 07:30", completed: "2028-01-31 12:00"), "2028-02-29 07:30")
    }

    func testCompletionBasisUsesTheZoneCalendarDay() throws {
        // Done at 2026-11-10 23:30 UTC = 2026-11-11 12:30 in Auckland: the next day there is the 12th.
        let r = rule("daily", tz: "Pacific/Auckland", basis: "completion")
        let due = at("2026-11-05 08:15", "Pacific/Auckland")
        let result = try r.successor(of: due, completedAt: at("2026-11-10 23:30", "UTC"))
        XCTAssertEqual(wall(result, "Pacific/Auckland"), "2026-11-12 08:15")
        // New York: 2026-11-11 02:30 UTC is still 2026-11-10 21:30 in New York.
        let ny = rule("daily", tz: "America/New_York", basis: "completion")
        let nyDue = at("2026-11-05 09:00", "America/New_York")
        XCTAssertEqual(wall(try ny.successor(of: nyDue, completedAt: at("2026-11-11 02:30", "UTC")), "America/New_York"), "2026-11-11 09:00")
        // UTC itself.
        let plain = rule("daily", basis: "completion")
        XCTAssertEqual(wall(try plain.successor(of: at("2026-11-05 09:00"), completedAt: at("2026-11-10 23:30"))), "2026-11-11 09:00")
    }

    func testCompletionBasisKeepsWallClockAcrossDaylightSaving() throws {
        let r = rule("daily", tz: "Europe/Berlin", basis: "completion")
        let due = at("2026-03-20 09:00", "Europe/Berlin")
        // Done on 2026-03-28 at noon: the next day is the switch day (CET -> CEST), 09:00 stays 09:00.
        let spring = try r.successor(of: due, completedAt: at("2026-03-28 12:00", "Europe/Berlin"))
        XCTAssertEqual(wall(spring, "Europe/Berlin"), "2026-03-29 09:00")
        XCTAssertEqual(utc(spring), "2026-03-29T07:00:00Z")
        let autumn = try r.successor(of: due, completedAt: at("2026-10-24 12:00", "Europe/Berlin"))
        XCTAssertEqual(wall(autumn, "Europe/Berlin"), "2026-10-25 09:00")
        XCTAssertEqual(utc(autumn), "2026-10-25T08:00:00Z")
        // Weekly across the autumn switch.
        let weekly = try rule("weekly", tz: "Europe/Berlin", basis: "completion").successor(of: due, completedAt: at("2026-10-22 08:00", "Europe/Berlin"))
        XCTAssertEqual(wall(weekly, "Europe/Berlin"), "2026-10-29 09:00")
    }

    func testCompletionBasisWithWeekdaysAndMonthDay() throws {
        // Completed on Wednesday 2026-11-25: Monday/Thursday -> Thursday; completed on Friday -> next Monday.
        let r = rule("weekly", weekdays: [1, 4], basis: "completion")
        XCTAssertEqual(try next(r, from: "2026-11-02 09:00", completed: "2026-11-25 20:00"), "2026-11-26 09:00")
        XCTAssertEqual(try next(r, from: "2026-11-02 09:00", completed: "2026-11-27 20:00"), "2026-11-30 09:00")
        let m = rule("monthly", basis: "completion", monthDay: 5)
        XCTAssertEqual(try next(m, from: "2026-11-02 09:00", completed: "2026-11-20 20:00"), "2026-12-05 09:00")
        // Completion on the 31st of January, monthDay 31 -> February is clamped.
        let end = rule("monthly", basis: "completion", monthDay: 31)
        XCTAssertEqual(try next(end, from: "2027-01-05 09:00", completed: "2027-01-31 09:00"), "2027-02-28 09:00")
    }

    func testExplicitDueBasisIsTheSameAsTheDefault() throws {
        for r in [rule("daily", 2), rule("weekly", 3), rule("monthly", 1), rule("monthly", 12, tz: "Europe/Berlin")] {
            var explicit = r; explicit.basis = "due"
            let due = at("2026-10-29 09:00", r.timeZone)
            XCTAssertEqual(try explicit.successor(of: due, completedAt: at("2030-01-01 00:00")), try r.next(due))
        }
    }

    // MARK: Month day

    func testMonthDay31ClampsToMonthEndWithoutDrifting() throws {
        let r = rule("monthly", tz: "Europe/Berlin", monthDay: 31)
        var current = "2027-01-31 09:00"
        var seen: [String] = []
        for _ in 0..<4 { current = try next(r, from: current); seen.append(current) }
        XCTAssertEqual(seen, ["2027-02-28 09:00", "2027-03-31 09:00", "2027-04-30 09:00", "2027-05-31 09:00"])
        // From any day of the month the target is the next month's day.
        XCTAssertEqual(try next(r, from: "2027-01-15 09:00"), "2027-02-28 09:00")
        XCTAssertEqual(try next(r, from: "2026-12-31 09:00"), "2027-01-31 09:00")
    }

    func testMonthDay29And30InLeapAndNonLeapYears() throws {
        XCTAssertEqual(try next(rule("monthly", monthDay: 29), from: "2027-01-29 10:00"), "2027-02-28 10:00")
        XCTAssertEqual(try next(rule("monthly", monthDay: 29), from: "2027-02-28 10:00"), "2027-03-29 10:00")
        XCTAssertEqual(try next(rule("monthly", monthDay: 29), from: "2028-01-29 10:00"), "2028-02-29 10:00")
        XCTAssertEqual(try next(rule("monthly", monthDay: 29), from: "2028-02-29 10:00"), "2028-03-29 10:00")
        XCTAssertEqual(try next(rule("monthly", monthDay: 30), from: "2027-01-30 10:00"), "2027-02-28 10:00")
        XCTAssertEqual(try next(rule("monthly", monthDay: 30), from: "2028-01-30 10:00"), "2028-02-29 10:00")
        XCTAssertEqual(try next(rule("monthly", monthDay: 30), from: "2028-02-29 10:00"), "2028-03-30 10:00")
    }

    func testMonthDayWithIntervalAndYearChange() throws {
        let r = rule("monthly", 2, monthDay: 15)
        XCTAssertEqual(try next(r, from: "2026-11-15 09:00"), "2027-01-15 09:00")
        XCTAssertEqual(try next(r, from: "2027-01-15 09:00"), "2027-03-15 09:00")
        XCTAssertEqual(try next(r, from: "2026-12-20 09:00"), "2027-02-15 09:00")
        XCTAssertEqual(try next(rule("monthly", 12, monthDay: 29), from: "2027-02-28 09:00"), "2028-02-29 09:00")
    }

    func testMonthDayKeepsWallClockAcrossDaylightSaving() throws {
        let r = rule("monthly", tz: "Europe/Berlin", monthDay: 29)
        let spring = try r.successor(of: at("2026-02-10 09:00", "Europe/Berlin"), completedAt: .distantPast)
        XCTAssertEqual(wall(spring, "Europe/Berlin"), "2026-03-29 09:00")
        XCTAssertEqual(utc(spring), "2026-03-29T07:00:00Z")
        let autumn = try rule("monthly", tz: "Europe/Berlin", monthDay: 25).successor(of: at("2026-09-25 09:00", "Europe/Berlin"), completedAt: .distantPast)
        XCTAssertEqual(utc(autumn), "2026-10-25T08:00:00Z")
        XCTAssertEqual(wall(autumn, "Europe/Berlin"), "2026-10-25 09:00")
    }

    func testMonthDayUsesTheZoneCalendarDay() throws {
        // 2027-01-31 20:00 UTC is already 2027-02-01 09:00 in Auckland: the target month is March there.
        let due = at("2027-01-31 20:00", "UTC")
        let auckland = try rule("monthly", tz: "Pacific/Auckland", monthDay: 31).successor(of: due, completedAt: due)
        XCTAssertEqual(wall(auckland, "Pacific/Auckland"), "2027-03-31 09:00")
        let plain = try rule("monthly", tz: "UTC", monthDay: 31).successor(of: due, completedAt: due)
        XCTAssertEqual(wall(plain), "2027-02-28 20:00")
    }

    // MARK: Validation

    private func assertInvalid(_ r: RecurrenceRule, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try r.validate(), message, file: file, line: line) {
            XCTAssertEqual(($0 as? Abort)?.status, .badRequest, message, file: file, line: line)
            XCTAssertEqual(($0 as? Abort)?.reason, "invalid_recurrence", message, file: file, line: line)
        }
    }

    func testValidationRejectsInvalidCombinationsAndValues() throws {
        assertInvalid(rule("daily", weekdays: [1]), "weekdays with daily")
        assertInvalid(rule("monthly", weekdays: [1]), "weekdays with monthly")
        assertInvalid(rule("weekly", weekdays: []), "empty weekdays")
        assertInvalid(rule("weekly", weekdays: [1, 1]), "duplicate weekdays")
        assertInvalid(rule("weekly", weekdays: [0]), "weekday 0")
        assertInvalid(rule("weekly", weekdays: [8]), "weekday 8")
        assertInvalid(rule("weekly", weekdays: [1, 9]), "weekday 9 next to a valid one")
        assertInvalid(rule("weekly", monthDay: 1), "monthDay with weekly")
        assertInvalid(rule("daily", monthDay: 1), "monthDay with daily")
        assertInvalid(rule("monthly", monthDay: 0), "monthDay 0")
        assertInvalid(rule("monthly", monthDay: 32), "monthDay 32")
        assertInvalid(rule("monthly", monthDay: -1), "monthDay -1")
        assertInvalid(rule("daily", basis: "yesterday"), "unknown basis")
        assertInvalid(rule("daily", basis: ""), "empty basis")
        assertInvalid(rule("daily", basis: "Due"), "basis is case sensitive")
        assertInvalid(rule("daily", 0, basis: "completion"), "bad interval still fails")
        let valid = [rule("weekly", weekdays: [1, 2, 3, 4, 5, 6, 7]), rule("weekly", weekdays: [7]), rule("monthly", monthDay: 1), rule("monthly", monthDay: 31),
                     rule("daily", basis: "due"), rule("daily", basis: "completion"), rule("weekly", 2, weekdays: [2], basis: "completion"),
                     rule("monthly", basis: "completion", monthDay: 15)]
        for r in valid { XCTAssertNoThrow(try r.validate()) }
    }

    func testPlanningDataRejectsInvalidRulesWithTheSameReason() {
        let bad = PlanningData(dueAt: Date(), priority: 0, recurrence: rule("daily", weekdays: [1]), reminders: [])
        XCTAssertThrowsError(try bad.validate()) { XCTAssertEqual(($0 as? Abort)?.reason, "invalid_recurrence") }
    }

    // MARK: Old rules stay byte-identical

    private func sortedJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testStoredOldRuleDecodesAndEncodesUnchanged() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let withoutUntil = #"{"frequency":"weekly","interval":2,"timeZone":"Europe/Berlin"}"#
        let old = try decoder.decode(RecurrenceRule.self, from: Data(withoutUntil.utf8))
        XCTAssertNil(old.weekdays); XCTAssertNil(old.basis); XCTAssertNil(old.monthDay)
        XCTAssertEqual(try sortedJSON(old), withoutUntil)
        let withUntil = #"{"frequency":"daily","interval":1,"timeZone":"UTC","until":"2027-01-01T00:00:00Z"}"#
        XCTAssertEqual(try sortedJSON(try decoder.decode(RecurrenceRule.self, from: Data(withUntil.utf8))),
                       #"{"frequency":"daily","interval":1,"timeZone":"UTC","until":"2027-01-01T00:00:00Z"}"#)
        // Inside PlanningData too (REST/sync answers).
        let data = PlanningData(dueAt: at("2026-11-23 09:00"), priority: 1, recurrence: rule("daily"), reminders: [])
        let json = try sortedJSON(data)
        XCTAssertFalse(json.contains("weekdays") || json.contains("basis") || json.contains("monthDay"), json)
    }

    func testNewFieldsAreEncodedOnlyWhenSet() throws {
        XCTAssertEqual(try sortedJSON(rule("weekly", weekdays: [1, 4], basis: "completion")),
                       #"{"basis":"completion","frequency":"weekly","interval":1,"timeZone":"UTC","weekdays":[1,4]}"#)
        XCTAssertEqual(try sortedJSON(rule("monthly", monthDay: 31)), #"{"frequency":"monthly","interval":1,"monthDay":31,"timeZone":"UTC"}"#)
        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: Data(#"{"frequency":"weekly","interval":1,"timeZone":"UTC","weekdays":[2,5],"basis":"due"}"#.utf8))
        XCTAssertEqual(decoded.weekdays, [2, 5]); XCTAssertEqual(decoded.basis, "due"); XCTAssertNil(decoded.monthDay)
    }

    func testRuleWithoutNewFieldsGivesExactlyTheLegacyResult() throws {
        for tz in ["UTC", "Europe/Berlin", "America/New_York", "Pacific/Auckland"] {
            for (frequency, interval) in [("daily", 1), ("daily", 45), ("weekly", 1), ("weekly", 2), ("monthly", 1), ("monthly", 13)] {
                let r = rule(frequency, interval, tz: tz)
                XCTAssertFalse(r.usesExtendedRules)
                for text in ["2026-03-28 09:00", "2026-10-24 23:30", "2027-01-31 00:00", "2028-02-29 12:34"] {
                    let due = at(text, tz)
                    let legacy = try r.next(due)
                    XCTAssertEqual(try r.successor(of: due, completedAt: at("2031-07-04 10:00")), legacy, "\(tz) \(frequency) \(interval) \(text)")
                }
            }
        }
        XCTAssertTrue(rule("daily", basis: "due").usesExtendedRules)
        XCTAssertTrue(rule("weekly", weekdays: [1]).usesExtendedRules)
        XCTAssertTrue(rule("monthly", monthDay: 1).usesExtendedRules)
    }

    // MARK: Successor cards (service level, injected completion time)

    private func completedTask(_ f: OAuthFixture, rule: RecurrenceRule, due: Date?, planned: Date? = nil, reminders: [Date] = []) async throws -> (TodoTask, TaskPlanning) {
        let db = f.test.app.db
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Recurring", details: "")
        task.status = "done"
        try await task.save(on: db)
        let p = TaskPlanning(taskID: try task.requireID())
        p.dueAt = due; p.plannedAt = planned; p.recurrence = rule; p.reminders = reminders; p.priority = 2
        try await p.save(on: db)
        return (task, p)
    }

    private func successor(_ f: OAuthFixture, of task: TodoTask) async throws -> TaskPlanning {
        let receipt = try await PlanningOccurrence.find(task.requireID(), on: f.test.app.db)
        let nextID = try XCTUnwrap(receipt?.nextTaskID)
        let planning = try await TaskPlanning.find(nextID, on: f.test.app.db)
        return try XCTUnwrap(planning)
    }

    func testSpawnNextWithCompletionBasisUsesTheInjectedTime() async throws {
        let f = try await OAuthFixture.make()
        do {
            let (task, p) = try await completedTask(f, rule: rule("daily", 2, tz: "Europe/Berlin", basis: "completion"),
                due: at("2026-11-02 09:00", "Europe/Berlin"), planned: at("2026-11-02 08:00", "Europe/Berlin"),
                reminders: [at("2026-11-02 08:30", "Europe/Berlin"), at("2026-11-01 18:00", "Europe/Berlin")])
            try await PlanningService(user: f.user, db: f.test.app.db).spawnNext(task, planning: p, completedAt: at("2026-11-10 18:20", "Europe/Berlin"))
            let next = try await successor(f, of: task)
            XCTAssertEqual(wall(try XCTUnwrap(next.dueAt), "Europe/Berlin"), "2026-11-12 09:00")
            XCTAssertEqual(wall(try XCTUnwrap(next.plannedAt), "Europe/Berlin"), "2026-11-12 08:00")
            // Reminders move by the due-date shift, keeping their distance to the due date.
            let shift = try XCTUnwrap(next.dueAt).timeIntervalSince(try XCTUnwrap(p.dueAt))
            XCTAssertEqual(next.reminders, p.reminders.map { $0.addingTimeInterval(shift) })
            XCTAssertEqual(next.priority, 2)
            XCTAssertEqual(next.recurrence, p.recurrence)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSpawnNextWithWeekdaysAndMonthDayFromTheDueDate() async throws {
        let f = try await OAuthFixture.make()
        do {
            let (weekly, wp) = try await completedTask(f, rule: rule("weekly", weekdays: [1, 4]), due: at("2026-11-23 09:00"), reminders: [at("2026-11-23 08:00")])
            // The completion time is irrelevant for basis due.
            try await PlanningService(user: f.user, db: f.test.app.db).spawnNext(weekly, planning: wp, completedAt: at("2030-01-01 00:00"))
            let a = try await successor(f, of: weekly)
            XCTAssertEqual(wall(try XCTUnwrap(a.dueAt)), "2026-11-26 09:00")
            XCTAssertEqual(a.reminders.map { wall($0) }, ["2026-11-26 08:00"])
            let (monthly, mp) = try await completedTask(f, rule: rule("monthly", monthDay: 31), due: at("2027-01-31 09:00"), reminders: [at("2027-01-30 09:00")])
            try await PlanningService(user: f.user, db: f.test.app.db).spawnNext(monthly, planning: mp, completedAt: at("2027-01-31 12:00"))
            let b = try await successor(f, of: monthly)
            XCTAssertEqual(wall(try XCTUnwrap(b.dueAt)), "2027-02-28 09:00")
            XCTAssertEqual(b.reminders.map { wall($0) }, ["2027-02-27 09:00"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSpawnNextKeepsLegacyReminderArithmeticForOldRules() async throws {
        let f = try await OAuthFixture.make()
        do {
            // Daily in Berlin across the spring switch: the legacy rule moves each reminder by a calendar day (wall clock stays).
            let r = rule("daily", tz: "Europe/Berlin")
            let (task, p) = try await completedTask(f, rule: r, due: at("2026-03-28 09:00", "Europe/Berlin"), reminders: [at("2026-03-28 08:00", "Europe/Berlin")])
            try await PlanningService(user: f.user, db: f.test.app.db).spawnNext(task, planning: p, completedAt: at("2031-01-01 00:00"))
            let next = try await successor(f, of: task)
            XCTAssertEqual(next.dueAt, try r.next(XCTUnwrap(p.dueAt)))
            XCTAssertEqual(next.reminders, [try r.next(p.reminders[0])])
            XCTAssertEqual(wall(next.reminders[0], "Europe/Berlin"), "2026-03-29 08:00")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSpawnNextHonoursUntilForTheNewRules() async throws {
        let f = try await OAuthFixture.make()
        do {
            var r = rule("weekly", weekdays: [1, 4]); r.until = at("2026-11-25 23:59")
            let (task, p) = try await completedTask(f, rule: r, due: at("2026-11-23 09:00"))
            try await PlanningService(user: f.user, db: f.test.app.db).spawnNext(task, planning: p, completedAt: at("2026-11-23 10:00"))
            let receipt = try await PlanningOccurrence.find(task.requireID(), on: f.test.app.db)
            XCTAssertNotNil(receipt); XCTAssertNil(receipt?.nextTaskID)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
