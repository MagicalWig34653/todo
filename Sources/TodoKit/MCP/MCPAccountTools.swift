import Fluent
import Vapor

/// Batch 8 (docs/MCP-PARITAET.md): personal settings, push notification preferences, the own connection and
/// read-only administration. Same domain code as REST (`PreferencesController.save`, `PushService`, admin routes).
/// Never exposes secrets, tokens, passkeys, passwords or e-mail addresses.
extension MCPController {
    static let accountTools: [Tool] = [
        Tool(name: "get_settings", scope: "account:read",
             description: "Read your personal appearance settings: {version, appearance:{colorScheme, accent, accentCustomHex, glow}, revision, updatedAt}. revision 0 means defaults. Pass revision to update_settings."),
        Tool(name: "update_settings", scope: "account:write",
             description: "Change your personal appearance settings (partial: only the given fields change). Pass the current revision from get_settings; a stale revision fails with version_conflict. accentCustomHex is required exactly when accent is 'custom'.",
             properties: ["revision": Schema.integer("Current revision from get_settings (0 if never saved).", min: 0),
                          "colorScheme": Schema.string("system, light or dark.", values: ["system", "light", "dark"]),
                          "accent": Schema.string("Accent name, for example blue, teal, violet or custom.", maxLength: 20),
                          "accentCustomHex": Schema.nullable("string", "Colour as #RRGGBB when accent is custom, otherwise null."),
                          "glow": Schema.string("off, subtle, medium or strong.", values: ["off", "subtle", "medium", "strong"])],
             required: ["revision"]),
        Tool(name: "get_notification_prefs", scope: "account:read",
             description: "Read your push notification preferences: {categories:{reminders, agent_questions, agent_reviews, assignments, comments, confirmations, daily_brief}, showContent, badge, dailyBriefHour}. daily_brief (default off) pushes the one-line daily brief once a day from dailyBriefHour (UTC, default 8)."),
        Tool(name: "update_notification_prefs", scope: "account:write",
             description: "Change your push notification preferences (partial). Unknown categories fail with invalid_category. Returns the new preferences.",
             properties: ["categories": .object(["type": .string("object"), "description": .string("Category name to boolean, for example {\"comments\": true}."),
                                                "additionalProperties": .object(["type": .string("boolean")])]),
                          "showContent": Schema.boolean("Show task text in push notifications."),
                          "badge": Schema.boolean("Show the badge count."),
                          "dailyBriefHour": Schema.integer("UTC hour 0 to 23 from which the daily brief is pushed (category daily_brief).", min: 0, max: 23)]),
        Tool(name: "get_connection", scope: "",
             description: "Describe this MCP connection: {client, name, scopes, projects:[{id,name}], refreshExpiresAt}. The project list is exactly this connection's grant. No tokens."),
        Tool(name: "list_users", scope: "admin:read",
             description: "Administrators only: list accounts (up to 500) with displayName, username, isAdmin and status active|disabled|anonymized. Read-only; no secrets.",
             properties: ["limit": Schema.integer("Maximum number of accounts (default 200).", min: 1, max: 500)]),
        Tool(name: "list_invitations", scope: "admin:read",
             description: "Administrators only: list invitations (newest expiry first, up to 200) with status open|used|expired. Codes are never returned."),
    ]

    func callAccount(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) async throws -> JSONValue {
        let userID = try user.requireID()
        func requireAdmin() throws { guard user.isAdmin else { throw Abort(.forbidden, reason: "forbidden") } }
        switch name {
        case "get_settings":
            return try .encoded(PreferencesController.response(try await UserPreferences.query(on: db).filter(\.$userID == userID).first()))
        case "update_settings":
            guard let revision = try intArgument(a["revision"], reason: "invalid_revision"), revision >= 0 else { throw Abort(.badRequest, reason: "invalid_revision") }
            let row = try await UserPreferences.query(on: db).filter(\.$userID == userID).first()
            var current = try row.map { try PreferencesDocument.migrated(version: $0.version, document: $0.document) } ?? .defaults
            var appearance = current.appearance
            if let v = try optionalString(a, "colorScheme") { appearance.colorScheme = v }
            if let v = try optionalString(a, "accent") { appearance.accent = v }
            if let v = try optionalString(a, "glow") { appearance.glow = v }
            if case .object(let args) = a, args["accentCustomHex"] != nil { appearance.accentCustomHex = try optionalString(a, "accentCustomHex") }
            else if appearance.accent != "custom" { appearance.accentCustomHex = nil }
            current.appearance = appearance
            // Strict validation shared with REST (known values, hex exactly for custom).
            let doc = try PreferencesDocument.validated(from: try JSONEncoder().encode(current))
            let saved = try await PreferencesController.save(doc, userID: userID, expectedRevision: revision, on: db)
            return try .encoded(PreferencesController.response(saved))
        case "get_notification_prefs":
            return try .encoded(try await PushService.prefs(of: userID, on: db))
        case "update_notification_prefs":
            var categories: [String: Bool]?
            if !a["categories"].isNull {
                guard case .object(let raw) = a["categories"], raw.count <= 20 else { throw Abort(.badRequest, reason: "invalid_categories") }
                var parsed: [String: Bool] = [:]
                for (k, v) in raw { guard case .bool(let b) = v else { throw Abort(.badRequest, reason: "invalid_categories") }; parsed[k] = b }
                categories = parsed
            }
            let show = try optionalBool(a, "showContent"), badge = try optionalBool(a, "badge")
            let hour = try intArgument(a["dailyBriefHour"], reason: "invalid_daily_brief_hour")
            guard categories != nil || show != nil || badge != nil || hour != nil else { throw Abort(.badRequest, reason: "invalid_arguments") }
            let dto = try await PushService(user: user, db: db, settings: settings.apns)
                .update(UpdatePushPrefsRequest(categories: categories, showContent: show, badge: badge, dailyBriefHour: hour))
            return try .encoded(dto)
        case "get_connection":
            let client = try await OAuthClient.find(grant.clientID, on: db)?.name
            var projects: [JSONValue] = []
            for id in grant.projects {
                if let p = try? await project(id, user: user, grant: grant, db: db) {
                    projects.append(.object(["id": .string(id.uuidString), "name": .string(p.name)]))
                }
            }
            let refresh = try await OAuthSecret.query(on: db).filter(\.$grantID == grant.requireID()).filter(\.$kind == "refresh")
                .filter(\.$consumed == false).sort(\.$expiresAt, .descending).first()
            return .object(["client": client.map { .string($0) } ?? .null, "name": .string(ConnectionNames.display(grant, clientName: client)), "scopes": .strings(grant.scopes), "projects": .array(projects),
                            "refreshExpiresAt": refresh.map { .string(ISO8601DateFormatter().string(from: $0.expiresAt)) } ?? .null])
        case "list_users":
            try requireAdmin()
            let limit = try intArgument(a["limit"], reason: "invalid_limit") ?? 200
            guard (1...500).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
            let rows = try await User.query(on: db).sort(\.$displayName).sort(\.$id).limit(limit).all()
            return try .encoded(rows.map { try AdminUserDTO($0) })
        case "list_invitations":
            try requireAdmin()
            let rows = try await Invitation.query(on: db).sort(\.$expiresAt, .descending).limit(200).all()
            let names = Dictionary(uniqueKeysWithValues: try await User.query(on: db).filter(\.$id ~~ Set(rows.map(\.createdBy))).all().map { ($0.id!, $0.displayName) })
            let now = Date()
            return try .encoded(rows.map {
                InvitationSummary(id: try $0.requireID(), status: $0.usedAt != nil ? "used" : ($0.expiresAt <= now ? "expired" : "open"),
                                  expiresAt: $0.expiresAt, usedAt: $0.usedAt, createdBy: $0.createdBy, createdByName: names[$0.createdBy] ?? "")
            })
        default: throw Abort(.notFound)
        }
    }
}
