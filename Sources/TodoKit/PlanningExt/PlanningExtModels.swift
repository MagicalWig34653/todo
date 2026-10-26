import Fluent
import Vapor

struct RecurrenceRule: Content, Equatable {
    var frequency: String
    var interval: Int
    var timeZone: String
    var until: Date?

    func validate() throws {
        guard ["daily", "weekly", "monthly"].contains(frequency), (1...1000).contains(interval),
              TimeZone(identifier: timeZone) != nil else { throw Abort(.badRequest, reason: "invalid_recurrence") }
    }

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
}

final class TaskPlanning: Model, @unchecked Sendable {
    static let schema = "task_planning"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @OptionalField(key: "due_at") var dueAt: Date?
    @OptionalField(key: "planned_at") var plannedAt: Date?
    @Field(key: "priority") var priority: Int
    @Field(key: "position") var position: Int
    @OptionalField(key: "recurrence") var recurrence: RecurrenceRule?
    @Field(key: "reminders") var reminders: [Date]
    init() {}
    init(taskID: UUID) { id = taskID; priority = 0; position = 0; reminders = [] }
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
