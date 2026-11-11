import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Daily brief (get_daily_brief, GET /v1/daily-brief) and its optional push (category daily_brief).
final class DailyBriefTests: XCTestCase {
    private let hour: TimeInterval = 3600
    /// 2027-01-15 08:00 UTC; only used where nothing depends on the real clock (rows are written with real timestamps).
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ f: OAuthFixture, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func service(_ f: OAuthFixture, user: User? = nil, allowed: Set<UUID>? = nil, at clock: Date? = nil) -> DailyBriefService {
        let at = clock ?? now
        return DailyBriefService(user: user ?? f.user, db: f.test.app.db, allowedProjects: allowed, clock: { at })
    }

    @discardableResult
    private func task(_ f: OAuthFixture, _ title: String, project: Project? = nil, owner: User? = nil, status: String = "open",
                      claimedAt: Date? = nil, updatedAt: Date? = nil) async throws -> TodoTask {
        let task = TodoTask(ownerID: try (owner ?? f.user).requireID(), projectID: try (project ?? f.project).requireID(), title: title, details: "")
        task.status = status
        try await task.save(on: f.test.app.db)
        if let claimedAt {
            let wf = TaskWorkflow(taskID: try task.requireID())
            wf.claimedByType = "agent"; wf.claimedByID = UUID(); wf.claimedLabel = "Claude"; wf.claimedAt = claimedAt
            try await wf.save(on: f.test.app.db)
        }
        if let updatedAt { try await setUpdatedAt(f, task, updatedAt) }
        return task
    }

    private func setUpdatedAt(_ f: OAuthFixture, _ task: TodoTask, _ date: Date) async throws {
        // `updated_at` is stamped on every model save, so write it with a query update.
        try await TodoTask.query(on: f.test.app.db).filter(\.$id == task.requireID()).set(\.$updatedAt, to: date).update()
    }

    private func question(_ f: OAuthFixture, on task: TodoTask) async throws {
        let q = TaskQuestion()
        q.taskID = try task.requireID(); q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "Which way?"
        q.options = []; q.blocking = true; q.state = "open"; q.version = 1
        try await q.save(on: f.test.app.db)
    }

    private func review(_ f: OAuthFixture, on task: TodoTask) async throws {
        let r = TaskReview()
        r.taskID = try task.requireID(); r.state = "pending"; r.requestedByType = .integration; r.requestedByID = UUID()
        r.summary = "Please look"; r.version = 1
        try await r.save(on: f.test.app.db)
    }

    private func confirmation(_ f: OAuthFixture, user: User? = nil, summary: String = "Delete project X") async throws {
        let r = ActionRequest()
        r.userID = try (user ?? f.user).requireID(); r.tool = "delete_project"; r.args = [:]; r.fingerprint = UUID().uuidString
        r.summary = summary; r.impact = ActionImpact(targetType: "project", targetID: UUID(), targetName: "X", destructive: true)
        r.state = "pending"; r.expiresAt = now.addingTimeInterval(86_400)
        try await r.save(on: f.test.app.db)
    }

    private func bind(_ f: OAuthFixture, _ project: Project, syncedDaysAgo: Int?) async throws {
        let b = ProjectRepositoryBinding(projectID: try project.requireID(), ownerID: project.ownerID, repoKey: "local/\(UUID().uuidString.lowercased())", staleAfterDays: 3)
        if let days = syncedDaysAgo { b.lastSyncedAt = now.addingTimeInterval(-Double(days) * 86_400) }
        try await b.save(on: f.test.app.db)
    }

    private func stranger(_ f: OAuthFixture) async throws -> (user: User, project: Project) {
        let user = User(displayName: "Stranger", isAdmin: false)
        try await user.save(on: f.test.app.db)
        let project = Project(ownerID: try user.requireID(), parentID: nil, name: "Hidden")
        try await project.save(on: f.test.app.db)
        return (user, project)
    }

    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ args: [String: Any] = [:], _ access: String, name: String = "get_daily_brief") async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    private func sections(_ r: DailyBriefResponse) -> [String: DailyBriefSection] {
        Dictionary(uniqueKeysWithValues: (r.sections ?? []).map { ($0.key, $0) })
    }

    // MARK: Sections

    func testSectionsAreOrderedByPriorityWithCountsAndItems() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let asked = try await task(f, "Needs an answer"); try await question(f, on: asked)
            let reviewed = try await task(f, "Needs a review", status: "in_review"); try await review(f, on: reviewed)
            try await confirmation(f)
            let stuck = try await task(f, "Stuck", status: "in_progress", claimedAt: now.addingTimeInterval(-30 * hour))
            let busy = try await task(f, "Busy", status: "in_progress", claimedAt: now.addingTimeInterval(-1 * hour))
            let unclaimed = try await task(f, "Started by hand", status: "in_progress")
            let finished = try await task(f, "Finished", status: "done", updatedAt: now.addingTimeInterval(-2 * hour))
            try await bind(f, f.other, syncedDaysAgo: 10)
            try await bind(f, f.project, syncedDaysAgo: 0)

            let brief = try await service(f).build()
            XCTAssertEqual(brief.format, "full")
            XCTAssertEqual(brief.scope, "account")
            XCTAssertEqual(brief.sections?.map(\.key), ["waiting", "orphaned", "stale", "running", "done"])
            let s = sections(brief)
            XCTAssertEqual(s["waiting"]?.count, 3)
            XCTAssertEqual(Set(s["waiting"]?.items.map(\.kind) ?? []), ["question", "review", "confirmation"])
            XCTAssertEqual(s["waiting"]?.truncated, false)
            XCTAssertEqual(s["orphaned"]?.items, [DailyBriefItem(id: try stuck.requireID(), title: "Stuck", projectID: try f.project.requireID(), kind: "task")])
            XCTAssertEqual(s["stale"]?.items, [DailyBriefItem(id: try f.other.requireID(), title: "Excluded", projectID: try f.other.requireID(), kind: "project")])
            XCTAssertEqual(s["running"]?.items.map(\.id), [try busy.requireID()], "claimed, not orphaned; a hand-started task without claim does not count")
            XCTAssertEqual(s["done"]?.items.map(\.title), ["Finished"])
            XCTAssertEqual(brief.summary, DailyBriefSummary(waiting: 3, openQuestions: 1, pendingReviews: 1, pendingConfirmations: 1,
                orphanedClaims: 1, staleProjects: 1, running: 1, done: 1))
            XCTAssertEqual(brief.line, "3 warten auf dich, 1 verwaist, 1 Projekt veraltet · 1 erledigt, 1 läuft")
            _ = (unclaimed, finished)
            // Every item carries id, title and projectID (nil only for confirmations); no rights leaks beyond that.
            for item in (brief.sections ?? []).flatMap(\.items) { XCTAssertTrue(item.kind == "confirmation" || item.projectID != nil) }
        }
    }

    func testDoneTasksAndOpenItemsOfFinishedTasksAreHandledByStatus() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let done = try await task(f, "Old question", status: "done", updatedAt: now.addingTimeInterval(-hour)); try await question(f, on: done)
            let brief = try await service(f).build()
            XCTAssertEqual(brief.summary?.waiting, 0, "an open question on a finished task does not wait for anyone")
            XCTAssertEqual(brief.summary?.done, 1)
        }
    }

    // MARK: Time boundary

    func testSinceBoundaryIsInclusiveAndDefaultsToStartOfYesterdayUTC() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            // now = 2027-01-15 08:00 UTC, so the default boundary is 2027-01-14 00:00 UTC.
            let boundary = Date(timeIntervalSince1970: 1_799_884_800)
            XCTAssertEqual(DailyBriefService.defaultSince(now: now), boundary)
            XCTAssertEqual(DailyBriefService.defaultSince(now: boundary.addingTimeInterval(2 * 86_400 - 1)), boundary)
            try await task(f, "Exactly at", status: "done", updatedAt: boundary)
            try await task(f, "One second before", status: "done", updatedAt: boundary.addingTimeInterval(-1))
            try await task(f, "After", status: "done", updatedAt: boundary.addingTimeInterval(1))
            let brief = try await service(f).build()
            XCTAssertEqual(brief.since, boundary)
            XCTAssertEqual(Set(sections(brief)["done"]?.items.map(\.title) ?? []), ["Exactly at", "After"])
            let explicit = try await service(f).build(since: boundary.addingTimeInterval(1))
            XCTAssertEqual(explicit.summary?.done, 1)
            do { _ = try await service(f).build(since: now.addingTimeInterval(1)); XCTFail("a boundary in the future is invalid") }
            catch let error as any AbortError { XCTAssertEqual(error.status, .badRequest) }
        }
    }

    func testSinceParsing() throws {
        XCTAssertEqual(try DailyBriefService.parseSince("2027-01-14"), Date(timeIntervalSince1970: 1_799_884_800))
        XCTAssertEqual(try DailyBriefService.parseSince("2027-01-14T01:00:00Z"), Date(timeIntervalSince1970: 1_799_888_400))
        XCTAssertEqual(try DailyBriefService.parseSince("2027-01-14T01:00:00.500Z"), Date(timeIntervalSince1970: 1_799_888_400.5))
        XCTAssertNil(try DailyBriefService.parseSince(nil))
        XCTAssertThrowsError(try DailyBriefService.parseSince("yesterday"))
        XCTAssertThrowsError(try DailyBriefService.parseFormat("short"))
        XCTAssertEqual(try DailyBriefService.parseFormat(nil), "full")
    }

    // MARK: Scope and tenants

    func testAccountVersusProjectScopeIncludingSubprojects() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let child = Project(ownerID: try f.user.requireID(), parentID: try f.project.requireID(), name: "Child")
            try await child.save(on: f.test.app.db)
            try await question(f, on: try await task(f, "In allowed"))
            try await question(f, on: try await task(f, "In child", project: child))
            try await question(f, on: try await task(f, "In other", project: f.other))
            let account = try await service(f).build()
            XCTAssertEqual(account.summary?.openQuestions, 3)
            let project = try await service(f).build(projectID: try f.project.requireID())
            XCTAssertEqual(project.scope, "project")
            XCTAssertEqual(project.projectID, try f.project.requireID())
            XCTAssertEqual(Set(sections(project)["waiting"]?.items.map(\.title) ?? []), ["In allowed", "In child"])
            XCTAssertEqual(project.summary?.pendingConfirmations, 0, "confirmations are account-wide and stay out of a project brief")
        }
    }

    func testForeignDataIsNeverVisible() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let other = try await stranger(f)
            let foreign = try await task(f, "Foreign secret", project: other.project, owner: other.user)
            try await question(f, on: foreign); try await review(f, on: foreign)
            try await task(f, "Foreign stuck", project: other.project, owner: other.user, status: "in_progress", claimedAt: now.addingTimeInterval(-40 * hour))
            try await task(f, "Foreign done", project: other.project, owner: other.user, status: "done", updatedAt: now.addingTimeInterval(-hour))
            try await confirmation(f, user: other.user, summary: "Foreign confirmation")
            try await bind(f, other.project, syncedDaysAgo: 30)
            let mine = try await service(f).build()
            XCTAssertEqual(mine.summary, DailyBriefSummary(waiting: 0, openQuestions: 0, pendingReviews: 0, pendingConfirmations: 0,
                orphanedClaims: 0, staleProjects: 0, running: 0, done: 0))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(mine), as: UTF8.self).contains("Foreign"))
            XCTAssertEqual(mine.line, "Alles ruhig: nichts wartet auf dich.")
            // The owner of that project sees all of it; asking for a foreign project is a 404 for everybody else.
            let theirs = try await service(f, user: other.user).build()
            XCTAssertEqual(theirs.summary?.waiting, 3)
            XCTAssertEqual(theirs.summary?.orphanedClaims, 1)
            XCTAssertEqual(theirs.summary?.staleProjects, 1)
            XCTAssertEqual(theirs.summary?.done, 1)
            do { _ = try await service(f).build(projectID: try other.project.requireID()); XCTFail("foreign project must be 404") }
            catch let error as any AbortError { XCTAssertEqual(error.status, .notFound) }
        }
    }

    func testOAuthGrantNarrowsTheBriefLikeTheCommandCenter() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            try await question(f, on: try await task(f, "Allowed question"))
            try await question(f, on: try await task(f, "Excluded question", project: f.other))
            try await confirmation(f)
            let t = try await f.tokens(scope: "projects:read tasks:read")
            let brief = try await call(f, ["format": "full"], t.access)
            XCTAssertFalse(brief.isError, brief.text)
            let summary = try XCTUnwrap((brief.json as? [String: Any])?["summary"] as? [String: Any])
            XCTAssertEqual(summary["openQuestions"] as? Int, 1, "only the granted project")
            XCTAssertEqual(summary["pendingConfirmations"] as? Int, 0, "account-level requests are not part of a grant-limited view")
            XCTAssertFalse(brief.text.contains("Excluded"))
            let outside = try await call(f, ["projectID": try f.other.requireID().uuidString], t.access)
            XCTAssertTrue(outside.isError)
            XCTAssertEqual(outside.text, "not_found")
            // The scope tasks:read is required (no new scope), like get_command_center.
            let narrow = try await f.tokens(scope: "projects:read")
            let denied = try await call(f, [:], narrow.access)
            XCTAssertTrue(denied.isError)
            XCTAssertEqual(denied.text, "insufficient_scope")
        }
    }

    // MARK: Truncation, chunking

    func testTruncationKeepsExactCounts() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            for n in 0..<7 { try await question(f, on: try await task(f, "Q\(n)")) }
            for n in 0..<5 { try await task(f, "D\(n)", status: "done", updatedAt: now.addingTimeInterval(-Double(n + 1) * 60)) }
            let brief = try await service(f).build()
            let s = sections(brief)
            XCTAssertEqual(s["waiting"]?.count, 7)
            XCTAssertEqual(s["waiting"]?.items.count, DailyBriefService.itemLimit)
            XCTAssertEqual(s["waiting"]?.truncated, true)
            XCTAssertEqual(s["done"]?.count, 5)
            XCTAssertEqual(s["done"]?.truncated, false, "exactly five items are not truncated")
            XCTAssertEqual(s["done"]?.items.map(\.title), ["D0", "D1", "D2", "D3", "D4"], "newest first")
            XCTAssertEqual(brief.summary?.openQuestions, 7)
            XCTAssertEqual(brief.line, "7 warten auf dich · 5 erledigt")
        }
    }

    func testCountsMergeAcrossProjectChunks() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let owner = try f.user.requireID()
            var projects: [Project] = []
            for n in 0..<430 {
                let p = Project(ownerID: owner, parentID: nil, name: "P\(n)")
                try await p.save(on: f.test.app.db); projects.append(p)
            }
            for p in projects.enumerated().filter({ $0.offset % 70 == 0 }).map(\.element) { try await question(f, on: try await task(f, "T-\(p.name)", project: p)) }
            let brief = try await service(f).build()
            XCTAssertEqual(brief.summary?.openQuestions, 7)
            XCTAssertEqual(sections(brief)["waiting"]?.items.count, 5)
        }
    }

    func testQueryCountDoesNotGrowWithTheNumberOfItems() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let history = QueryHistory()
            let db = try XCTUnwrap(f.test.app.databases.database(logger: f.test.app.logger, on: f.test.app.eventLoopGroup.next(), history: history))
            let clock = now
            func queries() async throws -> Int {
                history.queries = []
                let counted = DailyBriefService(user: f.user, db: db, clock: { clock })
                _ = try await counted.build()
                return history.queries.count
            }
            // Queries for empty parts are skipped, so compare two non-empty states of different size.
            func populate(_ count: Int) async throws {
                for n in 0..<count {
                    let t = try await task(f, "Q\(n)"); try await question(f, on: t); try await review(f, on: t)
                    try await task(f, "Busy \(n)", status: "in_progress", claimedAt: now.addingTimeInterval(-30 * hour))
                    try await task(f, "Done \(n)", status: "done", updatedAt: now.addingTimeInterval(-hour))
                }
            }
            try await populate(2)
            let small = try await queries()
            try await populate(25)
            let large = try await queries()
            XCTAssertGreaterThan(small, 0)
            XCTAssertEqual(small, large, "no per-item queries")
        }
    }

    // MARK: Line

    func testLineWordingSingularPluralAndCalmDay() {
        func line(_ w: Int = 0, _ o: Int = 0, _ s: Int = 0, _ r: Int = 0, _ d: Int = 0) -> String {
            DailyBriefService.line(for: DailyBriefSummary(waiting: w, openQuestions: w, pendingReviews: 0, pendingConfirmations: 0,
                orphanedClaims: o, staleProjects: s, running: r, done: d))
        }
        XCTAssertEqual(line(), "Alles ruhig: nichts wartet auf dich.")
        XCTAssertEqual(line(3, 2, 1, 4, 5), "3 warten auf dich, 2 verwaist, 1 Projekt veraltet · 5 erledigt, 4 laufen")
        XCTAssertEqual(line(1, 0, 2, 1, 0), "1 wartet auf dich, 2 Projekte veraltet · 1 läuft")
        XCTAssertEqual(line(0, 0, 0, 2, 3), "Alles ruhig: nichts wartet auf dich. · 3 erledigt, 2 laufen")
    }

    func testLineNeverExceeds200CharactersEvenWithExtremeNumbers() {
        let big = Int.max
        let extreme = DailyBriefSummary(waiting: big, openQuestions: big, pendingReviews: big, pendingConfirmations: big,
            orphanedClaims: big, staleProjects: big, running: big, done: big)
        let line = DailyBriefService.line(for: extreme)
        XCTAssertLessThanOrEqual(line.count, 200)
        XCTAssertTrue(line.hasPrefix("\(big) warten auf dich"))
        XCTAssertLessThanOrEqual(DailyBriefService.line(for: DailyBriefSummary(waiting: 999_999, openQuestions: 0, pendingReviews: 0,
            pendingConfirmations: 0, orphanedClaims: 999_999, staleProjects: 999_999, running: 999_999, done: 999_999)).count, 200)
    }

    func testLineFormatReturnsOnlyTheLine() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            try await question(f, on: try await task(f, "Q"))
            let brief = try await service(f).build(format: "line")
            XCTAssertEqual(brief.format, "line")
            XCTAssertEqual(brief.line, "1 wartet auf dich")
            XCTAssertNil(brief.sections)
            XCTAssertNil(brief.summary)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(brief)) as? [String: Any])
            XCTAssertNil(json["sections"])
            XCTAssertLessThanOrEqual((json["line"] as? String)?.count ?? 999, 200)
        }
    }

    // MARK: REST and MCP

    func testRESTAndMCPAnswerTheSame() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            try await question(f, on: try await task(f, "Q1"))
            let r = try await task(f, "R1", status: "in_review"); try await review(f, on: r)
            try await task(f, "Stuck", status: "in_progress", claimedAt: Date().addingTimeInterval(-40 * hour))
            try await task(f, "Done", status: "done")
            let t = try await f.tokens(scope: "projects:read tasks:read")
            for query in ["", "?format=line", "?projectID=\(try f.project.requireID().uuidString)", "?since=2020-01-01"] {
                let rest = try await f.test.json(.GET, "/v1/daily-brief\(query)", token: f.session)
                XCTAssertEqual(rest.status, .ok, query)
                var args: [String: Any] = [:]
                for item in query.dropFirst().split(separator: "&") {
                    let kv = item.split(separator: "=").map(String.init); args[kv[0]] = kv[1]
                }
                let mcp = try await call(f, args, t.access)
                XCTAssertFalse(mcp.isError, mcp.text)
                var a = try XCTUnwrap(rest.body), b = try XCTUnwrap(mcp.json as? [String: Any])
                a["generatedAt"] = nil; b["generatedAt"] = nil
                XCTAssertEqual(NSDictionary(dictionary: a), NSDictionary(dictionary: b), query)
            }
            let line = try await f.test.json(.GET, "/v1/daily-brief?format=line", token: f.session)
            XCTAssertEqual(line.body?["line"] as? String, "2 warten auf dich, 1 verwaist · 1 erledigt")
            XCTAssertNil(line.body?["sections"])
        }
    }

    func testRESTValidationAndAuthentication() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let anonymous = try await f.test.json(.GET, "/v1/daily-brief")
            XCTAssertEqual(anonymous.status, .unauthorized)
            for bad in ["?format=short", "?since=yesterday", "?projectID=nope"] {
                let r = try await f.test.json(.GET, "/v1/daily-brief\(bad)", token: f.session)
                XCTAssertEqual(r.status, .badRequest, bad)
            }
            let future = try await f.test.json(.GET, "/v1/daily-brief?since=2999-01-01", token: f.session)
            XCTAssertEqual(future.status, .badRequest)
            let foreign = try await f.test.json(.GET, "/v1/daily-brief?projectID=\(UUID().uuidString)", token: f.session)
            XCTAssertEqual(foreign.status, .notFound)
            let tools = try await f.rpc("tools/list", access: try await f.tokens(scope: "tasks:read").access)
            let list = ((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let tool = try XCTUnwrap(list.first { $0["name"] as? String == "get_daily_brief" })
            XCTAssertEqual(Set(((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.map { $0 } ?? []), ["projectID", "since", "format"])
        }
    }

    func testFullAnswerStaysSmall() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            for n in 0..<40 {
                let t = try await task(f, String(repeating: "Long title \(n % 10) ", count: 16)); try await question(f, on: t); try await review(f, on: t)
            }
            let brief = try await service(f).build()
            let size = try JSONEncoder().encode(brief).count
            XCTAssertLessThan(size, 5_000, "five items per section with clipped titles; the compact command center layer is not needed")
            XCTAssertTrue((brief.sections ?? []).flatMap(\.items).allSatisfy { $0.title.count <= DailyBriefService.titleLimit })
        }
    }

    // MARK: Preferences and push

    func testPrefsDefaultToOffAndValidateTheHour() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let initial = try await f.test.json(.GET, "/v1/me/push-prefs", token: f.session)
            XCTAssertEqual((initial.body?["categories"] as? [String: Bool])?["daily_brief"], false)
            XCTAssertEqual(initial.body?["dailyBriefHour"] as? Int, 8)
            for bad in [24, -1] {
                let r = try await f.test.json(.PUT, "/v1/me/push-prefs", ["dailyBriefHour": bad], token: f.session)
                XCTAssertEqual(r.status, .badRequest, "\(bad)")
            }
            let on = try await f.test.json(.PUT, "/v1/me/push-prefs", ["categories": ["daily_brief": true], "dailyBriefHour": 7], token: f.session)
            XCTAssertEqual(on.status, .ok)
            XCTAssertEqual((on.body?["categories"] as? [String: Bool])?["daily_brief"], true)
            XCTAssertEqual(on.body?["dailyBriefHour"] as? Int, 7)
            let t = try await f.tokens(scope: "account:read account:write")
            let viaMCP = try await call(f, ["dailyBriefHour": 9, "categories": ["daily_brief": false]], t.access, name: "update_notification_prefs")
            XCTAssertFalse(viaMCP.isError, viaMCP.text)
            let read = try await call(f, [:], t.access, name: "get_notification_prefs")
            let json = try XCTUnwrap(read.json as? [String: Any])
            XCTAssertEqual(json["dailyBriefHour"] as? Int, 9)
            XCTAssertEqual((json["categories"] as? [String: Bool])?["daily_brief"], false)
            let bad = try await call(f, ["dailyBriefHour": 30], t.access, name: "update_notification_prefs")
            XCTAssertTrue(bad.isError)
        }
    }

    private struct PushFixture {
        let t: TestApp
        let mock: MockAPNs
        let worker: PushWorker
        let user: PushTests.Account
        let other: PushTests.Account
        /// Start of the current UTC day; ticks use offsets from it so rows written with the real clock stay consistent.
        let day: Date
    }

    private func pushFixture(enable: Bool, hour: Int? = nil) async throws -> PushFixture {
        let t = try await TestApp.make()
        let cfg = PushTests.config()
        t.app.settings.apns = cfg
        let mock = MockAPNs()
        let user = try await PushTests.account(t, "Lino"), other = try await PushTests.account(t, "Other")
        for (index, account) in [user, other].enumerated() {
            let r = try await t.json(.POST, "/v1/push/devices", ["token": String(repeating: "a\(index)", count: 32), "platform": "ios",
                "bundleId": "de.linolaske.todo", "environment": "sandbox", "locale": "de-DE"], token: account.token)
            XCTAssertTrue([.ok, .created].contains(r.status))
        }
        if enable {
            var body: [String: Any] = ["categories": ["daily_brief": true]]
            if let hour { body["dailyBriefHour"] = hour }
            let r = try await t.json(.PUT, "/v1/me/push-prefs", body, token: user.token)
            XCTAssertEqual(r.status, .ok)
        }
        let worker = PushWorker(app: t.app, sender: try APNsSender(config: cfg, transport: mock), interval: 0)
        return PushFixture(t: t, mock: mock, worker: worker, user: user, other: other, day: PushDailyBriefEvent.startOfDay(Date()))
    }

    private func bodies(_ f: PushFixture) throws -> [String] {
        try f.mock.requests.compactMap { request -> String? in
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            guard root["kind"] as? String == "daily_brief" else { return nil }
            let alert = try XCTUnwrap((root["aps"] as? [String: Any])?["alert"] as? [String: Any])
            return try XCTUnwrap(alert["body"] as? String)
        }
    }

    func testSchedulerSendsNothingWhileTheSettingIsOff() async throws {
        let f = try await pushFixture(enable: false)
        defer { Task { await f.t.shutdown() } }
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(9 * hour))
        XCTAssertTrue(f.mock.requests.isEmpty)
        let rows = try await PushOutbox.query(on: f.t.app.db).filter(\.$category == "daily_brief").count()
        XCTAssertEqual(rows, 0)
    }

    func testSchedulerSendsOncePerDayFromTheChosenHourOnly() async throws {
        let f = try await pushFixture(enable: true, hour: 8)
        defer { Task { await f.t.shutdown() } }
        // The foreign account has a question; its content must never reach the other account's push.
        let foreignProject = Project(ownerID: f.other.id, parentID: nil, name: "Foreign project")
        try await foreignProject.save(on: f.t.app.db)
        let foreignTask = TodoTask(ownerID: f.other.id, projectID: try foreignProject.requireID(), title: "Foreign secret title")
        try await foreignTask.save(on: f.t.app.db)
        let q = TaskQuestion()
        q.taskID = try foreignTask.requireID(); q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "Foreign secret prompt"
        q.options = []; q.blocking = true; q.state = "open"; q.version = 1
        try await q.save(on: f.t.app.db)

        func briefRows() async throws -> Int { try await PushOutbox.query(on: f.t.app.db).filter(\.$category == "daily_brief").count() }
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(7.5 * hour))
        let beforeHour = try await briefRows()
        XCTAssertEqual(beforeHour, 0, "before the chosen hour")
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(8.25 * hour))
        let firstRows = try await briefRows()
        XCTAssertEqual(firstRows, 1)
        XCTAssertEqual(try bodies(f), ["Alles ruhig: nichts wartet auf dich."])
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(9 * hour))
        let againRows = try await briefRows()
        XCTAssertEqual(againRows, 1, "idempotent per account and day")
        XCTAssertEqual(try bodies(f).count, 1)
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(24 * hour + 8.25 * hour))
        XCTAssertEqual(try bodies(f).count, 2, "a new day sends again")
        for body in try bodies(f) {
            XCTAssertLessThanOrEqual(body.count, 200)
            XCTAssertFalse(body.contains("Foreign"))
        }
        let otherRows = try await PushOutbox.query(on: f.t.app.db).filter(\.$userID == f.other.id).filter(\.$category == "daily_brief").count()
        XCTAssertEqual(otherRows, 0, "the other account did not opt in")
    }

    func testSchedulerDoesNotPushAMorningReportInTheAfternoon() async throws {
        let f = try await pushFixture(enable: true, hour: 8)
        defer { Task { await f.t.shutdown() } }
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(15 * hour))
        XCTAssertTrue(f.mock.requests.isEmpty, "switching it on after the lookback window must not send a stale morning report")
    }

    func testPushBodyCarriesTheCurrentCounts() async throws {
        let f = try await pushFixture(enable: true, hour: 0)
        defer { Task { await f.t.shutdown() } }
        let project = Project(ownerID: f.user.id, parentID: nil, name: "Mine")
        try await project.save(on: f.t.app.db)
        for n in 0..<2 {
            let task = TodoTask(ownerID: f.user.id, projectID: try project.requireID(), title: "Secret \(n)")
            try await task.save(on: f.t.app.db)
            let q = TaskQuestion()
            q.taskID = try task.requireID(); q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "Prompt"
            q.options = []; q.blocking = true; q.state = "open"; q.version = 1
            try await q.save(on: f.t.app.db)
        }
        _ = try await f.worker.tick(now: f.day.addingTimeInterval(1 * hour))
        let sent = try bodies(f)
        XCTAssertEqual(sent, ["2 warten auf dich"])
        XCTAssertFalse(sent.joined().contains("Secret"), "counts only, even with showContent off")
    }

    func testMigrationIsAdditiveAndOldRowsKeepWorking() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            // A row written before the column existed has no hour: the default applies and the categories stay valid.
            let row = PushPrefs()
            row.userID = try f.user.requireID(); row.categories = ["reminders": false]; row.showContent = true; row.badge = false
            try await row.save(on: f.test.app.db)
            let dto = PushService.dto(try await PushPrefs.query(on: f.test.app.db).first())
            XCTAssertEqual(dto.dailyBriefHour, 8)
            XCTAssertEqual(dto.categories["daily_brief"], false)
            XCTAssertEqual(dto.categories["reminders"], false)
            XCTAssertTrue(dto.showContent)
        }
    }
}
