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
public struct MailConfig: Sendable, Equatable {
    public var enabled = false
    public var host = ""
    public var port = 587
    public var security: SMTPSecurity = .starttls
    public var user: String?
    public var password: String?
    public var from = ""
    public var fromName = "Todolino"
    /// Which connection targets the SMTP client may reach (resolved IP is checked at connect time).
    var protection: OutboundProtection = .standard

    public init() {}

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    static func fromEnvironment(get: (String) -> String?) throws -> MailConfig {
        try SettingsResolver.resolve(env: get, stored: [:]).mailConfig()
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
