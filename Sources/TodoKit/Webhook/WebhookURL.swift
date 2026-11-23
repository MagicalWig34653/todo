import Foundation
import Vapor

/// A syntactically checked webhook URL (https, host, port 443 only, no credentials). The text is a secret: no `description`,
/// no `CustomStringConvertible`, and errors never repeat it.
struct WebhookURL: Sendable {
    /// URL as entered (trimmed). Never sent as is: see `requestURL`.
    let absolute: String
    /// Host without brackets, lower case, without a trailing dot. This exact text is the key of the DNS pinning.
    let host: String
    let port: Int
    /// Path, query (case kept) of the entered URL; no fragment. Empty when there is none.
    let pathAndQuery: String
    /// Set when the host is an IP literal (IPv4 or IPv6); then no name resolution takes place.
    let literalIP: String?

    /// `https://host` (IPv6 in brackets). Shown in the API as `https://host/…`; path and query are never part of it.
    var mask: String { "https://" + (literalIP != nil && host.contains(":") ? "[\(host)]" : host) }

    /// The URL that goes to the HTTP client, built from the parsed parts: the client takes the host from this text and looks it up
    /// in the DNS pinning table by that exact spelling. Foundation keeps the spelling of what was entered (`Example.COM`,
    /// a trailing dot), so the entered text must not be used. `port` nil leaves the default of the scheme (tests use other values).
    func requestURL(scheme: String = "https", port: Int? = nil) -> String {
        let hostText = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(hostText)\(port.map { ":\($0)" } ?? "")\(pathAndQuery)"
    }

    static func parse(_ raw: String) throws -> WebhookURL {
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
        // Path and query as entered; the fragment never goes out.
        let afterAuthority = rest.dropFirst(authority.count)
        let pathAndQuery = String(afterAuthority.prefix { $0 != "#" })
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
        // Port 443 only (explicit `:443` is fine): the webhook is a plain https endpoint, and other ports would let the
        // server probe services on a host.
        if let portText {
            guard portText == "443" else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        }
        let port = 443
        var literal: String?
        // A trailing dot names the same host ("example.com."): the spelling without it is the one checked, resolved and sent.
        if !authority.hasPrefix("["), host.hasSuffix("."), host.count > 1 { host = String(host.dropLast()) }
        if authority.hasPrefix("[") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, host, &v6) == 1 else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
            literal = host
        } else {
            var v4 = in_addr()
            if inet_pton(AF_INET, host, &v4) == 1 { literal = host }
            else {
                // A name: letters, digits, dots and hyphens only (IDNs have to be given as punycode); no colon, bracket or percent sign.
                let name = host
                guard !name.isEmpty, name.utf8.count <= 253,
                      !name.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.count > 63 || $0.hasPrefix("-") || $0.hasSuffix("-") }),
                      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
                      name.contains(where: \.isLetter) || name.contains(".")
                else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
            }
        }
        guard URL(string: text) != nil else { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        return WebhookURL(absolute: text, host: host.lowercased(), port: port, pathAndQuery: pathAndQuery, literalIP: literal)
    }
}
