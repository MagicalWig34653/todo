import Fluent
import XCTVapor
@testable import TodoKit

final class MCPTests: XCTestCase {
    func testProtocolAndTaskLifecycle() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let initResult = try await f.rpc("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Test", "version": "1"]], access: tokens.access)
            XCTAssertEqual((initResult.body?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
            let listed = try await f.rpc("tools/list", access: tokens.access)
            let tools = (listed.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            XCTAssertEqual(Set(tools?.compactMap { $0["name"] as? String } ?? []), Set(["list_projects", "list_tasks", "get_task", "create_task", "update_task", "list_comments", "list_columns", "move_task_to_column", "create_column", "rename_column", "delete_column"]))
            let created = try await f.rpc("tools/call", ["name": "create_task", "arguments": ["projectID": try f.project.requireID().uuidString, "title": "  MCP Task  "]], access: tokens.access)
            let t = try decodedTool(created.body)
            XCTAssertEqual(t["title"] as? String, "MCP Task")
            let id = try XCTUnwrap(t["id"] as? String)
            let updated = try await f.rpc("tools/call", ["name": "update_task", "arguments": ["id": id, "version": 1, "status": "in_progress"]], access: tokens.access)
            XCTAssertEqual(try decodedTool(updated.body)["version"] as? Int, 2)
            let stale = try await f.rpc("tools/call", ["name": "update_task", "arguments": ["id": id, "version": 1, "title": "Stale"]], access: tokens.access)
            XCTAssertEqual((stale.body?["result"] as? [String: Any])?["isError"] as? Bool, true)
            let read = try await f.rpc("tools/call", ["name": "get_task", "arguments": ["id": id]], access: tokens.access)
            XCTAssertEqual(try decodedTool(read.body)["status"] as? String, "in_progress")
            let notification = try await f.test.json(.POST, "/mcp", ["jsonrpc": "2.0", "method": "notifications/initialized"], token: tokens.access)
            XCTAssertEqual(notification.status, .accepted)
            let invalid = try await f.rpc("unknown", access: tokens.access)
            XCTAssertEqual((invalid.body?["error"] as? [String: Any])?["code"] as? Int, -32601)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testScopeProjectAndLiveUserRightsIntersection() async throws {
        let f = try await OAuthFixture.make()
        do {
            let readOnly = try await f.tokens(scope: "tasks:read")
            let write = try await f.rpc("tools/call", ["name": "create_task", "arguments": ["projectID": try f.project.requireID().uuidString, "title": "Denied"]], access: readOnly.access)
            XCTAssertEqual((write.body?["result"] as? [String: Any])?["isError"] as? Bool, true)
            let full = try await f.tokens()
            let foreignTask = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Excluded", details: "")
            try await foreignTask.save(on: f.test.app.db)
            for args in [["id": try foreignTask.requireID().uuidString], ["id": UUID().uuidString]] {
                let r = try await f.rpc("tools/call", ["name": "get_task", "arguments": args], access: full.access)
                XCTAssertEqual(try toolText(r.body), "not_found")
            }
            let t = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Allowed", details: "")
            try await t.save(on: f.test.app.db)
            let move = try await f.rpc("tools/call", ["name": "update_task", "arguments": ["id": try t.requireID().uuidString, "version": 1, "projectID": try f.other.requireID().uuidString]], access: full.access)
            XCTAssertEqual(try toolText(move.body), "not_found")
            let stranger = User(displayName: "New Owner", isAdmin: false); try await stranger.save(on: f.test.app.db)
            f.project.ownerID = try stranger.requireID(); try await f.project.save(on: f.test.app.db)
            let lost = try await f.rpc("tools/call", ["name": "get_task", "arguments": ["id": try t.requireID().uuidString]], access: full.access)
            XCTAssertEqual(try toolText(lost.body), "not_found")
            let listed = try await f.rpc("tools/call", ["name": "list_projects", "arguments": [:]], access: full.access)
            XCTAssertEqual(try toolText(listed.body), "[]")
            let sessionRejected = try await f.rpc("tools/list", access: f.session)
            XCTAssertEqual(sessionRejected.status, .unauthorized)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func toolText(_ body: [String: Any]?) throws -> String {
        let result = try XCTUnwrap(body?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
    private func decodedTool(_ body: [String: Any]?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(toolText(body).utf8)) as? [String: Any])
    }
}
