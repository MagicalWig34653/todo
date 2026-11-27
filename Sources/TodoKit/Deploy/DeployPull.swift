import Foundation
import Vapor

// ADR 0041, contracts/deploy.yaml 1.1.0: pulling server changes. Read only on the server; the answer carries the files, the
// branch name and a commit message. Branch and commit are made by the person or the agent in their own checkout
// (scripts/deploy-pull-apply.py): the server has no write access to GitHub and no credentials for it.

enum DeployPullLimits {
    /// Per file delivered in one answer; larger files are named as findings (`too_large`).
    static let maxFile = 8 * 1024 * 1024
    static let maxBytesCeiling = 16 * 1024 * 1024
    static let defaultBytesREST = 4 * 1024 * 1024
    static let defaultBytesMCP = 256 * 1024
    static let maxSelection = 5_000
    static let maxFindings = 500
}

struct DeployPullRequest: Decodable {
    var files: [DeployManifestEntry]
    var paths: [String]?
    var maxBytes: Int?
    var eol: String?
}

struct DeployPullFile: Content, Equatable {
    /// Repo path.
    let path: String
    /// Path relative to the base path of the target.
    let serverPath: String
    /// `changed` | `serverOnly`
    let status: String
    /// Line ending policy applied: `lf` | `crlf` | `keep`, or `binary` (bytes untouched).
    let eol: String
    /// `utf-8` (content is text) | `base64`
    let encoding: String
    let content: String
    let size: Int
    let sha256: String
}

struct DeployPullFinding: Content, Equatable {
    let path: String
    let serverPath: String
    /// `secret_name` | `blocked_path` | `secret_content` | `excluded` | `too_large` | `unreadable`
    let reason: String
}

struct DeployPullSummary: Content, Equatable {
    var changed = 0, serverOnly = 0, onlyInRepo = 0, same = 0, withheld = 0, unverified = 0
}

struct DeployPullResult: Content {
    let ok: Bool
    let code: String?
    let branch: String?
    let commitMessage: String?
    let summary: DeployPullSummary?
    let files: [DeployPullFile]?
    let findings: [DeployPullFinding]?
    let findingsTotal: Int?
    let remaining: [String]?

    static func failure(_ code: String) -> DeployPullResult {
        DeployPullResult(ok: false, code: code, branch: nil, commitMessage: nil, summary: nil, files: nil, findings: nil, findingsTotal: nil, remaining: nil)
    }
}

enum DeployEOL {
    static func isBinary(_ data: Data) -> Bool { data.prefix(8000).contains(0) }

    /// CRLF -> LF; a lone CR stays.
    static func toLF(_ data: Data) -> Data {
        guard data.contains(0x0d) else { return data }
        var out = Data(capacity: data.count)
        var previousCR = false
        for b in data {
            if previousCR, b != 0x0a { out.append(0x0d) }
            previousCR = b == 0x0d
            if !previousCR { out.append(b) }
        }
        if previousCR { out.append(0x0d) }
        return out
    }

    /// Every line ending CRLF (after `toLF`).
    static func toCRLF(_ data: Data) -> Data {
        let lf = toLF(data)
        guard lf.contains(0x0a) else { return lf }
        var out = Data(capacity: lf.count + lf.count / 20)
        for b in lf { if b == 0x0a { out.append(0x0d) }; out.append(b) }
        return out
    }

    static func apply(_ policy: String, to data: Data) -> Data {
        isBinary(data) ? data : (policy == "crlf" ? toCRLF(data) : policy == "lf" ? toLF(data) : data)
    }
}

struct DeployPullOutcome {
    var droppedFindings = 0
    var remainingTotal = 0
    var summary = DeployPullSummary()
    var files: [DeployPullFile] = []
    var findings: [DeployPullFinding] = []
    var remaining: [String] = []
}

extension DeployService {
    static func validPull(_ r: DeployPullRequest, defaultBytes: Int) throws -> (maxBytes: Int, eol: String, selection: Set<String>?) {
        let maxBytes = r.maxBytes ?? defaultBytes
        let eol = r.eol ?? "lf"
        guard (1...DeployPullLimits.maxBytesCeiling).contains(maxBytes), ["lf", "keep"].contains(eol) else {
            throw Abort(.badRequest, reason: "deploy_pull_invalid")
        }
        var selection: Set<String>?
        if let paths = r.paths {
            guard paths.count <= DeployPullLimits.maxSelection, paths.allSatisfy({ DeployPath.isSafeRelative($0, allowEmpty: false) }) else {
                throw Abort(.badRequest, reason: "deploy_pull_invalid")
            }
            selection = Set(paths)
        }
        return (maxBytes, eol, selection)
    }

    /// Pure pull: the server listing against the repo manifest, after rules and mappings. Files named as secrets, in blocked
    /// paths or excluded are never read; files that may only differ in line endings are read to find out; what is left
    /// (changed or only on the server) is read within the byte budget, checked for secret content and delivered with the line
    /// endings of the repo.
    static func pull(repo: [String: DeployManifestEntry], server listed: [DeployRemoteFile], rules: DeployRules, selection: Set<String>?,
                     maxBytes: Int, defaultEOL: String, read: ([String]) async throws -> [String: Data]) async throws -> DeployPullOutcome {
        var wanted: [String: (repoPath: String, entry: DeployManifestEntry)] = [:]
        for (path, entry) in repo where !rules.isExcluded(path) {
            if let s = rules.serverPath(forRepo: path), rules.repoPath(forServer: s) == path { wanted[s] = (path, entry) }
        }
        var onServer: [String: Int] = [:]
        for f in listed where DeployPath.isSafeRelative(f.path, allowEmpty: false) { onServer[f.path] = f.size }

        var out = DeployPullOutcome()
        out.summary.onlyInRepo = wanted.filter { onServer[$0.key] == nil && (selection?.contains($0.value.repoPath) ?? true) }.count

        struct Candidate { let repoPath: String; let serverPath: String; let size: Int; let entry: DeployManifestEntry? }
        var candidates: [Candidate] = []
        func finding(_ repoPath: String, _ serverPath: String, _ reason: String, withheld: Bool = true) {
            if withheld { out.summary.withheld += 1 }
            if out.findings.count < DeployPullLimits.maxFindings { out.findings.append(DeployPullFinding(path: repoPath, serverPath: serverPath, reason: reason)) }
            else { out.droppedFindings += 1 }
        }
        for (serverPath, size) in onServer.sorted(by: { $0.key < $1.key }) {
            guard let repoPath = rules.repoPath(forServer: serverPath), rules.serverPath(forRepo: repoPath) == serverPath else { continue }
            if let s = selection, !s.contains(repoPath) { continue }
            if let reason = DeploySecretGuard.pathReason(serverPath) ?? DeploySecretGuard.pathReason(repoPath) { finding(repoPath, serverPath, reason); continue }
            if rules.isExcluded(repoPath) { finding(repoPath, serverPath, "excluded"); continue }
            candidates.append(Candidate(repoPath: repoPath, serverPath: serverPath, size: size, entry: wanted[serverPath]?.entry))
        }
        candidates.sort { $0.repoPath < $1.repoPath }

        func policy(_ c: Candidate) -> String { c.entry?.eol ?? defaultEOL }
        func isSame(_ data: Data, _ c: Candidate) -> Bool {
            guard let entry = c.entry else { return false }
            return sha256(data) == entry.sha256 || sha256(DeployEOL.apply(policy(c), to: data)) == entry.sha256
        }

        // 1. Files that may only differ in line endings are read to tell "same" from "changed".
        var verify: [String] = []
        var readBudget = DeployLimits.maxReadTotal
        var unverified = Set<String>()
        for c in candidates {
            guard let entry = c.entry else { continue }
            let maybeEqual = c.size == entry.size || (c.size <= DeployLimits.textCompareBytes && entry.size <= c.size * 2 + 2 && c.size <= entry.size * 2 + 2)
            guard maybeEqual else { continue }
            if c.size > DeployLimits.maxReadFile || c.size > readBudget { unverified.insert(c.serverPath); continue }
            readBudget -= c.size
            verify.append(c.serverPath)
        }
        var contents = verify.isEmpty ? [:] : try await read(verify)

        var pending: [Candidate] = []
        for c in candidates {
            if unverified.contains(c.serverPath) { out.summary.unverified += 1; continue }
            if verify.contains(c.serverPath) {
                guard let data = contents[c.serverPath] else { finding(c.repoPath, c.serverPath, "unreadable", withheld: false); continue }
                if isSame(data, c) { out.summary.same += 1; contents[c.serverPath] = nil; continue }
            }
            if c.entry == nil { out.summary.serverOnly += 1 } else { out.summary.changed += 1 }
            pending.append(c)
        }

        // 2. Within the budget: too large files are named, the rest of the list waits for the next call.
        var accepted: [Candidate] = []
        var used = 0, stopped = false
        for c in pending {
            if c.size > DeployPullLimits.maxFile { finding(c.repoPath, c.serverPath, "too_large", withheld: false); continue }
            if stopped { out.remaining.append(c.repoPath); continue }
            if !accepted.isEmpty, used + c.size > maxBytes { stopped = true; out.remaining.append(c.repoPath); continue }
            used += c.size
            accepted.append(c)
        }
        let missing = accepted.map(\.serverPath).filter { contents[$0] == nil }
        if !missing.isEmpty { for (k, v) in try await read(missing) { contents[k] = v } }

        // 3. Secret content check, line endings, encoding.
        for c in accepted {
            guard let data = contents[c.serverPath] else { finding(c.repoPath, c.serverPath, "unreadable", withheld: false); continue }
            if DeploySecretGuard.containsSecret(path: c.repoPath, data: data) { finding(c.repoPath, c.serverPath, "secret_content"); continue }
            let binary = DeployEOL.isBinary(data)
            let applied = policy(c)
            let result = DeployEOL.apply(applied, to: data)
            // Text goes as a JSON string. A leading BOM would be lost in some JSON readers (Foundation drops it), so such a file
            // travels as base64, like any file that is not valid UTF-8.
            let text = binary || result.starts(with: [0xef, 0xbb, 0xbf]) || String(data: result, encoding: .utf8) == nil ? nil : String(decoding: result, as: UTF8.self)
            out.files.append(DeployPullFile(path: c.repoPath, serverPath: c.serverPath, status: c.entry == nil ? "serverOnly" : "changed",
                                            eol: binary ? "binary" : applied, encoding: text == nil ? "base64" : "utf-8",
                                            content: text ?? result.base64EncodedString(), size: result.count, sha256: sha256(result)))
        }
        return out
    }

    static func branchName(target: String, now: Date = Date()) -> String {
        var slug = ""
        for ch in target.lowercased() {
            switch ch {
            case "ä": slug += "ae"
            case "ö": slug += "oe"
            case "ü": slug += "ue"
            case "ß": slug += "ss"
            case "a"..."z", "0"..."9": slug.append(ch)
            default: if slug.last != "-" { slug.append("-") }
            }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "server/\(slug.isEmpty ? "ziel" : slug)-\(day(now))"
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Berlin"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func commitMessage(target: String, outcome: DeployPullOutcome, now: Date = Date()) -> String {
        let changed = outcome.files.filter { $0.status == "changed" }, added = outcome.files.filter { $0.status == "serverOnly" }
        var lines = ["Server-Änderungen von „\(target)“ geholt (\(day(now)), \(outcome.files.count) \(outcome.files.count == 1 ? "Datei" : "Dateien"))", ""]
        if !changed.isEmpty { lines += ["Auf dem Server geändert:"] + changed.map { "- \($0.path)" } + [""] }
        if !added.isEmpty { lines += ["Neu auf dem Server:"] + added.map { "- \($0.path)" } + [""] }
        let names: [String: String] = ["secret_name": "Dateiname wie ein Geheimnis", "blocked_path": "Pfad gesperrt", "secret_content": "Inhalt wie ein Geheimnis",
                                       "excluded": "ausgeschlossen", "too_large": "zu groß", "unreadable": "nicht lesbar"]
        if !outcome.findings.isEmpty {
            lines.append("Nicht geholt:")
            lines += outcome.findings.prefix(20).map { "- \($0.path) (\(names[$0.reason] ?? $0.reason))" }
            if outcome.findings.count + outcome.droppedFindings > 20 { lines.append("- … und \(outcome.findings.count + outcome.droppedFindings - 20) weitere") }
            lines.append("")
        }
        lines.append("Geholt mit Todolino (nur gelesen, auf dem Server wurde nichts geändert). Vor dem Zusammenführen prüfen und nach Zweck gruppieren.")
        return lines.joined(separator: "\n")
    }

    func pull(_ id: UUID, request: DeployPullRequest, defaultBytes: Int) async throws -> DeployPullResult {
        let t = try await target(id, role: .edit)
        let repo = try Self.validManifest(request.files)
        let options = try Self.validPull(request, defaultBytes: defaultBytes)
        let rules = try DeployRulesDTO.decode(t.rules).rules()
        guard t.protocolName != DeployProtocol.sftp.rawValue || t.hostKey != nil else { return .failure("deploy_host_key_unconfirmed") }
        do {
            let conn = try connection(t, address: try await connectAddress(t))
            let listed = try await app.deployTransport.list(conn)
            let outcome = try await Self.pull(repo: repo, server: listed, rules: rules, selection: options.selection, maxBytes: options.maxBytes,
                                              defaultEOL: options.eol) { paths in try await app.deployTransport.read(conn, paths: paths) }
            app.logger.info("deploy pull ok", metadata: ["target": .string(id.uuidString), "files": .stringConvertible(outcome.files.count),
                                                         "withheld": .stringConvertible(outcome.summary.withheld)])
            return DeployPullResult(ok: true, code: nil, branch: Self.branchName(target: t.name), commitMessage: Self.commitMessage(target: t.name, outcome: outcome),
                                    summary: outcome.summary, files: outcome.files, findings: outcome.findings,
                                    findingsTotal: outcome.findings.count + outcome.droppedFindings, remaining: outcome.remaining)
        } catch let e as DeployTransportError {
            return .failure(failure(t, e.code, "pull"))
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" {
            return .failure(failure(t, "deploy_target_blocked", "pull"))
        }
    }
}

extension DeployController {
    @Sendable func pull(_ req: Request) async throws -> DeployPullResult {
        let s = DeployService(app: req.application, user: try await req.requireUser())
        let body: DeployPullRequest
        do { body = try req.content.decode(DeployPullRequest.self) } catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
        guard let id = req.parameters.get("targetID", as: UUID.self) else { throw Abort(.notFound) }
        return try await s.pull(id, request: body, defaultBytes: DeployPullLimits.defaultBytesREST)
    }
}
