import Foundation
import Vapor

/// A syntactically checked webhook URL (https, host, optional port, no credentials). The text is a secret: no `description`,
/// no `CustomStringConvertible`, and errors never repeat it.
struct WebhookURL: Sendable {
    /// Request URL as entered (trimmed).
    let absolute: String
    /// Host without brackets.
    let host: String
    let port: Int
    /// Set when the host is an IP literal (IPv4 or IPv6); then no name resolution takes place.
    let literalIP: String?

    /// `https://host` (IPv6 in brackets). Shown in the API as `https://host/…`; path and query are never part of it.
    var mask: String { "https://" + (literalIP != nil && host.contains(":") ? "[\(host)]" : host) }

    static func parse(_ raw: String) throws -> WebhookURL {
        if true { throw Abort(.notImplemented) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= WebhookLimits.maxURLLength,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }), !text.contains("\\")
        else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        guard let schemeEnd = text.range(of: "://") else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        guard scheme == "https" else { throw Abort(.badRequest, reason: "webhook_url_not_https") }
        let rest = text[schemeEnd.upperBound...]
        let authority = rest.prefix { !"/?#".contains($0) }
        // Credentials in the URL are not accepted (the URL itself is the secret).
        guard !authority.isEmpty, !authority.contains("@") else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        var host = String(authority), portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
                portText = tail.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon]); portText = authority[authority.index(after: colon)...]
        }
        var port = 443
        if let portText {
            guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
                  let p = Int(portText), (1...65535).contains(p) else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
            port = p
        }
        var literal: String?
        if authority.hasPrefix("[") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, host, &v6) == 1 else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
            literal = host
        } else {
            var v4 = in_addr()
            if inet_pton(AF_INET, host, &v4) == 1 { literal = host }
            else {
                // A name: letters, digits, dots and hyphens only (IDNs have to be given as punycode); no colon, bracket or percent sign.
                let name = host.hasSuffix(".") ? String(host.dropLast()) : host
                guard !name.isEmpty, name.utf8.count <= 253,
                      !name.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
                      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
                      name.contains(where: \.isLetter) || name.contains(".")
                else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
            }
        }
        guard URL(string: text) != nil else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        return WebhookURL(absolute: text, host: host.lowercased(), port: port, literalIP: literal)
    }
}
