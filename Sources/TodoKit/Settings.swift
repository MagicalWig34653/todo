import Vapor

/// Runtime settings read from the environment. No replica-local state is needed for correctness.
public struct AppSettings: Sendable {
    public var relyingPartyID: String
    public var relyingPartyName: String
    public var relyingPartyOrigin: String
    /// Server-side switch; checked on every password operation, not only hidden in the UI.
    public var passwordLoginEnabled: Bool
    /// One-time secret that authorises creating the first (admin) account.
    public var bootstrapToken: String?
    public var sessionLifetime: TimeInterval
    public var challengeLifetime: TimeInterval
    public var secureCookies: Bool

    public init(
        relyingPartyID: String = "localhost",
        relyingPartyName: String = "Todo",
        relyingPartyOrigin: String = "http://localhost:25173",
        passwordLoginEnabled: Bool = false,
        bootstrapToken: String? = nil,
        sessionLifetime: TimeInterval = 30 * 24 * 3600,
        challengeLifetime: TimeInterval = 300,
        secureCookies: Bool = false
    ) {
        self.relyingPartyID = relyingPartyID
        self.relyingPartyName = relyingPartyName
        self.relyingPartyOrigin = relyingPartyOrigin
        self.passwordLoginEnabled = passwordLoginEnabled
        self.bootstrapToken = bootstrapToken
        self.sessionLifetime = sessionLifetime
        self.challengeLifetime = challengeLifetime
        self.secureCookies = secureCookies
    }

    public static func fromEnvironment() -> AppSettings {
        var s = AppSettings()
        s.relyingPartyID = Environment.get("RP_ID") ?? s.relyingPartyID
        s.relyingPartyName = Environment.get("RP_NAME") ?? s.relyingPartyName
        s.relyingPartyOrigin = Environment.get("RP_ORIGIN") ?? s.relyingPartyOrigin
        s.passwordLoginEnabled = (Environment.get("PASSWORD_LOGIN_ENABLED") ?? "false") == "true"
        s.bootstrapToken = Environment.get("BOOTSTRAP_TOKEN").flatMap { $0.isEmpty ? nil : $0 }
        s.secureCookies = s.relyingPartyOrigin.hasPrefix("https://")
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
