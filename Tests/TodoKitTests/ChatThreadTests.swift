import Fluent
import XCTVapor
@testable import TodoKit

/// Chat per card: messages on a task, a question or a review (REST + MCP).
final class ChatThreadTests: XCTestCase {
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> (isError: Bool, text: String) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text)
    }
    private func list(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }
    private func question(_ taskID: UUID) -> TaskQuestion {
        let q = TaskQuestion()
        q.taskID = taskID; q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "Which?"; q.options = []
        q.blocking = false; q.state = "open"; q.version = 1
        return q
    }

    func testThreadsPerCardKindsAndFilters() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let owner = try f.user.requireID()
            let task = TodoTask(ownerID: owner, projectID: try f.project.requireID(), title: "Chat", details: "")
            try await task.save(on: db)
            let other = TodoTask(ownerID: owner, projectID: try f.project.requireID(), title: "Other", details: "")
            try await other.save(on: db)
            let tid = try task.requireID()
            let q = question(tid)
            try await q.save(on: db)
            let r = TaskReview()
            r.taskID = tid; r.state = "pending"; r.requestedByType = .integration; r.requestedByID = UUID(); r.summary = "Done"; r.version = 1
            try await r.save(on: db)
            let foreignQ = question(try other.requireID())
            try await foreignQ.save(on: db)
            let qid = try q.requireID().uuidString, rid = try r.requireID().uuidString
            let full = try await f.tokens(scope: MCPExtensionTests.allScopes)

            // A person writes through REST into the question chat; an agent answers through MCP.
            let person = try await f.test.json(.POST, "/v1/tasks/\(tid)/comments", ["body": "Why?", "questionID": qid], token: f.session)
            XCTAssertEqual(person.status, .created)
            XCTAssertEqual(person.body?["authorKind"] as? String, "person")
            XCTAssertEqual(person.body?["questionID"] as? String, qid)
            XCTAssertNotNil(person.body?["createdAt"])
            let reply = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "Because.", "questionID": qid, "agentName": "claude-code@chat"], access: full.access)
            XCTAssertFalse(reply.isError)
            _ = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "Review note", "reviewID": rid], access: full.access)
            _ = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "Task note"], access: full.access)

            let inQuestion = try list(try await call(f, "list_comments", ["taskID": tid.uuidString, "questionID": qid], access: full.access).text)
            XCTAssertEqual(inQuestion.compactMap { $0["body"] as? String }, ["Why?", "Because."])
            XCTAssertEqual(inQuestion.last?["authorKind"] as? String, "agent")
            XCTAssertEqual(inQuestion.last?["authorLabel"] as? String, "claude-code@chat")
            let inReview = try list(try await call(f, "list_comments", ["taskID": tid.uuidString, "reviewID": rid], access: full.access).text)
            XCTAssertEqual(inReview.count, 1)
            let taskOnly = try list(try await call(f, "list_comments", ["taskID": tid.uuidString, "thread": "task"], access: full.access).text)
            XCTAssertEqual(taskOnly.compactMap { $0["body"] as? String }, ["Task note"])
            let all = try list(try await call(f, "list_comments", ["taskID": tid.uuidString], access: full.access).text)
            XCTAssertEqual(all.count, 4)
            let people = try list(try await call(f, "list_comments", ["taskID": tid.uuidString, "authorKind": "person"], access: full.access).text)
            XCTAssertEqual(people.compactMap { $0["body"] as? String }, ["Why?"])
            let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            let none = try list(try await call(f, "list_comments", ["taskID": tid.uuidString, "since": future], access: full.access).text)
            XCTAssertTrue(none.isEmpty)
            let badKind = try await call(f, "list_comments", ["taskID": tid.uuidString, "authorKind": "robot"], access: full.access)
            XCTAssertTrue(badKind.isError)
            let rest = try await f.test.json(.GET, "/v1/tasks/\(tid)/comments?questionID=\(qid)", token: f.session)
            XCTAssertEqual(rest.list?.count, 2)
            let restTask = try await f.test.json(.GET, "/v1/tasks/\(tid)/comments?thread=task", token: f.session)
            XCTAssertEqual(restTask.list?.count, 1)

            // A question of another task, both targets at once, unknown ids and over-long input are rejected; nothing is stored.
            let foreign = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "x", "questionID": foreignQ.requireID().uuidString], access: full.access)
            XCTAssertTrue(foreign.isError)
            let both = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "x", "questionID": qid, "reviewID": rid], access: full.access)
            XCTAssertTrue(both.isError)
            let unknown = try await f.test.json(.POST, "/v1/tasks/\(tid)/comments", ["body": "x", "reviewID": UUID().uuidString], token: f.session)
            XCTAssertEqual(unknown.status, .notFound)
            let longName = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "x", "agentName": String(repeating: "a", count: 101)], access: full.access)
            XCTAssertTrue(longName.isError)
            let tooLong = try await f.test.json(.POST, "/v1/tasks/\(tid)/comments", ["body": String(repeating: "a", count: 10_001)], token: f.session)
            XCTAssertEqual(tooLong.status, .badRequest)
            let count = try await TaskComment.query(on: db).count()
            XCTAssertEqual(count, 4)

            // Read-only tokens still cannot write into a card chat.
            let readOnly = try await f.tokens(scope: "tasks:read")
            let denied = try await call(f, "add_comment", ["taskID": tid.uuidString, "body": "x", "questionID": qid], access: readOnly.access)
            XCTAssertEqual(denied.text, "insufficient_scope")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testToolDocumentationMentionsCardChat() throws {
        for name in ["list_comments", "add_comment"] {
            let tool = try XCTUnwrap(MCPController.tools.first { $0.name == name })
            XCTAssertTrue(tool.description.contains("questionID"), name)
            XCTAssertTrue(AgentManualContent.text.contains("`\(name)`"), name)
        }
        XCTAssertTrue(AgentManualContent.text.contains("reviewID"))
        XCTAssertEqual(AgentManual.version, "1.15.0")
    }
}
