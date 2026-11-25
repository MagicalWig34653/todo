import Foundation

/// Masks typical secrets in text an agent reports to the live view (ADR 0031). It runs before anything is stored, so
/// the server never holds the secret; the filtered text is the only copy. Heuristic by design: it prefers masking a
/// harmless value (`token: refresh`) over missing a real secret. Pure function, no logging.
enum SecretFilter {
    static let mask = "[gefiltert]"

    struct Result: Equatable {
        let text: String
        let didRedact: Bool
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    // Patterns are literals in this file; a typo must fail loudly in tests, not silently disable a rule.
    private static func insensitive(_ pattern: String, _ template: String = mask) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), template: template)
    }
    private static func sensitive(_ pattern: String, _ template: String = mask) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
    }

    private static let keyWords = "password|passwort|passwd|pass|pwd|passphrase|kennwort|secret|geheim|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credentials?|zugangsdaten|schl(?:ü|ue)ssel|auth|key"

    // Private key blocks, also when the end marker is missing (cut off text).
    private static let privateKeyBlock = sensitive("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)")
    // Cookies carry session ids.
    private static let cookieLine = insensitive("(\\b(?:set-)?cookie[\"']?\\s*[:=]\\s*)[^\\n]+", "$1\(mask)")

    /// Order matters: structured forms first, generic shapes last. Templates use `$1`; the mask has no template characters.
    private static let rules: [Rule] = [
        privateKeyBlock,
        // Authorization header: keep the header name, mask scheme and credentials.
        insensitive("(\\bauthorization[\"']?\\s*[:=]\\s*)(?:(?:bearer|basic|token|digest)\\s+)?[^\\s'\",;]+", "$1\(mask)"),
        cookieLine,
        // CLI flags: --password x, --token=x, -phunter2, curl -u user:pw.
        insensitive("(--?(?:password|passwort|passwd|pass|pwd|token|secret|api-?key|auth)(?:=|\\s+))\\S+", "$1\(mask)"),
        sensitive("(?<=\\s)-p[^\\s=-]\\S{2,}"),
        insensitive("((?:\\s|^)(?:-u|--user)\\s+)\\S+", "$1\(mask)"),
        // Bearer tokens elsewhere.
        insensitive("\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer \(mask)"),
        // user:password@ in URLs.
        insensitive("([a-z][a-z0-9+.-]*://)[^\\s/@:]+:(?!\\d+[/\\s]|\\d+$)\\S*@", "$1\(mask)@"),
        // JWT.
        sensitive("\\beyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]*"),
        // Vendor key shapes.
        sensitive("\\bsk-[A-Za-z0-9_-]{16,}"),
        sensitive("\\bsk_(?:live|test)_[A-Za-z0-9]{8,}"),
        sensitive("\\bglpat-[A-Za-z0-9_-]{16,}"),
        sensitive("\\bgh[pousr]_[A-Za-z0-9]{20,}"),
        sensitive("\\bgithub_pat_[A-Za-z0-9_]{20,}"),
        sensitive("\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b"),
        sensitive("\\bxox[baprs]-[A-Za-z0-9-]{10,}"),
        sensitive("\\bAIza[0-9A-Za-z_-]{35}"),
        // password=..., "api_key": "...", CLIENT_SECRET: ...; the key stays readable.
        insensitive("([A-Za-z0-9_.-]{0,40}(?:\(keyWords))[A-Za-z0-9_.-]{0,40}(?:\\\\?[\"'])?\\s*[:=]\\s*)(\\[gefiltert\\]|\\\\?\"[^\"]*\"|'[^']*'|[^\\s,;&\"']+)", "$1\(mask)"),
    ]

    private static let hex = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{32,}\\b")
    private static let blob = try! NSRegularExpression(pattern: "[A-Za-z0-9+/_-]{40,}={0,2}")

    /// Everything beyond this is cut before the regex rules run (the keyword rule is quadratic on adversarial input).
    static let maxInputScalars = 2048

    /// Unicode tricks (fullwidth colon, zero-width characters inside a key) are folded away first; a second look at the
    /// URL-decoded text catches `password%3Dx`. Heuristic and incomplete by design (ADR 0031).
    static func redact(_ raw: String) -> Result {
        let first = redactOnce(normalize(raw))
        if let decoded = first.text.removingPercentEncoding, decoded != first.text {
            let second = redactOnce(decoded)
            if second.didRedact { return Result(text: second.text, didRedact: true) }
        }
        return first
    }

    /// Long texts that must not be cut (card plans): the rules that reach over a whole block or line run on the whole text,
    /// everything else piece by piece (up to `maxInputScalars`). A piece without a finding stays byte for byte as written.
    static func redactLong(_ raw: String) -> String {
        let blocks = [privateKeyBlock, cookieLine].reduce(raw) { apply($1, to: $0) }
        return pieces(of: blocks).map { piece in
            let result = redact(piece)
            return result.didRedact ? result.text : piece
        }.joined()
    }

    private static func pieces(of text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var result: [String] = []
        var start = 0
        while start < scalars.count {
            var end = min(start + maxInputScalars, scalars.count)
            if end < scalars.count { end = cut(scalars, from: start, limit: end) }
            result.append(string(scalars[start..<end]))
            start = end
        }
        return result
    }

    /// Where the piece starting at `start` ends: after a line break if possible, else after a blank, else after a
    /// separator, else near the limit. A candidate counts only if it does not part a key from its value.
    private static func cut(_ scalars: [Unicode.Scalar], from start: Int, limit: Int) -> Int {
        let breaks: [(Unicode.Scalar) -> Bool] = [{ $0 == "\n" }, { $0 == " " || $0 == "\t" }, { $0 == "," || $0 == ";" || $0 == "&" }]
        // A few candidates of each kind keep the work bounded on adversarial input.
        let perKind = 12
        var candidates: [Int] = []
        for isBreak in breaks {
            candidates += stride(from: limit - 1, through: start, by: -1).lazy.filter { isBreak(scalars[$0]) }.prefix(perKind).map { $0 + 1 }
        }
        candidates += stride(from: limit, to: start, by: -64).prefix(perKind)
        return candidates.first { isSafeCut(scalars, at: $0, from: start) } ?? candidates.first ?? limit
    }

    /// Both sides of the cut, redacted on their own, must read like the two redacted together. The look reaches half a
    /// piece in each direction, so it sees a key left of the cut and its value right of it.
    private static func isSafeCut(_ scalars: [Unicode.Scalar], at cut: Int, from start: Int) -> Bool {
        let reach = maxInputScalars / 2
        let before = string(scalars[max(start, cut - reach)..<cut])
        let after = string(scalars[cut..<min(scalars.count, cut + reach)])
        return redact(before).text + redact(after).text == redact(before + after).text
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView(); view.append(contentsOf: scalars)
        return String(view)
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        rule.regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: rule.template)
    }

    private static func normalize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars.prefix(maxInputScalars) { scalars.append(u) }
        let folded = String(scalars).precomposedStringWithCompatibilityMapping
        let kept = folded.unicodeScalars.filter { $0.properties.generalCategory != .format }
        var out = String.UnicodeScalarView(); out.append(contentsOf: kept)
        return String(out)
    }

    private static func redactOnce(_ input: String) -> Result {
        var text = input
        var changed = false
        for rule in rules {
            let out = apply(rule, to: text)
            if out != text { changed = true; text = out }
        }
        // 40 hex characters are a git commit hash, which agents mention all the time; every other long hex run is a key or digest.
        replace(hex, in: &text, changed: &changed) { $0.count != 40 }
        replace(blob, in: &text, changed: &changed) { candidate in
            // Paths, branch names and identifiers also form long runs; a secret mixes upper, lower and digits.
            let hasUpper = candidate.contains { $0.isASCII && $0.isUppercase }
            let hasLower = candidate.contains { $0.isASCII && $0.isLowercase }
            let hasDigit = candidate.contains { $0.isASCII && $0.isNumber }
            let slashes = candidate.filter { $0 == "/" }.count
            let gitHash = candidate.count == 40 && candidate.allSatisfy { $0.isHexDigit }
            return hasUpper && hasLower && hasDigit && slashes <= 2 && !gitHash
        }
        return Result(text: text, didRedact: changed)
    }

    private static func replace(_ regex: NSRegularExpression, in text: inout String, changed: inout Bool, where qualifies: (String) -> Bool) {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { qualifies(ns.substring(with: $0.range)) }
        guard !matches.isEmpty else { return }
        var out = text
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: mask)
        }
        text = out
        changed = true
    }
}
