import Fluent
import XCTVapor
@testable import TodoKit

/// Light session status without a claimed card (ADR 0034): heartbeat, overview "now", rights, rate limit, live hint.
final class SessionStatusTests: XCTestCase {
    private let secret = "ghp_1234567890abcdefghijklmnopqrstuvwxyzAB"

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
    private func report(_ f: OAuthFixture, _ access: String, project: Project? = nil, session: String = "Mac Studio", _ activity: String = "Baue Tests") async throws -> Called {
        try await call(f, "report_session_status", ["projectID": try (project ?? f.project).requireID().uuidString, "sessionName": session, "activity": activity], access)
    }
    private func backdate(_ f: OAuthFixture, seconds: TimeInterval, name: String? = nil) async throws {
        for row in try await SessionStatus.query(on: f.test.app.db).all() where name == nil || row.sessionName == name {
            row.updatedAt = row.updatedAt.addingTimeInterval(-seconds); try await row.save(on: f.test.app.db)
        }
    }
    private func now(_ f: OAuthFixture) async throws -> [String: Any] {
        let r = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
        XCTAssertEqual(r.status, .ok)
        return r.body ?? [:]
    }
    private func entry(_ body: [String: Any], _ project: Project) throws -> [String: Any]? {
        let id = try project.requireID().uuidString
        return (body["projects"] as? [[String: Any]])?.first { ($0["projectID"] as? String) == id }
    }

    func testToolsRegisteredWithScopes() {
        XCTAssertEqual(MCPController.tools.first { $0.name == "report_session_status" }?.scope, "tasks:write")
        XCTAssertEqual(MCPController.tools.first { $0.name == "get_overview_now" }?.scope, "tasks:read")
    }

    func testReportUpsertsAndMasksSecrets() async throws {
        try await fixture { f, access in
            let first = try await report(f, access, "Lese Code \(secret)")
            XCTAssertFalse(first.isError, first.text)
            XCTAssertFalse(first.text.contains(secret))
            _ = try await report(f, access, session: "Window 2", "andere Sitzung")
            try await backdate(f, seconds: 11)
            let again = try await report(f, access, "Zweiter Stand")
            XCTAssertFalse(again.isError, again.text)
            let rows = try await SessionStatus.query(on: f.test.app.db).all()
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.first { $0.sessionName == "Mac Studio" }?.activity, "Zweiter Stand")
            XCTAssertFalse(rows.contains { $0.activity.contains(secret) })
        }
    }

    func testRateLimitOneWritePerTenSecondsPerSession() async throws {
        try await fixture { f, access in
            let v1 = try await report(f, access).isError
            XCTAssertFalse(v1)
            let second = try await report(f, access, "gleich nochmal")
            XCTAssertTrue(second.isError); XCTAssertTrue(second.text.contains("rate_limited"), second.text)
            let v2 = try await report(f, access, session: "other").isError
            XCTAssertFalse(v2, "limit is per session name")
            try await backdate(f, seconds: 11, name: "Mac Studio")
            let v3 = try await report(f, access, "nach Wartezeit").isError
            XCTAssertFalse(v3)
        }
    }

    func testValidation() async throws {
        try await fixture { f, access in
            let v4 = try await report(f, access, session: String(repeating: "n", count: 101)).isError
            XCTAssertTrue(v4)
            let v5 = try await report(f, access, String(repeating: "a", count: 301)).isError
            XCTAssertTrue(v5)
            let v6 = try await report(f, access, "   ").isError
            XCTAssertTrue(v6)
            let v7 = try await SessionStatus.query(on: f.test.app.db).count()
            XCTAssertEqual(v7, 0)
        }
    }

    func testRights() async throws {
        try await fixture { f, access in
            let v8 = try await report(f, access, project: f.other).isError
            XCTAssertTrue(v8, "project outside the OAuth grant")
            let stranger = User(displayName: "S", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Foreign"); try await foreign.save(on: f.test.app.db)
            let v9 = try await report(f, access, project: foreign).isError
            XCTAssertTrue(v9)
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let v10 = try await report(f, readOnly.access).isError
            XCTAssertTrue(v10, "tasks:write required")
            let v11 = try await SessionStatus.query(on: f.test.app.db).count()
            XCTAssertEqual(v11, 0)
            // Read-only role on a shared project cannot report either.
            let shared = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Shared"); try await shared.save(on: f.test.app.db)
            try await ProjectGrant(projectID: try shared.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read).save(on: f.test.app.db)
            let denied = try await f.test.json(.PUT, "/v1/projects/\(try shared.requireID().uuidString)/session-status", ["sessionName": "x", "activity": "y"], token: f.session)
            XCTAssertEqual(denied.status, .forbidden)
            let rest = try await f.test.json(.PUT, "/v1/projects/\(try foreign.requireID().uuidString)/session-status", ["sessionName": "x", "activity": "y"], token: f.session)
            XCTAssertEqual(rest.status, .notFound)
            let noAuth = try await f.test.json(.PUT, "/v1/projects/\(try f.project.requireID().uuidString)/session-status", ["sessionName": "x", "activity": "y"])
            XCTAssertEqual(noAuth.status, .unauthorized)
            let noOverview = try await f.test.json(.GET, "/v1/overview/now")
            XCTAssertEqual(noOverview.status, .unauthorized)
            let noScope = try await f.rpc("tools/call", ["name": "get_overview_now", "arguments": [:]], access: (try await f.tokens(scope: "projects:read")).access)
            XCTAssertEqual((noScope.body?["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    func testRestPutAndOverviewBundlesEverything() async throws {
        try await fixture { f, access in
            let uid = try f.user.requireID(), pid = try f.project.requireID()
            let put = try await f.test.json(.PUT, "/v1/projects/\(pid.uuidString)/session-status", ["sessionName": "Web", "activity": "Plane"], token: f.session)
            XCTAssertEqual(put.status, .ok, String(describing: put.body))
            let running = TodoTask(ownerID: uid, projectID: pid, title: "Running card"); running.status = "in_progress"
            try await running.save(on: f.test.app.db)
            let rid = try running.requireID()
            let wf = TaskWorkflow(taskID: rid); wf.claimedByType = "integration"; wf.claimedByID = UUID(); wf.claimedLabel = "Claude Code"; wf.claimedAt = Date()
            try await wf.save(on: f.test.app.db)
            let note = TaskProgressNote(); note.taskID = rid; note.actorType = .integration; note.actorID = UUID(); note.note = "Schritt 1 fertig"
            try await note.save(on: f.test.app.db)
            let open = TodoTask(ownerID: uid, projectID: pid, title: "Open card"); try await open.save(on: f.test.app.db)
            let q = TaskQuestion(); q.taskID = try open.requireID(); q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "Welche Farbe?"; q.options = []; q.blocking = true; q.state = "open"; q.version = 1
            try await q.save(on: f.test.app.db)
            let rv = TaskReview(); rv.taskID = try open.requireID(); rv.state = "pending"; rv.requestedByType = .integration; rv.requestedByID = UUID(); rv.summary = "Fertig"; rv.version = 1
            try await rv.save(on: f.test.app.db)
            let body = try await now(f)
            XCTAssertNotNil(body["serverTime"])
            let p = try XCTUnwrap(try entry(body, f.project), String(describing: body))
            let tasks = try XCTUnwrap(p["runningTasks"] as? [[String: Any]])
            XCTAssertEqual(tasks.first?["title"] as? String, "Running card")
            XCTAssertEqual(tasks.first?["worker"] as? String, "Claude Code")
            XCTAssertEqual((tasks.first?["lastProgress"] as? [String: Any])?["note"] as? String, "Schritt 1 fertig")
            XCTAssertNotNil(tasks.first?["ageSeconds"])
            let sessions = try XCTUnwrap(p["sessions"] as? [[String: Any]])
            XCTAssertEqual(sessions.first?["sessionName"] as? String, "Web")
            XCTAssertEqual(sessions.first?["orphaned"] as? Bool, false)
            XCTAssertEqual((p["openQuestions"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((p["pendingReviews"] as? [[String: Any]])?.count, 1)
            XCTAssertNotNil(p["agentJobs"]); XCTAssertNotNil(p["builds"]); XCTAssertNotNil(p["recentActivity"])
            let mcp = try await call(f, "get_overview_now", [:], access)
            XCTAssertFalse(mcp.isError, mcp.text)
            XCTAssertNotNil(obj(mcp)["projects"])
        }
    }

    func testOrphanedAfter30MinutesHiddenAfter24Hours() async throws {
        try await fixture { f, access in
            _ = try await report(f, access, session: "fresh"); _ = try await report(f, access, session: "old"); _ = try await report(f, access, session: "gone")
            try await backdate(f, seconds: 31 * 60, name: "old")
            try await backdate(f, seconds: 25 * 3600, name: "gone")
            let body = try await now(f)
            let p = try XCTUnwrap(try entry(body, f.project))
            let byName = Dictionary(uniqueKeysWithValues: (p["sessions"] as! [[String: Any]]).map { ($0["sessionName"] as! String, $0) })
            XCTAssertEqual(byName["fresh"]?["orphaned"] as? Bool, false)
            XCTAssertEqual(byName["old"]?["orphaned"] as? Bool, true)
            XCTAssertNil(byName["gone"])
        }
    }

    func testOverviewOnlyShowsReadableProjectsAndGrantProjectsForMCP() async throws {
        try await fixture { f, access in
            let stranger = User(displayName: "S", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Foreign"); try await foreign.save(on: f.test.app.db)
            try await SessionStatus(userID: try stranger.requireID(), projectID: try foreign.requireID(), sessionName: "secret", activity: "geheim", updatedAt: Date()).save(on: f.test.app.db)
            _ = try await report(f, access)
            try await SessionStatus(userID: try f.user.requireID(), projectID: try f.other.requireID(), sessionName: "o", activity: "x", updatedAt: Date()).save(on: f.test.app.db)
            let v12 = try entry(try await now(f), foreign)
            XCTAssertNil(v12)
            let v13 = try entry(try await now(f), f.other)
            XCTAssertNotNil(v13, "REST shows every readable project")
            let mcp = obj(try await call(f, "get_overview_now", [:], access))
            XCTAssertNil(try entry(mcp, foreign)); XCTAssertNil(try entry(mcp, f.other), "OAuth grant limits the projects")
            XCTAssertNotNil(try entry(mcp, f.project))
            // Sharing makes the foreign project readable, including the stranger's status.
            try await ProjectGrant(projectID: try foreign.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read).save(on: f.test.app.db)
            let body2 = try await now(f)
            let shared = try XCTUnwrap(try entry(body2, foreign))
            XCTAssertEqual((shared["sessions"] as? [[String: Any]])?.count, 1)
        }
    }

    func testReportChangesLiveTokenButNotTaskHints() async throws {
        try await fixture { f, access in
            let before = try await LiveToken.current(on: f.test.app.db).token
            _ = try await report(f, access)
            let v14 = try await LiveToken.current(on: f.test.app.db).token
            XCTAssertNotEqual(before, v14)
            let hints = try await LiveToken.taskHints(after: LiveToken.maxEventID(of: before) ?? 0, on: f.test.app.db)
            XCTAssertTrue(hints.isEmpty, "session status never appears among the task hints")
        }
    }

    func testWaitForEventsHintsProjectProgressOnlyForReadableGrantProjects() async throws {
        try await fixture { f, access in
            let first = try await call(f, "wait_for_events", [:], access)
            let token = try XCTUnwrap(obj(first)["token"] as? String)
            let other = User(displayName: "O", isAdmin: false); try await other.save(on: f.test.app.db)
            let pid = try f.project.requireID()
            try await ProjectGrant(projectID: pid, principalType: "person", principalID: try other.requireID(), role: .edit).save(on: f.test.app.db)
            _ = try await SessionStatusService(user: other, db: f.test.app.db).report(projectID: pid, sessionName: "Remote", activity: "arbeitet")
            let excluded = Project(ownerID: try other.requireID(), parentID: nil, name: "NotInGrant"); try await excluded.save(on: f.test.app.db)
            _ = try await SessionStatusService(user: other, db: f.test.app.db).report(projectID: try excluded.requireID(), sessionName: "R2", activity: "x")
            let woke = try await call(f, "wait_for_events", ["since": token], access)
            let hints = try XCTUnwrap(obj(woke)["hints"] as? [[String: Any]], woke.text)
            let projectHints = hints.filter { ($0["kind"] as? String) == "progress" && $0["taskID"] == nil }
            XCTAssertEqual(projectHints.compactMap { $0["projectID"] as? String }, [pid.uuidString])
        }
    }
}
