import Fluent
import XCTVapor
@testable import TodoKit

final class MCPWaitForEventsTests: XCTestCase {
    private func text(_ body: [String: Any]?) throws -> String { try Self.textOf(body) }
    private static func textOf(_ body: [String: Any]?) throws -> String {
        let result = try XCTUnwrap(body?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
    private func isError(_ body: [String: Any]?) -> Bool { Self.isErr(body) }
    private static func isErr(_ body: [String: Any]?) -> Bool { ((body?["result"] as? [String: Any])?["isError"] as? Bool) == true }
    private func wait(_ f: OAuthFixture, _ access: String, since: String?, timeout: Int? = nil) async throws -> (error: Bool, json: [String: Any]) {
        try await Self.waitCall(f, access, since: since, timeout: timeout)
    }
    private static func waitCall(_ f: OAuthFixture, _ access: String, since: String?, timeout: Int? = nil) async throws -> (error: Bool, json: [String: Any]) {
        var args: [String: Any] = [:]
        if let since { args["since"] = since }
        if let timeout { args["timeoutSeconds"] = timeout }
        let r = try await f.rpc("tools/call", ["name": "wait_for_events", "arguments": args], access: access)
        let raw = try Self.textOf(r.body)
        let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? ["raw": raw]
        return (isErr(r.body), json)
    }

    func testDefinitionAndFirstCallReturnsTokenWithoutWaiting() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let tool = try XCTUnwrap(MCPController.tools.first { $0.name == "wait_for_events" })
            XCTAssertEqual(tool.scope, "tasks:read")
            let started = Date()
            let first = try await wait(f, tokens.access, since: nil)
            XCTAssertFalse(first.error)
            XCTAssertEqual(first.json["changed"] as? Bool, false)
            XCTAssertTrue((first.json["token"] as? String)?.hasPrefix("l") == true)
            XCTAssertEqual((first.json["hints"] as? [Any])?.count, 0)
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            for bad in [0, 26] {
                let r = try await wait(f, tokens.access, since: nil, timeout: bad)
                XCTAssertTrue(r.error, "timeout \(bad)")
            }
            let readOnly = try await f.tokens(scope: "projects:read")
            let denied = try await f.rpc("tools/call", ["name": "wait_for_events", "arguments": [:]], access: readOnly.access)
            XCTAssertTrue(isError(denied.body))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testTimesOutUnchangedAndWakesOnQuestionWithHint() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Wait", details: "")
            try await task.save(on: f.test.app.db)
            let taskID = try task.requireID().uuidString
            let first = try await wait(f, tokens.access, since: nil)
            let token = try XCTUnwrap(first.json["token"] as? String)

            let idle = try await wait(f, tokens.access, since: token, timeout: 1)
            XCTAssertEqual(idle.json["changed"] as? Bool, false)
            XCTAssertEqual(idle.json["token"] as? String, token)

            async let pending = Self.waitCall(f, tokens.access, since: token, timeout: 20)
            for _ in 0..<500 {
                if await f.test.app.liveHub.waiterCount >= 1 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let asked = try await f.rpc("tools/call", ["name": "ask_question", "arguments": ["taskID": taskID, "prompt": "Which one?"]], access: tokens.access)
            XCTAssertFalse(isError(asked.body))
            let woken = try await pending
            XCTAssertFalse(woken.error)
            XCTAssertEqual(woken.json["changed"] as? Bool, true)
            let newToken = try XCTUnwrap(woken.json["token"] as? String)
            XCTAssertNotEqual(newToken, token)
            let hints = try XCTUnwrap(woken.json["hints"] as? [[String: Any]])
            XCTAssertTrue(hints.contains { $0["kind"] as? String == "question" && $0["taskID"] as? String == taskID
                && $0["projectID"] as? String == (try? f.project.requireID().uuidString) })
            // Hints carry no content.
            let again = try await f.rpc("tools/call", ["name": "wait_for_events", "arguments": ["since": token]], access: tokens.access)
            XCTAssertFalse(try text(again.body).contains("Which one?"))

            // A stale token answers immediately with changed=true.
            let stale = try await wait(f, tokens.access, since: token, timeout: 25)
            XCTAssertEqual(stale.json["changed"] as? Bool, true)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testHintsAreLimitedToGrantProjectsAndCurrentRights() async throws {
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            let owner = try f.user.requireID()
            let granted = TodoTask(ownerID: owner, projectID: try f.project.requireID(), title: "In", details: "")
            let excluded = TodoTask(ownerID: owner, projectID: try f.other.requireID(), title: "Out", details: "")
            try await granted.save(on: f.test.app.db); try await excluded.save(on: f.test.app.db)
            let first = try await wait(f, tokens.access, since: nil)
            let token = try XCTUnwrap(first.json["token"] as? String)
            try await TaskComment(taskID: excluded.requireID(), authorID: owner, body: "secret outside the grant").save(on: f.test.app.db)
            try await TaskComment(taskID: granted.requireID(), authorID: owner, body: "inside").save(on: f.test.app.db)

            let r = try await wait(f, tokens.access, since: token, timeout: 1)
            XCTAssertEqual(r.json["changed"] as? Bool, true)
            let hints = try XCTUnwrap(r.json["hints"] as? [[String: Any]])
            XCTAssertEqual(hints.count, 1)
            XCTAssertEqual(hints.first?["taskID"] as? String, try granted.requireID().uuidString)
            XCTAssertEqual(hints.first?["kind"] as? String, "comment")
            let again = try await f.rpc("tools/call", ["name": "wait_for_events", "arguments": ["since": token]], access: tokens.access)
            XCTAssertFalse(try text(again.body).contains("secret"))

            // The account loses the project: still changed/token, but no hint for it.
            let stranger = User(displayName: "New Owner", isAdmin: false); try await stranger.save(on: f.test.app.db)
            f.project.ownerID = try stranger.requireID(); try await f.project.save(on: f.test.app.db)
            let lost = try await wait(f, tokens.access, since: token, timeout: 1)
            XCTAssertEqual(lost.json["changed"] as? Bool, true)
            XCTAssertEqual((lost.json["hints"] as? [Any])?.count, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
