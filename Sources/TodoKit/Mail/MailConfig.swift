import Foundation
import Vapor

public enum SMTPSecurity: String, Sendable, CaseIterable {
    /// Plain connection upgraded with STARTTLS (usually port 587).
    case starttls
    /// TLS from the first byte (usually port 465).
    case tls
    /// No encryption (port 25 relays inside a trusted network, or a local test server).
    case none

    var defaultPort: Int {
        switch self {
        case .starttls: return 587
        case .tls: return 465
        case .none: return 25
        }
    }
}

/// Settings for outgoing mail (ADR 0024). Disabled unless `MAIL_ENABLED=true`; with it, an incomplete or invalid
/// configuration is a startup error. The password is read from `SMTP_PASSWORD_FILE` (Docker secret) and never
/// logged or returned by an endpoint.
public struct MailConfig: Sendable {
    public var enabled = false
    public var host = ""
    public var port = 587
    public var security: SMTPSecurity = .starttls
    public var user: String?
    public var password: String?
    public var from = ""
    public var fromName = "Todolino"

    public init() {}

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    static func fromEnvironment(get: (String) -> String?) throws -> MailConfig {
        var c = MailConfig()
        let flag = try RuntimeEnvironment.value("MAIL_ENABLED", get: get) ?? "false"
        guard ["true", "false", ""].contains(flag) else { throw SettingsError.invalid("MAIL_ENABLED must be true or false") }
        guard flag == "true" else { return c }
        c.enabled = true
        guard let host = try RuntimeEnvironment.value("SMTP_HOST", get: get), !host.isEmpty else {
            throw SettingsError.invalid("MAIL_ENABLED=true needs SMTP_HOST (host name of the mail server)")
        }
        guard host.utf8.allSatisfy({ (33...126).contains($0) }), !host.contains("/"), !host.contains("@") else {
            throw SettingsError.invalid("SMTP_HOST must be a plain host name or IP address")
        }
        c.host = host
        if let raw = try RuntimeEnvironment.value("SMTP_SECURITY", get: get), !raw.isEmpty {
            guard let s = SMTPSecurity(rawValue: raw) else { throw SettingsError.invalid("SMTP_SECURITY must be starttls, tls or none") }
            c.security = s
        }
        c.port = c.security.defaultPort
        if let raw = try RuntimeEnvironment.value("SMTP_PORT", get: get), !raw.isEmpty {
            guard let p = Int(raw), (1...65535).contains(p) else { throw SettingsError.invalid("SMTP_PORT must be a port number (1-65535)") }
            c.port = p
        }
        let user = try RuntimeEnvironment.value("SMTP_USER", get: get).flatMap { $0.isEmpty ? nil : $0 }
        let password = try RuntimeEnvironment.value("SMTP_PASSWORD", get: get).flatMap { $0.isEmpty ? nil : $0 }
        guard (user == nil) == (password == nil) else {
            throw SettingsError.invalid("SMTP_USER and the password (SMTP_PASSWORD_FILE) must be set together or not at all")
        }
        if let user, let password {
            guard user.utf8.count <= 256, password.utf8.count <= 256, !user.utf8.contains(0), !password.utf8.contains(0),
                  !user.utf8.contains(13), !user.utf8.contains(10) else {
                throw SettingsError.invalid("SMTP_USER / SMTP_PASSWORD contain invalid characters or are too long")
            }
            if c.security == .none, !isLoopback(host) {
                throw SettingsError.invalid("SMTP_SECURITY=none with credentials is only allowed for a loopback host; use starttls or tls")
            }
        }
        c.user = user; c.password = password
        guard let from = try RuntimeEnvironment.value("MAIL_FROM", get: get), MailAddress.isValid(from) else {
            throw SettingsError.invalid("MAIL_ENABLED=true needs MAIL_FROM with a valid sender address (e.g. todolino@example.org)")
        }
        c.from = from
        if let name = try RuntimeEnvironment.value("MAIL_FROM_NAME", get: get), !name.isEmpty {
            guard name.utf8.count <= 128, !name.utf8.contains(13), !name.utf8.contains(10), !name.utf8.contains(0) else {
                throw SettingsError.invalid("MAIL_FROM_NAME is too long or contains control characters")
            }
            c.fromName = name
        }
        return c
    }
}

/// Address handling shared by the account settings and the SMTP envelope.
enum MailAddress {
    /// Trimmed and lower-cased (simplification: local parts are case-insensitive in practice; documented in ADR 0024).
    static func normalize(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Conservative ASCII check: no display names, quotes, comments or internationalised addresses.
    static func isValid(_ address: String) -> Bool {
        guard address.utf8.count <= 254, address.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."),
              !parts[0].contains(".."), parts[0].allSatisfy({ $0.isLetter || $0.isNumber || "!#$%&'*+-/=?^_`{|}~.".contains($0) }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && l.first != "-" && l.last != "-" && l.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}
