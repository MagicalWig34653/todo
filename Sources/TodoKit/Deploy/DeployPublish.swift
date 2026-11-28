import Crypto
import Fluent
import Foundation
import Vapor

// ADR 0042, contracts/deploy.yaml 1.2.0: the files a pull delivers become one commit on a NEW branch `server/*` and a pull request,
// written through the GitHub App (GitHubApp.swift). The server of the target is only read.

enum DeployPublishLimits {
    /// Files in one commit; bounds the tree reads and the work of one run.
    static let maxFiles = 500
    /// Binary files need one API call each (GitHub limits creating requests); the rest waits for the next run.
    static let maxBinaries = 50
    static let maxBranchSuffix = 20
    /// GitHub refuses pull request bodies above 65536 characters.
    static let maxBody = 60_000
}

struct DeployPublishRequest: Decodable {
    var files: [DeployManifestEntry]
    /// Commit of the default branch the manifest describes; the new branch starts there.
    var baseCommit: String?
    var paths: [String]?
    var maxBytes: Int?
    var eol: String?
    /// Own branch name below `server/` (default: `server/<ziel>-JJJJ-MM-TT`).
    var branch: String?
    /// `owner/repo`, needed only when the operator allows several for the project.
    var repository: String?
}

struct DeployPublishFile: Content, Equatable { let path: String; let serverPath: String; let status: String; let size: Int; let sha256: String }
struct DeployPullRequestRef: Content, Equatable { let number: Int; let url: String }

struct DeployPublishResult: Content {
    var ok = false
    var code: String?
    var repository: String?
    var branch: String?
    var baseBranch: String?
    var baseCommit: String?
    var commit: String?
    var pullRequest: DeployPullRequestRef?
    var summary: DeployPullSummary?
    var files: [DeployPublishFile]?
    var findings: [DeployPullFinding]?
    var findingsTotal: Int?
    var remaining: [String]?
    var remainingTotal: Int?
}

/// Files that tell a build system what to run. The pushed branch may start a pipeline before anybody looked at it, so the write
/// path never carries such a file (`.github` and `.gitlab*` are already refused by the pull). Build scripts of the project itself
/// cannot be told apart: CI on `server/**` must not get secrets (docs/GITHUB-APP-EINRICHTUNG.md).
enum DeployPipelinePath {
    private static let directories: Set<String> = [".circleci", ".forgejo", ".gitea", ".woodpecker", ".buildkite", ".semaphore"]
    private static let names: Set<String> = ["jenkinsfile", ".woodpecker.yml", ".woodpecker.yaml", "azure-pipelines.yml", "azure-pipelines.yaml",
                                             "bitbucket-pipelines.yml", ".travis.yml", ".drone.yml", ".cirrus.yml", "appveyor.yml", ".appveyor.yml",
                                             "cloudbuild.yml", "cloudbuild.yaml"]
    static func matches(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        return parts.contains { directories.contains($0) } || names.contains(parts.last ?? "")
    }
}

extension DeployService {
    /// `@name` would notify people, `#1` and `GH-1` would link or close issues: a zero width space takes that away. File names come
    /// from the server of the target and are not trusted.
    private static func quiet(_ text: String) -> String {
        text.replacingOccurrences(of: "@", with: "@\u{200B}").replacingOccurrences(of: "#", with: "#\u{200B}")
            .replacingOccurrences(of: "(?i)gh-(?=[0-9])", with: "$0\u{200B}", options: .regularExpression)
    }

    /// The commit message as an indented code block, so that nothing in a file name is read as Markdown.
    private static func pullRequestBody(_ message: String, remaining: Int) -> String {
        var body = "", cut = false
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            if body.utf8.count + line.utf8.count > DeployPublishLimits.maxBody { cut = true; break }
            body += "    \(line)\n"
        }
        if cut { body += "    … gekürzt, alle Dateien stehen im Commit.\n" }
        if remaining > 0 { body += "\n\(remaining) weitere Dateien passten nicht in diesen Lauf (Feld `remaining`); sie folgen mit dem nächsten.\n" }
        return body + "\nErstellt von Todolino über die GitHub-App.\n"
    }

    private static func gitBlobID(_ data: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }

    /// Splits the delivered files into tree changes against the base commit. Left out: files that are already like that in the base
    /// (nothing to commit), pipeline definitions and paths where the repository has a symlink, a submodule or a directory/file
    /// clash (`blocked_path`). Repository names are matched byte by byte, as git does (Swift strings treat NFC and NFD as equal).
    private static func changes(_ outcome: inout DeployPullOutcome, root: String, client: GitHubRepoClient) async throws -> [GitHubTreeChange] {
        var cache: [String: [Data: GitHubTreeEntry]] = [:]
        func entries(_ sha: String) async throws -> [Data: GitHubTreeEntry] {
            if let known = cache[sha] { return known }
            let list = Dictionary(try await client.entries(ofTree: sha).map { (Data($0.path.utf8), $0) }, uniquingKeysWith: { a, _ in a })
            cache[sha] = list
            return list
        }
        var kept: [DeployPullFile] = [], changes: [GitHubTreeChange] = [], overflow: [String] = [], binaries = 0
        files: for file in outcome.files {
            func blocked() {
                outcome.summary.withheld += 1
                outcome.findings.append(DeployPullFinding(path: file.path, serverPath: file.serverPath, reason: "blocked_path"))
            }
            // Second line of defence in front of the write: the pull already refuses these.
            guard DeployPath.isSafeRelative(file.path, allowEmpty: false), DeploySecretGuard.pathReason(file.path) == nil,
                  !DeployPipelinePath.matches(file.path),
                  let data = file.encoding == "base64" ? Data(base64Encoded: file.content) : Data(file.content.utf8) else { blocked(); continue }
            var tree = root, existing: GitHubTreeEntry?
            let parts = file.path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                guard let entry = try await entries(tree)[Data(part.utf8)] else { break }
                if index < parts.count - 1 {
                    guard entry.type == "tree" else { blocked(); continue files }
                    tree = entry.sha
                } else {
                    guard entry.type == "blob", entry.mode == "100644" || entry.mode == "100755" else { blocked(); continue files }
                    existing = entry
                }
            }
            if existing?.sha == gitBlobID(data) { continue }
            if kept.count == DeployPublishLimits.maxFiles { overflow.append(file.path); continue }
            var change = GitHubTreeChange(path: file.path, mode: existing?.mode ?? "100644")
            if file.encoding == "utf-8" {
                change.content = file.content
            } else {
                if binaries == DeployPublishLimits.maxBinaries { overflow.append(file.path); continue }
                binaries += 1
                change.sha = Self.gitBlobID(data)   // created right before the tree, see `openPullRequest`
            }
            kept.append(file)
            changes.append(change)
        }
        outcome.files = kept
        outcome.remainingTotal += overflow.count
        outcome.remaining = Array((overflow + outcome.remaining).prefix(DeployPullLimits.maxSelection))
        return changes
    }

    func openPullRequest(_ id: UUID, request: DeployPublishRequest) async throws -> DeployPublishResult {
        let t = try await target(id, role: .edit)
        if let branch = request.branch, !GitHubBranch.isAllowed(branch) { throw Abort(.badRequest, reason: "deploy_branch_forbidden") }
        let base = request.baseCommit?.lowercased() ?? ""
        guard GitHubRepoClient.isObjectID(base) else { throw Abort(.badRequest, reason: "deploy_pull_invalid") }
        let repo = try Self.validManifest(request.files)
        let options = try Self.validPull(DeployPullRequest(files: [], paths: request.paths, maxBytes: request.maxBytes, eol: request.eol),
                                         defaultBytes: DeployPullLimits.defaultBytesREST)
        let rules = try DeployRulesDTO.decode(t.rules).rules()

        func refused(_ code: String) -> DeployPublishResult { DeployPublishResult(code: failure(t, code, "pull-request")) }
        let config: GitHubAppConfig
        switch app.githubApp {
        case .disabled: return refused("deploy_github_not_configured")
        case .invalid: return refused("deploy_github_config_invalid")
        case .enabled(let c): config = c
        }
        // Only repositories that were allowed for exactly this project: by the operator (old variables) or by a person who connected
        // their own installation and mapped it here. The installation may reach more.
        struct Route { let repository: String; let mapping: GitHubProjectRepository?; let connection: GitHubConnection? }
        var allowed: [Route] = config.installationID == nil ? [] : (config.repositories[t.projectID] ?? []).map { Route(repository: $0, mapping: nil, connection: nil) }
        for mapping in try await GitHubProjectRepository.query(on: db).filter(\.$projectID == t.projectID).sort(\.$createdAt).sort(\.$id).all() {
            // One repository is one entry; the operator's entry for the same one keeps working as before.
            guard !allowed.contains(where: { $0.repository.lowercased() == mapping.repository.lowercased() }),
                  let connection = try await GitHubConnection.find(mapping.connectionID, on: db) else { continue }
            allowed.append(Route(repository: mapping.repository, mapping: mapping, connection: connection))
        }
        let route: Route
        if let wanted = request.repository {
            guard let match = allowed.first(where: { $0.repository.lowercased() == wanted.lowercased() }) else { return refused("deploy_github_repository_not_allowed") }
            route = match
        } else {
            guard let first = allowed.first else { return refused("deploy_github_repository_not_allowed") }
            guard allowed.count == 1 else { return refused("deploy_github_repository_required") }
            route = first
        }
        let repository = route.repository
        guard t.protocolName != DeployProtocol.sftp.rawValue || t.hostKey != nil else { return refused("deploy_host_key_unconfirmed") }

        var result = DeployPublishResult(repository: repository)
        do {
            let client: GitHubRepoClient
            let remote: (defaultBranch: String, isPrivate: Bool, id: Int?, fullName: String?)
            if let mapping = route.mapping, let connection = route.connection {
                // A person's own installation: GitHub and Todolino are asked again, every time (installation, repository, GitHub rights, project rights).
                (client, remote) = try await GitHubAccess.open(config: config, connection: connection, repository: repository, expectedRepositoryID: mapping.repositoryID,
                                                               project: t.projectID, assignedBy: mapping.assignedBy, app: app)
            } else {
                client = try await GitHubRepoClient.open(config: config, repository: repository, transport: app.githubTransport)
                remote = try await client.info()
            }
            // In a public repository whatever the secret heuristic misses would be published at once.
            guard remote.isPrivate else { return refused("deploy_github_repository_public") }
            let baseBranch = remote.defaultBranch
            guard try await client.branch(baseBranch, contains: base) else { return refused("deploy_github_base_unknown") }
            let rootTree = try await client.tree(ofCommit: base)

            let conn = try connection(t, address: try await connectAddress(t))
            let listed = try await app.deployTransport.list(conn)
            var outcome = try await Self.pull(repo: repo, server: listed, rules: rules, selection: options.selection, maxBytes: options.maxBytes,
                                              defaultEOL: options.eol) { paths in try await app.deployTransport.read(conn, paths: paths) }
            let changes = try await Self.changes(&outcome, root: rootTree, client: client)
            result.summary = outcome.summary
            result.findings = outcome.findings
            result.findingsTotal = outcome.findings.count + outcome.droppedFindings
            result.remaining = outcome.remaining
            result.remainingTotal = outcome.remainingTotal
            guard !changes.isEmpty else { result.code = failure(t, "deploy_pull_nothing", "pull-request"); return result }

            for (file, change) in zip(outcome.files, changes) where change.sha != nil {
                guard let data = Data(base64Encoded: file.content), try await client.createBlob(data) == change.sha else {
                    throw GitHubError(code: "deploy_github_failed", operation: "blob")
                }
            }
            let tree = try await client.createTree(base: rootTree, changes: changes)
            let message = Self.quiet(Self.commitMessage(target: t.name, outcome: outcome))
            let commit = try await client.createCommit(message: message, tree: tree, parent: base)
            let wanted = request.branch ?? Self.branchName(target: t.name)
            var branch: String?
            for n in 1...DeployPublishLimits.maxBranchSuffix {
                let suffix = n == 1 ? "" : "-\(n)"
                let name = String(wanted.prefix(GitHubBranch.maxName - suffix.count)) + suffix
                if try await client.createBranch(name, commit: commit) { branch = name; break }
            }
            guard let branch else { result.code = failure(t, "deploy_github_branch_exists", "pull-request"); return result }
            result.branch = branch
            result.baseBranch = baseBranch
            result.baseCommit = base
            result.commit = commit
            result.files = outcome.files.map { DeployPublishFile(path: $0.path, serverPath: $0.serverPath, status: $0.status, size: $0.size, sha256: $0.sha256) }
            do {
                let title = String(message.prefix { $0 != "\n" }.prefix(200))
                let pull = try await client.createPullRequest(head: branch, base: baseBranch, title: title,
                                                              body: Self.pullRequestBody(message, remaining: outcome.remainingTotal))
                result.pullRequest = DeployPullRequestRef(number: pull.number, url: pull.url)
            } catch let e as GitHubError {
                // The branch with the commit exists; the person can open the pull request by hand.
                logGitHub(t, e)
                result.code = failure(t, "deploy_github_pr_failed", "pull-request")
                return result
            }
            result.ok = true
            app.logger.info("deploy pull request ok", metadata: ["target": .string(id.uuidString), "repository": .string(repository), "branch": .string(branch),
                                                                 "number": .stringConvertible(result.pullRequest?.number ?? 0),
                                                                 "files": .stringConvertible(outcome.files.count)])
            return result
        } catch let e as GitHubError {
            logGitHub(t, e)
            return refused(e.code)
        } catch let e as DeployTransportError {
            return refused(e.code)
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" {
            return refused("deploy_target_blocked")
        }
    }

    private func logGitHub(_ t: DeployTarget, _ e: GitHubError) {
        app.logger.warning("deploy github call failed", metadata: ["target": .string(t.id?.uuidString ?? "-"), "operation": .string(e.operation),
                                                                   "status": .stringConvertible(e.status), "code": .string(e.code)])
    }
}

extension DeployController {
    @Sendable func pullRequest(_ req: Request) async throws -> DeployPublishResult {
        let s = DeployService(app: req.application, user: try await req.requireUser())
        let body: DeployPublishRequest
        do { body = try req.content.decode(DeployPublishRequest.self) } catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
        guard let id = req.parameters.get("targetID", as: UUID.self) else { throw Abort(.notFound) }
        return try await s.openPullRequest(id, request: body)
    }
}
