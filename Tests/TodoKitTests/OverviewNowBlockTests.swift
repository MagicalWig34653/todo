import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Block `now` of the overview (ADR 0034 addendum 24.11.2026, contract session-status 1.4.0): running, silent,
/// waiting, recentlyDone over all readable projects.
final class OverviewNowBlockTests: XCTestCase {
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
    private func block(_ f: OAuthFixture) async throws -> [String: Any] {
        let r = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
        XCTAssertEqual(r.status, .ok)
        return try XCTUnwrap(r.body?["now"] as? [String: Any], String(describing: r.body))
    }
    private func list(_ block: [String: Any], _ key: String) -> [[String: Any]] { (block[key] as? [[String: Any]]) ?? [] }
    private func counts(_ block: [String: Any]) -> [String: Int] { (block["counts"] as? [String: Int]) ?? [:] }
    private func titles(_ block: [String: Any], _ key: String) -> [String] { list(block, key).compactMap { $0["title"] as? String } }

    @discardableResult
    private func card(_ f: OAuthFixture, _ title: String, status: String = "in_progress", project: Project? = nil, claimedAgo: TimeInterval? = nil, label: String = "Claude Code") async throws -> UUID {
        let db = f.test.app.db
        let t = TodoTask(ownerID: try f.user.requireID(), projectID: try (project ?? f.project).requireID(), title: title); t.status = status
        try await t.save(on: db)
        let id = try t.requireID()
        if let claimedAgo {
            let wf = TaskWorkflow(taskID: id); wf.claimedByType = "integration"; wf.claimedByID = UUID(); wf.claimedLabel = label
            wf.claimedAt = Date().addingTimeInterval(-claimedAgo)
            try await wf.save(on: db)
        }
        return id
    }
    private func note(_ f: OAuthFixture, _ id: UUID, _ text: String, ago: TimeInterval, percent: Int? = nil) async throws {
        let n = TaskProgressNote(); n.taskID = id; n.actorType = .integration; n.actorID = UUID(); n.note = text; n.percent = percent
        try await n.save(on: f.test.app.db)
        n.createdAt = Date().addingTimeInterval(-ago); try await n.save(on: f.test.app.db)
    }
    private func setUpdatedAt(_ f: OAuthFixture, _ id: UUID, ago: TimeInterval) async throws {
        try await TodoTask.query(on: f.test.app.db).filter(\.$id == id).set(\.$updatedAt, to: Date().addingTimeInterval(-ago)).update()
    }
    private func report(_ f: OAuthFixture, _ access: String, session: String, _ activity: String) async throws {
        let c = try await call(f, "report_session_status", ["projectID": try f.project.requireID().uuidString, "sessionName": session, "activity": activity], access)
        XCTAssertFalse(c.isError, c.text)
    }
    private func backdate(_ f: OAuthFixture, seconds: TimeInterval, name: String) async throws {
        for row in try await SessionStatus.query(on: f.test.app.db).all() where row.sessionName == name {
            row.updatedAt = row.updatedAt.addingTimeInterval(-seconds); try await row.save(on: f.test.app.db)
        }
    }

    func testNowBlockIsAlwaysPresentEvenWithoutContent() async throws {
        try await fixture { f, access in
            let rest = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            let now = try XCTUnwrap(rest.body?["now"] as? [String: Any], String(describing: rest.body))
            XCTAssertEqual(counts(now), ["running": 0, "waiting": 0, "recentlyDone": 0, "silent": 0])
            for key in ["running", "waiting", "recentlyDone", "silent"] { XCTAssertNotNil(now[key] as? [Any], key); XCTAssertEqual(list(now, key).count, 0) }
            XCTAssertNotNil(rest.body?["projects"], "projects stays in the full answer")
            let mcp = obj(try await call(f, "get_overview_now", [:], access))
            XCTAssertNotNil(mcp["now"] as? [String: Any]); XCTAssertNotNil(mcp["projects"])
        }
    }

    func testRunningNeedsSignOfLifeWithin30MinutesOtherwiseSilent() async throws {
        try await fixture { f, access in
            let db = f.test.app.db, uid = try f.user.requireID()
            let due = Date(timeIntervalSince1970: 1_800_000_000)
            // Alpha: fresh progress note (multi-line, with percent) and a due date.
            let alpha = try await card(f, "Alpha", claimedAgo: 120)
            try await note(f, alpha, "Zeile eins\nZeile  zwei", ago: 60, percent: 40)
            let plan = TaskPlanning(taskID: alpha); plan.dueAt = due; try await plan.save(on: db)
            // Bravo: everything older than 30 minutes -> silent.
            let bravo = try await card(f, "Bravo", claimedAgo: 40 * 60)
            try await note(f, bravo, "alt", ago: 35 * 60)
            // Charlie: old claim and note, but a fresh activity event -> running.
            let charlie = try await card(f, "Charlie", claimedAgo: 3 * 3600)
            try await note(f, charlie, "alt", ago: 2 * 3600)
            try await appendActivity(taskID: charlie, actorType: .person, actorID: uid, kind: "task.updated", subjectID: nil, on: db)
            // Delta: unclaimed card with only an old note -> silent.
            let delta = try await card(f, "Delta")
            try await note(f, delta, "alt", ago: 3600)
            // Echo: old claim, only a fresh live session of the card -> running.
            let echo = try await card(f, "Echo", claimedAgo: 3 * 3600)
            let live = TaskLiveSession(); live.taskID = echo; live.userID = uid; live.name = "main"; live.actorType = "integration"; live.actorID = UUID()
            live.status = "active"; live.startedAt = Date().addingTimeInterval(-3600); live.lastSeenAt = Date().addingTimeInterval(-30)
            try await live.save(on: db)
            // Foxtrot: old claim, only a fresh comment -> running.
            let fox = try await card(f, "Foxtrot", claimedAgo: 3 * 3600)
            let comment = TaskComment(); comment.taskID = fox; comment.authorID = uid; comment.body = "Hallo"; comment.version = 1
            try await comment.save(on: db)
            // Not in progress: never listed.
            let todo = try await card(f, "Golf", status: "todo", claimedAgo: 10)
            try await note(f, todo, "frisch", ago: 5)

            let now = try await block(f)
            XCTAssertEqual(Set(titles(now, "running")), ["Alpha", "Charlie", "Echo", "Foxtrot"])
            XCTAssertEqual(Set(titles(now, "silent")), ["Bravo", "Delta"])
            XCTAssertEqual(counts(now)["running"], 4); XCTAssertEqual(counts(now)["silent"], 2)
            let alphaRow = try XCTUnwrap(list(now, "running").first { $0["title"] as? String == "Alpha" })
            XCTAssertEqual(alphaRow["kind"] as? String, "task")
            XCTAssertEqual(alphaRow["taskID"] as? String, alpha.uuidString)
            XCTAssertEqual(alphaRow["projectID"] as? String, try f.project.requireID().uuidString)
            XCTAssertEqual(alphaRow["projectName"] as? String, "Allowed")
            XCTAssertEqual(alphaRow["text"] as? String, "Zeile eins Zeile zwei", "one line")
            XCTAssertEqual(alphaRow["worker"] as? String, "Claude Code")
            XCTAssertEqual(alphaRow["percent"] as? Int, 40)
            XCTAssertNotNil(alphaRow["since"]); XCTAssertNotNil(alphaRow["lastSignAt"])
            XCTAssertLessThan(try XCTUnwrap(alphaRow["ageSeconds"] as? Int), 120)
            let dueText = try XCTUnwrap(alphaRow["dueAt"] as? String)
            XCTAssertEqual(parseISO(dueText), due)
            let charlieRow = try XCTUnwrap(list(now, "running").first { $0["title"] as? String == "Charlie" })
            XCTAssertNil(charlieRow["dueAt"]); XCTAssertNil(charlieRow["percent"])
            // Newest sign of life first.
            let ages = list(now, "running").compactMap { $0["ageSeconds"] as? Int }
            XCTAssertEqual(ages, ages.sorted(), "running: newest sign of life first")
            let silentAges = list(now, "silent").compactMap { $0["ageSeconds"] as? Int }
            XCTAssertEqual(silentAges, silentAges.sorted(), "silent: newest sign of life first")
            XCTAssertEqual(titles(now, "silent"), ["Bravo", "Delta"], "Bravo (35 min) is younger than Delta (1 h)")
            let bravoRow = try XCTUnwrap(list(now, "silent").first { $0["title"] as? String == "Bravo" })
            XCTAssertGreaterThan(try XCTUnwrap(bravoRow["ageSeconds"] as? Int), 30 * 60)
            XCTAssertEqual(bravoRow["text"] as? String, "alt")
            // MCP shows the same block, narrowed to the grant.
            let other = try await card(f, "Hotel", project: f.other, claimedAgo: 5)
            _ = other
            let mcpCall = try await call(f, "get_overview_now", [:], access)
            let mcp = try XCTUnwrap(obj(mcpCall)["now"] as? [String: Any])
            XCTAssertEqual(Set(titles(mcp, "running")), ["Alpha", "Charlie", "Echo", "Foxtrot"], "project outside the grant stays out")
            let restNow = try await block(f)
            XCTAssertTrue(Set(titles(restNow, "running")).contains("Hotel"), "REST sees every readable project")
        }
    }

    func testSessionsRunningSilentAndEndedAreExcluded() async throws {
        try await fixture { f, access in
            try await report(f, access, session: "fresh", "Baue Tests")
            try await report(f, access, session: "quiet", "Warte")
            try await report(f, access, session: "gone", "Alt")
            try await report(f, access, session: "end1", "Beendet: alles fertig")
            try await report(f, access, session: "end2", "  beendet")
            try await report(f, access, session: "end3", "BEENDET - Feierabend")
            try await report(f, access, session: "end4", "Nicht beendet, läuft")
            try await backdate(f, seconds: 31 * 60, name: "quiet")
            try await backdate(f, seconds: 25 * 3600, name: "gone")
            try await backdate(f, seconds: 40 * 60, name: "end3")
            let now = try await block(f)
            XCTAssertEqual(Set(titles(now, "running")), ["fresh", "end4"])
            XCTAssertEqual(titles(now, "silent"), ["quiet"])
            let fresh = try XCTUnwrap(list(now, "running").first { $0["title"] as? String == "fresh" })
            XCTAssertEqual(fresh["kind"] as? String, "session")
            XCTAssertEqual(fresh["text"] as? String, "Baue Tests")
            XCTAssertEqual(fresh["projectName"] as? String, "Allowed")
            XCTAssertNil(fresh["taskID"]); XCTAssertNil(fresh["dueAt"]); XCTAssertNil(fresh["percent"])
            XCTAssertNotNil(fresh["lastSignAt"])
            XCTAssertEqual(counts(now)["running"], 2); XCTAssertEqual(counts(now)["silent"], 1)
            // projects[].sessions is unchanged: ended sentences stay, 24 h old ones are hidden as before.
            let full = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            let project = try XCTUnwrap((full.body?["projects"] as? [[String: Any]])?.first)
            let names = Set((project["sessions"] as? [[String: Any]] ?? []).compactMap { $0["sessionName"] as? String })
            XCTAssertEqual(names, ["fresh", "quiet", "end1", "end2", "end3", "end4"])
        }
    }

    func testWaitingHasOpenQuestionsAndPendingReviewsNewestFirst() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let open = try await card(f, "Offen", status: "todo")
            let secondProject = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Zweit"); try await secondProject.save(on: db)
            let otherCard = try await card(f, "Anderes Projekt", status: "todo", project: secondProject)
            func question(_ id: UUID, _ text: String, state: String = "open", ago: TimeInterval) async throws -> UUID {
                let q = TaskQuestion(); q.taskID = id; q.askedByType = .integration; q.askedByID = UUID(); q.prompt = text; q.options = []; q.blocking = true; q.state = state; q.version = 1
                try await q.save(on: db); q.createdAt = Date().addingTimeInterval(-ago); try await q.save(on: db); return try q.requireID()
            }
            func review(_ id: UUID, _ text: String, state: String = "pending", ago: TimeInterval) async throws -> UUID {
                let r = TaskReview(); r.taskID = id; r.state = state; r.requestedByType = .integration; r.requestedByID = UUID(); r.summary = text; r.version = 1
                try await r.save(on: db); r.createdAt = Date().addingTimeInterval(-ago); try await r.save(on: db); return try r.requireID()
            }
            let q1 = try await question(open, "Welche Farbe?", ago: 300)
            let r1 = try await review(open, String(repeating: "x", count: 500), ago: 200)
            let q2 = try await question(otherCard, "Neueste Frage", ago: 10)
            _ = try await question(open, "Beantwortet", state: "answered", ago: 5)
            _ = try await review(open, "Erledigt", state: "accepted", ago: 5)
            let now = try await block(f)
            let waiting = list(now, "waiting")
            XCTAssertEqual(waiting.compactMap { $0["id"] as? String }, [q2.uuidString, r1.uuidString, q1.uuidString], "newest first across projects")
            XCTAssertEqual(waiting.compactMap { $0["kind"] as? String }, ["question", "review", "question"])
            XCTAssertEqual(counts(now)["waiting"], 3)
            let first = waiting[0]
            XCTAssertEqual(first["projectName"] as? String, "Zweit"); XCTAssertEqual(first["taskTitle"] as? String, "Anderes Projekt")
            XCTAssertEqual(first["taskID"] as? String, otherCard.uuidString); XCTAssertEqual(first["text"] as? String, "Neueste Frage")
            XCTAssertNotNil(first["createdAt"]); XCTAssertNotNil(first["projectID"])
            XCTAssertLessThanOrEqual((waiting[1]["text"] as? String)?.count ?? 999, 200)
            // The grant for MCP only covers the first project.
            let mcpCall = try await call(f, "get_overview_now", [:], access)
            let mcp = try XCTUnwrap(obj(mcpCall)["now"] as? [String: Any])
            XCTAssertEqual(list(mcp, "waiting").compactMap { $0["id"] as? String }, [r1.uuidString, q1.uuidString])
        }
    }

    func testRecentlyDoneWithinSixHoursNewestFirstFromUpdatedAt() async throws {
        try await fixture { f, _ in
            let fresh = try await card(f, "Neu fertig", status: "done")
            let older = try await card(f, "Vor 5 h", status: "done")
            let tooOld = try await card(f, "Vor 7 h", status: "done")
            let open = try await card(f, "Nicht fertig", status: "in_progress", claimedAgo: 5)
            try await setUpdatedAt(f, older, ago: 5 * 3600)
            try await setUpdatedAt(f, tooOld, ago: 7 * 3600)
            _ = open
            let now = try await block(f)
            let done = list(now, "recentlyDone")
            XCTAssertEqual(done.compactMap { $0["title"] as? String }, ["Neu fertig", "Vor 5 h"])
            XCTAssertEqual(counts(now)["recentlyDone"], 2)
            let first = done[0]
            XCTAssertEqual(first["taskID"] as? String, fresh.uuidString)
            XCTAssertEqual(first["projectName"] as? String, "Allowed"); XCTAssertNotNil(first["projectID"])
            let doneAt = try XCTUnwrap(parseISO(try XCTUnwrap(first["doneAt"] as? String)))
            XCTAssertLessThan(Date().timeIntervalSince(doneAt), 60)
            let olderAt = try XCTUnwrap(parseISO(try XCTUnwrap(done[1]["doneAt"] as? String)))
            XCTAssertEqual(Date().timeIntervalSince(olderAt), 5 * 3600, accuracy: 60)
        }
    }

    func testOtherAccountsProjectsStayHiddenUntilShared() async throws {
        try await fixture { f, _ in
            let db = f.test.app.db
            let stranger = User(displayName: "S", isAdmin: false); try await stranger.save(on: db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Fremd"); try await foreign.save(on: db)
            let t = TodoTask(ownerID: try stranger.requireID(), projectID: try foreign.requireID(), title: "Geheim"); t.status = "in_progress"; try await t.save(on: db)
            let d = TodoTask(ownerID: try stranger.requireID(), projectID: try foreign.requireID(), title: "Geheim fertig"); d.status = "done"; try await d.save(on: db)
            try await SessionStatus(userID: try stranger.requireID(), projectID: try foreign.requireID(), sessionName: "geheime Sitzung", activity: "x", updatedAt: Date()).save(on: db)
            var now = try await block(f)
            XCTAssertEqual(counts(now), ["running": 0, "waiting": 0, "recentlyDone": 0, "silent": 0])
            XCTAssertFalse(String(describing: now).contains("Geheim"))
            try await ProjectGrant(projectID: try foreign.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read).save(on: db)
            now = try await block(f)
            XCTAssertEqual(counts(now)["recentlyDone"], 1)
            XCTAssertEqual(titles(now, "running"), ["geheime Sitzung"], "fresh session of the shared project")
            XCTAssertEqual(titles(now, "silent"), ["Geheim"], "card in progress without any sign of life")
        }
    }

    func testFullAnswerKeepsAtMost100EntriesPerListButCountsAreTotals() async throws {
        try await fixture { f, _ in
            for i in 0..<105 { try await card(f, "Done \(i)", status: "done") }
            let now = try await block(f)
            XCTAssertEqual(counts(now)["recentlyDone"], 105)
            XCTAssertEqual(list(now, "recentlyDone").count, 100)
        }
    }
}

func parseISO(_ text: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)
}
