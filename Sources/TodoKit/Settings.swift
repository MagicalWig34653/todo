import Crypto
import Vapor

/// Runtime settings: environment first, then values stored by administrators (ADR 0025). Replicas converge by polling.
public struct AppSettings: Sendable {
    public var relyingPartyID: String
    public var relyingPartyName: String
    public var relyingPartyOrigin: String
    /// Public base URL of this server as seen by OAuth/MCP clients (issuer, endpoints, resource indicator, audience).
    /// OAUTH_ISSUER, else RP_ORIGIN when that is not a loopback address, else the dev default.
    public var oauthIssuer: String = AppSettings.defaultOAuthIssuer
    public static let defaultOAuthIssuer = "http://localhost:28080"
    /// RFC 8707 resource indicator of the MCP endpoint; also the audience every grant is bound to.
    public var oauthResource: String { oauthIssuer + "/mcp" }
    /// True when the issuer points to a loopback host (only sensible for development).
    public var oauthIssuerIsLoopback: Bool {
        guard let host = URLComponents(string: oauthIssuer)?.host?.lowercased() else { return true }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    /// Pure derivation, see `oauthIssuer`. Trailing slashes are dropped so `issuer + "/mcp"` stays well formed.
    static func deriveOAuthIssuer(explicit: String?, rpOrigin: String?) -> String {
        func clean(_ v: String?) -> String? {
            guard let t = v?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return t.hasSuffix("/") ? String(t.dropLast(t.reversed().prefix { $0 == "/" }.count)) : t
        }
        if let e = clean(explicit) { return e }
        if let o = clean(rpOrigin), let host = URLComponents(string: o)?.host?.lowercased(),
           !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return o }
        return defaultOAuthIssuer
    }
    /// Server-side switch; checked on every password operation, not only hidden in the UI.
    public var passwordLoginEnabled: Bool
    /// One-time secret that authorises creating the first (admin) account.
    public var bootstrapToken: String?
    public var sessionLifetime: TimeInterval
    public var challengeLifetime: TimeInterval
    public var secureCookies: Bool
    /// Apple app IDs (TeamID.BundleID) for the apple-app-site-association webcredentials entry. Empty: not served.
    public var appleAppIDs: [String]
    /// Where new attachment bytes are written. Existing attachments keep the store recorded on their row.
    public var attachmentStorage: AttachmentStorageKind
    /// Upper bound for one attachment (bytes). Also bounds the PUT request body.
    public var attachmentMaxBytes: Int
    /// Directory with the built PWA, served same-origin next to the API. nil or missing directory: API only.
    public var webRoot: String?
    /// Minutes between automatic cleanup runs (CLEANUP_INTERVAL_MINUTES); 0 disables the in-process scheduler.
    public var cleanupIntervalMinutes: Int = 360
    /// Days after which sync tombstones and stored mutation results are purged (SYNC_RETENTION_DAYS); 0 keeps them.
    public var syncRetentionDays: Int = 90
    /// APNs push configuration (ADR 0021). Disabled unless APNS_ENABLED=true.
    public var apns = APNsConfig()
    /// Outgoing mail (ADR 0024). Disabled unless MAIL_ENABLED=true.
    public var mail = MailConfig()

    public init(
        relyingPartyID: String = "localhost",
        relyingPartyName: String = "Todolino",
        relyingPartyOrigin: String = "http://localhost:25173",
        passwordLoginEnabled: Bool = false,
        bootstrapToken: String? = nil,
        sessionLifetime: TimeInterval = 30 * 24 * 3600,
        challengeLifetime: TimeInterval = 300,
        secureCookies: Bool = false,
        appleAppIDs: [String] = [],
        attachmentStorage: AttachmentStorageKind = .database,
        attachmentMaxBytes: Int = AttachmentLimits.defaultMaxBytes,
        webRoot: String? = nil
    ) {
        self.webRoot = webRoot
        self.relyingPartyID = relyingPartyID
        self.relyingPartyName = relyingPartyName
        self.relyingPartyOrigin = relyingPartyOrigin
        self.passwordLoginEnabled = passwordLoginEnabled
        self.bootstrapToken = bootstrapToken
        self.sessionLifetime = sessionLifetime
        self.challengeLifetime = challengeLifetime
        self.secureCookies = secureCookies
        self.appleAppIDs = appleAppIDs
        self.attachmentStorage = attachmentStorage
        self.attachmentMaxBytes = attachmentMaxBytes
    }

    /// Display name of this instance (`branding.instanceName`).
    public var instanceName = "Todolino"
    /// S3 connection for attachments; nil while endpoint/bucket are not configured.
    var s3: S3Config?

    /// Environment-only resolution (no database): what the process starts with before stored settings are merged.
    public static func fromEnvironment(
        get: (String) -> String? = { Environment.get($0) }
    ) throws -> AppSettings {
        var s = try Self.baseFromEnvironment(get: get)
        let values = try SettingsResolver.resolve(env: get, stored: [:])
        try s.applyHot(values)
        s.applyStartup(values)
        return s
    }

    /// Fixed, environment-only values (never stored in the database, ADR 0025).
    static func baseFromEnvironment(get: (String) -> String?) throws -> AppSettings {
        var s = AppSettings()
        s.relyingPartyID = try RuntimeEnvironment.value("RP_ID", get: get) ?? s.relyingPartyID
        s.relyingPartyName = try RuntimeEnvironment.value("RP_NAME", get: get) ?? s.relyingPartyName
        s.relyingPartyOrigin = try RuntimeEnvironment.value("RP_ORIGIN", get: get) ?? s.relyingPartyOrigin
        s.bootstrapToken = try RuntimeEnvironment.value("BOOTSTRAP_TOKEN", get: get).flatMap { $0.isEmpty ? nil : $0 }
        s.oauthIssuer = Self.deriveOAuthIssuer(explicit: try RuntimeEnvironment.value("OAUTH_ISSUER", get: get),
                                               rpOrigin: try RuntimeEnvironment.value("RP_ORIGIN", get: get))
        s.secureCookies = s.relyingPartyOrigin.hasPrefix("https://")
        // Default /srv/web is where the container image ships the PWA; absent directory means API only.
        s.webRoot = try RuntimeEnvironment.value("WEB_ROOT", get: get) ?? "/srv/web"
        return s
    }
}

public enum APNsEnvironment: String, Sendable, Codable, CaseIterable {
    case sandbox, production
    public var host: String { self == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
}

/// Settings for the APNs sender. The `.p8` key is read from `APNS_KEY_FILE` (a Docker secret) and validated at
/// startup; with `APNS_ENABLED=true` a missing or unparsable key, key ID, team ID or topic is a startup error.
public struct APNsConfig: Sendable, Equatable {
    public var enabled = false
    /// PEM text of the `.p8` key. Never logged or returned by any endpoint.
    public var keyPEM: String?
    public var keyID: String?
    public var teamID: String?
    /// Allowed bundle IDs (apns-topic); the first one is the default for devices that report none.
    public var topics: [String] = ["de.linolaske.todo"]
    /// Used for devices that do not name an environment; each device row may override it.
    public var environment: APNsEnvironment = .production

    public init() {}

    static func fromEnvironment(get: (String) -> String?) throws -> APNsConfig {
        try SettingsResolver.resolve(env: get, stored: [:]).apnsConfig()
    }
}

extension Application {
    private struct SettingsKey: StorageKey { typealias Value = Locked<AppSettings> }

    /// Replaced atomically by the settings runtime when stored settings change (hot reload).
    public var settings: AppSettings {
        get { lockedBox(SettingsKey.self, AppSettings()).value }
        set { lockedBox(SettingsKey.self, AppSettings()).value = newValue }
    }
}

enum SettingsError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let m) = self { return m }; return "invalid settings" }
}

/// File values take precedence. Invalid files fail startup without exposing their contents.
enum RuntimeEnvironment {
    enum ReadError: Error { case unreadableSecret(String) }

    static func value(_ name: String, get: (String) -> String?) throws -> String? {
        guard let path = get(name + "_FILE") else { return get(name) }
        guard !path.isEmpty, let value = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ReadError.unreadableSecret(name)
        }
        // Strip line endings from secret files, preserving meaningful spaces.
        return value.trimmingCharacters(in: .newlines)
    }
}
