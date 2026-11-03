import Fluent
import XCTVapor
@testable import TodoKit

/// Compact default answers of get_command_center and list_open_questions (docs/MCP-PARITAET.md, "Kompakte Antworten").
final class MCPCompactTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private func fixture(_ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: "projects:read tasks:read tasks:write"); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private let longText = String(repeating: "Long progress text with many details. ", count: 40)

    /// Six tasks with two subtasks each, a long note, two open and one answered question per task, in the granted project.
    private func populate(_ f: OAuthFixture, project: Project) async throws {
        let db = f.test.app.db
        let owner = try f.user.requireID(), pid = try project.requireID()
        for n in 0..<6 {
            let parent = TodoTask(ownerID: owner, projectID: pid, title: "Feature \(n)")
            try await parent.save(on: db)
            let parentID = try parent.requireID()
            let wf = TaskWorkflow(taskID: parentID); wf.kind = "feature"; try await wf.save(on: db)
            for k in 0..<2 {
                let child = TodoTask(ownerID: owner, projectID: pid, title: "Subtask \(n).\(k)")
                try await child.save(on: db)
                let cw = TaskWorkflow(taskID: try child.requireID()); cw.parentTaskID = parentID; try await cw.save(on: db)
            }
            let note = TaskProgressNote()
            note.taskID = parentID; note.actorType = .integration; note.actorID = UUID(); note.actorLabel = "agent"; note.note = longText
            try await note.save(on: db)
            for (i, state) in ["open", "open", "answered"].enumerated() {
                let q = TaskQuestion()
                q.taskID = parentID; q.askedByType = .integration; q.askedByID = UUID(); q.askedByLabel = "agent"
                q.prompt = "Question \(i) of \(n): " + longText.prefix(300); q.options = ["yes", "no"]; q.blocking = true
                q.state = state; q.version = 1
                if state == "answered" { q.answer = "yes"; q.answeredBy = owner; q.answeredVia = "rest"; q.answeredAt = Date() }
                try await q.save(on: db)
            }
        }
    }

    func testOpenQuestionsDefaultsToOpenAndCompactAndRespectsFilters() async throws {
        try await fixture { f, access in
            try await populate(f, project: f.project)
            let other = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Other")
            try await other.save(on: f.test.app.db)
            let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: f.test.app.db).first())
            g.projects.append(try other.requireID()); try await g.save(on: f.test.app.db)
            try await populate(f, project: other)

            let def = try await call(f, "list_open_questions", [:], access)
            let rows = try XCTUnwrap(def.json as? [[String: Any]], def.text)
            XCTAssertEqual(rows.count, 24)
            XCTAssertTrue(rows.allSatisfy { $0["state"] as? String == "open" })
            XCTAssertNil(rows[0]["version"]); XCTAssertNil(rows[0]["askedByID"]); XCTAssertNil(rows[0]["answeredVia"])
            XCTAssertNotNil(rows[0]["id"]); XCTAssertNotNil(rows[0]["taskID"]); XCTAssertNotNil(rows[0]["prompt"]); XCTAssertNotNil(rows[0]["projectName"])

            let scoped = try await call(f, "list_open_questions", ["projectID": try f.project.requireID().uuidString], access)
            let scopedRows = try XCTUnwrap(scoped.json as? [[String: Any]])
            XCTAssertEqual(scopedRows.count, 12)
            XCTAssertTrue(scopedRows.allSatisfy { $0["projectID"] as? String == f.project.id?.uuidString })

            let all = try await call(f, "list_open_questions", ["includeAnswered": true], access)
            XCTAssertEqual((all.json as? [[String: Any]])?.count, 36)
            let answered = try await call(f, "list_open_questions", ["status": "answered"], access)
            let answeredRows = try XCTUnwrap(answered.json as? [[String: Any]])
            XCTAssertEqual(answeredRows.count, 12)
            XCTAssertTrue(answeredRows.allSatisfy { $0["answer"] as? String == "yes" })

            let limited = try await call(f, "list_open_questions", ["limit": 3, "fields": "id,prompt"], access)
            let limitedRows = try XCTUnwrap(limited.json as? [[String: Any]])
            XCTAssertEqual(limitedRows.count, 3)
            XCTAssertEqual(Set(limitedRows[0].keys), ["id", "prompt"])

            let full = try await call(f, "list_open_questions", ["compact": false], access)
            XCTAssertNotNil((full.json as? [[String: Any]])?.first?["version"])
            XCTAssertLessThan(def.text.utf8.count, full.text.utf8.count)

            let bad = try await call(f, "list_open_questions", ["status": "weird"], access)
            XCTAssertTrue(bad.isError)
        }
    }

    func testCommandCenterDefaultIsCompactAndSmallerThanFull() async throws {
        try await fixture { f, access in
            try await populate(f, project: f.project)
            let compact = try await call(f, "get_command_center", [:], access)
            let full = try await call(f, "get_command_center", ["compact": false, "updatesLimit": 20], access)
            print("MEASURE get_command_center default=\(compact.text.utf8.count) full=\(full.text.utf8.count) bytes")
            XCTAssertLessThan(compact.text.utf8.count * 10, full.text.utf8.count * 6)

            let json = try XCTUnwrap(compact.json as? [String: Any], compact.text)
            XCTAssertEqual(json["compact"] as? Bool, true)
            XCTAssertNotNil(json["summary"]); XCTAssertNotNil(json["lanes"])
            let cards = ((json["lanes"] as? [[String: Any]]) ?? []).flatMap { ($0["cards"] as? [[String: Any]]) ?? [] }
            XCTAssertFalse(cards.isEmpty)
            for card in cards {
                XCTAssertEqual((card["subtasks"] as? [Any])?.count, 0, "no subtask detail by default")
                XCTAssertEqual(card["subtaskCount"] as? Int, 2)
                XCTAssertEqual((card["builds"] as? [Any])?.count, 0)
                XCTAssertNotNil(card["buildCount"])
                let text = (card["latestUpdate"] as? [String: Any])?["text"] as? String
                XCTAssertLessThanOrEqual(text?.count ?? 0, 201)
                XCTAssertLessThanOrEqual((card["questions"] as? [[String: Any]])?.count ?? 0, 3)
            }
            XCTAssertEqual((json["builds"] as? [Any])?.count, 0)
            XCTAssertLessThanOrEqual((json["updates"] as? [Any])?.count ?? 0, 5)

            // Full keeps the old shape with subtask detail.
            let fullCards = (((full.json as? [String: Any])?["lanes"] as? [[String: Any]]) ?? []).flatMap { ($0["cards"] as? [[String: Any]]) ?? [] }
            XCTAssertEqual((fullCards.first?["subtasks"] as? [Any])?.count, 2)
            XCTAssertNil((full.json as? [String: Any])?["compact"])
        }
    }

    func testCommandCenterFieldsLaneAndLimit() async throws {
        try await fixture { f, access in
            try await populate(f, project: f.project)
            let c = try await call(f, "get_command_center", ["view": "list", "lane": "question", "limit": 2, "fields": "lane,openQuestionCount"], access)
            let json = try XCTUnwrap(c.json as? [String: Any], c.text)
            let items = try XCTUnwrap(json["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(Set(items[0].keys), ["task", "lane", "openQuestionCount"])
            XCTAssertEqual(json["total"] as? Int, 6)
            let none = try await call(f, "get_command_center", ["updatesLimit": 0], access)
            XCTAssertEqual(((none.json as? [String: Any])?["updates"] as? [Any])?.count, 0)
            let bad = try await call(f, "get_command_center", ["fields": "nope"], access)
            XCTAssertTrue(bad.isError)
        }
    }
}
