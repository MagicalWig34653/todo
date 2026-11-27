import Fluent
import Foundation
import SQLKit
import XCTVapor
@testable import TodoKit

/// Cost efficiency, phase 1 (card 71FD73CF, contracts/usage.yaml): idempotent usage reports, rights, metrics,
/// thresholds, verdict, settings, cross-cutting rules. Black box over REST and MCP.
final class UsageTests: XCTestCase {
    private typealias Obj = [String: Any]

    // MARK: Fixture

    private func fixture(_ run: (OAuthFixture) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { try await run(f) } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func account(_ f: OAuthFixture, _ name: String) async throws -> (user: User, session: String) {
        let u = User(displayName: name, isAdmin: false); try await u.save(on: f.test.app.db)
        let session = AuthSupport.randomToken()
        try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
        return (u, session)
    }

    private func row(_ day: String = "2026-03-10", _ session: String = "s1", _ model: String = "claude-opus-5-5",
                     provider: String = "claude", input: Int = 0, output: Int = 0, write: Int = 0, read: Int = 0, extra: Obj = [:]) -> Obj {
        var r: Obj = ["day": day, "sessionKey": session, "model": model, "provider": provider,
                      "inputTokens": input, "outputTokens": output, "cacheWriteTokens": write, "cacheReadTokens": read]
        for (k, v) in extra { r[k] = v }
        return r
    }

    @discardableResult
    private func report(_ f: OAuthFixture, _ rows: [Obj], session: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> Obj {
        let r = try await f.test.json(.POST, "/v1/usage", ["rows": rows], token: session ?? f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
        return r.body ?? [:]
    }

    private func rejected(_ f: OAuthFixture, _ body: Obj, _ reason: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await f.test.json(.POST, "/v1/usage", body, token: f.session)
        XCTAssertEqual(r.status, .badRequest, "\(r.body ?? [:])", file: file, line: line)
        XCTAssertEqual(r.body?["reason"] as? String, reason, file: file, line: line)
    }

    private func summary(_ f: OAuthFixture, days: Int = 7, until: String = "2026-03-14", session: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> Obj {
        let r = try await f.test.json(.GET, "/v1/usage/summary?days=\(days)&until=\(until)", token: session ?? f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
        return r.body ?? [:]
    }

    private func settings(_ f: OAuthFixture, _ body: Obj, session: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await f.test.json(.PUT, "/v1/usage/settings", body, token: session ?? f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
    }

    private func count(_ f: OAuthFixture, _ table: String = "usage_daily") async throws -> Int {
        let sql = try XCTUnwrap(f.test.app.db as? any SQLDatabase)
        let rows = try await sql.raw("SELECT COUNT(*) AS n FROM \(unsafeRaw: table)").all()
        return try XCTUnwrap(rows.first).decode(column: "n", as: Int.self)
    }

    private func number(_ value: Any?, _ expected: Double, _ label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let n = (value as? NSNumber)?.doubleValue else { return XCTFail("missing number \(label): \(String(describing: value))", file: file, line: line) }
        XCTAssertEqual(n, expected, accuracy: 1e-9, label, file: file, line: line)
    }

    private func metric(_ body: Obj, _ id: String) -> Obj { (body["metrics"] as? [Obj])?.first { $0["id"] as? String == id } ?? [:] }
    private func rating(_ body: Obj, _ id: String) -> String? { metric(body, id)["rating"] as? String }
    private func verdict(_ body: Obj) -> Obj { body["verdict"] as? Obj ?? [:] }
    private func sessions(_ body: Obj) -> [Obj] { body["sessions"] as? [Obj] ?? [] }
    private func projects(_ body: Obj) -> [Obj] { body["projects"] as? [Obj] ?? [] }

    private func instant(_ day: String) -> Date { ISO8601DateFormatter().date(from: day + "T12:00:00Z")! }

    private func card(_ f: OAuthFixture, in project: Project, status: String = "done", changed day: String) async throws {
        let t = TodoTask(ownerID: project.ownerID, projectID: try project.requireID(), title: "Card", status: status)
        try await t.save(on: f.test.app.db)
        let sql = try XCTUnwrap(f.test.app.db as? any SQLDatabase)
        try await sql.raw("UPDATE tasks SET updated_at = \(bind: instant(day)) WHERE id = \(bind: try t.requireID())").run()
    }

    /// The hand-calculated data set (current window 2026-03-08...14, previous 2026-03-01...07).
    /// opus s1: 4 + (1.5*5 + 0.5*8 = 11.5) + 1.4 + 2 = 18.9; sonnet s2: 1 + 0 + 0.45 + 2 = 3.45; codex s3: unpriced.
    /// previous p1: 5M opus input = 20.
    private func seed(_ f: OAuthFixture) async throws {
        let pid = try f.project.requireID().uuidString
        try await report(f, [
            row("2026-03-10", "s1", "claude-opus-5-5", input: 1_000_000, output: 100_000, write: 2_000_000, read: 7_000_000,
                extra: ["cacheWrite1hTokens": 500_000, "turns": 100, "maxContextTokens": 150_000, "projectID": pid, "commits": 2, "cardUpdates": 1]),
            row("2026-03-11", "s2", "claude-sonnet-5-5-20260101", input: 500_000, output: 200_000, read: 4_500_000,
                extra: ["subagent": true, "commits": 0, "cardUpdates": 0]),
            row("2026-03-11", "s3", "gpt-6-codex", provider: "codex", input: 1_000_000, output: 100_000, read: 1_000_000, extra: ["turns": 10]),
            row("2026-03-05", "p1", "claude-opus-5-5", input: 5_000_000, extra: ["turns": 50, "projectID": pid]),
        ])
        try await card(f, in: f.project, changed: "2026-03-10")
        try await card(f, in: f.project, changed: "2026-03-14")
        try await card(f, in: f.project, changed: "2026-03-04")
        try await card(f, in: f.project, status: "open", changed: "2026-03-10")
        try await card(f, in: f.project, changed: "2026-02-10")
        try await card(f, in: f.other, changed: "2026-03-10") // project without usage
    }

    // MARK: Formulas

    func testSummaryFormulasMatchTheHandCalculation() async throws {
        try await fixture { f in
            try await seed(f)
            let s = try await summary(f)
            XCTAssertEqual(s["from"] as? String, "2026-03-08"); XCTAssertEqual(s["until"] as? String, "2026-03-14")
            XCTAssertEqual(s["days"] as? Int, 7); XCTAssertEqual(s["partial"] as? Bool, false)
            XCTAssertEqual(s["hasData"] as? Bool, true); XCTAssertEqual(s["hasAnyData"] as? Bool, true)
            number(s["totalCostUSD"], 22.35, "total"); number(s["previousCostUSD"], 20, "previous total")
            XCTAssertEqual((s["metrics"] as? [Obj])?.compactMap { $0["id"] as? String },
                           ["costPerDay", "cacheHitRate", "cacheWriteCostShare", "outputShare", "contextPerTurn", "opusCostShare", "costPerDoneCard", "idleCostShare"])

            number(metric(s, "costPerDay")["value"], 11.175); number(metric(s, "costPerDay")["previous"], 20)
            number(metric(s, "costPerDay")["change"], -0.44125); XCTAssertEqual(rating(s, "costPerDay"), "good")
            number(metric(s, "cacheHitRate")["value"], 12.5 / 17); XCTAssertEqual(rating(s, "cacheHitRate"), "bad")
            number(metric(s, "cacheHitRate")["previous"], 0); XCTAssertNil(metric(s, "cacheHitRate")["change"])
            number(metric(s, "cacheWriteCostShare")["value"], 11.5 / 22.35); XCTAssertEqual(rating(s, "cacheWriteCostShare"), "medium")
            number(metric(s, "outputShare")["value"], 0.4 / 17.4); XCTAssertEqual(rating(s, "outputShare"), "info")
            number(metric(s, "contextPerTurn")["value"], 12_000_000.0 / 110); XCTAssertEqual(rating(s, "contextPerTurn"), "medium")
            number(metric(s, "contextPerTurn")["previous"], 100_000)
            number(metric(s, "opusCostShare")["value"], 18.9 / 22.35); XCTAssertEqual(rating(s, "opusCostShare"), "info")
            number(metric(s, "costPerDoneCard")["value"], 9.45); number(metric(s, "costPerDoneCard")["previous"], 20)
            number(metric(s, "costPerDoneCard")["change"], (9.45 - 20) / 20); XCTAssertEqual(rating(s, "costPerDoneCard"), "good")
            number(metric(s, "idleCostShare")["value"], 3.45 / 22.35); XCTAssertEqual(rating(s, "idleCostShare"), "bad")
            XCTAssertNil(metric(s, "idleCostShare")["previous"])

            XCTAssertEqual(verdict(s)["rating"] as? String, "bad")
            XCTAssertEqual(verdict(s)["best"] as? String, "costPerDay")
            XCTAssertEqual(verdict(s)["worst"] as? String, "cacheHitRate")
            XCTAssertEqual(verdict(s)["lever"] as? String, "cacheHitRate")
            XCTAssertEqual(s["unpricedModels"] as? [String], ["gpt-6-codex"])

            let series = try XCTUnwrap(s["series"] as? [Obj])
            XCTAssertEqual(series.compactMap { $0["day"] as? String }, (8...14).map { String(format: "2026-03-%02d", $0) })
            number(series[0]["costUSD"], 0); number(series[2]["costUSD"], 18.9); number(series[3]["costUSD"], 3.45)
            let parts = try XCTUnwrap(series[2]["parts"] as? Obj)
            number(parts["input"], 4); number(parts["cacheWrite"], 11.5); number(parts["cacheRead"], 1.4); number(parts["output"], 2)

            let models = try XCTUnwrap(s["models"] as? [Obj])
            XCTAssertEqual(models.compactMap { $0["family"] as? String }, ["opus", "sonnet", "codex"])
            number(models[0]["costUSD"], 18.9); number(models[0]["share"], 18.9 / 22.35); XCTAssertEqual(models[0]["tokens"] as? Int, 10_100_000)
            XCTAssertEqual(models[2]["tokens"] as? Int, 2_100_000)

            let list = sessions(s)
            XCTAssertEqual(list.compactMap { $0["sessionKey"] as? String }, ["s1", "s2", "s3"])
            XCTAssertEqual(list[0]["projectName"] as? String, "Allowed"); XCTAssertEqual(list[0]["turns"] as? Int, 100)
            XCTAssertEqual(list[0]["maxContextTokens"] as? Int, 150_000); XCTAssertEqual(list[0]["commits"] as? Int, 2)
            XCTAssertEqual(list[0]["cardUpdates"] as? Int, 1); XCTAssertEqual(list[0]["idle"] as? Bool, false)
            XCTAssertEqual(list[0]["subagent"] as? Bool, false); XCTAssertEqual(list[0]["models"] as? [String], ["claude-opus-5-5"])
            XCTAssertEqual(list[1]["idle"] as? Bool, true); XCTAssertEqual(list[1]["subagent"] as? Bool, true)
            XCTAssertNil(list[1]["projectID"]); XCTAssertEqual(list[1]["commits"] as? Int, 0)
            XCTAssertNil(list[2]["commits"]); XCTAssertNil(list[2]["cardUpdates"]); XCTAssertEqual(list[2]["idle"] as? Bool, false)

            let p = projects(s)
            XCTAssertEqual(p.count, 2)
            XCTAssertEqual(p[0]["projectName"] as? String, "Allowed"); number(p[0]["costUSD"], 18.9)
            XCTAssertEqual(p[0]["doneCards"] as? Int, 2); number(p[0]["costPerDoneCard"], 9.45)
            XCTAssertNil(p[1]["projectID"]); number(p[1]["costUSD"], 3.45); XCTAssertEqual(p[1]["doneCards"] as? Int, 0)
            XCTAssertNil(p[1]["costPerDoneCard"])
        }
    }

    func testEmptyAccountAndUnknownMetrics() async throws {
        try await fixture { f in
            var s = try await summary(f)
            XCTAssertEqual(s["hasData"] as? Bool, false); XCTAssertEqual(s["hasAnyData"] as? Bool, false)
            number(s["totalCostUSD"], 0); XCTAssertNil(s["previousCostUSD"])
            XCTAssertEqual((s["metrics"] as? [Obj])?.count, 8)
            for m in s["metrics"] as? [Obj] ?? [] { XCTAssertEqual(m["rating"] as? String, "unknown", "\(m)"); XCTAssertNil(m["value"], "\(m)") }
            XCTAssertEqual(verdict(s)["rating"] as? String, "unknown"); XCTAssertNil(verdict(s)["best"]); XCTAssertNil(verdict(s)["lever"])
            XCTAssertEqual((s["series"] as? [Obj])?.count, 7)
            try await report(f, [row("2026-01-02", input: 1)])
            s = try await summary(f)
            XCTAssertEqual(s["hasData"] as? Bool, false); XCTAssertEqual(s["hasAnyData"] as? Bool, true)
            // Data without a previous window: values, but no trend rating.
            s = try await summary(f, days: 1, until: "2026-01-02")
            XCTAssertEqual(rating(s, "costPerDay"), "unknown"); number(metric(s, "costPerDay")["value"], 4.0 / 1_000_000)
            XCTAssertEqual((s["series"] as? [Obj])?.count, 1)
            let today = try await f.test.json(.GET, "/v1/usage/summary", token: f.session)
            XCTAssertEqual(today.body?["days"] as? Int, 7); XCTAssertEqual(today.body?["partial"] as? Bool, true)
        }
    }

    func testSummaryParameterValidation() async throws {
        try await fixture { f in
            for (query, reason) in [("days=2", "invalid_days"), ("days=x", "invalid_days"), ("days=90", "invalid_days"),
                                    ("until=2026-02-30", "invalid_until"), ("until=14.03.2026", "invalid_until"), ("until=x", "invalid_until")] {
                let r = try await f.test.json(.GET, "/v1/usage/summary?\(query)", token: f.session)
                XCTAssertEqual(r.status, .badRequest, query); XCTAssertEqual(r.body?["reason"] as? String, reason, query)
            }
            let thirty = try await summary(f, days: 30)
            XCTAssertEqual(thirty["from"] as? String, "2026-02-13")
        }
    }

    func testOnlyTenMostExpensiveSessions() async throws {
        try await fixture { f in
            try await report(f, (1...12).map { row("2026-03-10", "s\($0)", input: $0 * 1000) })
            let s = try await summary(f)
            XCTAssertEqual(sessions(s).count, 10)
            XCTAssertEqual(sessions(s).first?["sessionKey"] as? String, "s12")
            XCTAssertEqual(sessions(s).last?["sessionKey"] as? String, "s3")
        }
    }

    func testModelMatchingByLongestPrefixAndFamilies() async throws {
        try await fixture { f in
            let r = try await report(f, [
                row("2026-03-10", "a", "CLAUDE-OPUS-5-5[1m]", input: 1_000_000),          // 4
                row("2026-03-10", "b", "claude-haiku-5-5-20260101", input: 1_000_000),    // 0.1
                row("2026-03-10", "c", "claude-fable-5-2", input: 1_000_000),             // 8
                row("2026-03-10", "d", "claude-opus-5-5-fast", input: 1_000_000),         // unpriced suffix
                row("2026-03-10", "e", "claude-opus-5-50", input: 1_000_000),             // unpriced
                row("2026-03-10", "g", "something", input: 1_000_000),
            ])
            number(r["costUSD"], 12.1)
            XCTAssertEqual(r["unpricedModels"] as? [String], ["claude-opus-5-5-fast", "claude-opus-5-50", "something"])
            let s = try await summary(f)
            XCTAssertEqual((s["models"] as? [Obj])?.compactMap { $0["family"] as? String }, ["fable", "opus", "haiku", "other"])
            // The longest matching entry wins.
            try await settings(f, ["prices": [price("claude-opus-5-5-fast", input: 100), price("claude-opus", input: 1),
                                              price("claude-haiku-5-5-20260101", input: 0.2)]])
            let after = try await summary(f)
            number(after["totalCostUSD"], 112.2)
        }
    }

    private func price(_ model: String, input: Double = 0, write: Double = 0, write1h: Double = 0, read: Double = 0, output: Double = 0) -> Obj {
        ["model": model, "input": input, "cacheWrite": write, "cacheWrite1h": write1h, "cacheRead": read, "output": output]
    }

    // MARK: Thresholds and verdict

    /// One day, one session; returns the summary of days=1.
    private func single(_ f: OAuthFixture, _ rows: [Obj], day: String) async throws -> Obj {
        try await report(f, rows)
        return try await summary(f, days: 1, until: day)
    }

    func testDefaultThresholdBoundaries() async throws {
        try await fixture { f in
            // cacheHit 92 % good, 85 % medium, below bad.
            var s = try await single(f, [row("2026-03-01", input: 8, read: 92)], day: "2026-03-01")
            XCTAssertEqual(rating(s, "cacheHitRate"), "good")
            s = try await single(f, [row("2026-03-03", input: 15, read: 85)], day: "2026-03-03")
            XCTAssertEqual(rating(s, "cacheHitRate"), "medium")
            s = try await single(f, [row("2026-03-05", input: 16, read: 84)], day: "2026-03-05")
            XCTAssertEqual(rating(s, "cacheHitRate"), "bad")
            // Cache write share of cost (sonnet: input 2, write 2.5): 45 % medium, 65 % medium, above bad, below good.
            s = try await single(f, [row("2026-03-07", "w", "claude-sonnet-5-5", input: 55_000, write: 36_000)], day: "2026-03-07")
            number(metric(s, "cacheWriteCostShare")["value"], 0.45); XCTAssertEqual(rating(s, "cacheWriteCostShare"), "medium")
            s = try await single(f, [row("2026-03-09", "w", "claude-sonnet-5-5", input: 35_000, write: 52_000)], day: "2026-03-09")
            number(metric(s, "cacheWriteCostShare")["value"], 0.65); XCTAssertEqual(rating(s, "cacheWriteCostShare"), "medium")
            s = try await single(f, [row("2026-03-11", "w", "claude-sonnet-5-5", input: 34_000, write: 52_800)], day: "2026-03-11")
            XCTAssertEqual(rating(s, "cacheWriteCostShare"), "bad")
            s = try await single(f, [row("2026-03-13", "w", "claude-sonnet-5-5", input: 60_000, write: 32_000)], day: "2026-03-13")
            XCTAssertEqual(rating(s, "cacheWriteCostShare"), "good")
            // Context per turn.
            for (day, tokens, expected) in [("2026-04-01", 59_999, "good"), ("2026-04-03", 60_000, "medium"),
                                            ("2026-04-05", 120_000, "medium"), ("2026-04-07", 120_001, "bad")] {
                s = try await single(f, [row(day, input: tokens, extra: ["turns": 1])], day: day)
                XCTAssertEqual(rating(s, "contextPerTurn"), expected, day)
            }
            // Idle share.
            for (day, idle, expected) in [("2026-05-01", 4, "good"), ("2026-05-03", 5, "medium"),
                                          ("2026-05-05", 15, "medium"), ("2026-05-07", 16, "bad")] {
                s = try await single(f, [row(day, "idle", input: idle * 1000, extra: ["commits": 0]),
                                         row(day, "busy", input: (100 - idle) * 1000, extra: ["cardUpdates": 1]),
                                         row(day, "unknown", input: 500_000)], day: day)
                number(metric(s, "idleCostShare")["value"], Double(idle) / 100, day); XCTAssertEqual(rating(s, "idleCostShare"), expected, day)
            }
            // Cost trend against the previous day (previous 100 units).
            for (month, current, expected) in [("06", 94, "good"), ("07", 95, "medium"), ("08", 115, "medium"), ("09", 116, "bad")] {
                s = try await single(f, [row("2026-\(month)-01", input: 100_000), row("2026-\(month)-02", input: current * 1000)], day: "2026-\(month)-02")
                XCTAssertEqual(rating(s, "costPerDay"), expected, month)
            }
        }
    }

    func testCardTrendThresholdAndUnknownWithoutPreviousCards() async throws {
        try await fixture { f in
            let pid = try f.project.requireID().uuidString
            try await report(f, [row("2026-03-01", input: 100_000, extra: ["projectID": pid]),
                                 row("2026-03-02", input: 106_000, extra: ["projectID": pid])])
            try await card(f, in: f.project, changed: "2026-03-02")
            var s = try await summary(f, days: 1, until: "2026-03-02")
            XCTAssertEqual(rating(s, "costPerDoneCard"), "unknown"); number(metric(s, "costPerDoneCard")["value"], 0.424)
            try await card(f, in: f.project, changed: "2026-03-01")
            s = try await summary(f, days: 1, until: "2026-03-02")
            XCTAssertEqual(rating(s, "costPerDoneCard"), "bad")
            try await report(f, [row("2026-03-02", input: 105_000, extra: ["projectID": pid])])
            s = try await summary(f, days: 1, until: "2026-03-02")
            XCTAssertEqual(rating(s, "costPerDoneCard"), "medium")
        }
    }

    func testOpusTargetAndThresholdSettingsRecalculate() async throws {
        try await fixture { f in
            try await seed(f)
            try await settings(f, ["thresholds": ["cacheHitGoodPercent": 70, "cacheHitMediumPercent": 60, "opusTargetPercent": 80,
                                                  "idleGoodPercent": 20, "idleBadPercent": 30]])
            var s = try await summary(f)
            XCTAssertEqual(rating(s, "cacheHitRate"), "good"); XCTAssertEqual(rating(s, "opusCostShare"), "medium")
            XCTAssertEqual(rating(s, "idleCostShare"), "good")
            XCTAssertEqual(verdict(s)["rating"] as? String, "medium")
            XCTAssertEqual(verdict(s)["best"] as? String, "cacheHitRate")
            XCTAssertEqual(verdict(s)["worst"] as? String, "cacheWriteCostShare")
            XCTAssertEqual(verdict(s)["lever"] as? String, "cacheWriteCostShare")
            try await settings(f, ["thresholds": ["opusTargetPercent": 90]])
            s = try await summary(f)
            XCTAssertEqual(rating(s, "opusCostShare"), "good"); XCTAssertEqual(rating(s, "cacheHitRate"), "bad", "omitted thresholds are defaults again")
            try await settings(f, ["thresholds": ["opusTargetPercent": 60]])
            s = try await summary(f)
            XCTAssertEqual(rating(s, "opusCostShare"), "bad")
            // Exactly target and target + 15 points.
            try await report(f, [row("2026-07-01", "o", "claude-opus-5-5", input: 250_000), row("2026-07-01", "n", "claude-sonnet-5-5", input: 500_000)])
            try await settings(f, ["thresholds": ["opusTargetPercent": 50]])
            s = try await summary(f, days: 1, until: "2026-07-01")
            XCTAssertEqual(rating(s, "opusCostShare"), "good")
            try await settings(f, ["thresholds": ["opusTargetPercent": 35]])
            s = try await summary(f, days: 1, until: "2026-07-01")
            XCTAssertEqual(rating(s, "opusCostShare"), "medium")
        }
    }

    func testVerdictGoodAndSingleBadIsMedium() async throws {
        try await fixture { f in
            // Good: only cacheHit and context rated, both good; a single medium stays good.
            var s = try await single(f, [row("2026-03-01", input: 5, read: 95, extra: ["turns": 1])], day: "2026-03-01")
            XCTAssertEqual(verdict(s)["rating"] as? String, "good"); XCTAssertEqual(verdict(s)["best"] as? String, "cacheHitRate")
            XCTAssertNil(verdict(s)["worst"]); XCTAssertNil(verdict(s)["lever"])
            s = try await single(f, [row("2026-03-03", input: 10_000, read: 90_000, extra: ["turns": 10])], day: "2026-03-03")
            XCTAssertEqual(verdict(s)["rating"] as? String, "good"); XCTAssertEqual(verdict(s)["worst"] as? String, "cacheHitRate")
            // Exactly one bad.
            s = try await single(f, [row("2026-03-05", input: 50, read: 50, extra: ["turns": 1])], day: "2026-03-05")
            XCTAssertEqual(verdict(s)["rating"] as? String, "medium"); XCTAssertEqual(verdict(s)["worst"] as? String, "cacheHitRate")
        }
    }

    // MARK: Settings

    func testSettingsDefaultsOverridesAndRetroactivePrices() async throws {
        try await fixture { f in
            let initial = try await f.test.json(.GET, "/v1/usage/settings", token: f.session)
            XCTAssertEqual(initial.status, .ok)
            let prices = try XCTUnwrap(initial.body?["prices"] as? [Obj])
            XCTAssertEqual(prices.compactMap { $0["model"] as? String },
                           ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
            XCTAssertTrue(prices.allSatisfy { $0["custom"] as? Bool == false })
            number(prices[0]["input"], 8); number(prices[0]["cacheWrite"], 10); number(prices[0]["cacheWrite1h"], 16)
            number(prices[0]["cacheRead"], 0.2); number(prices[0]["output"], 40)
            number(prices[1]["input"], 4); number(prices[1]["cacheWrite"], 5); number(prices[1]["cacheWrite1h"], 8)
            number(prices[1]["cacheRead"], 0.2); number(prices[1]["output"], 20)
            number(prices[2]["input"], 2); number(prices[2]["cacheWrite"], 2.5); number(prices[2]["cacheWrite1h"], 4)
            number(prices[2]["cacheRead"], 0.1); number(prices[2]["output"], 10)
            number(prices[3]["input"], 0.1); number(prices[3]["cacheWrite"], 0.125); number(prices[3]["cacheWrite1h"], 0.2)
            number(prices[3]["cacheRead"], 0.01); number(prices[3]["output"], 0.5)
            let thresholds = try XCTUnwrap(initial.body?["thresholds"] as? Obj)
            for (key, value) in ["costTrendGoodPercent": -5.0, "costTrendBadPercent": 15, "cacheHitGoodPercent": 92, "cacheHitMediumPercent": 85,
                                 "cacheWriteGoodPercent": 45, "cacheWriteBadPercent": 65, "contextGoodTokens": 60000, "contextBadTokens": 120_000,
                                 "cardTrendPercent": 5, "idleGoodPercent": 5, "idleBadPercent": 15] {
                number(thresholds[key], value, key)
            }
            XCTAssertNil(thresholds["opusTargetPercent"]); XCTAssertEqual(thresholds.count, 11)

            try await seed(f)
            let changed = try await f.test.json(.PUT, "/v1/usage/settings", ["prices": [
                price("gpt-6-codex", input: 1, read: 0.1, output: 8),
                price("Claude-Opus-5-5", input: 8, write: 5, write1h: 8, read: 0.2, output: 20),
            ]], token: f.session)
            XCTAssertEqual(changed.status, .ok, "\(changed.body ?? [:])")
            let effective = try XCTUnwrap(changed.body?["prices"] as? [Obj])
            XCTAssertEqual(effective.count, 5, "an own entry replaces the default with the same prefix")
            XCTAssertEqual(effective.filter { $0["custom"] as? Bool == true }.count, 2)
            var s = try await summary(f)
            number(s["totalCostUSD"], 22.35 + 4 + 1.9); number(s["previousCostUSD"], 40)
            XCTAssertEqual(s["unpricedModels"] as? [String], [])
            // Replace semantics: an empty body restores all defaults.
            try await settings(f, [:])
            s = try await summary(f)
            number(s["totalCostUSD"], 22.35)
            let left = try await count(f, "usage_settings")
            XCTAssertLessThanOrEqual(left, 1)
        }
    }

    func testSettingsValidation() async throws {
        try await fixture { f in
            func refuse(_ body: Obj, _ reason: String, line: UInt = #line) async throws {
                let r = try await f.test.json(.PUT, "/v1/usage/settings", body, token: f.session)
                XCTAssertEqual(r.status, .badRequest, "\(r.body ?? [:])", line: line)
                XCTAssertEqual(r.body?["reason"] as? String, reason, line: line)
            }
            try await refuse(["foo": 1], "unknown_field")
            try await refuse(["thresholds": ["foo": 1]], "unknown_field")
            var extra = price("x"); extra["foo"] = 1
            try await refuse(["prices": [extra]], "unknown_field")
            try await refuse(["prices": [["model": "x", "input": 1]]], "invalid_prices")
            try await refuse(["prices": [price("bad name")]], "invalid_prices")
            try await refuse(["prices": [price("x", input: -1)]], "invalid_prices")
            try await refuse(["prices": [price("x", output: 10001)]], "invalid_prices")
            try await refuse(["prices": [price("x"), price("X")]], "invalid_prices")
            try await refuse(["prices": (0...100).map { price("m\($0)") }], "invalid_prices")
            try await refuse(["prices": "x"], "invalid_prices")
            try await refuse(["thresholds": ["cacheHitGoodPercent": 101]], "invalid_thresholds")
            try await refuse(["thresholds": ["cacheHitGoodPercent": "90"]], "invalid_thresholds")
            try await refuse(["thresholds": ["cacheHitGoodPercent": 50]], "invalid_thresholds")
            try await refuse(["thresholds": ["contextGoodTokens": -1]], "invalid_thresholds")
            try await refuse(["thresholds": ["idleGoodPercent": 20]], "invalid_thresholds")
            let stored = try await count(f, "usage_settings")
            XCTAssertEqual(stored, 0)
        }
    }

    func testSettingsAndRowsBelongToTheAccount() async throws {
        try await fixture { f in
            try await seed(f)
            let b = try await account(f, "B")
            try await settings(f, ["prices": [price("claude-opus-5-5", input: 1000)]], session: b.session)
            let mine = try await summary(f)
            number(mine["totalCostUSD"], 22.35)
            let theirs = try await summary(f, session: b.session)
            XCTAssertEqual(theirs["hasAnyData"] as? Bool, false); XCTAssertEqual(sessions(theirs).count, 0); XCTAssertEqual(projects(theirs).count, 0)
            // Same key from another account is its own row.
            let r = try await report(f, [row("2026-03-10", "s1", input: 1)], session: b.session)
            XCTAssertEqual(r["created"] as? Int, 1); XCTAssertEqual(r["updated"] as? Int, 0)
            let again = try await summary(f)
            number(again["totalCostUSD"], 22.35)
        }
    }

    // MARK: Idempotency

    func testRepeatedReportReplacesAndNeverAdds() async throws {
        try await fixture { f in
            let rows = [row(input: 1_000_000, extra: ["turns": 5, "commits": 1, "cardUpdates": 2, "projectID": try f.project.requireID().uuidString, "subagent": true]),
                        row("2026-03-11", input: 1_000_000)]
            let first = try await report(f, rows)
            XCTAssertEqual(first["stored"] as? Int, 2); XCTAssertEqual(first["created"] as? Int, 2); XCTAssertEqual(first["updated"] as? Int, 0)
            number(first["costUSD"], 8)
            XCTAssertEqual((first["unassigned"] as? [Obj])?.count, 0); XCTAssertEqual(first["unpricedModels"] as? [String], [])
            let second = try await report(f, rows)
            XCTAssertEqual(second["created"] as? Int, 0); XCTAssertEqual(second["updated"] as? Int, 2)
            var s = try await summary(f)
            number(s["totalCostUSD"], 8)
            let stored = try await count(f)
            XCTAssertEqual(stored, 2)
            // A new report replaces the whole row: omitted optional fields are "not reported".
            let third = try await report(f, [row(input: 500_000)])
            XCTAssertEqual(third["updated"] as? Int, 1)
            s = try await summary(f)
            number(s["totalCostUSD"], 6)
            let entry = try XCTUnwrap(sessions(s).first)
            XCTAssertNil(entry["commits"]); XCTAssertNil(entry["cardUpdates"]); XCTAssertNil(entry["projectID"])
            XCTAssertEqual(entry["turns"] as? Int, 0); XCTAssertEqual(entry["subagent"] as? Bool, false)
            XCTAssertEqual(rating(s, "idleCostShare"), "unknown")
        }
    }

    func testModelAndSessionKeyAreCaseSensitiveKeys() async throws {
        try await fixture { f in
            let r = try await report(f, [row("2026-03-10", "abc", input: 1), row("2026-03-10", "ABC", input: 1)])
            XCTAssertEqual(r["created"] as? Int, 2)
            let stored = try await count(f)
            XCTAssertEqual(stored, 2)
        }
    }

    func testParallelIdenticalReportsNeverDuplicateOrFail() async throws {
        try await fixture { f in
            let rows = (0..<40).map { row("2026-03-10", "p\($0)", input: 1000) }
            let body = try JSONSerialization.data(withJSONObject: ["rows": rows])
            let test = f.test, token = f.session
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for _ in 0..<8 { group.addTask { try await test.rawStatus(.POST, "/v1/usage", body: body, token: token) } }
                var all: [HTTPStatus] = []
                for try await s in group { all.append(s) }
                return all
            }
            XCTAssertEqual(statuses, Array(repeating: .ok, count: 8))
            let stored = try await count(f)
            XCTAssertEqual(stored, 40)
        }
    }

    // MARK: Validation

    /// Review finding (card 71FD73CF): without a cap the account export and the summary grow without bound.
    func testStoredRowsPerAccountAreCappedAndTheOldestDaysGoFirst() async throws {
        try await fixture { f in
            XCTAssertEqual(UsageService.defaultMaxStoredRows, 20_000)
            let other = try await account(f, "Other")
            try await report(f, [row("2026-03-01", "keep")], session: other.session)
            var service = UsageService(user: f.user, db: f.test.app.db)
            service.maxStoredRows = 3
            func send(_ rows: [Obj]) async throws {
                let data = try JSONSerialization.data(withJSONObject: ["rows": rows])
                _ = try await service.report(try JSONDecoder().decode(JSONValue.self, from: data))
            }
            func days() async throws -> [String] {
                try await UsageDaily.query(on: f.test.app.db).filter(\.$userID == f.user.requireID()).all().map(\.day).sorted()
            }
            try await send([row("2026-03-02"), row("2026-03-01"), row("2026-03-03")])
            try await send([row("2026-03-05"), row("2026-03-04")])
            let kept = try await days()
            XCTAssertEqual(kept, ["2026-03-03", "2026-03-04", "2026-03-05"])
            // Replacing an existing row at the cap removes nothing.
            try await send([row("2026-03-03", input: 5)])
            let unchanged = try await days()
            XCTAssertEqual(unchanged, kept)
            let all = try await count(f)
            XCTAssertEqual(all, 4, "the other account keeps its row")
        }
    }

    func testDuplicateRowsInOneCallAreRejectedAtomically() async throws {
        try await fixture { f in
            try await rejected(f, ["rows": [row("2026-03-09", input: 1), row(input: 1), row(input: 2)]], "duplicate_row")
            let stored = try await count(f)
            XCTAssertEqual(stored, 0)
        }
    }

    func testUnknownFieldsAndInvalidValues() async throws {
        try await fixture { f in
            try await rejected(f, ["rows": [row()], "note": "x"], "unknown_field")
            try await rejected(f, ["rows": [row(extra: ["title": "secret"])]], "unknown_field")
            try await rejected(f, [:], "invalid_rows")
            try await rejected(f, ["rows": [Obj]()], "invalid_rows")
            try await rejected(f, ["rows": "x"], "invalid_rows")
            try await rejected(f, ["rows": [1]], "invalid_rows")
            try await rejected(f, ["rows": (0..<501).map { row("2026-03-10", "s\($0)") }], "invalid_rows")
            let tomorrow = Self.day(offset: 1), later = Self.day(offset: 2)
            let cases: [(String, Any, String)] = [
                ("day", "2019-12-31", "invalid_day"), ("day", "2026-02-30", "invalid_day"), ("day", "10.03.2026", "invalid_day"),
                ("day", later, "invalid_day"), ("day", NSNull(), "invalid_day"),
                ("sessionKey", "", "invalid_sessionKey"), ("sessionKey", "a b", "invalid_sessionKey"),
                ("sessionKey", String(repeating: "a", count: 129), "invalid_sessionKey"), ("sessionKey", "ä", "invalid_sessionKey"),
                ("model", "", "invalid_model"), ("model", String(repeating: "m", count: 81), "invalid_model"), ("model", "a b", "invalid_model"),
                ("provider", "openai", "invalid_provider"),
                ("inputTokens", -1, "invalid_inputTokens"), ("inputTokens", 1.5, "invalid_inputTokens"), ("inputTokens", "1", "invalid_inputTokens"),
                ("inputTokens", 1_000_000_000_001, "invalid_inputTokens"), ("outputTokens", true, "invalid_outputTokens"),
                ("cacheWriteTokens", -1, "invalid_cacheWriteTokens"), ("cacheReadTokens", NSNull(), "invalid_cacheReadTokens"),
                ("cacheWrite1hTokens", 1, "invalid_cacheWrite1hTokens"), ("turns", 1_000_001, "invalid_turns"),
                ("maxContextTokens", 1_000_000_001, "invalid_maxContextTokens"), ("subagent", 1, "invalid_subagent"),
                ("projectID", "x", "invalid_projectID"), ("repository", String(repeating: "r", count: 301), "invalid_repository"),
                ("repository", "has space", "invalid_repository"), ("commits", -1, "invalid_commits"), ("cardUpdates", 100_001, "invalid_cardUpdates"),
            ]
            for (key, value, reason) in cases {
                try await rejected(f, ["rows": [row(), row("2026-03-11", extra: [key: value])]], reason)
            }
            var missing = row(); missing.removeValue(forKey: "outputTokens")
            try await rejected(f, ["rows": [missing]], "invalid_outputTokens")
            let stored = try await count(f)
            XCTAssertEqual(stored, 0, "a call is atomic")
            // Limits that must pass, including token counts far above 32 bit.
            let r = try await report(f, [row(tomorrow, "A.b_c:d/e#f-1", "x[1m]", input: 1_000_000_000_000, output: 5_000_000_000,
                                             extra: ["projectID": NSNull(), "commits": NSNull()])])
            XCTAssertEqual(r["created"] as? Int, 1)
            try await report(f, [row("2020-01-01")])
        }
    }

    static func day(offset: Int) -> String {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withFullDate]
        return format.string(from: Date().addingTimeInterval(Double(offset) * 86400))
    }

    func testFiveHundredLargeRowsFitAndHugeBodiesAre413() async throws {
        try await fixture { f in
            let repo = "github.com/example/" + String(repeating: "r", count: 175)
            let huge64: Int = 1_000_000_000_000
            let counters: Obj = ["cacheWrite1hTokens": huge64, "turns": 1_000_000, "maxContextTokens": 1_000_000_000, "subagent": true]
            var extra: Obj = counters
            extra["repository"] = repo; extra["commits"] = 100_000; extra["cardUpdates"] = 100_000
            var rows: [Obj] = []
            for i in 0..<500 {
                extra["projectID"] = UUID().uuidString
                let key = String(format: "%0128d", i), model = String(repeating: "m", count: 80)
                rows.append(row("2026-03-10", key, model, input: huge64, output: huge64, write: huge64, read: huge64, extra: extra))
            }
            XCTAssertGreaterThan(try JSONSerialization.data(withJSONObject: ["rows": rows]).count, 256 * 1024)
            let r = try await report(f, rows)
            XCTAssertEqual(r["created"] as? Int, 500); XCTAssertEqual((r["unassigned"] as? [Obj])?.count, 500)
            _ = try await summary(f)
            // A real server enforces the collect limit of the route (the in-process client bypasses it).
            let huge = ByteBuffer(data: Data(repeating: 32, count: 3 * 1024 * 1024))
            try await f.test.app.testable(method: .running(port: 0)).test(.POST, "/v1/usage", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: f.session); req.headers.contentType = .json; req.body = huge
            }, afterResponse: { res async in XCTAssertEqual(res.status, .payloadTooLarge) })
        }
    }

    // MARK: Rights

    func testProjectAssignmentOnlyForReadableProjectsWithoutLeaks() async throws {
        try await fixture { f in
            let b = try await account(f, "B")
            let db = f.test.app.db
            let foreign = Project(ownerID: try b.user.requireID(), parentID: nil, name: "Geheim"); try await foreign.save(on: db)
            let shared = Project(ownerID: try b.user.requireID(), parentID: nil, name: "Geteilt"); try await shared.save(on: db)
            let grant = ProjectGrant(projectID: try shared.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read)
            try await grant.save(on: db)
            try await ProjectRepositoryBinding(projectID: try foreign.requireID(), ownerID: foreign.ownerID, repoKey: "github.com/x/secret", staleAfterDays: 3).save(on: db)
            try await ProjectRepositoryBinding(projectID: try f.project.requireID(), ownerID: f.project.ownerID, repoKey: "github.com/x/mine", staleAfterDays: 3).save(on: db)
            let foreignID = try foreign.requireID().uuidString, unknownID = UUID().uuidString
            let r = try await report(f, [
                row("2026-03-10", "a", input: 1, extra: ["projectID": foreignID]),
                row("2026-03-10", "b", input: 1, extra: ["projectID": unknownID]),
                row("2026-03-10", "c", input: 1, extra: ["repository": "https://github.com/x/secret.git"]),
                row("2026-03-10", "d", input: 1, extra: ["repository": "github.com/x/nothing"]),
                row("2026-03-10", "e", input: 1, extra: ["projectID": try shared.requireID().uuidString]),
                row("2026-03-10", "g", input: 1, extra: ["repository": "git@github.com:X/Mine.git"]),
                // projectID wins over repository, also when it cannot be assigned.
                row("2026-03-10", "h", input: 1, extra: ["projectID": foreignID, "repository": "github.com/x/mine"]),
                row("2026-03-10", "i", input: 1),
            ])
            let unassigned = try XCTUnwrap(r["unassigned"] as? [Obj])
            XCTAssertEqual(unassigned.compactMap { $0["index"] as? Int }, [0, 1, 2, 3, 6])
            XCTAssertEqual(unassigned[0]["projectID"] as? String, foreignID)
            XCTAssertEqual(unassigned[2]["repository"] as? String, "https://github.com/x/secret.git")
            XCTAssertEqual(Set(unassigned[0].keys), Set(unassigned[1].keys), "foreign and unknown look the same")
            XCTAssertEqual(Set(unassigned[2].keys), Set(unassigned[3].keys))
            var s = try await summary(f)
            XCTAssertEqual(Set(projects(s).compactMap { $0["projectName"] as? String }), ["Allowed", "Geteilt"])
            XCTAssertEqual(projects(s).count, 3)
            XCTAssertFalse(String(describing: s).contains("Geheim"))
            // Losing the read right hides the name; the row counts as "without project".
            try await grant.delete(on: db)
            s = try await summary(f)
            XCTAssertEqual(projects(s).compactMap { $0["projectName"] as? String }, ["Allowed"])
            XCTAssertFalse(String(describing: s).contains("Geteilt"))
            XCTAssertFalse(String(describing: s).contains(try shared.requireID().uuidString))
        }
    }

    func testAuthenticationAndCSRF() async throws {
        try await fixture { f in
            for (method, path) in [(HTTPMethod.POST, "/v1/usage"), (.GET, "/v1/usage/summary"), (.GET, "/v1/usage/settings"), (.PUT, "/v1/usage/settings")] {
                let r = try await f.test.json(method, path, method == .GET ? nil : ["rows": [row()]])
                XCTAssertEqual(r.status, .unauthorized, "\(method) \(path)")
            }
            let token = try await f.tokens()
            let oauth = try await f.test.json(.POST, "/v1/usage", ["rows": [row()]], token: token.access)
            XCTAssertEqual(oauth.status, .unauthorized, "OAuth tokens use MCP")
            let body = try JSONSerialization.data(withJSONObject: ["rows": [row()]])
            for (method, path) in [(HTTPMethod.POST, "/v1/usage"), (.PUT, "/v1/usage/settings")] {
                try await f.test.app.test(method, path, beforeRequest: { req in
                    req.headers.add(name: .cookie, value: "\(AuthSupport.cookieName)=\(f.session)")
                    req.headers.add(name: .origin, value: "https://evil.example")
                    req.headers.contentType = .json
                    req.body = ByteBuffer(data: body)
                }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })
            }
            let stored = try await count(f)
            XCTAssertEqual(stored, 0)
        }
    }

    // MARK: MCP

    private func call(_ f: OAuthFixture, _ args: Obj, _ access: String) async throws -> (isError: Bool, text: String, json: Obj) {
        let r = try await f.rpc("tools/call", ["name": "report_usage", "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? Obj, String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [Obj])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? Obj) ?? [:])
    }

    func testReportUsageToolSharesRulesAndRespectsScopeAndGrant() async throws {
        try await fixture { f in
            XCTAssertEqual(MCPController.tools.first { $0.name == "report_usage" }?.scope, "tasks:write")
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let denied = try await call(f, ["rows": [row()]], readOnly.access)
            XCTAssertTrue(denied.isError); XCTAssertEqual(denied.text, "insufficient_scope")
            let token = try await f.tokens()
            let db = f.test.app.db
            try await ProjectRepositoryBinding(projectID: try f.other.requireID(), ownerID: f.other.ownerID, repoKey: "github.com/x/other", staleAfterDays: 3).save(on: db)
            let args: Obj = ["rows": [
                row(input: 3_000_000_000, extra: ["projectID": try f.project.requireID().uuidString]),
                row("2026-03-11", input: 1, extra: ["projectID": try f.other.requireID().uuidString]),
                row("2026-03-12", input: 1, extra: ["repository": "github.com/x/other"]),
            ]]
            let first = try await call(f, args, token.access)
            XCTAssertFalse(first.isError, first.text)
            XCTAssertEqual(first.json["created"] as? Int, 3)
            number(first.json["costUSD"], 12_000.000008)
            XCTAssertEqual((first.json["unassigned"] as? [Obj])?.compactMap { $0["index"] as? Int }, [1, 2], "projects outside the grant")
            let second = try await call(f, args, token.access)
            XCTAssertEqual(second.json["updated"] as? Int, 3)
            let stored = try await count(f)
            XCTAssertEqual(stored, 3)
            let unknown = try await call(f, ["rows": [row(extra: ["prompt": "x"])]], token.access)
            XCTAssertTrue(unknown.isError); XCTAssertEqual(unknown.text, "unknown_field")
            let duplicate = try await call(f, ["rows": [row(), row()]], token.access)
            XCTAssertEqual(duplicate.text, "duplicate_row")
        }
    }

    // MARK: Cross-cutting

    func testAccountDeletionRemovesRowsAndSettings() async throws {
        try await fixture { f in
            let b = try await account(f, "B")
            try await seed(f)
            try await settings(f, ["thresholds": ["idleBadPercent": 30]])
            try await report(f, [row(input: 1)], session: b.session)
            try await settings(f, ["thresholds": ["idleBadPercent": 30]], session: b.session)
            try await AccountDeletion.delete(userID: try f.user.requireID(), on: f.test.app.db)
            let rows = try await count(f), prefs = try await count(f, "usage_settings")
            XCTAssertEqual(rows, 1); XCTAssertEqual(prefs, 1)
        }
    }

    func testAnonymizingRemovesUsageData() async throws {
        try await fixture { f in
            let admin = User(displayName: "Admin", isAdmin: true); try await admin.save(on: f.test.app.db)
            try await report(f, [row(input: 1)])
            try await settings(f, ["thresholds": ["idleBadPercent": 30]])
            let r = try await f.test.json(.POST, "/v1/me/anonymize", ["confirm": AccountLock.confirmation], token: f.session)
            XCTAssertEqual(r.status, .noContent, "\(r.body ?? [:])")
            let rows = try await count(f), prefs = try await count(f, "usage_settings")
            XCTAssertEqual(rows, 0); XCTAssertEqual(prefs, 0)
        }
    }

    func testProjectDeletionKeepsRowsWithoutProject() async throws {
        try await fixture { f in
            try await report(f, [row(input: 1_000_000, extra: ["projectID": try f.project.requireID().uuidString])])
            try await f.project.delete(on: f.test.app.db)
            let s = try await summary(f)
            number(s["totalCostUSD"], 4)
            XCTAssertEqual(projects(s).count, 1); XCTAssertNil(projects(s).first?["projectID"])
        }
    }

    func testExportContainsOwnUsageData() async throws {
        try await fixture { f in
            try await seed(f)
            try await settings(f, ["thresholds": ["idleBadPercent": 30]])
            let b = try await account(f, "B")
            try await report(f, [row("2026-03-10", "foreign-session", input: 1)], session: b.session)
            let r = try await f.test.json(.GET, "/v1/me/export", token: f.session)
            XCTAssertEqual(r.status, .ok)
            let usage = try XCTUnwrap(r.body?["usage"] as? [Obj])
            XCTAssertEqual(usage.count, 4)
            XCTAssertFalse(usage.contains { $0["sessionKey"] as? String == "foreign-session" })
            let s1 = try XCTUnwrap(usage.first { $0["sessionKey"] as? String == "s1" })
            XCTAssertEqual(s1["cacheWrite1hTokens"] as? Int, 500_000); XCTAssertEqual(s1["projectID"] as? String, try f.project.requireID().uuidString)
            let prefs = try XCTUnwrap(r.body?["usageSettings"] as? Obj)
            number((prefs["thresholds"] as? Obj)?["idleBadPercent"], 30)
        }
    }

    func testContractRoutesAreRegistered() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contract = try String(contentsOf: root.appendingPathComponent("contracts/usage.yaml"), encoding: .utf8)
        let app = try await Application.make(.testing)
        do { try routes(app) } catch { try? await app.asyncShutdown(); throw error }
        let registered = Set(app.routes.all.map { r in r.method.rawValue + " /" + r.path.map(\.description).joined(separator: "/") })
        try await app.asyncShutdown()
        for route in ["POST /v1/usage", "GET /v1/usage/summary", "GET /v1/usage/settings", "PUT /v1/usage/settings"] {
            XCTAssertTrue(registered.contains(route), route)
            XCTAssertTrue(contract.contains("  \(route.split(separator: " ")[1]):"), route)
        }
        let oauth = try String(contentsOf: root.appendingPathComponent("contracts/oauth-mcp.yaml"), encoding: .utf8)
        XCTAssertTrue(oauth.contains("report_usage"))
        XCTAssertTrue(AgentManual.markdown.contains("`report_usage`"))
        let parity = try String(contentsOf: root.appendingPathComponent("docs/MCP-PARITAET.md"), encoding: .utf8)
        XCTAssertTrue(parity.contains("report_usage"))
    }
}
