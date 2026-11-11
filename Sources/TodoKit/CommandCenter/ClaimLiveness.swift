import Fluent
import Vapor

/// Orphaned claims: a claimed, in-progress task without any sign of life for longer than `orphanedAfter`.
/// Flag only; nothing is released automatically. Derived from existing data, no migration.
enum ClaimLiveness {
    static let orphanedAfter: TimeInterval = 24 * 3600
    private static let chunkSize = 400

    static func isOrphaned(status: String, hasClaim: Bool, lastSignOfLife: Date?, now: Date) -> Bool {
        guard hasClaim, status == "in_progress", let last = lastSignOfLife else { return false }
        return now.timeIntervalSince(last) > orphanedAfter
    }

    /// Latest sign of life per task: newest of the claim time, progress note, comment, activity event (status changes,
    /// questions, reviews, claims, ...) and runner event (checkpoints, progress, questions of the task's jobs).
    /// `claims` maps task id to its `claimedAt`. A constant number of queries per chunk of 400 tasks.
    static func lastSignOfLife(claims: [UUID: Date?], on db: any Database) async throws -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        func bump(_ id: UUID, _ date: Date?) { if let date, date > (result[id] ?? .distantPast) { result[id] = date } }
        for (id, at) in claims { bump(id, at) }
        let ids = Array(claims.keys)
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + chunkSize, ids.count)])
            index += chunkSize
            for note in try await TaskProgressNote.query(on: db).field(\.$taskID).field(\.$createdAt).filter(\.$taskID ~~ chunk)
                .filter(latest("task_progress_notes", "task_id")).all() { bump(note.taskID, note.createdAt) }
            for comment in try await TaskComment.query(on: db).field(\.$taskID).field(\.$createdAt).filter(\.$taskID ~~ chunk)
                .filter(latest("comments", "task_id")).all() { bump(comment.taskID, comment.createdAt) }
            for event in try await ActivityEvent.query(on: db).field(\.$taskID).field(\.$createdAt).filter(\.$taskID ~~ chunk)
                .filter(latest("activity_events", "task_id")).all() { bump(event.taskID, event.createdAt) }
            let jobs = try await AgentJob.query(on: db).field(\.$id).field(\.$taskID).filter(\.$taskID ~~ chunk).all()
            guard !jobs.isEmpty else { continue }
            let taskOfJob = Dictionary(jobs.compactMap { job in job.id.map { ($0, job.taskID) } }, uniquingKeysWith: { first, _ in first })
            for event in try await AgentEvent.query(on: db).field(\.$jobID).field(\.$createdAt).filter(\.$jobID ~~ Array(taskOfJob.keys))
                .filter(latest("agent_events", "job_id")).all() {
                if let task = taskOfJob[event.jobID] { bump(task, event.createdAt) }
            }
        }
        return result
    }

    /// `table` and `group` are only ever the literal table/column names passed above, never user input.
    /// Keeps only the newest row per group (ties by id), so one row per task or job is read.
    private static func latest(_ table: String, _ group: String) -> DatabaseQuery.Filter {
        .sql(embed: "\(unsafeRaw: table).id = (SELECT n2.id FROM \(unsafeRaw: table) n2 WHERE n2.\(unsafeRaw: group) = \(unsafeRaw: table).\(unsafeRaw: group) ORDER BY n2.created_at DESC, n2.id DESC LIMIT 1)")
    }
}
