import Fluent
import Vapor

/// Reads the plan activities (`plan.written`, `plan.approved`, `plan.changes_requested`) for the feed and the update list.
/// The activity points to the audit entry of the card pipeline, which knows the version and the comment of that very moment;
/// activities of an earlier build pointed to the plan row, which only knows the current ones (a fallback, without history).
struct PipelinePlanActivity: Sendable {
    static let kinds = ["plan.written", "plan.approved", "plan.changes_requested"]

    let events: [UUID: TaskPipelineEvent]
    let plans: [UUID: TaskPlan]

    static func load(_ subjectIDs: [UUID], on db: any Database) async throws -> PipelinePlanActivity {
        guard !subjectIDs.isEmpty else { return PipelinePlanActivity(events: [:], plans: [:]) }
        let ids = Array(Set(subjectIDs))
        let events = try await TaskPipelineEvent.query(on: db).filter(\.$id ~~ ids).all()
        let rest = ids.filter { id in !events.contains { $0.id == id } }
        let plans = rest.isEmpty ? [] : try await TaskPlan.query(on: db).filter(\.$id ~~ rest).all()
        return PipelinePlanActivity(events: Dictionary(events.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { first, _ in first }),
            plans: Dictionary(plans.compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { first, _ in first }))
    }

    /// Version of the plan and the decision comment (nil for a written plan or a decision without comment).
    func describe(_ subjectID: UUID?) -> (version: Int, comment: String?)? {
        guard let subjectID else { return nil }
        if let e = events[subjectID], let version = e.planVersion { return (version, e.note) }
        if let p = plans[subjectID] { return (p.version, p.decisionComment) }
        return nil
    }
}
