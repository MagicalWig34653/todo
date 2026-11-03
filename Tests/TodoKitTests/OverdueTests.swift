import Fluent
import XCTVapor
@testable import TodoKit

final class OverdueTests: XCTestCase {
    private func task(_ f: OAuthFixture, title: String, project: Project? = nil, status: String = "open", due: Date? = nil, parent: TodoTask? = nil) async throws -> TodoTask {
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try (project ?? f.project).requireID(), title: title, details: "")
        task.status = status
        try await task.save(on: f.test.app.db)
        let planning = TaskPlanning(taskID: try task.requireID())
        planning.dueAt = due
        try await planning.save(on: f.test.app.db)
        if let parent {
            let workflow = TaskWorkflow(taskID: try task.requireID())
            workflow.parentTaskID = try parent.requireID()
            try await workflow.save(on: f.test.app.db)
        }
        return task
    }

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> Any {
        let result = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let body = try XCTUnwrap(result.body?["result"] as? [String: Any])
        XCTAssertEqual(body["isError"] as? Bool, false)
        let text = try XCTUnwrap((body["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testOverdueAcrossRESTAndMCPRespectsVisibilityAndFinishedTasks() async throws {
        let f = try await OAuthFixture.make()
        do {
            let past = Date().addingTimeInterval(-3600), future = Date().addingTimeInterval(3600)
            let parent = try await task(f, title: "Feature", due: future)
            _ = try await task(f, title: "Overdue child", due: past, parent: parent)
            _ = try await task(f, title: "Done child", status: "done", due: past.addingTimeInterval(-3600), parent: parent)
            _ = try await task(f, title: "No due")
            _ = try await task(f, title: "Done", status: "done", due: past)
            let backlog = ProjectColumn(projectID: try f.project.requireID(), name: "Backlog", color: nil, isDone: false, position: 0)
            try await backlog.save(on: f.test.app.db)
            let waiting = try await task(f, title: "Overdue backlog", due: past)
            waiting.columnID = try backlog.requireID()
            try await waiting.save(on: f.test.app.db)
            _ = try await task(f, title: "Outside grant", project: f.other, due: past)
            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: f.test.app.db)
            let hidden = Project(ownerID: try stranger.requireID(), parentID: try f.project.requireID(), name: "Hidden child project")
            try await hidden.save(on: f.test.app.db)
            let sharing = try ProjectSharing(project: hidden)
            sharing.inherits = false
            try await sharing.save(on: f.test.app.db)
            _ = try await task(f, title: "Hidden", project: hidden, due: past)
            let tokens = try await f.tokens()
            let pid = try f.project.requireID().uuidString
            let rest = try await f.test.json(.GET, "/v1/tasks?projectID=\(pid)&overdue=true", token: f.session)
            XCTAssertEqual(Set(rest.list!.compactMap { $0["title"] as? String }), ["Overdue child", "Overdue backlog"])
            let mcp = try await call(f, "list_tasks", ["projectID": pid, "overdue": true], access: tokens.access) as! [[String: Any]]
            XCTAssertEqual(Set(mcp.compactMap { $0["title"] as? String }), ["Overdue child", "Overdue backlog"])
            XCTAssertTrue(mcp.allSatisfy { ($0["planning"] as? [String: Any])?["dueAt"] != nil })
            let all = try await call(f, "list_tasks", ["projectID": pid, "overdue": false], access: tokens.access) as! [[String: Any]]
            XCTAssertEqual(all.count, 6)
            let center = try await call(f, "get_command_center", ["view": "list", "limit": 1, "lane": "ready", "fields": "dueDate,nextDue"], access: tokens.access) as! [String: Any]
            XCTAssertEqual((center["summary"] as? [String: Any])?["overdue"] as? Int, 2, "includes backlog and subtask before card filters/limit, excludes outside grant")
            let card = try XCTUnwrap((center["items"] as? [[String: Any]])?.first)
            XCTAssertNotEqual(card["dueDate"] as? String, card["nextDue"] as? String)
            XCTAssertEqual(card["dueDate"] as? String, (all.first { $0["title"] as? String == "Feature" }?["planning"] as? [String: Any])?["dueAt"] as? String)
            XCTAssertEqual(card["nextDue"] as? String, (mcp.first { $0["title"] as? String == "Overdue child" }?["planning"] as? [String: Any])?["dueAt"] as? String)
            let full = try await call(f, "get_command_center", ["view": "list", "compact": false, "projectID": pid, "includeSubprojects": false], access: tokens.access) as! [String: Any]
            let fullCard = try XCTUnwrap((full["items"] as? [[String: Any]])?.first { ($0["task"] as? [String: Any])?["title"] as? String == "Feature" })
            XCTAssertEqual(fullCard["dueDate"] as? String, card["dueDate"] as? String)
            XCTAssertEqual(fullCard["nextDue"] as? String, card["nextDue"] as? String)
            let account = try await f.test.json(.GET, "/v1/command-center?view=list&limit=1", token: f.session)
            XCTAssertEqual((account.body?["summary"] as? [String: Any])?["overdue"] as? Int, 3, "user sees excluded grant project, never hidden child project")
            let hiddenList = try await f.test.json(.GET, "/v1/tasks?projectID=\(try hidden.requireID())&overdue=true", token: f.session)
            XCTAssertEqual(hiddenList.status, .notFound)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testStrictDueBoundaryAndBatchedQueryCount() async throws {
        let f = try await OAuthFixture.make()
        do {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try await task(f, title: "Before", due: now.addingTimeInterval(-1))
            _ = try await task(f, title: "Equal", due: now)
            _ = try await task(f, title: "After", due: now.addingTimeInterval(1))
            let history = QueryHistory()
            let db = try XCTUnwrap(f.test.app.databases.database(logger: f.test.app.logger, on: f.test.app.eventLoopGroup.next(), history: history))
            let small = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: true, now: now)
            XCTAssertEqual(small.map(\.title), ["Before"])
            let listQueries = history.queries.count
            history.queries = []
            _ = try await CommandCenterService(user: f.user, db: db).build(CommandCenterQuery())
            let centerQueries = history.queries.count
            for index in 0..<15 {
                let project = Project(ownerID: try f.user.requireID(), parentID: nil, name: "P\(index)")
                try await project.save(on: f.test.app.db)
                _ = try await task(f, title: "T\(index)", project: project, due: now.addingTimeInterval(-1))
            }
            history.queries = []
            let large = try await PlanningController.taskList(user: f.user, db: db, projectID: nil, overdue: true, now: now)
            XCTAssertEqual(large.count, 16)
            XCTAssertEqual(history.queries.count, listQueries, "one SharingSnapshot and batched planning, no per-task/project reads")
            history.queries = []
            _ = try await CommandCenterService(user: f.user, db: db).build(CommandCenterQuery())
            XCTAssertEqual(history.queries.count, centerQueries, "command center query count stays constant below batch size")
            print("Overdue query counts (3 -> 18 tasks, 2 -> 17 projects): list=\(listQueries), command-center=\(centerQueries)")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
