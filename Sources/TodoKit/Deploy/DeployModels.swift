import Fluent
import Foundation
import NIOSSL
import Vapor

// ADR 0039, contracts/deploy.yaml: deploy targets of a project (phase 1a: targets, credentials, connection test, read-only compare).
// Only persons create or change targets; agents see id, name, stage, protocol and results, never host, user or secrets.

enum DeployLimits {
    static let maxTargetsPerProject = 20
    static let maxName = 120
    static let maxHost = 253
    static let maxPath = 512
    static let maxUsername = 128
    static let maxSecret = 16_384
    static let maxCertificate = 16_384
    static let maxPatterns = 200
    static let maxPattern = 256
    static let maxMappings = 50
    static let maxManifest = 50_000
    static let maxRepoPath = 1024
    /// Text files up to this size are compared without line ending differences (CRLF on the server, LF in the repo).
    static let textCompareBytes = 2 * 1024 * 1024
    /// Per compare run: files above this size are not downloaded (status `unverified`), and the run stops reading at the total.
    static let maxReadFile = 64 * 1024 * 1024
    static let maxReadTotal = 256 * 1024 * 1024
}

enum DeployProtocol: String, CaseIterable, Sendable {
    case sftp, ftp, ftps
    case ftpsImplicit = "ftps-implicit"
    var defaultPort: Int { switch self { case .sftp: 22; case .ftp, .ftps: 21; case .ftpsImplicit: 990 } }
    var usesTLS: Bool { self == .ftps || self == .ftpsImplicit }
}

/// Repo path -> server path, both relative and `/`-separated (`""` = root of the repo or of the base path).
struct DeployMapping: Codable, Sendable, Equatable { let local: String; let remote: String }

/// A relative path without `..`, `.`, empty segments, backslashes or control characters. `""` is allowed (root).
enum DeployPath {
    static func isSafeRelative(_ path: String, allowEmpty: Bool = true, max: Int = DeployLimits.maxRepoPath) -> Bool {
        if path.isEmpty { return allowEmpty }
        guard path.utf8.count <= max, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    /// Base path: relative to the login directory or absolute; same segment rules.
    static func isSafeBase(_ path: String) -> Bool {
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        if p.hasSuffix("/") { p.removeLast() }
        return isSafeRelative(p, max: DeployLimits.maxPath)
    }
    static func trimmed(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }
    static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : (b.isEmpty ? a : a + "/" + b) }
}

/// Includes, excludes and path mappings of a target (8.2). Globs work on repo paths: `*` and `?` stay within one segment, `**`
/// crosses segments; a pattern without `/` matches the file name at any depth, a pattern with `/` is anchored at the repo root.
struct DeployRules: Sendable {
    /// Always excluded unless the target switches the defaults off: VCS, tooling, tests, docs, dependencies, secrets.
    static let defaultExcludes = [
        "**/.git/**", ".github/**", ".idea/**", ".vscode/**", "**/node_modules/**", "**/tests/**", "docs/**",
        ".env", ".env.*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", ".DS_Store", ".todolino.json", ".todolino-deploy.json",
        ".claude/**", "CLAUDE.md", "AGENTS.md", "phpunit.xml*",
    ]

    let includes: [String]
    let excludes: [String]
    let mappings: [DeployMapping]
    let defaultExcludes: Bool
    private let includeRegex: [NSRegularExpression]
    private let excludeRegex: [NSRegularExpression]

    init(includes: [String], excludes: [String], mappings: [DeployMapping], defaultExcludes: Bool) throws {
        guard includes.count <= DeployLimits.maxPatterns, excludes.count <= DeployLimits.maxPatterns,
              mappings.count <= DeployLimits.maxMappings else { throw Abort(.badRequest, reason: "deploy_rules_invalid") }
        let normalizedMappings = try mappings.map { m -> DeployMapping in
            let local = DeployPath.trimmed(m.local), remote = DeployPath.trimmed(m.remote)
            guard DeployPath.isSafeRelative(local, max: DeployLimits.maxPath), DeployPath.isSafeRelative(remote, max: DeployLimits.maxPath)
            else { throw Abort(.badRequest, reason: "deploy_rules_invalid") }
            return DeployMapping(local: local, remote: remote)
        }
        guard Set(normalizedMappings.map(\.local)).count == normalizedMappings.count,
              Set(normalizedMappings.map(\.remote)).count == normalizedMappings.count else { throw Abort(.badRequest, reason: "deploy_rules_invalid") }
        self.includes = includes; self.excludes = excludes; self.mappings = normalizedMappings; self.defaultExcludes = defaultExcludes
        includeRegex = try includes.map(Self.regex)
        excludeRegex = try (excludes + (defaultExcludes ? Self.defaultExcludes : [])).map(Self.regex)
    }

    var effectiveExcludes: [String] { excludes + (defaultExcludes ? Self.defaultExcludes : []) }
    var effectiveMappings: [DeployMapping] { mappings.isEmpty ? [DeployMapping(local: "", remote: "")] : mappings }

    static func regex(_ pattern: String) throws -> NSRegularExpression {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.utf8.count <= DeployLimits.maxPattern, !p.contains("\\"),
              !p.unicodeScalars.contains(where: { $0.value < 0x20 }),
              !p.split(separator: "/").contains("..") else { throw Abort(.badRequest, reason: "deploy_rules_invalid") }
        var directory = false
        if p.hasSuffix("/") { p.removeLast(); directory = true }
        let anchored = p.contains("/")
        if p.hasPrefix("/") { p.removeFirst() }
        var out = ""
        let chars = Array(p)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    if i + 2 < chars.count, chars[i + 2] == "/" { out += "(?:.*/)?"; i += 3; continue }
                    out += ".*"; i += 2; continue
                }
                out += "[^/]*"
            } else if c == "?" {
                out += "[^/]"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        let body = (anchored ? "" : "(?:.*/)?") + out + (directory ? "/.*" : "")
        return try NSRegularExpression(pattern: "^" + body + "$")
    }

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Not part of the target: matched by an exclude, or includes exist and none matches.
    func isExcluded(_ repoPath: String) -> Bool {
        if excludeRegex.contains(where: { Self.matches($0, repoPath) }) { return true }
        if !includeRegex.isEmpty, !includeRegex.contains(where: { Self.matches($0, repoPath) }) { return true }
        return false
    }

    private static func strip(_ prefix: String, from path: String) -> String? {
        if prefix.isEmpty { return path }
        if path == prefix { return "" }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : nil
    }

    /// Server path (relative to the base path) for a repo file; `nil` when no mapping covers it. The longest local prefix wins.
    func serverPath(forRepo path: String) -> String? {
        let best = effectiveMappings.compactMap { m in Self.strip(m.local, from: path).map { (m, $0) } }.max { $0.0.local.count < $1.0.local.count }
        guard let (m, rest) = best, !rest.isEmpty else { return nil }
        return DeployPath.join(m.remote, rest)
    }

    /// Repo path for a server file; `nil` when no mapping covers it. The longest remote prefix wins.
    func repoPath(forServer path: String) -> String? {
        let best = effectiveMappings.compactMap { m in Self.strip(m.remote, from: path).map { (m, $0) } }.max { $0.0.remote.count < $1.0.remote.count }
        guard let (m, rest) = best, !rest.isEmpty else { return nil }
        return DeployPath.join(m.local, rest)
    }
}

/// Stored form of the rules (JSON in `deploy_targets.rules`) and their API shape.
struct DeployRulesDTO: Content, Equatable {
    var includes: [String]
    var excludes: [String]
    var mappings: [DeployMapping]
    var defaultExcludes: Bool

    init(includes: [String] = [], excludes: [String] = [], mappings: [DeployMapping] = [], defaultExcludes: Bool = true) {
        self.includes = includes; self.excludes = excludes; self.mappings = mappings; self.defaultExcludes = defaultExcludes
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includes = try c.decodeIfPresent([String].self, forKey: .includes) ?? []
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        mappings = try c.decodeIfPresent([DeployMapping].self, forKey: .mappings) ?? []
        defaultExcludes = try c.decodeIfPresent(Bool.self, forKey: .defaultExcludes) ?? true
    }
    func rules() throws -> DeployRules { try DeployRules(includes: includes, excludes: excludes, mappings: mappings, defaultExcludes: defaultExcludes) }
    func encoded() throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(self), as: UTF8.self)
    }
    static func decode(_ text: String) -> DeployRulesDTO { (try? JSONDecoder().decode(DeployRulesDTO.self, from: Data(text.utf8))) ?? DeployRulesDTO() }
}

/// One target. `secret_ciphertext` is AES-256-GCM over `{"password"|"privateKey"|"passphrase"}` with additional data
/// `todolino.deploy.v1:<targetID>:secret:<protocol|host|port|user>`; the plain secret is never stored, returned or logged.
final class DeployTarget: Model, @unchecked Sendable {
    static let schema = "deploy_targets"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "name") var name: String
    /// `test` | `prod`
    @Field(key: "stage") var stage: String
    @Field(key: "protocol") var protocolName: String
    @Field(key: "host") var host: String
    @Field(key: "port") var port: Int
    @Field(key: "base_path") var basePath: String
    @Field(key: "username") var username: String
    /// `password` | `key`
    @Field(key: "auth_method") var authMethod: String
    @Field(key: "secret_ciphertext") var secretCiphertext: String
    @Field(key: "secret_key_id") var secretKeyID: String
    @OptionalField(key: "host_key_type") var hostKeyType: String?
    @OptionalField(key: "host_key_base64") var hostKeyBase64: String?
    /// FTPS: PEM of the only trusted certificate (public data); `nil` = system trust.
    @OptionalField(key: "tls_certificate") var tlsCertificate: String?
    @Field(key: "rules") var rules: String
    @Field(key: "created_by") var createdBy: UUID
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}

    var hostKey: DeployHostKey? {
        guard let hostKeyType, let hostKeyBase64 else { return nil }
        return DeployHostKey(type: hostKeyType, base64: hostKeyBase64)
    }
}

struct CreateDeployTargets: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(DeployTarget.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("stage", .string, .required)
            .field("protocol", .string, .required)
            .field("host", .string, .required)
            .field("port", .int, .required)
            .field("base_path", .sql(unsafeRaw: "TEXT"), .required)
            .field("username", .string, .required)
            .field("auth_method", .string, .required)
            .field("secret_ciphertext", .sql(unsafeRaw: "TEXT"), .required)
            .field("secret_key_id", .string, .required)
            .field("host_key_type", .string)
            .field("host_key_base64", .sql(unsafeRaw: "TEXT"))
            .field("tls_certificate", .sql(unsafeRaw: "TEXT"))
            .field("rules", .sql(unsafeRaw: "TEXT"), .required)
            .field("created_by", .uuid, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(DeployTarget.schema).delete() }
}

func configureDeploy(_ app: Application) {
    app.migrations.add(CreateDeployTargets())
    configureGitHubConnect(app)
    // GitHub App for pull requests (ADR 0042, environment or Docker secret only). A wrong configuration switches the write path
    // off and is named here without values; the server starts anyway.
    app.githubApp = GitHubAppSetup.fromEnvironment { Environment.get($0) }
    if case .invalid(let names) = app.githubApp {
        app.logger.warning("deploy github app configuration invalid, pull requests are switched off", metadata: ["variables": .string(names.joined(separator: ", "))])
    }
}

/// Plain secret of a target (decoded JSON inside the ciphertext).
struct DeploySecret: Codable, Sendable {
    var password: String?
    var privateKey: String?
    var passphrase: String?
}

extension SettingsKeyRing {
    /// Bound to the target and its endpoint: a secret saved for one protocol, host, port and user cannot be opened for another one
    /// (also not after a lost-update race of two changes).
    private func deployAAD(_ targetID: UUID, _ endpoint: String) -> Data { Data("todolino.deploy.v1:\(targetID.uuidString):secret:\(endpoint)".utf8) }

    static func deployEndpoint(protocolName: String, host: String, port: Int, username: String) -> String {
        "\(protocolName)|\(host)|\(port)|\(username)"
    }

    func sealDeploy(_ secret: DeploySecret, targetID: UUID, endpoint: String) throws -> (blob: String, keyID: String) {
        guard let current else { throw Abort(.conflict, reason: "encryption_key_missing") }
        let plain = try JSONEncoder().encode(secret)
        let box = try AES.GCM.seal(plain, using: current.key, nonce: AES.GCM.Nonce(), authenticating: deployAAD(targetID, endpoint))
        guard let combined = box.combined else { throw Abort(.internalServerError, reason: "seal_failed") }
        return ("v1." + combined.base64EncodedString(), current.id)
    }

    func openDeploy(_ blob: String, keyID: String?, targetID: UUID, endpoint: String) throws -> DeploySecret {
        guard blob.hasPrefix("v1."), let combined = Data(base64Encoded: String(blob.dropFirst(3))) else { throw DeployTransportError(code: "deploy_secret_unreadable") }
        for k in ([current].compactMap { $0 } + previous).filter({ keyID == nil || $0.id == keyID }) {
            if let box = try? AES.GCM.SealedBox(combined: combined), let plain = try? AES.GCM.open(box, using: k.key, authenticating: deployAAD(targetID, endpoint)),
               let secret = try? JSONDecoder().decode(DeploySecret.self, from: plain) { return secret }
        }
        throw DeployTransportError(code: "deploy_secret_unreadable")
    }
}

/// A PEM with at least one parseable certificate, nothing else (no private key).
enum DeployCertificate {
    static func validate(_ pem: String) throws -> String {
        let t = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf8.count <= DeployLimits.maxCertificate, t.hasPrefix("-----BEGIN CERTIFICATE-----"), !t.contains("PRIVATE KEY"),
              let certs = try? NIOSSLCertificate.fromPEMBytes(Array(t.utf8)), !certs.isEmpty else {
            throw Abort(.badRequest, reason: "deploy_certificate_invalid")
        }
        return t + "\n"
    }
}
