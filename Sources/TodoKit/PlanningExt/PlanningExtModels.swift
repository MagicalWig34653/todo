import Fluent
import Vapor

/// A recurrence rule. Stored as a JSON column and sent as-is over REST, sync and MCP.
/// The three optional fields were added later (card 21CF716D); they are omitted from the JSON when nil, so rules written
/// without them encode byte-identically and clients that do not know them keep working.
struct RecurrenceRule: Content, Equatable {
    var frequency: String
    var interval: Int
    var timeZone: String
    var until: Date?
    /// ISO weekdays (1 Monday ... 7 Sunday), only with `weekly`; unique, not empty.
    var weekdays: [Int]?
    /// `due` (default, count from the due date) or `completion` (count from the day the task was completed).
    var basis: String?
    /// Day of month 1...31, only with `monthly`; short months use their last day without drifting the target.
    var monthDay: Int?

    static let bases = ["due", "completion"]

    /// True when any field added after the first version is set; only then the successor is not plain `next`.
    var usesExtendedRules: Bool { weekdays != nil || basis != nil || monthDay != nil }

    func validate() throws {
        guard ["daily", "weekly", "monthly"].contains(frequency), (1...1000).contains(interval),
              TimeZone(identifier: timeZone) != nil else { throw Abort(.badRequest, reason: "invalid_recurrence") }
        if let weekdays {
            guard frequency == "weekly", !weekdays.isEmpty, Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (1...7).contains($0) }) else { throw Abort(.badRequest, reason: "invalid_recurrence") }
        }
        if let monthDay {
            guard frequency == "monthly", (1...31).contains(monthDay) else { throw Abort(.badRequest, reason: "invalid_recurrence") }
        }
        if let basis, !Self.bases.contains(basis) { throw Abort(.badRequest, reason: "invalid_recurrence") }
    }

    /// Legacy step: one interval from `date` (wall-clock time kept in `timeZone`).
    func next(_ date: Date) throws -> Date {
        try validate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        let component: Calendar.Component = frequency == "daily" ? .day : frequency == "weekly" ? .weekOfYear : .month
        guard let result = calendar.date(byAdding: component, value: interval, to: date) else {
            throw Abort(.badRequest, reason: "invalid_recurrence_date")
        }
        return result
    }

    /// Next occurrence after `date` (a due date or planned start). Rules without new fields, and `basis: due` alone, are `next`.
    /// The base day is the calendar day in `timeZone` of `date` (or of `completedAt` for basis completion); the wall-clock time
    /// of `date` stays, also across daylight saving changes.
    func successor(of date: Date, completedAt: Date) throws -> Date {
        try validate()
        guard weekdays != nil || monthDay != nil || basis == "completion" else { return try next(date) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        let baseDay = calendar.startOfDay(for: basis == "completion" ? completedAt : date)
        let target: Date?
        if let weekdays {
            // ISO weekday of the base day: Calendar numbers Sunday as 1.
            let iso = (calendar.component(.weekday, from: baseDay) + 5) % 7 + 1
            let days: Int
            if let later = weekdays.filter({ $0 > iso }).min() { days = later - iso }
            else { days = 7 * interval - (iso - 1) + ((weekdays.min() ?? 1) - 1) }
            target = calendar.date(byAdding: .day, value: days, to: baseDay)
        } else if let monthDay {
            var first = calendar.dateComponents([.year, .month], from: baseDay); first.day = 1
            if let month = calendar.date(from: first).flatMap({ calendar.date(byAdding: .month, value: interval, to: $0) }),
               let length = calendar.range(of: .day, in: .month, for: month)?.count {
                var parts = calendar.dateComponents([.year, .month], from: month); parts.day = min(monthDay, length)
                target = calendar.date(from: parts)
            } else { target = nil }
        } else {
            let component: Calendar.Component = frequency == "monthly" ? .month : .day
            let amount = frequency == "weekly" ? 7 * interval : interval
            target = calendar.date(byAdding: component, value: amount, to: baseDay)
        }
        guard let target else { throw Abort(.badRequest, reason: "invalid_recurrence_date") }
        var parts = calendar.dateComponents([.year, .month, .day], from: target)
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        parts.hour = time.hour; parts.minute = time.minute; parts.second = time.second; parts.nanosecond = time.nanosecond
        guard let result = calendar.date(from: parts) else { throw Abort(.badRequest, reason: "invalid_recurrence_date") }
        return result
    }
}

final class TaskPlanning: Model, @unchecked Sendable {
    static let schema = "task_planning"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @OptionalField(key: "due_at") var dueAt: Date?
    @OptionalField(key: "planned_at") var plannedAt: Date?
    @OptionalField(key: "planned_minutes") var plannedMinutes: Int?
    @Field(key: "planned_all_day") var plannedAllDay: Bool
    /// ADR 0033: the owner allowed the guard to hand this card to a runner at `plannedAt` (one time).
    @Field(key: "auto_start") var autoStart: Bool
    /// Server clock of the automatic hand-over; set only for the scheduler origin.
    @OptionalField(key: "auto_started_at") var autoStartedAt: Date?
    @Field(key: "priority") var priority: Int
    @Field(key: "position") var position: Int
    @OptionalField(key: "recurrence") var recurrence: RecurrenceRule?
    @Field(key: "reminders") var reminders: [Date]
    init() {}
    init(taskID: UUID) { id = taskID; priority = 0; position = 0; reminders = []; plannedAllDay = false; autoStart = false }
}

final class PlanningDependency: Model, @unchecked Sendable {
    static let schema = "planning_dependencies"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "prerequisite_id") var prerequisiteID: UUID
    init() {}
    init(_ task: UUID, _ prerequisite: UUID) { taskID = task; prerequisiteID = prerequisite }
}

final class PlanningMilestone: Model, Content, @unchecked Sendable {
    static let schema = "planning_milestones"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "title") var title: String
    @OptionalField(key: "due_at") var dueAt: Date?
    init() {}
    init(projectID: UUID, title: String, dueAt: Date?) { self.projectID = projectID; self.title = title; self.dueAt = dueAt }
}

final class PlanningMilestoneTask: Model, @unchecked Sendable {
    static let schema = "planning_milestone_tasks"
    @ID(key: .id) var id: UUID?
    @Field(key: "milestone_id") var milestoneID: UUID
    @Field(key: "task_id") var taskID: UUID
    init() {}
    init(_ milestone: UUID, _ task: UUID) { milestoneID = milestone; taskID = task }
}

/// A durable receipt, unique per completed source, survives retries and reopening.
final class PlanningOccurrence: Model, @unchecked Sendable {
    static let schema = "planning_occurrences"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @OptionalField(key: "next_task_id") var nextTaskID: UUID?
    init() {}
    init(source: UUID, next: UUID?) { id = source; nextTaskID = next }
}
