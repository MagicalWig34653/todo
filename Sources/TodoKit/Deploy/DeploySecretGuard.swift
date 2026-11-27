import Foundation

/// ADR 0041: what a pull never delivers. The server is untrusted input and its files may hold secrets (`.env`, keys, a `config.php`
/// with a database password); a pull names such files as findings and does not return their content. Names and paths are checked
/// before anything is downloaded, content only for files that would be delivered. Everything here is bounded: patterns run on
/// windows of at most 2 kB, literal markers gate the whole-file patterns.
enum DeploySecretGuard {
    /// `secret_name`, `blocked_path` or `nil`. Works on a repo or server path, `/`-separated, case-insensitive.
    static func pathReason(_ path: String) -> String? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        if parts.dropLast().contains(where: { secretDirectories.contains($0) }) || secretDirectories.contains(name) { return "secret_name" }
        if secretNames.contains(name) { return "secret_name" }
        if name.hasPrefix(".env") || name.hasSuffix(".env") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa")
            || name.hasPrefix("id_dsa") || name.hasPrefix("credentials") { return "secret_name" }
        for ext in secretExtensions where name.hasSuffix("." + ext) || name.contains("." + ext + ".") { return "secret_name" }
        if parts.contains(where: { $0 == ".git" || $0 == ".github" || $0 == ".gitlab" }) || blockedNames.contains(name) { return "blocked_path" }
        return nil
    }

    private static let secretDirectories: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".docker"]
    private static let secretNames: Set<String> = [".htpasswd", ".netrc", ".npmrc", ".pgpass", ".git-credentials", ".pypirc", "secrets.json",
                                                   "secrets.yml", "secrets.yaml", "service-account.json"]
    private static let secretExtensions = ["pem", "key", "p12", "pfx", "jks", "keystore", "ppk", "kdbx", "asc", "gpg"]
    private static let blockedNames: Set<String> = [".gitlab-ci.yml", ".gitattributes", ".gitmodules"]

    // MARK: Content

    private static let keyword = "pass(?:word|wd|phrase)?|pwd|secret|token|api[_\\-]?key|auth[_\\-]?key|private[_\\-]?key|access[_\\-]?key|salt|credential"
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }

    private static let keywordRegex = regex("(?:" + keyword + ")")
    /// `'password' => 'x'`, `$cfg['pass'] = "x"`, `"apiKey": "x"`, `password="x"`.
    private static let quoted = regex("(?:" + keyword + ")[A-Za-z0-9_.\\-]{0,30}['\"\\])]{0,2}\\s{0,3}(?:=>|=|:)\\s{0,3}['\"]([^'\"\\r\\n]{1,200})['\"]")
    /// `password: x` (YAML, INI, env style), at the start of a line.
    private static let bare = regex("^\\s*[A-Za-z0-9_.\\-]{0,30}(?:" + keyword + ")[A-Za-z0-9_.\\-]{0,30}\\s{0,3}[:=]\\s{0,3}([^\\s#'\"$%{<\\[][^\\s#]{0,200})")
    /// `<password>x</password>`
    private static let xml = regex("<[A-Za-z0-9_.\\-]{0,30}(?:" + keyword + ")[A-Za-z0-9_.\\-]{0,30}>\\s{0,3}([^<\\s$%{][^<]{0,200})<")
    private static let define = regex("define\\s*\\(\\s*['\"][A-Za-z0-9_]{0,60}(?:KEY|SALT|PASSWORD|PASS|SECRET|TOKEN)['\"]\\s*,\\s*['\"][^'\"]+['\"]")
    private static let envFallback: [NSRegularExpression] = [
        regex("\\benv\\s*\\(\\s*['\"][^'\"]{0,80}['\"]\\s*,\\s*['\"][^'\"]+['\"]"),
        regex("getenv\\s*\\([^)]{0,100}\\)\\s*(?:\\?:|\\?\\?)\\s*['\"][^'\"]+['\"]"),
        regex("\\?\\?\\s*['\"][^'\"]+['\"]"),
    ]
    /// Whole-file patterns, each gated by a literal marker so a large file costs one substring search per marker.
    private static let universal: [(marker: String, pattern: NSRegularExpression)] = [
        ("PRIVATE KEY-----", regex("-----BEGIN [A-Z ]{0,30}PRIVATE KEY-----")),
        ("AKIA", regex("\\bAKIA[0-9A-Z]{16}\\b")),
        ("gh", regex("\\bgh[pousr]_[A-Za-z0-9]{30,}")),
        ("github_pat_", regex("github_pat_[A-Za-z0-9_]{20,}")),
        ("_live_", regex("\\b[sr]k_live_[A-Za-z0-9]{16,}")),
        ("xox", regex("\\bxox[abprs]-[A-Za-z0-9\\-]{10,}")),
        ("://", regex("://[^/\\s:@'\"]{1,64}:[^/\\s@'\"]{1,128}@")),
        ("PDO", regex("PDO\\s*\\(\\s*['\"][^'\"]{0,256}['\"]\\s*,\\s*['\"][^'\"]{0,128}['\"]\\s*,\\s*['\"][^'\"]+['\"]")),
        ("mysqli", regex("(?:mysqli_connect|new\\s+mysqli)\\s*\\(\\s*['\"][^'\"]{0,128}['\"]\\s*,\\s*['\"][^'\"]{0,128}['\"]\\s*,\\s*['\"][^'\"]+['\"]")),
    ]

    /// A file whose path looks like configuration: the keyword heuristics apply to it.
    static func isConfigLike(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.contains("config") || $0.contains("settings") || $0.contains("secret") || $0.contains("credential") }) { return true }
        guard let name = parts.last, let dot = name.lastIndex(of: ".") else { return false }
        return ["ini", "conf", "cnf", "toml", "properties", "yml", "yaml", "env"].contains(String(name[name.index(after: dot)...]))
    }

    private static func literalValue(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        if v.hasPrefix("$") || v.hasPrefix("%") || v.hasPrefix("{{") || v.hasPrefix("<?") { return false }
        return !["null", "~", "true", "false", "none", "yes", "no"].contains(v.lowercased())
    }

    private static func matches(_ r: NSRegularExpression, _ s: String, valueGroup: Bool = false) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = r.firstMatch(in: s, range: range) else { return false }
        guard valueGroup, m.numberOfRanges > 1, let r1 = Range(m.range(at: 1), in: s) else { return true }
        return literalValue(String(s[r1]))
    }

    /// True when the content looks like it holds a secret. Fail closed: a configuration-like file that is not readable text counts.
    static func containsSecret(path: String, data: Data) -> Bool {
        let config = isConfigLike(path)
        if config, data.prefix(8000).contains(0) { return true }
        let text = String(decoding: data, as: UTF8.self)
        for (marker, pattern) in universal where text.contains(marker) {
            if matches(pattern, text) { return true }
        }
        guard config else { return false }
        // Line heuristics on windows of at most 2 kB (hostile input: one huge line); the first 2 MiB only.
        let window = 2000, overlap = 200
        for lineData in data.prefix(2 * 1024 * 1024).split(separator: 0x0a, omittingEmptySubsequences: true) {
            var start = lineData.startIndex
            while start < lineData.endIndex {
                let end = lineData.index(start, offsetBy: window, limitedBy: lineData.endIndex) ?? lineData.endIndex
                let line = String(decoding: lineData[start..<end], as: UTF8.self)
                if matches(keywordRegex, line) || line.contains("define") {
                    if matches(quoted, line, valueGroup: true) || matches(bare, line, valueGroup: true) || matches(xml, line, valueGroup: true)
                        || matches(define, line) || envFallback.contains(where: { matches($0, line) }) { return true }
                }
                if end == lineData.endIndex { break }
                start = lineData.index(end, offsetBy: -overlap)
            }
        }
        return false
    }
}
