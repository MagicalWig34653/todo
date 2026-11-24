import Fluent
import XCTVapor
@testable import TodoKit

/// Ending a session status (contract session-status 1.4.0): `ended: true` deletes the row.
final class SessionStatusEndedTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private func obj(_ c: Called) -> [String: Any] { (c.json as? [String: Any]) ?? [:] }
    private func fixture(_ scope: String = "projects:read tasks:read tasks:write", _ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: scope); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func path(_ project: Project) throws -> String { "/v1/projects/\(try project.requireID().uuidString)/session-status" }
    private func put(_ f: OAuthFixture, _ body: [String: Any], project: Project? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.test.json(.PUT, try path(project ?? f.project), body, token: f.session)
        return (r.status, r.body)
    }
    private func count(_ f: OAuthFixture, name: String? = nil) async throws -> Int {
        var q = SessionStatus.query(on: f.test.app.db)
        if let name { q = q.filter(\.$sessionName == name) }
        return try await q.count()
    }

    func testRestEndDeletesTheRowAndAnswersWithEndedTrue() async throws {
        try await fixture { f, _ in
            let first = try await put(f, ["sessionName": "Mac", "activity": "Baue"])
            XCTAssertEqual(first.status, .ok)
            XCTAssertNil(first.body?["ended"], "a normal report carries no ended field")
            let ended = try await put(f, ["sessionName": "Mac", "ended": true])
            XCTAssertEqual(ended.status, .ok, String(describing: ended.body))
            XCTAssertEqual(ended.body?["ended"] as? Bool, true)
            XCTAssertEqual(ended.body?["activity"] as? String, "")
            XCTAssertEqual(ended.body?["sessionName"] as? String, "Mac")
            XCTAssertEqual(ended.body?["projectID"] as? String, try f.project.requireID().uuidString)
            XCTAssertNotNil(ended.body?["updatedAt"])
            let gone = try await count(f)
            XCTAssertEqual(gone, 0)
            // Idempotent: again, and for a name that never existed.
            let again = try await put(f, ["sessionName": "Mac", "ended": true])
            XCTAssertEqual(again.status, .ok); XCTAssertEqual(again.body?["ended"] as? Bool, true)
            let unknown = try await put(f, ["sessionName": "never-existed", "ended": true])
            XCTAssertEqual(unknown.status, .ok)
            // An activity next to ended=true is ignored.
            _ = try await put(f, ["sessionName": "Mac", "activity": "wieder"])
            let both = try await put(f, ["sessionName": "Mac", "activity": "ignoriert", "ended": true])
            XCTAssertEqual(both.body?["activity"] as? String, "")
            let none = try await count(f)
            XCTAssertEqual(none, 0)
        }
    }

    func testEndingHasNoRateLimitAndLeavesRoomToReportAgain() async throws {
        try await fixture { f, _ in
            let a = try await put(f, ["sessionName": "Mac", "activity": "x"]); XCTAssertEqual(a.status, .ok)
            let b = try await put(f, ["sessionName": "Mac", "ended": true]); XCTAssertEqual(b.status, .ok, "no 10 s limit when ending")
            let c = try await put(f, ["sessionName": "Mac", "activity": "neu"]); XCTAssertEqual(c.status, .ok, "the row is gone, so no limit applies")
            let d = try await put(f, ["sessionName": "Mac", "activity": "zu schnell"]); XCTAssertEqual(d.status, .tooManyRequests)
        }
    }

    func testActivityStaysRequiredWithoutEnded() async throws {
        try await fixture { f, access in
            for body in [["sessionName": "Mac"], ["sessionName": "Mac", "ended": false], ["sessionName": "Mac", "activity": "  "]] as [[String: Any]] {
                let r = try await put(f, body)
                XCTAssertEqual(r.status, .badRequest, String(describing: body))
                XCTAssertEqual(r.body?["reason"] as? String, "invalid_activity", String(describing: body))
            }
            let badName = try await put(f, ["sessionName": String(repeating: "n", count: 101), "ended": true])
            XCTAssertEqual(badName.status, .badRequest); XCTAssertEqual(badName.body?["reason"] as? String, "invalid_session")
            let emptyName = try await put(f, ["sessionName": " ", "ended": true])
            XCTAssertEqual(emptyName.status, .badRequest)
            let mcp = try await call(f, "report_session_status", ["projectID": try f.project.requireID().uuidString, "sessionName": "Mac"], access)
            XCTAssertTrue(mcp.isError); XCTAssertTrue(mcp.text.contains("invalid_activity"), mcp.text)
        }
    }

    func testMcpEndWithoutActivity() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            let made = try await call(f, "report_session_status", ["projectID": pid, "sessionName": "Mac", "activity": "Baue"], access)
            XCTAssertFalse(made.isError, made.text)
            let ended = try await call(f, "report_session_status", ["projectID": pid, "sessionName": "Mac", "ended": true], access)
            XCTAssertFalse(ended.isError, ended.text)
            XCTAssertEqual(obj(ended)["ended"] as? Bool, true); XCTAssertEqual(obj(ended)["activity"] as? String, "")
            let gone = try await count(f)
            XCTAssertEqual(gone, 0)
            let again = try await call(f, "report_session_status", ["projectID": pid, "sessionName": "Mac", "ended": true], access)
            XCTAssertFalse(again.isError, "idempotent")
            let tool = try XCTUnwrap(MCPController.tools.first { $0.name == "report_session_status" })
            XCTAssertNotNil(tool.properties["ended"]); XCTAssertEqual(tool.properties["ended"]?["type"].string, "boolean")
            XCTAssertEqual(Set(tool.required), ["projectID", "sessionName"], "activity is optional with ended")
            XCTAssertTrue(tool.description.contains("ended"))
            let bad = try await call(f, "report_session_status", ["projectID": pid, "sessionName": "Mac", "ended": "yes"], access)
            XCTAssertTrue(bad.isError)
        }
    }

    func testEndedSessionDisappearsFromOverviewAndBlockNow() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            for name in ["keep", "close"] {
                let c = try await call(f, "report_session_status", ["projectID": pid, "sessionName": name, "activity": "arbeitet"], access)
                XCTAssertFalse(c.isError, c.text)
            }
            _ = try await call(f, "report_session_status", ["projectID": pid, "sessionName": "close", "ended": true], access)
            let r = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            let now = try XCTUnwrap(r.body?["now"] as? [String: Any])
            XCTAssertEqual((now["running"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["keep"])
            let sessions = ((r.body?["projects"] as? [[String: Any]])?.first?["sessions"] as? [[String: Any]])?.compactMap { $0["sessionName"] as? String }
            XCTAssertEqual(sessions, ["keep"])
        }
    }

    func testRightsAreTheSameAsForReporting() async throws {
        try await fixture { f, access in
            let db = f.test.app.db, me = try f.user.requireID()
            let stranger = User(displayName: "S", isAdmin: false); try await stranger.save(on: db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Foreign"); try await foreign.save(on: db)
            let shared = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Shared"); try await shared.save(on: db)
            try await ProjectGrant(projectID: try shared.requireID(), principalType: "person", principalID: me, role: .read).save(on: db)
            // A row of mine in the project that is only readable stays untouched by a rejected end.
            try await SessionStatus(userID: me, projectID: try shared.requireID(), sessionName: "x", activity: "y", updatedAt: Date()).save(on: db)
            let readOnly = try await put(f, ["sessionName": "x", "ended": true], project: shared)
            XCTAssertEqual(readOnly.status, .forbidden)
            let unseen = try await put(f, ["sessionName": "x", "ended": true], project: foreign)
            XCTAssertEqual(unseen.status, .notFound)
            let anonymous = try await f.test.json(.PUT, try path(f.project), ["sessionName": "x", "ended": true])
            XCTAssertEqual(anonymous.status, .unauthorized)
            let kept = try await count(f)
            XCTAssertEqual(kept, 1, "rejected requests delete nothing")
            // MCP: project outside the grant and missing scope.
            try await SessionStatus(userID: me, projectID: try f.other.requireID(), sessionName: "o", activity: "y", updatedAt: Date()).save(on: db)
            let outside = try await call(f, "report_session_status", ["projectID": try f.other.requireID().uuidString, "sessionName": "o", "ended": true], access)
            XCTAssertTrue(outside.isError)
            let readScope = try await f.tokens(scope: "projects:read tasks:read")
            let noScope = try await call(f, "report_session_status", ["projectID": try f.project.requireID().uuidString, "sessionName": "o", "ended": true], readScope.access)
            XCTAssertTrue(noScope.isError)
            let stillThere = try await count(f)
            XCTAssertEqual(stillThere, 2)
        }
    }

    func testEndingOnlyRemovesTheCallersOwnRow() async throws {
        try await fixture { f, _ in
            let db = f.test.app.db, pid = try f.project.requireID()
            let colleague = User(displayName: "C", isAdmin: false); try await colleague.save(on: db)
            try await ProjectGrant(projectID: pid, principalType: "person", principalID: try colleague.requireID(), role: .edit).save(on: db)
            try await SessionStatus(userID: try colleague.requireID(), projectID: pid, sessionName: "Mac", activity: "fremd", updatedAt: Date()).save(on: db)
            _ = try await put(f, ["sessionName": "Mac", "activity": "mein"])
            _ = try await put(f, ["sessionName": "Mac", "ended": true])
            let rows = try await SessionStatus.query(on: db).all()
            XCTAssertEqual(rows.map(\.activity), ["fremd"])
        }
    }

    func testEndingMakesRoomAgainstTooManySessions() async throws {
        try await fixture { f, _ in
            let db = f.test.app.db, me = try f.user.requireID(), pid = try f.project.requireID()
            for i in 0..<SessionStatusService.maxSessionsPerProject {
                try await SessionStatus(userID: me, projectID: pid, sessionName: "s\(i)", activity: "x", updatedAt: Date().addingTimeInterval(-60)).save(on: db)
            }
            let full = try await put(f, ["sessionName": "one-too-many", "activity": "x"])
            XCTAssertEqual(full.status, .tooManyRequests); XCTAssertEqual(full.body?["reason"] as? String, "too_many_sessions")
            let ended = try await put(f, ["sessionName": "s7", "ended": true]); XCTAssertEqual(ended.status, .ok)
            let fits = try await put(f, ["sessionName": "one-too-many", "activity": "x"])
            XCTAssertEqual(fits.status, .ok, String(describing: fits.body))
            let all = try await count(f)
            XCTAssertEqual(all, SessionStatusService.maxSessionsPerProject)
        }
    }

    func testEndingChangesTheLiveTokenOnlyWhenARowWasDeleted() async throws {
        try await fixture { f, _ in
            _ = try await put(f, ["sessionName": "Mac", "activity": "x"])
            let before = try await LiveToken.current(on: f.test.app.db).token
            _ = try await put(f, ["sessionName": "Mac", "ended": true])
            let after = try await LiveToken.current(on: f.test.app.db).token
            XCTAssertNotEqual(before, after, "ending is a change people see right away")
            _ = try await put(f, ["sessionName": "Mac", "ended": true])
            let unchanged = try await LiveToken.current(on: f.test.app.db).token
            XCTAssertEqual(after, unchanged, "nothing deleted, nothing to announce")
        }
    }
}
