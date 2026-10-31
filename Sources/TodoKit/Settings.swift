import Crypto
import Vapor

/// Runtime settings read from the environment. No replica-local state is needed for correctness.
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

    public static func fromEnvironment(
        get: (String) -> String? = { Environment.get($0) }
    ) throws -> AppSettings {
        var s = AppSettings()
        s.relyingPartyID = try RuntimeEnvironment.value("RP_ID", get: get) ?? s.relyingPartyID
        s.relyingPartyName = try RuntimeEnvironment.value("RP_NAME", get: get) ?? s.relyingPartyName
        s.relyingPartyOrigin = try RuntimeEnvironment.value("RP_ORIGIN", get: get) ?? s.relyingPartyOrigin
        s.passwordLoginEnabled = (try RuntimeEnvironment.value("PASSWORD_LOGIN_ENABLED", get: get) ?? "false") == "true"
        s.bootstrapToken = try RuntimeEnvironment.value("BOOTSTRAP_TOKEN", get: get).flatMap { $0.isEmpty ? nil : $0 }
        s.oauthIssuer = Self.deriveOAuthIssuer(explicit: try RuntimeEnvironment.value("OAUTH_ISSUER", get: get),
                                               rpOrigin: try RuntimeEnvironment.value("RP_ORIGIN", get: get))
        s.secureCookies = s.relyingPartyOrigin.hasPrefix("https://")
        s.appleAppIDs = (try RuntimeEnvironment.value("AASA_APP_IDS", get: get) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let storage = try RuntimeEnvironment.value("ATTACHMENT_STORAGE", get: get) ?? ""
        if !storage.isEmpty {
            guard let kind = AttachmentStorageKind(rawValue: storage) else { throw AttachmentConfigError.invalid("ATTACHMENT_STORAGE must be database or s3") }
            s.attachmentStorage = kind
        }
        if let raw = try RuntimeEnvironment.value("ATTACHMENT_MAX_BYTES", get: get), !raw.isEmpty {
            guard let bytes = Int(raw), (AttachmentLimits.minMaxBytes...AttachmentLimits.hardMaxBytes).contains(bytes) else {
                throw AttachmentConfigError.invalid("ATTACHMENT_MAX_BYTES must be an integer between \(AttachmentLimits.minMaxBytes) and \(AttachmentLimits.hardMaxBytes)")
            }
            s.attachmentMaxBytes = bytes
        }
        func nonNegative(_ name: String, max: Int, into target: inout Int) throws {
            guard let raw = try RuntimeEnvironment.value(name, get: get), !raw.isEmpty else { return }
            guard let v = Int(raw), (0...max).contains(v) else { throw SettingsError.invalid("\(name) must be an integer between 0 and \(max)") }
            target = v
        }
        try nonNegative("CLEANUP_INTERVAL_MINUTES", max: 10_080, into: &s.cleanupIntervalMinutes)
        try nonNegative("SYNC_RETENTION_DAYS", max: 3_650, into: &s.syncRetentionDays)
        s.apns = try APNsConfig.fromEnvironment(get: get)
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
public struct APNsConfig: Sendable {
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
        var c = APNsConfig()
        if let raw = try RuntimeEnvironment.value("APNS_ENVIRONMENT", get: get), !raw.isEmpty {
            guard let env = APNsEnvironment(rawValue: raw) else { throw SettingsError.invalid("APNS_ENVIRONMENT must be sandbox or production") }
            c.environment = env
        }
        if let raw = try RuntimeEnvironment.value("APNS_TOPIC", get: get), !raw.isEmpty {
            c.topics = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let flag = try RuntimeEnvironment.value("APNS_ENABLED", get: get) ?? "false"
        guard ["true", "false", ""].contains(flag) else { throw SettingsError.invalid("APNS_ENABLED must be true or false") }
        guard flag == "true" else { return c }
        c.enabled = true
        guard !c.topics.isEmpty, c.topics.allSatisfy({ $0.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil }) else {
            throw SettingsError.invalid("APNS_TOPIC must list bundle IDs like de.example.app (comma separated)")
        }
        let id = "^[A-Z0-9]{10}$"
        guard let keyID = try RuntimeEnvironment.value("APNS_KEY_ID", get: get), keyID.range(of: id, options: .regularExpression) != nil else {
            throw SettingsError.invalid("APNS_ENABLED=true needs APNS_KEY_ID (10 characters A-Z0-9, shown next to the key in the developer portal)")
        }
        guard let teamID = try RuntimeEnvironment.value("APNS_TEAM_ID", get: get), teamID.range(of: id, options: .regularExpression) != nil else {
            throw SettingsError.invalid("APNS_ENABLED=true needs APNS_TEAM_ID (10 characters A-Z0-9)")
        }
        guard get("APNS_KEY_FILE") != nil || get("APNS_KEY") != nil, let pem = try RuntimeEnvironment.value("APNS_KEY", get: get), !pem.isEmpty else {
            throw SettingsError.invalid("APNS_ENABLED=true needs the .p8 key: set APNS_KEY_FILE to the path of the Docker secret (e.g. /run/secrets/apns_key)")
        }
        do { _ = try P256.Signing.PrivateKey(pemRepresentation: pem) }
        catch { throw SettingsError.invalid("APNS_KEY_FILE does not contain a valid APNs .p8 key (PEM, EC P-256)") }
        c.keyID = keyID; c.teamID = teamID; c.keyPEM = pem
        return c
    }
}

extension Application {
    private struct SettingsKey: StorageKey { typealias Value = AppSettings }

    public var settings: AppSettings {
        get { storage[SettingsKey.self] ?? AppSettings() }
        set { storage[SettingsKey.self] = newValue }
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
