import Fluent
import Vapor

/// Cost efficiency (ADR 0038, contracts/usage.yaml): the collector reports aggregated token counters. Same service,
/// rules and answer as `POST /v1/usage`; project assignment additionally needs the project in the grant.
extension MCPController {
    private static let usageRowSchema: JSONValue = {
        func count(_ description: String) -> JSONValue { Schema.integer(description, min: 0, max: 1_000_000_000_000) }
        let properties: [String: JSONValue] = [
            "day": Schema.string("Calendar day of the usage, YYYY-MM-DD, from 2020-01-01 to tomorrow (UTC).", maxLength: 10),
            "sessionKey": Schema.string("Thread or session id, characters A-Za-z0-9._:/#- ; never a title or free text. Subagents use their own key.", maxLength: 128),
            "model": Schema.string("Model id, characters A-Za-z0-9._:/[]- .", maxLength: 80),
            "provider": Schema.string("Provider of the model.", values: ["claude", "codex"]),
            "inputTokens": count("Input tokens neither read from nor written to the cache."),
            "outputTokens": count("Output tokens, including reasoning tokens."),
            "cacheWriteTokens": count("Tokens written to the cache."),
            "cacheWrite1hTokens": count("Part of cacheWriteTokens written to the 1 hour cache (default 0)."),
            "cacheReadTokens": count("Tokens read from the cache."),
            "turns": Schema.integer("Tool steps or model answers (default 0).", min: 0, max: 1_000_000),
            "maxContextTokens": Schema.integer("Largest context of one request on this day (default 0).", min: 0, max: 1_000_000_000),
            "subagent": Schema.boolean("true for a subagent session (default false)."),
            "projectID": Schema.uuid("Project of the usage; wins over repository."),
            "repository": Schema.string("Git remote URL or free repository key, resolved like find_project_by_repository.", maxLength: 300),
            "commits": Schema.integer("Commits of this session on this day. Omit with cardUpdates when unknown.", min: 0, max: 100_000),
            "cardUpdates": Schema.integer("Progress notes, claimed or changed cards of this session on this day.", min: 0, max: 100_000),
        ]
        return .object(["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
            "required": .strings(["day", "sessionKey", "model", "provider", "inputTokens", "outputTokens", "cacheWriteTokens", "cacheReadTokens"])])
    }()

    static let usageTools: [Tool] = [
        Tool(name: "report_usage", scope: "tasks:write",
             description: "Report aggregated token usage for the account's cost efficiency page: one row per day, session and model, counters and ids only, never prompts, titles, paths or names. Idempotent: reporting a (day, sessionKey, model) again REPLACES the whole row, so always send the full state of the day, never differences. A call is atomic (one invalid row stores nothing; the same key twice is duplicate_row). A project is only assigned when you may read it and it is in your grant; other rows are stored without project and listed in unassigned. Answer: {stored, created, updated, costUSD, unpricedModels, unassigned}.",
             properties: ["rows": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(500), "items": usageRowSchema,
                                           "description": .string("1 to 500 usage rows.")])],
             required: ["rows"]),
    ]

    func callUsage(_ a: JSONValue, user: User, grant: OAuthGrant, db: any Database) async throws -> JSONValue {
        try .encoded(try await UsageService(user: user, db: db, allowedProjects: Set(grant.effectiveProjects)).report(a))
    }
}
