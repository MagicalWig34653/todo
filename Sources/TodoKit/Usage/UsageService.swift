import Fluent
import Vapor

struct UsageReportResult: Content {
    struct Unassigned: Content { let index: Int; let repository: String?; let projectID: String? }
    let stored: Int
    let created: Int
    let updated: Int
    let costUSD: Double
    let unpricedModels: [String]
    let unassigned: [Unassigned]
}

/// UTC calendar days as `YYYY-MM-DD`.
enum UsageDay {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    /// Start of the day; nil for anything that is not a real date in this exact form.
    static func parse(_ s: String) -> Date? {
        guard s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              format(date) == s else { return nil }
        return date
    }

    static func format(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func adding(_ days: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }
}

/// One business path for REST and MCP (contracts/usage.yaml). Rows, prices and thresholds belong to the account;
/// `allowedProjects` narrows an OAuth grant. A project the caller cannot read is silently dropped from a row.
struct UsageService: Sendable {
    static let maxRows = 500
    static let maxTokens = 1_000_000_000_000.0
    /// Keeps the summary, the account export (20 MB limit) and the token sums bounded.
    static let defaultMaxStoredRows = 20_000
    static let rowFields: Set<String> = ["day", "sessionKey", "model", "provider", "inputTokens", "outputTokens", "cacheWriteTokens",
        "cacheWrite1hTokens", "cacheReadTokens", "turns", "maxContextTokens", "subagent", "projectID", "repository", "commits", "cardUpdates"]

    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil
    var maxStoredRows = UsageService.defaultMaxStoredRows

    static func isModel(_ s: String) -> Bool { s.range(of: #"\A[A-Za-z0-9._:/\[\]-]{1,80}\z"#, options: .regularExpression) != nil }
    static func isSessionKey(_ s: String) -> Bool { s.range(of: #"\A[A-Za-z0-9._:/#-]{1,128}\z"#, options: .regularExpression) != nil }

    // MARK: Report

    private struct Input {
        var day = "", sessionKey = "", model = "", provider = ""
        var input: Int64 = 0, output: Int64 = 0, write: Int64 = 0, write1h: Int64 = 0, read: Int64 = 0
        var turns: Int64 = 0, maxContext: Int64 = 0
        var subagent = false
        var projectID: UUID?
        var rawProjectID: String?
        var repository: String?
        var repositoryKey: String?
        var commits: Int64?
        var cardUpdates: Int64?
        var key: String { "\(day)\u{0}\(sessionKey)\u{0}\(model)" }

        func apply(to row: UsageDaily, project: UUID?) {
            row.provider = provider
            row.inputTokens = input; row.outputTokens = output; row.cacheWriteTokens = write
            row.cacheWrite1hTokens = write1h; row.cacheReadTokens = read
            row.turns = turns; row.maxContextTokens = maxContext; row.subagent = subagent
            row.projectID = project; row.commits = commits; row.cardUpdates = cardUpdates
        }
    }

    private static func parse(_ value: JSONValue, latestDay: String) throws -> Input {
        guard case .object(let o) = value else { throw Abort(.badRequest, reason: "invalid_rows") }
        guard Set(o.keys).isSubset(of: rowFields) else { throw Abort(.badRequest, reason: "unknown_field") }
        func invalid(_ key: String) -> Abort { Abort(.badRequest, reason: "invalid_\(key)") }
        func string(_ key: String) throws -> String {
            guard let s = o[key]?.string else { throw invalid(key) }
            return s
        }
        func optionalString(_ key: String) throws -> String? {
            guard let v = o[key], !v.isNull else { return nil }
            return try string(key)
        }
        // Token counts exceed 32 bit: own whole-number check with the contract's limits (not the generic intArgument).
        func optionalCount(_ key: String, max: Double) throws -> Int64? {
            guard let v = o[key], !v.isNull else { return nil }
            guard case .number(let n) = v, n.isFinite, n == n.rounded(), n >= 0, n <= max else { throw invalid(key) }
            return Int64(n)
        }
        func tokens(_ key: String) throws -> Int64 {
            guard let n = try optionalCount(key, max: maxTokens) else { throw invalid(key) }
            return n
        }
        var r = Input()
        r.day = try string("day")
        guard UsageDay.parse(r.day) != nil, r.day >= "2020-01-01", r.day <= latestDay else { throw invalid("day") }
        r.sessionKey = try string("sessionKey"); guard isSessionKey(r.sessionKey) else { throw invalid("sessionKey") }
        r.model = try string("model"); guard isModel(r.model) else { throw invalid("model") }
        r.provider = try string("provider"); guard ["claude", "codex"].contains(r.provider) else { throw invalid("provider") }
        r.input = try tokens("inputTokens"); r.output = try tokens("outputTokens")
        r.write = try tokens("cacheWriteTokens"); r.read = try tokens("cacheReadTokens")
        r.write1h = try optionalCount("cacheWrite1hTokens", max: maxTokens) ?? 0
        guard r.write1h <= r.write else { throw invalid("cacheWrite1hTokens") }
        r.turns = try optionalCount("turns", max: 1_000_000) ?? 0
        r.maxContext = try optionalCount("maxContextTokens", max: 1_000_000_000) ?? 0
        if let v = o["subagent"], !v.isNull {
            guard case .bool(let b) = v else { throw invalid("subagent") }
            r.subagent = b
        }
        r.rawProjectID = try optionalString("projectID")
        if let raw = r.rawProjectID {
            guard let id = UUID(uuidString: raw) else { throw invalid("projectID") }
            r.projectID = id
        }
        r.repository = try optionalString("repository")
        if let raw = r.repository {
            guard raw.count <= 300 else { throw invalid("repository") }
            r.repositoryKey = try RepositoryKey.normalize(raw)
        }
        r.commits = try optionalCount("commits", max: 100_000)
        r.cardUpdates = try optionalCount("cardUpdates", max: 100_000)
        return r
    }

    /// Projects the account can read right now (and, over MCP, that the grant lists).
    private func readableProjects() async throws -> [UUID: Project] {
        var visible = try await ProjectAccess(user: user, db: db).visibleProjects()
        if let allowedProjects { visible = visible.filter { allowedProjects.contains($0.id ?? UUID()) } }
        return Dictionary(uniqueKeysWithValues: try visible.map { (try $0.requireID(), $0) })
    }

    /// One project per repository key among the readable ones: an own project first, then the oldest binding.
    private func repositoryProjects(_ keys: Set<String>, readable: [UUID: Project]) async throws -> [String: UUID] {
        guard !keys.isEmpty else { return [:] }
        let uid = try user.requireID()
        let bindings = try await ProjectRepositoryBinding.query(on: db).filter(\.$repoKey ~~ Array(keys)).all()
            .filter { readable[$0.projectID] != nil }
        return Dictionary(grouping: bindings, by: \.repoKey).compactMapValues { list in
            let own = list.filter { $0.ownerID == uid }
            return ProjectRepositoryBinding.defaultBinding(of: own.isEmpty ? list : own)?.projectID
        }
    }

    func report(_ body: JSONValue) async throws -> UsageReportResult {
        guard case .object(let root) = body else { throw Abort(.badRequest, reason: "invalid_rows") }
        guard Set(root.keys).isSubset(of: ["rows"]) else { throw Abort(.badRequest, reason: "unknown_field") }
        guard case .array(let raw) = root["rows"] ?? .null, (1...Self.maxRows).contains(raw.count) else { throw Abort(.badRequest, reason: "invalid_rows") }
        let latest = UsageDay.format(UsageDay.adding(1, to: Date()))
        let rows = try raw.map { try Self.parse($0, latestDay: latest) }
        guard Set(rows.map(\.key)).count == rows.count else { throw Abort(.badRequest, reason: "duplicate_row") }

        let needsProjects = rows.contains { $0.projectID != nil || $0.repositoryKey != nil }
        let readable = needsProjects ? try await readableProjects() : [:]
        let byRepository = try await repositoryProjects(Set(rows.filter { $0.projectID == nil }.compactMap(\.repositoryKey)), readable: readable)
        var unassigned: [UsageReportResult.Unassigned] = []
        var projects: [UUID?] = []
        for (index, r) in rows.enumerated() {
            // projectID wins over repository, also when it cannot be assigned.
            let project: UUID? = if let id = r.projectID { readable[id] == nil ? nil : id } else { r.repositoryKey.flatMap { byRepository[$0] } }
            projects.append(project)
            if project == nil, r.projectID != nil || r.repositoryKey != nil {
                unassigned.append(.init(index: index, repository: r.repository, projectID: r.rawProjectID))
            }
        }

        let uid = try user.requireID()
        let assigned = projects
        let cap = maxStoredRows
        let stored: (rows: [UsageDaily], updated: Int) = try await db.transaction { tx in
            // Serialises reports of one account, so parallel identical calls update instead of colliding on the unique key.
            try await lockRow(table: User.schema, id: uid, on: tx)
            let found = try await UsageDaily.query(on: tx).filter(\.$userID == uid)
                .filter(\.$day ~~ Array(Set(rows.map(\.day)))).filter(\.$sessionKey ~~ Array(Set(rows.map(\.sessionKey)))).all()
            let existing = Dictionary(uniqueKeysWithValues: found.map { ("\($0.day)\u{0}\($0.sessionKey)\u{0}\($0.model)", $0) })
            var result: [UsageDaily] = [], fresh: [UsageDaily] = [], updated = 0
            for (index, input) in rows.enumerated() {
                if let row = existing[input.key] {
                    input.apply(to: row, project: assigned[index])
                    try await row.save(on: tx)
                    updated += 1; result.append(row)
                } else {
                    let row = UsageDaily()
                    row.userID = uid; row.day = input.day; row.sessionKey = input.sessionKey; row.model = input.model
                    input.apply(to: row, project: assigned[index])
                    fresh.append(row); result.append(row)
                }
            }
            for start in stride(from: 0, to: fresh.count, by: 100) {
                try await Array(fresh[start..<min(start + 100, fresh.count)]).create(on: tx)
            }
            // Over the cap the oldest days go first, so the collector is never blocked.
            let excess = fresh.isEmpty ? 0 : try await UsageDaily.query(on: tx).filter(\.$userID == uid).count() - cap
            if excess > 0 {
                let oldest = try await UsageDaily.query(on: tx).filter(\.$userID == uid)
                    .sort(\.$day).sort(\.$id).limit(excess).all(\.$id)
                for start in stride(from: 0, to: oldest.count, by: 500) {
                    try await UsageDaily.query(on: tx).filter(\.$id ~~ Array(oldest[start..<min(start + 500, oldest.count)])).delete()
                }
            }
            return (result, updated)
        }
        let prices = UsagePrice.effective(own: try await ownSettings().prices)
        let priced = stored.rows.map { UsagePricedRow($0, prices: prices, readable: []) }
        return UsageReportResult(stored: stored.rows.count, created: stored.rows.count - stored.updated, updated: stored.updated,
            costUSD: UsageMetrics.total(priced), unpricedModels: Self.unpriced(priced), unassigned: unassigned)
    }

    private static func unpriced(_ rows: [UsagePricedRow]) -> [String] {
        Set(rows.filter { !$0.priced }.map(\.row.model)).sorted()
    }

    // MARK: Settings

    func ownSettings() async throws -> UsageOwnSettings {
        guard let row = try await UsageSetting.query(on: db).filter(\.$userID == user.requireID()).first() else { return UsageOwnSettings() }
        let decoder = JSONDecoder()
        return UsageOwnSettings(prices: try decoder.decode([UsagePrice].self, from: Data(row.prices.utf8)),
                                thresholds: try decoder.decode(UsageThresholds.self, from: Data(row.thresholds.utf8)))
    }

    private static func dto(_ own: UsageOwnSettings) -> UsageSettingsDTO {
        UsageSettingsDTO(prices: UsagePrice.effective(own: own.prices), thresholds: own.thresholds.effective)
    }

    func settings() async throws -> UsageSettingsDTO { Self.dto(try await ownSettings()) }

    /// Replaces the account's own entries completely.
    func replaceSettings(_ body: JSONValue) async throws -> UsageSettingsDTO {
        let own = try UsageOwnSettings.parse(body)
        let uid = try user.requireID()
        let encoder = JSONEncoder()
        let prices = String(decoding: try encoder.encode(own.prices), as: UTF8.self)
        let thresholds = String(decoding: try encoder.encode(own.thresholds), as: UTF8.self)
        try await db.transaction { tx in
            try await lockRow(table: User.schema, id: uid, on: tx)
            let existing = try await UsageSetting.query(on: tx).filter(\.$userID == uid).first()
            if own == UsageOwnSettings() { try await existing?.delete(on: tx); return }
            let row = existing ?? UsageSetting()
            row.userID = uid; row.prices = prices; row.thresholds = thresholds
            try await row.save(on: tx)
        }
        return Self.dto(own)
    }

    // MARK: Summary

    func summary(days: Int, until: Date) async throws -> UsageSummaryDTO {
        let uid = try user.requireID()
        let start = UsageDay.adding(1 - days, to: until)
        let previousStart = UsageDay.adding(-days, to: start)
        let from = UsageDay.format(start), last = UsageDay.format(until)
        let own = try await ownSettings()
        let prices = UsagePrice.effective(own: own.prices)
        let thresholds = own.thresholds.effective
        let readable = try await readableProjects()
        let names = readable.mapValues(\.name)
        let readableIDs = Set(readable.keys)
        let rows = try await UsageDaily.query(on: db).filter(\.$userID == uid)
            .filter(\.$day >= UsageDay.format(previousStart)).filter(\.$day <= last).all()
            .map { UsagePricedRow($0, prices: prices, readable: readableIDs) }
        let current = rows.filter { $0.row.day >= from }, previous = rows.filter { $0.row.day < from }
        let hasAny: Bool
        if rows.isEmpty { hasAny = try await UsageDaily.query(on: db).filter(\.$userID == uid).first() != nil } else { hasAny = true }

        // Done cards, approximated like the overview "now": status done and last change inside the window (UTC days).
        var cards: [UUID: Int] = [:], previousCards: [UUID: Int] = [:]
        let projectIDs = Array(Set(rows.compactMap(\.projectID)))
        if !projectIDs.isEmpty {
            let end = UsageDay.adding(1, to: until)
            let done = try await TodoTask.query(on: db).filter(\.$projectID ~~ projectIDs).filter(\.$status == "done")
                .filter(\.$updatedAt >= previousStart).filter(\.$updatedAt < end)
                .field(\.$id).field(\.$projectID).field(\.$updatedAt).all()
            let used = Set(current.compactMap(\.projectID)), usedBefore = Set(previous.compactMap(\.projectID))
            for task in done {
                guard let changed = task.updatedAt else { continue }
                if changed >= start { if used.contains(task.projectID) { cards[task.projectID, default: 0] += 1 } }
                else if usedBefore.contains(task.projectID) { previousCards[task.projectID, default: 0] += 1 }
            }
        }

        let values = UsageMetrics.values(current, doneCards: cards)
        let before = UsageMetrics.values(previous, doneCards: previousCards)
        let metrics = UsageMetrics.order.map { UsageMetrics.metric($0, value: values[$0], previous: before[$0], thresholds) }
        let byDay = Dictionary(grouping: current, by: \.row.day)
        let series = (0..<days).map { offset -> UsageSummaryDTO.Day in
            let day = UsageDay.format(UsageDay.adding(offset, to: start))
            var parts = UsageSummaryDTO.Parts()
            for row in byDay[day] ?? [] { parts += row.cost }
            return .init(day: day, costUSD: parts.total, parts: parts)
        }
        return UsageSummaryDTO(days: days, from: from, until: last, partial: last >= UsageDay.format(Date()),
            hasData: !current.isEmpty, hasAnyData: hasAny, totalCostUSD: UsageMetrics.total(current),
            previousCostUSD: previous.isEmpty ? nil : UsageMetrics.total(previous),
            verdict: UsageMetrics.verdict(metrics), metrics: metrics, series: series, models: UsageMetrics.models(current),
            sessions: UsageMetrics.sessions(current, names: names),
            projects: UsageMetrics.projects(current, names: names, doneCards: cards), unpricedModels: Self.unpriced(current))
    }
}

struct UsageController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // 500 rows with long keys are about 400 kB, above the global limit of 256 kB.
        routes.on(.POST, "v1", "usage", body: .collect(maxSize: "2mb"), use: report)
        routes.get("v1", "usage", "summary", use: summary)
        routes.get("v1", "usage", "settings", use: settings)
        routes.put("v1", "usage", "settings", use: replaceSettings)
    }

    private func service(_ req: Request) async throws -> UsageService {
        UsageService(user: try await req.requireUser(), db: req.db)
    }

    @Sendable func report(_ req: Request) async throws -> UsageReportResult {
        let service = try await service(req)
        return try await service.report(try req.content.decode(JSONValue.self))
    }

    @Sendable func summary(_ req: Request) async throws -> UsageSummaryDTO {
        let service = try await service(req)
        var days = 7
        if let raw = req.query[String.self, at: "days"] {
            guard let value = Int(raw), [1, 7, 30].contains(value) else { throw Abort(.badRequest, reason: "invalid_days") }
            days = value
        }
        var until = UsageDay.parse(UsageDay.format(Date()))!
        if let raw = req.query[String.self, at: "until"] {
            guard let value = UsageDay.parse(raw), raw >= "1970-01-01" else { throw Abort(.badRequest, reason: "invalid_until") }
            until = value
        }
        return try await service.summary(days: days, until: until)
    }

    @Sendable func settings(_ req: Request) async throws -> UsageSettingsDTO {
        try await service(req).settings()
    }

    @Sendable func replaceSettings(_ req: Request) async throws -> UsageSettingsDTO {
        let service = try await service(req)
        return try await service.replaceSettings(try req.content.decode(JSONValue.self))
    }
}
