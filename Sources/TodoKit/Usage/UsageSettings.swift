import Vapor

/// US dollars per one million tokens for a model id or prefix.
struct UsagePrice: Content, Equatable {
    let model: String
    let input: Double
    let cacheWrite: Double
    let cacheWrite1h: Double
    let cacheRead: Double
    let output: Double
    /// Only in answers: true = an entry of the account.
    var custom: Bool? = nil

    /// Anthropic list prices as of 03.11.2026. Haiku: only the tier up to 100k prompt tokens. No Codex defaults.
    static let defaults: [UsagePrice] = [
        UsagePrice(model: "claude-fable-5-2", input: 8, cacheWrite: 10, cacheWrite1h: 16, cacheRead: 0.2, output: 40),
        UsagePrice(model: "claude-opus-5-5", input: 4, cacheWrite: 5, cacheWrite1h: 8, cacheRead: 0.2, output: 20),
        UsagePrice(model: "claude-sonnet-5-5", input: 2, cacheWrite: 2.5, cacheWrite1h: 4, cacheRead: 0.1, output: 10),
        UsagePrice(model: "claude-haiku-5-5", input: 0.1, cacheWrite: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01, output: 0.5),
    ]

    /// Defaults with the account's entries: same model id (any case) replaces, others are appended.
    static func effective(own: [UsagePrice]) -> [UsagePrice] {
        var rest = own.map { price -> UsagePrice in var p = price; p.custom = true; return p }
        var result = defaults.map { price -> UsagePrice in
            if let i = rest.firstIndex(where: { $0.model.lowercased() == price.model }) { return rest.remove(at: i) }
            var p = price; p.custom = false; return p
        }
        result += rest
        return result
    }

    /// Longest entry that is a prefix of the model id, followed by nothing, `-<8 digits>` or `[...]`.
    static func match(_ model: String, in prices: [UsagePrice]) -> UsagePrice? {
        let id = model.lowercased()
        return prices.filter { price in
            let prefix = price.model.lowercased()
            guard id.hasPrefix(prefix) else { return false }
            let rest = String(id.dropFirst(prefix.count))
            return rest.isEmpty || rest.range(of: #"^(-[0-9]{8}|\[.*\])$"#, options: .regularExpression) != nil
        }.max { $0.model.count < $1.model.count }
    }
}

/// Shares in percent (0...100), context in tokens, trend limits in percent.
struct UsageThresholds: Content, Equatable {
    var costTrendGoodPercent: Double?
    var costTrendBadPercent: Double?
    var cacheHitGoodPercent: Double?
    var cacheHitMediumPercent: Double?
    var cacheWriteGoodPercent: Double?
    var cacheWriteBadPercent: Double?
    var contextGoodTokens: Double?
    var contextBadTokens: Double?
    var opusTargetPercent: Double?
    var cardTrendPercent: Double?
    var idleGoodPercent: Double?
    var idleBadPercent: Double?

    static let ranges: [String: ClosedRange<Double>] = [
        "costTrendGoodPercent": -100...1000, "costTrendBadPercent": -100...1000,
        "cacheHitGoodPercent": 0...100, "cacheHitMediumPercent": 0...100,
        "cacheWriteGoodPercent": 0...100, "cacheWriteBadPercent": 0...100,
        "contextGoodTokens": 0...1_000_000_000, "contextBadTokens": 0...1_000_000_000,
        "opusTargetPercent": 0...100, "cardTrendPercent": 0...1000,
        "idleGoodPercent": 0...100, "idleBadPercent": 0...100,
    ]

    /// Every value filled; `opusTargetPercent` has no default.
    struct Effective: Content, Equatable {
        let costTrendGoodPercent: Double, costTrendBadPercent: Double
        let cacheHitGoodPercent: Double, cacheHitMediumPercent: Double
        let cacheWriteGoodPercent: Double, cacheWriteBadPercent: Double
        let contextGoodTokens: Double, contextBadTokens: Double
        let opusTargetPercent: Double?
        let cardTrendPercent: Double
        let idleGoodPercent: Double, idleBadPercent: Double

        var consistent: Bool {
            costTrendGoodPercent <= costTrendBadPercent && cacheHitMediumPercent <= cacheHitGoodPercent
                && cacheWriteGoodPercent <= cacheWriteBadPercent && contextGoodTokens <= contextBadTokens
                && idleGoodPercent <= idleBadPercent
        }
    }

    var effective: Effective {
        Effective(
            costTrendGoodPercent: costTrendGoodPercent ?? -5, costTrendBadPercent: costTrendBadPercent ?? 15,
            cacheHitGoodPercent: cacheHitGoodPercent ?? 92, cacheHitMediumPercent: cacheHitMediumPercent ?? 85,
            cacheWriteGoodPercent: cacheWriteGoodPercent ?? 45, cacheWriteBadPercent: cacheWriteBadPercent ?? 65,
            contextGoodTokens: contextGoodTokens ?? 60_000, contextBadTokens: contextBadTokens ?? 120_000,
            opusTargetPercent: opusTargetPercent, cardTrendPercent: cardTrendPercent ?? 5,
            idleGoodPercent: idleGoodPercent ?? 5, idleBadPercent: idleBadPercent ?? 15)
    }
}

struct UsageSettingsDTO: Content {
    let prices: [UsagePrice]
    let thresholds: UsageThresholds.Effective
}

/// The account's own changes (stored, exported).
struct UsageOwnSettings: Content, Equatable {
    var prices: [UsagePrice] = []
    var thresholds = UsageThresholds()

    /// Strict validation of `PUT /v1/usage/settings`.
    static func parse(_ body: JSONValue) throws -> UsageOwnSettings {
        guard case .object(let root) = body else { throw Abort(.badRequest, reason: "invalid_prices") }
        guard Set(root.keys).isSubset(of: ["prices", "thresholds"]) else { throw Abort(.badRequest, reason: "unknown_field") }
        var result = UsageOwnSettings()

        let invalidPrices = Abort(.badRequest, reason: "invalid_prices")
        if let raw = root["prices"], !raw.isNull {
            guard case .array(let list) = raw, list.count <= 100 else { throw invalidPrices }
            var seen = Set<String>()
            for entry in list {
                guard case .object(let o) = entry else { throw invalidPrices }
                guard Set(o.keys).isSubset(of: ["model", "input", "cacheWrite", "cacheWrite1h", "cacheRead", "output", "custom"]) else {
                    throw Abort(.badRequest, reason: "unknown_field")
                }
                func amount(_ key: String) throws -> Double {
                    guard case .number(let n) = o[key] ?? .null, n.isFinite, (0...10_000).contains(n) else { throw invalidPrices }
                    return n
                }
                guard let model = o["model"]?.string, UsageService.isModel(model), seen.insert(model.lowercased()).inserted else { throw invalidPrices }
                result.prices.append(UsagePrice(model: model, input: try amount("input"), cacheWrite: try amount("cacheWrite"),
                    cacheWrite1h: try amount("cacheWrite1h"), cacheRead: try amount("cacheRead"), output: try amount("output")))
            }
        }

        let invalid = Abort(.badRequest, reason: "invalid_thresholds")
        if let raw = root["thresholds"], !raw.isNull {
            guard case .object(let o) = raw else { throw invalid }
            guard Set(o.keys).isSubset(of: Set(UsageThresholds.ranges.keys)) else { throw Abort(.badRequest, reason: "unknown_field") }
            var values: [String: JSONValue] = [:]
            for (key, value) in o where !value.isNull {
                guard case .number(let n) = value, n.isFinite, UsageThresholds.ranges[key]!.contains(n) else { throw invalid }
                values[key] = value
            }
            result.thresholds = try JSONValue.object(values).decode(UsageThresholds.self)
        }
        guard result.thresholds.effective.consistent else { throw invalid }
        return result
    }
}
