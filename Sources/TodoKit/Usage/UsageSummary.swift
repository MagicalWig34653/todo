import Vapor

enum UsageRating: String, Content { case good, medium, bad, info, unknown }

struct UsageSummaryDTO: Content {
    struct Verdict: Content { let rating: UsageRating; let best: String?; let worst: String?; let lever: String? }
    struct Metric: Content { let id: String; let rating: UsageRating; let value: Double?; let previous: Double?; let change: Double? }
    struct Parts: Content {
        var input = 0.0, cacheWrite = 0.0, cacheRead = 0.0, output = 0.0
        var total: Double { input + cacheWrite + cacheRead + output }
        static func += (a: inout Parts, b: Parts) { a.input += b.input; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead; a.output += b.output }
    }
    struct Day: Content { let day: String; let costUSD: Double; let parts: Parts }
    struct Model: Content { let family: String; let costUSD: Double; let share: Double; let tokens: Int64 }
    struct Session: Content {
        let sessionKey: String; let costUSD: Double; let share: Double; let models: [String]
        let projectID: UUID?; let projectName: String?
        let turns: Int64; let maxContextTokens: Int64; let subagent: Bool
        let commits: Int64?; let cardUpdates: Int64?; let idle: Bool
    }
    struct Project: Content {
        let projectID: UUID?; let projectName: String?; let costUSD: Double; let share: Double
        let doneCards: Int; let costPerDoneCard: Double?
    }
    let days: Int
    let from: String
    let until: String
    let partial: Bool
    let hasData: Bool
    let hasAnyData: Bool
    let totalCostUSD: Double
    let previousCostUSD: Double?
    let verdict: Verdict
    let metrics: [Metric]
    let series: [Day]
    let models: [Model]
    let sessions: [Session]
    let projects: [Project]
    let unpricedModels: [String]
}

/// A stored row with its cost and its project already reduced to what the account may read now.
struct UsagePricedRow {
    let row: UsageDaily
    let cost: UsageSummaryDTO.Parts
    let priced: Bool
    let projectID: UUID?

    init(_ row: UsageDaily, prices: [UsagePrice], readable: Set<UUID>) {
        self.row = row
        projectID = row.projectID.flatMap { readable.contains($0) ? $0 : nil }
        let price = UsagePrice.match(row.model, in: prices)
        priced = price != nil
        var parts = UsageSummaryDTO.Parts()
        if let price {
            parts.input = Double(row.inputTokens) * price.input / 1e6
            parts.cacheWrite = (Double(row.cacheWriteTokens - row.cacheWrite1hTokens) * price.cacheWrite
                + Double(row.cacheWrite1hTokens) * price.cacheWrite1h) / 1e6
            parts.cacheRead = Double(row.cacheReadTokens) * price.cacheRead / 1e6
            parts.output = Double(row.outputTokens) * price.output / 1e6
        }
        cost = parts
    }

    var tokens: Int64 { row.inputTokens + row.outputTokens + row.cacheWriteTokens + row.cacheReadTokens }
    var reportsOutcome: Bool { row.commits != nil || row.cardUpdates != nil }
}

/// All metrics of contracts/usage.yaml; pure functions over the rows of one window.
enum UsageMetrics {
    static let order = ["costPerDay", "cacheHitRate", "cacheWriteCostShare", "outputShare", "contextPerTurn", "opusCostShare", "costPerDoneCard", "idleCostShare"]
    static let verdictOrder = ["cacheHitRate", "cacheWriteCostShare", "contextPerTurn", "costPerDay", "idleCostShare", "opusCostShare"]
    /// Threshold comparisons must not depend on binary rounding (0.05 * 100 is not exactly 5).
    private static let epsilon = 1e-9

    private static func ratio(_ a: Double, _ b: Double) -> Double? { b > 0 ? a / b : nil }

    static func total(_ rows: [UsagePricedRow]) -> Double { rows.reduce(0) { $0 + $1.cost.total } }

    static func isOpus(_ model: String) -> Bool { model.lowercased().contains("opus") }

    /// Outcome of the rows that report one, per session: idle = 0 commits and 0 card updates.
    private static func idleShare(_ rows: [UsagePricedRow]) -> Double? {
        let reported = Dictionary(grouping: rows.filter(\.reportsOutcome), by: \.row.sessionKey)
        var all = 0.0, idle = 0.0
        for list in reported.values {
            let cost = total(list)
            all += cost
            if list.allSatisfy({ ($0.row.commits ?? 0) == 0 && ($0.row.cardUpdates ?? 0) == 0 }) { idle += cost }
        }
        return ratio(idle, all)
    }

    static func values(_ rows: [UsagePricedRow], doneCards: [UUID: Int]) -> [String: Double] {
        let cost = total(rows)
        let tokens = rows.reduce(0.0) { $0 + Double($1.tokens) }
        let read = rows.reduce(0.0) { $0 + Double($1.row.cacheReadTokens) }
        let prompt = rows.reduce(0.0) { $0 + Double($1.row.cacheReadTokens + $1.row.cacheWriteTokens + $1.row.inputTokens) }
        let stepped = rows.filter { $0.row.turns > 0 }
        let steppedPrompt = stepped.reduce(0.0) { $0 + Double($1.row.cacheReadTokens + $1.row.cacheWriteTokens + $1.row.inputTokens) }
        let inProjects = rows.filter { $0.projectID != nil }
        let cards = Set(inProjects.compactMap(\.projectID)).reduce(0) { $0 + (doneCards[$1] ?? 0) }

        var result: [String: Double] = [:]
        result["costPerDay"] = ratio(cost, Double(Set(rows.map(\.row.day)).count))
        result["cacheHitRate"] = ratio(read, prompt)
        result["cacheWriteCostShare"] = ratio(rows.reduce(0) { $0 + $1.cost.cacheWrite }, cost)
        result["outputShare"] = ratio(rows.reduce(0.0) { $0 + Double($1.row.outputTokens) }, tokens)
        result["contextPerTurn"] = ratio(steppedPrompt, stepped.reduce(0.0) { $0 + Double($1.row.turns) })
        result["opusCostShare"] = ratio(total(rows.filter { isOpus($0.row.model) }), cost)
        result["costPerDoneCard"] = ratio(total(inProjects), Double(cards))
        result["idleCostShare"] = idleShare(rows)
        return result
    }

    static func metric(_ id: String, value: Double?, previous: Double?, _ t: UsageThresholds.Effective) -> UsageSummaryDTO.Metric {
        var change: Double?
        if let value, let previous, previous > 0 { change = (value - previous) / previous }
        func below(_ a: Double, _ limit: Double) -> Bool { a < limit - epsilon }
        func above(_ a: Double, _ limit: Double) -> Bool { a > limit + epsilon }
        var rating = UsageRating.unknown
        if let value {
            let percent = value * 100
            switch id {
            case "costPerDay":
                if let change { rating = below(change * 100, t.costTrendGoodPercent) ? .good : above(change * 100, t.costTrendBadPercent) ? .bad : .medium }
            case "costPerDoneCard":
                if let change { rating = below(change * 100, -t.cardTrendPercent) ? .good : above(change * 100, t.cardTrendPercent) ? .bad : .medium }
            case "cacheHitRate":
                rating = !below(percent, t.cacheHitGoodPercent) ? .good : !below(percent, t.cacheHitMediumPercent) ? .medium : .bad
            case "cacheWriteCostShare":
                rating = below(percent, t.cacheWriteGoodPercent) ? .good : !above(percent, t.cacheWriteBadPercent) ? .medium : .bad
            case "contextPerTurn":
                rating = below(value, t.contextGoodTokens) ? .good : !above(value, t.contextBadTokens) ? .medium : .bad
            case "opusCostShare":
                if let target = t.opusTargetPercent { rating = !above(percent, target) ? .good : !above(percent, target + 15) ? .medium : .bad }
                else { rating = .info }
            case "idleCostShare":
                rating = below(percent, t.idleGoodPercent) ? .good : !above(percent, t.idleBadPercent) ? .medium : .bad
            default: rating = .info
            }
        }
        return .init(id: id, rating: rating, value: value, previous: previous, change: change)
    }

    static func verdict(_ metrics: [UsageSummaryDTO.Metric]) -> UsageSummaryDTO.Verdict {
        let rated = verdictOrder.compactMap { id in metrics.first { $0.id == id } }
            .filter { [.good, .medium, .bad].contains($0.rating) }
        guard !rated.isEmpty else { return .init(rating: .unknown, best: nil, worst: nil, lever: nil) }
        let bad = rated.filter { $0.rating == .bad }.count, medium = rated.filter { $0.rating == .medium }.count
        let rating: UsageRating = bad >= 2 ? .bad : bad == 1 || medium >= 2 ? .medium : .good
        func first(_ ratings: [UsageRating]) -> String? {
            for r in ratings { if let m = rated.first(where: { $0.rating == r }) { return m.id } }
            return nil
        }
        let worst = first([.bad, .medium])
        return .init(rating: rating, best: first([.good, .medium, .bad]), worst: worst, lever: worst)
    }

    static func family(_ row: UsageDaily) -> String {
        if row.provider == "codex" { return "codex" }
        let id = row.model.lowercased()
        return ["opus", "sonnet", "haiku", "fable"].first { id.contains($0) } ?? "other"
    }

    static func models(_ rows: [UsagePricedRow]) -> [UsageSummaryDTO.Model] {
        let cost = total(rows)
        return Dictionary(grouping: rows) { family($0.row) }.map { name, list in
            .init(family: name, costUSD: total(list), share: ratio(total(list), cost) ?? 0, tokens: list.reduce(0) { $0 + $1.tokens })
        }.sorted { ($1.costUSD, $0.family) < ($0.costUSD, $1.family) }
    }

    /// The ten most expensive sessions.
    static func sessions(_ rows: [UsagePricedRow], names: [UUID: String]) -> [UsageSummaryDTO.Session] {
        let cost = total(rows)
        let grouped = Dictionary(grouping: rows, by: \.row.sessionKey).map { (key: $0.key, rows: $0.value, cost: total($0.value)) }
            .sorted { ($1.cost, $0.key) < ($0.cost, $1.key) }
        return grouped.prefix(10).map { key, list, sum in
            let models = Dictionary(grouping: list, by: \.row.model).map { (model: $0.key, cost: total($0.value)) }
                .sorted { ($1.cost, $0.model) < ($0.cost, $1.model) }.map(\.model)
            let project = Dictionary(grouping: list.filter { $0.projectID != nil }) { $0.projectID! }
                .map { (id: $0.key, cost: total($0.value)) }
                .sorted { ($1.cost, $0.id.uuidString) < ($0.cost, $1.id.uuidString) }.first?.id
            let commits = list.compactMap(\.row.commits), updates = list.compactMap(\.row.cardUpdates)
            let reported = !commits.isEmpty || !updates.isEmpty
            return .init(sessionKey: key, costUSD: sum, share: ratio(sum, cost) ?? 0, models: models,
                         projectID: project, projectName: project.flatMap { names[$0] },
                         turns: list.reduce(0) { $0 + $1.row.turns }, maxContextTokens: list.map(\.row.maxContextTokens).max() ?? 0,
                         subagent: list.contains { $0.row.subagent },
                         commits: commits.isEmpty ? nil : commits.reduce(0, +), cardUpdates: updates.isEmpty ? nil : updates.reduce(0, +),
                         idle: reported && commits.reduce(0, +) == 0 && updates.reduce(0, +) == 0)
        }
    }

    static func projects(_ rows: [UsagePricedRow], names: [UUID: String], doneCards: [UUID: Int]) -> [UsageSummaryDTO.Project] {
        let cost = total(rows)
        return Dictionary(grouping: rows, by: \.projectID).map { id, list -> UsageSummaryDTO.Project in
            let sum = total(list), cards = id.flatMap { doneCards[$0] } ?? 0
            return .init(projectID: id, projectName: id.flatMap { names[$0] }, costUSD: sum, share: ratio(sum, cost) ?? 0,
                         doneCards: cards, costPerDoneCard: ratio(sum, Double(cards)))
        }.sorted { ($1.costUSD, $0.projectID?.uuidString ?? "~") < ($0.costUSD, $1.projectID?.uuidString ?? "~") }
    }
}
