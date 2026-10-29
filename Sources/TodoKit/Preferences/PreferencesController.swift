import Fluent
import Vapor

struct AppearancePreferences: Content, Equatable {
    var colorScheme: String
    var accent: String
    var accentCustomHex: String?
    var glow: String

    static let defaults = AppearancePreferences(colorScheme: "system", accent: "blue", accentCustomHex: nil, glow: "subtle")
    static let colorSchemes: Set<String> = ["system", "light", "dark"]
    static let glows: Set<String> = ["off", "subtle", "medium", "strong"]
    static let accents: Set<String> = [
        "blue", "teal", "violet", "green", "orange", "pink", "graphite", "indigo", "navy", "purple", "magenta",
        "crimson", "forest", "petrol", "bronze", "wine", "slate", "cocoa", "olive", "ocean", "ink", "custom",
    ]
}

/// The stored document. Top-level sections are namespaced so later preference groups need no new endpoint.
struct PreferencesDocument: Content, Equatable {
    static let currentVersion = 1
    var version: Int
    var appearance: AppearancePreferences

    static let defaults = PreferencesDocument(version: currentVersion, appearance: .defaults)

    /// Strict validation of a client document: exact keys, known enum values, hex colour exactly for `custom`.
    static func validated(from data: Data) throws -> PreferencesDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Abort(.badRequest, reason: "invalid_preferences")
        }
        guard Set(root.keys).isSubset(of: ["version", "appearance"]) else { throw Abort(.badRequest, reason: "unknown_preferences_key") }
        guard let version = root["version"] as? Int, version >= 1, version <= currentVersion else {
            throw Abort(.badRequest, reason: "unsupported_preferences_version")
        }
        guard let a = root["appearance"] as? [String: Any],
            Set(a.keys).isSubset(of: ["colorScheme", "accent", "accentCustomHex", "glow"]),
            let scheme = a["colorScheme"] as? String, AppearancePreferences.colorSchemes.contains(scheme),
            let accent = a["accent"] as? String, AppearancePreferences.accents.contains(accent),
            let glow = a["glow"] as? String, AppearancePreferences.glows.contains(glow)
        else { throw Abort(.badRequest, reason: "invalid_preferences") }
        var hex: String?
        if let raw = a["accentCustomHex"], !(raw is NSNull) {
            guard let s = raw as? String, s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                throw Abort(.badRequest, reason: "invalid_preferences")
            }
            hex = s.uppercased()
        }
        guard (accent == "custom") == (hex != nil) else { throw Abort(.badRequest, reason: "invalid_preferences") }
        return PreferencesDocument(version: currentVersion, appearance: .init(colorScheme: scheme, accent: accent, accentCustomHex: hex, glow: glow))
    }

    /// Upgrades a stored document of an older schema version. Only version 1 exists so far.
    static func migrated(version: Int, document: String) throws -> PreferencesDocument {
        guard let data = document.data(using: .utf8) else { throw Abort(.internalServerError) }
        switch version {
        case 1: return try JSONDecoder().decode(PreferencesDocument.self, from: data)
        default: throw Abort(.internalServerError, reason: "unknown_stored_preferences_version")
        }
    }
}

struct PreferencesResponse: Content {
    var version: Int
    var appearance: AppearancePreferences
    /// 0 while nothing was stored (defaults apply).
    var revision: Int
    var updatedAt: Date?
}

struct PreferencesController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("v1", "me", "preferences", use: get)
        routes.put("v1", "me", "preferences", use: put)
    }

    private func response(_ row: UserPreferences?) throws -> PreferencesResponse {
        guard let row else {
            return PreferencesResponse(version: PreferencesDocument.currentVersion, appearance: .defaults, revision: 0, updatedAt: nil)
        }
        let doc = try PreferencesDocument.migrated(version: row.version, document: row.document)
        return PreferencesResponse(version: doc.version, appearance: doc.appearance, revision: row.revision, updatedAt: row.updatedAt)
    }

    @Sendable func get(_ req: Request) async throws -> PreferencesResponse {
        let userID = try await req.requireUser().requireID()
        return try response(try await UserPreferences.query(on: req.db).filter(\.$userID == userID).first())
    }

    @Sendable func put(_ req: Request) async throws -> PreferencesResponse {
        let userID = try await req.requireUser().requireID()
        guard let buffer = req.body.data, buffer.readableBytes <= 4096 else { throw Abort(.badRequest, reason: "invalid_preferences") }
        let doc = try PreferencesDocument.validated(from: Data(buffer.readableBytesView))
        let text = String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
        let row = try await req.db.transaction { db -> UserPreferences in
            try await lockRow(table: User.schema, id: userID, on: db)
            let existing = try await UserPreferences.query(on: db).filter(\.$userID == userID).first()
            let row = existing ?? UserPreferences()
            row.userID = userID
            row.version = doc.version
            row.document = text
            row.revision = (existing?.revision ?? 0) + 1
            row.updatedAt = Date()
            try await row.save(on: db)
            return row
        }
        return try response(row)
    }
}
