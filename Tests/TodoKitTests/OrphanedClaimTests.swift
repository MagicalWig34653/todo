import Fluent
import XCTVapor
@testable import TodoKit

final class OrphanedClaimTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var hour: TimeInterval { 3600 }

    private func claimedTask(_ f: OAuthFixture, title: String, project: Project? = nil, status: String = "in_progress",
                             claimedAt: Date, claim: Bool = true) async throws -> TodoTask {
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try (project ?? f.project).requireID(), title: title, details: "")
        task.status = status
        try await task.save(on: f.test.app.db)
        let wf = TaskWorkflow(taskID: try task.requireID())
        if claim { wf.claimedByType = "agent"; wf.claimedByID = UUID(); wf.claimedLabel = "Claude"; wf.claimedAt = claimedAt }
        try await wf.save(on: f.test.app.db)
        return task
    }

    private func center(_ f: OAuthFixture, at now: Date, user: User? = nil, _ query: CommandCenterQuery = CommandCenterQuery()) async throws -> CommandCenterResponse {
        try await CommandCenterService(user: user ?? f.user, db: f.test.app.db, clock: { now }).build(query)
    }

    private func listQuery(_ extra: (inout CommandCenterQuery) -> Void = { _ in }) -> CommandCenterQuery {
        var q = CommandCenterQuery(); q.view = "list"; q.includeSubtasks = true; extra(&q); return q
    }

    private func run(_ f: OAuthFixture, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testFreshClaimIsNotOrphanedStaleOneIs() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let task = try await claimedTask(f, title: "Stale", claimedAt: base)
            let fresh = try await center(f, at: base.addingTimeInterval(23 * hour), listQuery())
            XCTAssertEqual(fresh.summary.orphanedClaims, 0)
            XCTAssertEqual(fresh.items?.first?.orphaned, false)
            let exactly = try await center(f, at: base.addingTimeInterval(24 * hour), listQuery())
            XCTAssertEqual(exactly.summary.orphanedClaims, 0, "threshold is strictly more than 24 hours")
            let stale = try await center(f, at: base.addingTimeInterval(25 * hour), listQuery())
            XCTAssertEqual(stale.summary.orphanedClaims, 1)
            let card = try XCTUnwrap(stale.items?.first)
            XCTAssertTrue(card.orphaned)
            XCTAssertEqual(card.lastSignOfLifeAt, base)
            let context = try await WorkflowService(user: f.user, db: f.test.app.db).context(try task.requireID(), now: base.addingTimeInterval(25 * hour))
            XCTAssertTrue(context.workflow.orphaned)
            XCTAssertEqual(context.workflow.lastSignOfLifeAt, base)
        }
    }

    func testNoClaimOrNotInProgressIsNeverOrphaned() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            _ = try await claimedTask(f, title: "No claim", claimedAt: base, claim: false)
            _ = try await claimedTask(f, title: "In review", status: "in_review", claimedAt: base)
            _ = try await claimedTask(f, title: "Done", status: "done", claimedAt: base)
            let result = try await center(f, at: base.addingTimeInterval(100 * hour), listQuery())
            XCTAssertEqual(result.summary.orphanedClaims, 0)
            XCTAssertTrue((result.items ?? []).allSatisfy { !$0.orphaned })
        }
    }

    func testSignsOfLifeResetTheClock() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let db = f.test.app.db
            let note = try await claimedTask(f, title: "Note", claimedAt: base)
            let comment = try await claimedTask(f, title: "Comment", claimedAt: base)
            let status = try await claimedTask(f, title: "Status", claimedAt: base)
            let job = try await claimedTask(f, title: "Runner", claimedAt: base)
            let silent = try await claimedTask(f, title: "Silent", claimedAt: base)
            let signAt = base.addingTimeInterval(20 * hour)
            let n = TaskProgressNote()
            n.taskID = try note.requireID(); n.actorType = .integration; n.actorID = UUID(); n.note = "working"
            try await n.save(on: db); n.createdAt = signAt; try await n.save(on: db)
            let c = TaskComment(taskID: try comment.requireID(), authorID: try f.user.requireID(), body: "hi")
            try await c.save(on: db); c.createdAt = signAt; try await c.save(on: db)
            try await appendActivity(taskID: try status.requireID(), actorType: .person, actorID: try f.user.requireID(), kind: "task.status_changed", subjectID: nil, on: db)
            let event = try await ActivityEvent.query(on: db).filter(\.$taskID == status.requireID()).first()!
            event.createdAt = signAt; try await event.save(on: db)
            let device = RunnerDevice(ownerID: try f.user.requireID(), label: "Mac", tokenHash: "dev-hash", revokedAt: nil)
            try await device.save(on: db)
            let binding = ProjectRunnerBinding(projectID: try f.project.requireID(), deviceID: try device.requireID(), repositoryKey: "r", label: "l")
            try await binding.save(on: db)
            let agentJob = AgentJob(taskID: try job.requireID(), projectID: try f.project.requireID(), bindingID: try binding.requireID(), requestedBy: try f.user.requireID(),
                taskRevision: 0, mode: "implement", scope: "task", state: "running", progress: "", result: nil)
            try await agentJob.save(on: db)
            try await AgentEvent(jobID: try agentJob.requireID(), runID: nil, kind: "checkpoint", detail: "", createdAt: signAt).save(on: db)

            let now = base.addingTimeInterval(30 * hour)
            let early = try await center(f, at: base.addingTimeInterval(25 * hour), listQuery())
            XCTAssertEqual(early.summary.orphanedClaims, 1, "only the silent claim is older than 24h; the others had a sign 5h ago")
            let result = try await center(f, at: now, listQuery())
            let byTitle = Dictionary(uniqueKeysWithValues: (result.items ?? []).map { ($0.task.title, $0) })
            for title in ["Note", "Comment", "Status", "Runner"] {
                XCTAssertFalse(try XCTUnwrap(byTitle[title]).orphaned, "\(title) had a sign of life 10h ago")
                XCTAssertEqual(try XCTUnwrap(byTitle[title]).lastSignOfLifeAt, signAt, title)
            }
            XCTAssertTrue(try XCTUnwrap(byTitle["Silent"]).orphaned)
            XCTAssertEqual(result.summary.orphanedClaims, 1)
            _ = silent
            // 25h after the sign of life the same tasks are orphaned again.
            let later = try await center(f, at: signAt.addingTimeInterval(25 * hour), listQuery())
            XCTAssertEqual(later.summary.orphanedClaims, 5)
        }
    }

    func testFilterAndCounterIgnoreUnreadableTasks() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let db = f.test.app.db
            _ = try await claimedTask(f, title: "Mine", claimedAt: base)
            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: db)
            let hidden = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Hidden")
            try await hidden.save(on: db)
            _ = try await claimedTask(f, title: "Hidden", project: hidden, claimedAt: base)
            let now = base.addingTimeInterval(48 * hour)
            let mine = try await center(f, at: now, listQuery { $0.orphaned = true })
            XCTAssertEqual(mine.summary.orphanedClaims, 1)
            XCTAssertEqual(mine.items?.map(\.task.title), ["Mine"])
            let nonOrphaned = try await center(f, at: now, listQuery { $0.orphaned = false })
            XCTAssertEqual(nonOrphaned.items?.count, 0)
            let theirs = try await center(f, at: now, user: stranger, listQuery { $0.orphaned = true })
            XCTAssertEqual(theirs.summary.orphanedClaims, 1)
            XCTAssertEqual(theirs.items?.map(\.task.title), ["Hidden"])

            let listed = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: false, orphaned: true, now: now)
            XCTAssertEqual(listed.map(\.title), ["Mine"])
            XCTAssertEqual(listed.first?.orphaned, true)
            let fresh = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: false, orphaned: true, now: base.addingTimeInterval(hour))
            XCTAssertTrue(fresh.isEmpty)
            let others = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: false, orphaned: false, now: now)
            XCTAssertTrue(others.isEmpty)
            let plain = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: false, now: now)
            XCTAssertEqual(plain.count, 1)
            XCTAssertNil(plain.first?.orphaned)
        }
    }

    func testRESTAndMCPFilters() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            // Real clock: a claim from 3 days ago.
            _ = try await claimedTask(f, title: "Old claim", claimedAt: Date().addingTimeInterval(-72 * hour))
            _ = try await claimedTask(f, title: "New claim", claimedAt: Date())
            let pid = try f.project.requireID().uuidString
            let rest = try await f.test.json(.GET, "/v1/tasks?projectID=\(pid)&orphaned=true", token: f.session)
            XCTAssertEqual(rest.list?.compactMap { $0["title"] as? String }, ["Old claim"])
            let bad = try await f.test.json(.GET, "/v1/tasks?projectID=\(pid)&orphaned=maybe", token: f.session)
            XCTAssertEqual(bad.status, .badRequest)
            let center = try await f.test.json(.GET, "/v1/command-center?view=list&orphaned=true&includeSubtasks=true", token: f.session)
            XCTAssertEqual((center.body?["summary"] as? [String: Any])?["orphanedClaims"] as? Int, 1)
            XCTAssertEqual((center.body?["items"] as? [[String: Any]])?.count, 1)
            let tokens = try await f.tokens()
            let result = try await f.rpc("tools/call", ["name": "list_tasks", "arguments": ["projectID": pid, "orphaned": true]], access: tokens.access)
            let text = try XCTUnwrap((((result.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let tasks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
            XCTAssertEqual(tasks.compactMap { $0["title"] as? String }, ["Old claim"])
            let cc = try await f.rpc("tools/call", ["name": "get_command_center", "arguments": ["view": "list", "orphaned": true]], access: tokens.access)
            let ccText = try XCTUnwrap((((cc.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let ccBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ccText.utf8)) as? [String: Any])
            XCTAssertEqual((ccBody["summary"] as? [String: Any])?["orphanedClaims"] as? Int, 1)
            XCTAssertEqual((ccBody["items"] as? [[String: Any]])?.first?["orphaned"] as? Bool, true)
        }
    }

    func testQueryCountStaysConstantBelowChunkSize() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            _ = try await claimedTask(f, title: "One", claimedAt: base)
            let history = QueryHistory()
            let db = try XCTUnwrap(f.test.app.databases.database(logger: f.test.app.logger, on: f.test.app.eventLoopGroup.next(), history: history))
            let now = base.addingTimeInterval(48 * hour)
            _ = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: false, orphaned: true, now: now)
            let listQueries = history.queries.count
            history.queries = []
            _ = try await CommandCenterService(user: f.user, db: db, clock: { now }).build(CommandCenterQuery())
            let centerQueries = history.queries.count
            for index in 0..<30 { _ = try await claimedTask(f, title: "T\(index)", claimedAt: base) }
            history.queries = []
            let listed = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: false, orphaned: true, now: now)
            XCTAssertEqual(listed.count, 31)
            XCTAssertEqual(history.queries.count, listQueries)
            history.queries = []
            let response = try await CommandCenterService(user: f.user, db: db, clock: { now }).build(CommandCenterQuery())
            XCTAssertEqual(response.summary.orphanedClaims, 31)
            XCTAssertEqual(history.queries.count, centerQueries)
        }
    }

    func testParentCardWithOrphanedChildAndKanbanFilter() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let db = f.test.app.db
            let parent = try await claimedTask(f, title: "Parent", claimedAt: base, claim: false)
            let child = try await claimedTask(f, title: "Child", claimedAt: base)
            let ownParent = try await claimedTask(f, title: "Own", claimedAt: base)
            let found = try await TaskWorkflow.find(try child.requireID(), on: db)
            let wf = try XCTUnwrap(found)
            wf.parentTaskID = try parent.requireID(); try await wf.save(on: db)
            _ = ownParent
            let now = base.addingTimeInterval(48 * hour)
            let kanban = try await center(f, at: now, { var q = CommandCenterQuery(); q.orphaned = true; return q }())
            let cards = (kanban.lanes ?? []).flatMap(\.cards)
            XCTAssertEqual(Set(cards.map(\.task.title)), ["Parent", "Own"])
            let parentCard = try XCTUnwrap(cards.first { $0.task.title == "Parent" })
            XCTAssertTrue(parentCard.orphaned)
            XCTAssertEqual(parentCard.subtasks.first?.orphaned, true)
            XCTAssertEqual(parentCard.lastSignOfLifeAt, base)
            XCTAssertEqual(kanban.summary.orphanedClaims, 2, "tasks are counted individually (child and Own), cards with the flag are 2 as well")
            let negated = try await center(f, at: now, { var q = CommandCenterQuery(); q.orphaned = false; return q }())
            XCTAssertTrue((negated.lanes ?? []).flatMap(\.cards).isEmpty)
            XCTAssertEqual(negated.summary.orphanedClaims, 2, "summary is not narrowed by card filters")
        }
    }

    func testGrantScopeAndMultipleJobsPerTask() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let db = f.test.app.db
            _ = try await claimedTask(f, title: "Allowed", claimedAt: base)
            _ = try await claimedTask(f, title: "Excluded", project: f.other, claimedAt: base)
            let now = base.addingTimeInterval(48 * hour)
            let all = try await center(f, at: now)
            XCTAssertEqual(all.summary.orphanedClaims, 2)
            let granted = try await CommandCenterService(user: f.user, db: db, allowedProjects: [try f.project.requireID()], clock: { now }).build(listQuery { $0.orphaned = true })
            XCTAssertEqual(granted.summary.orphanedClaims, 1)
            XCTAssertEqual(granted.items?.map(\.task.title), ["Allowed"])

            // Two jobs on one task: the newest event of any job counts.
            let task = try await claimedTask(f, title: "Jobs", claimedAt: base)
            let device = RunnerDevice(ownerID: try f.user.requireID(), label: "Mac", tokenHash: "h", revokedAt: nil)
            try await device.save(on: db)
            let binding = ProjectRunnerBinding(projectID: try f.project.requireID(), deviceID: try device.requireID(), repositoryKey: "r", label: "l")
            try await binding.save(on: db)
            var jobIDs: [UUID] = []
            for state in ["failed", "running"] {
                let job = AgentJob(taskID: try task.requireID(), projectID: try f.project.requireID(), bindingID: try binding.requireID(), requestedBy: try f.user.requireID(),
                    taskRevision: 0, mode: "implement", scope: "task", state: state, progress: "", result: nil)
                try await job.save(on: db); jobIDs.append(try job.requireID())
            }
            try await AgentEvent(jobID: jobIDs[0], runID: nil, kind: "checkpoint", detail: "", createdAt: base.addingTimeInterval(10 * hour)).save(on: db)
            try await AgentEvent(jobID: jobIDs[1], runID: nil, kind: "checkpoint", detail: "", createdAt: base.addingTimeInterval(40 * hour)).save(on: db)
            try await AgentEvent(jobID: jobIDs[1], runID: nil, kind: "progress", detail: "", createdAt: base.addingTimeInterval(41 * hour)).save(on: db)
            let signs = try await ClaimLiveness.lastSignOfLife(claims: [try task.requireID(): base], on: db)
            XCTAssertEqual(signs[try task.requireID()], base.addingTimeInterval(41 * hour))
        }
    }

    func testClaimResponseCarriesLastSignOfLife() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "To claim", details: "")
            try await task.save(on: f.test.app.db)
            let context = try await WorkflowService(user: f.user, db: f.test.app.db)
                .claim(try task.requireID(), agentName: "Claude", takeOver: false, actor: WorkflowActor(type: .integration, id: UUID(), label: "Claude", via: "mcp"))
            XCTAssertFalse(context.workflow.orphaned)
            XCTAssertNotNil(context.workflow.lastSignOfLifeAt)
        }
    }
}
