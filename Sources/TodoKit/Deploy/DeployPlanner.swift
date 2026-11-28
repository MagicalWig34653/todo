import Foundation

// ADR 0044: the pure part of a plan: repo state against server state against what Todolino last left on the server.

/// What is on the server at one path.
struct DeployServerFileState: Sendable, Equatable {
    /// SHA-256 of the bytes; `""` = absent, `"?"` = listed but not readable or too large to check.
    let sha256: String
    /// SHA-256 without line ending differences (text only).
    var normalized: String? = nil
    var size: Int? = nil
    var absent: Bool { sha256.isEmpty }
    var unchecked: Bool { sha256 == "?" }
    static let missing = DeployServerFileState(sha256: "")
}

struct DeployPlanOutcome {
    var items: [DeployPlanItem] = []
    var blockers: [DeployBlocker] = []
    var findings: [DeployPullFinding] = []
    var summary = DeployPlanSummary()
    var observed: [String: String] = [:]
    var manifest: [String: DeployManifestState] = [:]
}

enum DeployPlanner {
    /// Name ending of a file while it is being uploaded.
    static let temporarySuffix = ".todolino.tmp"

    /// Leftovers of an interrupted upload; never part of a repo state and never shown as server files.
    static func isTemporary(_ path: String) -> Bool { path.hasSuffix(temporarySuffix) }

    /// Repo files that may go to the server (server path -> repo file); the rest is named as finding.
    static func wanted(repo: [String: DeployManifestEntry], rules: DeployRules)
        -> (files: [String: (path: String, entry: DeployManifestEntry)], findings: [DeployPullFinding]) {
        var files: [String: (path: String, entry: DeployManifestEntry)] = [:]
        var findings: [DeployPullFinding] = []
        for (path, entry) in repo.sorted(by: { $0.key < $1.key }) {
            guard let serverPath = rules.serverPath(forRepo: path), rules.repoPath(forServer: serverPath) == path else {
                findings.append(DeployPullFinding(path: path, serverPath: "", reason: "excluded")); continue
            }
            if isTemporary(path) || isTemporary(serverPath) { findings.append(DeployPullFinding(path: path, serverPath: serverPath, reason: "blocked_path")) }
            else if let reason = DeploySecretGuard.pathReason(serverPath) ?? DeploySecretGuard.pathReason(path) {
                findings.append(DeployPullFinding(path: path, serverPath: serverPath, reason: reason))
            } else if rules.isExcluded(path) { findings.append(DeployPullFinding(path: path, serverPath: serverPath, reason: "excluded")) }
            else { files[serverPath] = (path, entry) }
        }
        return (files, findings)
    }

    /// The server state of `paths`: absent when not listed, otherwise read (within the limits) and hashed.
    static func states(of paths: [String], listed: [DeployRemoteFile], read: ([String]) async throws -> [String: Data])
        async throws -> (states: [String: DeployServerFileState], contents: [String: Data]) {
        var sizes: [String: Int] = [:]
        for f in listed where DeployPath.isSafeRelative(f.path, allowEmpty: false) { sizes[f.path] = f.size }
        var states: [String: DeployServerFileState] = [:]
        var toRead: [String] = []
        var budget = DeployLimits.maxReadTotal
        for path in paths.sorted() {
            guard let size = sizes[path] else { states[path] = .missing; continue }
            if size > DeployLimits.maxReadFile || size > budget { states[path] = DeployServerFileState(sha256: "?", size: size); continue }
            budget -= size
            toRead.append(path)
        }
        let contents = toRead.isEmpty ? [:] : try await read(toRead)
        for path in toRead {
            guard let data = contents[path] else { states[path] = DeployServerFileState(sha256: "?", size: sizes[path]); continue }
            states[path] = DeployServerFileState(sha256: DeployService.sha256(data),
                                                 normalized: DeployService.normalized(data).map(DeployService.sha256), size: data.count)
        }
        return (states, contents)
    }

    /// An upload plan. `last` = what Todolino knows from its runs at this endpoint. Any file that differs from that knowledge is
    /// a change made on the server and locks the plan; so is a differing file Todolino never wrote.
    static func upload(wanted: [String: (path: String, entry: DeployManifestEntry)], last: [String: DeployManifestState],
                       states: [String: DeployServerFileState]) -> DeployPlanOutcome {
        var out = DeployPlanOutcome()
        out.manifest = last
        for (serverPath, (path, entry)) in wanted.sorted(by: { $0.key < $1.key }) {
            let state = states[serverPath] ?? .missing
            out.observed[serverPath] = state.sha256
            if !state.absent, state.sha256 == entry.sha256 || state.normalized == entry.sha256 {
                out.summary.unchanged += 1
                out.manifest[serverPath] = DeployManifestState(path: path, sha256: state.sha256)
                continue
            }
            let known = last[serverPath]
            var reason = "drift"
            if state.unchecked { out.blockers.append(DeployBlocker(path: path, serverPath: serverPath, reason: "unverified")) }
            else if state.absent {
                if known == nil { reason = "new" } else { out.blockers.append(DeployBlocker(path: path, serverPath: serverPath, reason: "server_deleted")) }
            } else if known == nil {
                out.blockers.append(DeployBlocker(path: path, serverPath: serverPath, reason: "unknown_server_state"))
            } else if known?.sha256 == state.sha256 { reason = "changed" }
            else { out.blockers.append(DeployBlocker(path: path, serverPath: serverPath, reason: "server_changed")) }
            out.items.append(DeployPlanItem(path: path, serverPath: serverPath, action: "upload", reason: reason,
                                            baseSha: state.absent ? nil : state.sha256, baseSize: state.size,
                                            newSha: entry.sha256, newSize: entry.size,
                                            after: DeployManifestState(path: path, sha256: entry.sha256)))
        }
        // Files Todolino knows that the repo state no longer holds: never written or deleted, but a change there locks too.
        for (serverPath, known) in last.sorted(by: { $0.key < $1.key }) where wanted[serverPath] == nil {
            let state = states[serverPath] ?? .missing
            out.observed[serverPath] = state.sha256
            if state.absent { out.manifest[serverPath] = nil }
            else if state.unchecked { out.blockers.append(DeployBlocker(path: known.path, serverPath: serverPath, reason: "unverified")) }
            else if state.sha256 != known.sha256 { out.blockers.append(DeployBlocker(path: known.path, serverPath: serverPath, reason: "server_changed")) }
        }
        out.summary.upload = out.items.count
        return out
    }

    /// The way back of one run: every file it touched returns to what it was before (backup or absent). `known` = the knowledge
    /// now, `previous` = the knowledge before that run.
    static func rollback(source: [DeployPlanItem], known: [String: DeployManifestState], previous: [String: DeployManifestState],
                         states: [String: DeployServerFileState]) -> (outcome: DeployPlanOutcome, backups: [Int]) {
        var out = DeployPlanOutcome()
        out.manifest = known
        var backups: [Int] = []   // for each upload item of the outcome: the index of the source item whose backup it restores
        for (index, item) in source.enumerated() {
            let state = states[item.serverPath] ?? .missing
            out.observed[item.serverPath] = state.sha256
            let before = item.baseSha ?? ""
            if state.sha256 == before {
                out.manifest[item.serverPath] = previous[item.serverPath]
                out.summary.unchanged += 1
                continue
            }
            if state.unchecked { out.blockers.append(DeployBlocker(path: item.path, serverPath: item.serverPath, reason: "unverified")) }
            else if state.sha256 != (item.newSha ?? "") {
                out.blockers.append(DeployBlocker(path: item.path, serverPath: item.serverPath, reason: state.absent ? "server_deleted" : "server_changed"))
            }
            let restore = item.baseSha != nil
            out.items.append(DeployPlanItem(path: item.path, serverPath: item.serverPath, action: restore ? "upload" : "delete",
                                            reason: restore ? "restore" : "remove", baseSha: state.absent ? nil : state.sha256, baseSize: state.size,
                                            newSha: item.baseSha, newSize: item.baseSize, after: previous[item.serverPath]))
            backups.append(index)
            if restore { out.summary.upload += 1 } else { out.summary.delete += 1 }
        }
        return (out, backups)
    }
}
