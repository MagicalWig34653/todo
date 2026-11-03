import Fluent
import XCTVapor
@testable import TodoKit

/// Account-wide MCP reads name the current project and mark or filter foreign entries (docs/MCP-PARITAET.md).
final class MCPCurrentProjectTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    /// One task with an open question and a pending review in the project.
    private func seed(_ f: OAuthFixture, project: Project, title: String) async throws {
        let db = f.test.app.db
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try project.requireID(), title: title)
        task.status = "in_review"
        try await task.save(on: db)
        let q = TaskQuestion()
        q.taskID = try task.requireID(); q.askedByType = .integration; q.askedByID = UUID(); q.askedByLabel = "agent"
        q.prompt = "Question for \(title)"; q.options = []; q.blocking = true; q.state = "open"; q.version = 1
        try await q.save(on: db)
        let r = TaskReview()
        r.taskID = try task.requireID(); r.state = "pending"; r.requestedByType = .integration; r.requestedByID = UUID()
        r.requestedByLabel = "agent"; r.summary = "Review of \(title)"; r.version = 1
        try await r.save(on: db)
    }

    private func items(_ c: Called) throws -> [[String: Any]] {
        try XCTUnwrap((try XCTUnwrap(c.json as? [String: Any], c.text))["items"] as? [[String: Any]], c.text)
    }
    private func current(_ c: Called) -> [String: Any]? { (c.json as? [String: Any])?["currentProject"] as? [String: Any] }

    func testCurrentProjectFiltersMarksForeignAndHintsWithoutProject() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: "projects:read tasks:read tasks:write")
            let access = t.access
            let db = f.test.app.db
            let other = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Other")
            try await other.save(on: db)
            let sub = Project(ownerID: try f.user.requireID(), parentID: try f.project.requireID(), name: "Sub")
            try await sub.save(on: db)
            let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: db).first())
            g.projects.append(contentsOf: [try other.requireID(), try sub.requireID()]); try await g.save(on: db)
            try await seed(f, project: f.project, title: "Mine")
            try await seed(f, project: sub, title: "Mine sub")
            try await seed(f, project: other, title: "Foreign")
            let pid = try f.project.requireID().uuidString

            for tool in ["list_open_questions", "list_pending_reviews"] {
                // No project: everything, hint, no currentProject, no foreign marks.
                let none = try await call(f, tool, [:], access)
                XCTAssertEqual(try items(none).count, 3, tool)
                XCTAssertTrue(((none.json as? [String: Any])?["hint"] as? String)?.contains("projectID") == true)
                XCTAssertNil(current(none)?["id"])
                XCTAssertTrue(try items(none).allSatisfy { $0["foreignProject"] == nil && $0["projectName"] != nil })
                // Current project: filtered (including sub-project), named, no hint.
                let scoped = try await call(f, tool, ["projectID": pid], access)
                XCTAssertEqual(current(scoped)?["id"] as? String, pid)
                XCTAssertEqual(current(scoped)?["name"] as? String, f.project.name)
                XCTAssertNil((scoped.json as? [String: Any])?["hint"])
                XCTAssertEqual(Set(try items(scoped).compactMap { $0["projectName"] as? String }), [f.project.name, "Sub"], tool)
                XCTAssertTrue(try items(scoped).allSatisfy { $0["foreignProject"] as? Bool == false })
                // Account scope: all entries, foreign ones marked.
                let account = try await call(f, tool, ["projectID": pid, "scope": "account"], access)
                let rows = try items(account)
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows.filter { $0["foreignProject"] as? Bool == true }.compactMap { $0["projectName"] as? String }, ["Other"], tool)
                XCTAssertTrue(((account.json as? [String: Any])?["hint"] as? String)?.contains("foreignProject") == true)
                // fields filter keeps the mark.
                let fields = try await call(f, tool == "list_open_questions" ? tool : "list_open_questions", ["projectID": pid, "scope": "account", "fields": "id,prompt"], access)
                XCTAssertTrue(try items(fields).allSatisfy { $0["foreignProject"] != nil && $0["prompt"] != nil })
                // Invalid scope / unknown project.
                let bad = try await call(f, tool, ["scope": "weird"], access)
                XCTAssertTrue(bad.isError)
                let needs = try await call(f, tool, ["scope": "project"], access)
                XCTAssertTrue(needs.isError)
                let unknown = try await call(f, tool, ["projectID": UUID().uuidString], access)
                XCTAssertTrue(unknown.isError)
            }

            // Command center: kanban and list.
            let none = try await call(f, "get_command_center", ["view": "list"], access)
            let noneObj = try XCTUnwrap(none.json as? [String: Any])
            XCTAssertNotNil(noneObj["hint"])
            XCTAssertEqual((noneObj["items"] as? [[String: Any]])?.count, 3)
            let scoped = try await call(f, "get_command_center", ["view": "list", "projectID": pid], access)
            let scopedObj = try XCTUnwrap(scoped.json as? [String: Any])
            XCTAssertEqual((scopedObj["currentProject"] as? [String: Any])?["name"] as? String, f.project.name)
            let scopedCards = try XCTUnwrap(scopedObj["items"] as? [[String: Any]])
            XCTAssertEqual(scopedCards.count, 2)
            XCTAssertTrue(scopedCards.allSatisfy { $0["foreignProject"] as? Bool == false })
            let account = try await call(f, "get_command_center", ["view": "list", "projectID": pid, "scope": "account", "fields": "lane"], access)
            let accountCards = try XCTUnwrap((account.json as? [String: Any])?["items"] as? [[String: Any]])
            XCTAssertEqual(accountCards.count, 3)
            XCTAssertEqual(accountCards.filter { $0["foreignProject"] as? Bool == true }.count, 1)
            let kanban = try await call(f, "get_command_center", ["projectID": pid, "scope": "account"], access)
            let lanes = try XCTUnwrap((kanban.json as? [String: Any])?["lanes"] as? [[String: Any]])
            let laneCards = lanes.flatMap { $0["cards"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(laneCards.count, 3)
            XCTAssertEqual(laneCards.filter { $0["foreignProject"] as? Bool == true }.count, 1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testCurrentProjectAddsNoPerEntryQueries() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let user = f.user
            func count(_ run: (any Database) async throws -> Void) async throws -> Int {
                let history = QueryHistory()
                let d = try XCTUnwrap(f.test.app.databases.database(logger: f.test.app.logger, on: f.test.app.eventLoopGroup.next(), history: history))
                try await run(d)
                return history.queries.count
            }
            func resolve(_ d: any Database) async throws {
                _ = try await MCPProjectContext.resolve(projectID: try f.project.requireID(), scope: "account", user: user, db: d, allowed: nil)
            }
            try await seed(f, project: f.project, title: "A")
            let small = try await count(resolve)
            for n in 0..<10 {
                let p = Project(ownerID: try user.requireID(), parentID: nil, name: "P\(n)")
                try await p.save(on: db)
                try await seed(f, project: p, title: "T\(n)")
            }
            let large = try await count(resolve)
            XCTAssertEqual(small, large, "context resolution does not grow with projects/entries")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
