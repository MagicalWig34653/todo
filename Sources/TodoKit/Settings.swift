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
        // Default /srv/web is where the container image ships the PWA; absent directory means API only.
        s.webRoot = try RuntimeEnvironment.value("WEB_ROOT", get: get) ?? "/srv/web"
        return s
    }
}

extension Application {
    private struct SettingsKey: StorageKey { typealias Value = AppSettings }

    public var settings: AppSettings {
        get { storage[SettingsKey.self] ?? AppSettings() }
        set { storage[SettingsKey.self] = newValue }
    }
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
