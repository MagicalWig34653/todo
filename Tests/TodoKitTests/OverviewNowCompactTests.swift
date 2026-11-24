import Fluent
import XCTVapor
@testable import TodoKit

/// Compact answer of the overview (contract session-status 1.4.0): `GET /v1/overview/now?compact=true&limit=N`
/// and MCP `get_overview_now {compact, limit}`.
final class OverviewNowCompactTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private func obj(_ c: Called) -> [String: Any] { (c.json as? [String: Any]) ?? [:] }
    private func fixture(_ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: "projects:read tasks:read tasks:write"); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func list(_ block: [String: Any], _ key: String) -> [[String: Any]] { (block[key] as? [[String: Any]]) ?? [] }
    private func addDone(_ f: OAuthFixture, _ count: Int, title: String = "Done") async throws {
        for i in 0..<count {
            let t = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "\(title) \(i)"); t.status = "done"
            try await t.save(on: f.test.app.db)
        }
    }

    func testCompactRestHasOnlyServerTimeAndNowWithDefaultLimit10() async throws {
        try await fixture { f, _ in
            try await addDone(f, 12)
            let r = try await f.test.json(.GET, "/v1/overview/now?compact=true", token: f.session)
            XCTAssertEqual(r.status, .ok)
            let body = try XCTUnwrap(r.body)
            XCTAssertEqual(Set(body.keys), ["serverTime", "now"], "projects is absent")
            let now = try XCTUnwrap(body["now"] as? [String: Any])
            XCTAssertEqual(list(now, "recentlyDone").count, 10, "default limit")
            XCTAssertEqual((now["counts"] as? [String: Int])?["recentlyDone"], 12, "counts are totals before the cut")
            for key in ["running", "waiting", "silent"] { XCTAssertNotNil(now[key] as? [Any], key) }
            let limited = try await f.test.json(.GET, "/v1/overview/now?compact=true&limit=3", token: f.session)
            XCTAssertEqual(list(try XCTUnwrap(limited.body?["now"] as? [String: Any]), "recentlyDone").count, 3)
            let max = try await f.test.json(.GET, "/v1/overview/now?compact=true&limit=50", token: f.session)
            XCTAssertEqual(max.status, .ok)
            // Without compact the answer keeps its old shape, plus now.
            let full = try await f.test.json(.GET, "/v1/overview/now?compact=false", token: f.session)
            XCTAssertNotNil(full.body?["projects"]); XCTAssertNotNil(full.body?["now"])
            let plain = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            XCTAssertNotNil(plain.body?["projects"]); XCTAssertEqual(list(try XCTUnwrap(plain.body?["now"] as? [String: Any]), "recentlyDone").count, 12)
        }
    }

    func testInvalidLimitIs400() async throws {
        try await fixture { f, access in
            for bad in ["0", "51", "-1", "abc", "2.5", ""] {
                let r = try await f.test.json(.GET, "/v1/overview/now?compact=true&limit=\(bad)", token: f.session)
                XCTAssertEqual(r.status, .badRequest, "limit=\(bad)")
                XCTAssertEqual(r.body?["reason"] as? String, "invalid_limit", "limit=\(bad)")
            }
            for bad: Any in [0, 51, 2.5, "x"] {
                let c = try await call(f, "get_overview_now", ["compact": true, "limit": bad], access)
                XCTAssertTrue(c.isError, "limit=\(bad)"); XCTAssertTrue(c.text.contains("invalid_limit"), c.text)
            }
        }
    }

    func testCompactShortensEveryTextTo140CharactersWithEllipsis() async throws {
        try await fixture { f, access in
            let db = f.test.app.db, uid = try f.user.requireID(), pid = try f.project.requireID()
            let long = String(repeating: "abcdefghij ", count: 40)
            let t = TodoTask(ownerID: uid, projectID: pid, title: String(repeating: "T", count: 300)); t.status = "in_progress"; try await t.save(on: db)
            let wf = TaskWorkflow(taskID: try t.requireID()); wf.claimedByType = "integration"; wf.claimedByID = UUID(); wf.claimedLabel = "A"; wf.claimedAt = Date()
            try await wf.save(on: db)
            let n = TaskProgressNote(); n.taskID = try t.requireID(); n.actorType = .integration; n.actorID = UUID(); n.note = long; try await n.save(on: db)
            let q = TaskQuestion(); q.taskID = try t.requireID(); q.askedByType = .integration; q.askedByID = UUID(); q.prompt = long; q.options = []; q.blocking = true; q.state = "open"; q.version = 1
            try await q.save(on: db)
            let short = TodoTask(ownerID: uid, projectID: pid, title: "Kurz"); short.status = "done"; try await short.save(on: db)
            let compact = try await f.test.json(.GET, "/v1/overview/now?compact=true", token: f.session)
            let now = try XCTUnwrap(compact.body?["now"] as? [String: Any])
            let active = try XCTUnwrap(list(now, "running").first)
            XCTAssertEqual((active["text"] as? String)?.count, 140); XCTAssertTrue((active["text"] as? String)?.hasSuffix("…") ?? false)
            XCTAssertEqual((active["title"] as? String)?.count, 140)
            let waiting = try XCTUnwrap(list(now, "waiting").first)
            XCTAssertEqual((waiting["text"] as? String)?.count, 140); XCTAssertEqual((waiting["taskTitle"] as? String)?.count, 140)
            XCTAssertEqual(list(now, "recentlyDone").first?["title"] as? String, "Kurz", "short texts stay as they are")
            // The full answer keeps up to 200 characters.
            let full = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            let fullActive = try XCTUnwrap(list(try XCTUnwrap(full.body?["now"] as? [String: Any]), "running").first)
            XCTAssertEqual((fullActive["text"] as? String)?.count, 200)
            XCTAssertEqual((fullActive["title"] as? String)?.count, 300)
            // MCP compact is the same answer, and clearly smaller than the full one.
            let mcp = try await call(f, "get_overview_now", ["compact": true, "limit": 5], access)
            XCTAssertFalse(mcp.isError, mcp.text)
            XCTAssertEqual(Set(obj(mcp).keys), ["serverTime", "now"])
            let mcpFull = try await call(f, "get_overview_now", [:], access)
            XCTAssertNotNil(obj(mcpFull)["projects"]); XCTAssertNotNil(obj(mcpFull)["now"])
            XCTAssertLessThan(mcp.text.utf8.count, mcpFull.text.utf8.count)
        }
    }

    func testMcpCompactRespectsLimitAndGrant() async throws {
        try await fixture { f, access in
            try await addDone(f, 8)
            let hidden = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Outside grant"); hidden.status = "done"
            try await hidden.save(on: f.test.app.db)
            let c = try await call(f, "get_overview_now", ["compact": true, "limit": 4], access)
            let now = try XCTUnwrap(obj(c)["now"] as? [String: Any])
            XCTAssertEqual(list(now, "recentlyDone").count, 4)
            XCTAssertEqual((now["counts"] as? [String: Int])?["recentlyDone"], 8, "the project outside the grant is not counted")
            let d = try await call(f, "get_overview_now", ["compact": true], access)
            XCTAssertEqual(list(try XCTUnwrap(obj(d)["now"] as? [String: Any]), "recentlyDone").count, 8)
            let off = try await call(f, "get_overview_now", ["compact": false], access)
            XCTAssertNotNil(obj(off)["projects"])
        }
    }

    func testToolSchemaAndDescriptionNameCompactAndNow() throws {
        let tool = try XCTUnwrap(MCPController.tools.first { $0.name == "get_overview_now" })
        XCTAssertEqual(tool.scope, "tasks:read")
        let properties = tool.properties
        XCTAssertNotNil(properties["compact"]); XCTAssertNotNil(properties["limit"])
        XCTAssertEqual(properties["compact"]?["type"].string, "boolean")
        XCTAssertEqual(properties["limit"]?["type"].string, "integer")
        guard case .number(let minimum) = properties["limit"]?["minimum"] ?? .null, case .number(let maximum) = properties["limit"]?["maximum"] ?? .null else {
            return XCTFail("limit needs minimum and maximum")
        }
        XCTAssertEqual(minimum, 1); XCTAssertEqual(maximum, 50)
        XCTAssertTrue(tool.description.contains("compact=true"), "recommend compact for agents")
        let nowAt = try XCTUnwrap(tool.description.range(of: "{serverTime, now:")?.lowerBound, "the answer shape names now")
        let projectsAt = try XCTUnwrap(tool.description.range(of: "projects:[")?.lowerBound)
        XCTAssertLessThan(nowAt, projectsAt, "the description names now first")
    }
}
