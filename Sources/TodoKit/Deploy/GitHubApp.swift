import _CryptoExtras
import AsyncHTTPClient
import Crypto
import Foundation
import NIOCore
import NIOPosix
import Vapor

// ADR 0042, contracts/deploy.yaml 1.2.0: the write path to GitHub through a GitHub App. The server only ever reads and creates:
// blobs, trees, commits, a NEW branch below `server/` and a pull request. There is no ref update, merge or delete here. The private
// key, the app JWT and the installation token never leave this file: no answer or log carries them, and bodies of GitHub error
// answers are never passed on.

struct GitHubHTTPRequest: Sendable { let method: HTTPMethod; let url: String; let headers: [String: String]; let body: Data? }
struct GitHubHTTPResponse: Sendable { let status: Int; let body: Data }
protocol GitHubTransport: Sendable { func send(_ r: GitHubHTTPRequest) async throws -> GitHubHTTPResponse }

/// A failed GitHub call as a fixed machine code; `status` and `operation` only for the log.
struct GitHubError: Error, Sendable, Equatable {
    let code: String
    var status = 0
    var operation = ""
}

struct GitHubAppConfig: Sendable {
    let appID: String
    let installationID: String
    let key: _RSA.Signing.PrivateKey
    /// Without a trailing slash.
    let apiURL: String
    /// Allowlist of the operator: project -> `owner/repo` the project may open pull requests in.
    let repositories: [UUID: [String]]
}

enum GitHubAppSetup: Sendable {
    /// No app variable set: the write path is switched off.
    case disabled
    /// Names of the variables that are missing or wrong (never values).
    case invalid([String])
    case enabled(GitHubAppConfig)

    /// `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY[_FILE]`, `GITHUB_APP_REPOSITORIES`
    /// (`projectID=owner/repo`, comma separated), optional `GITHUB_API_URL`. Empty variables count as unset.
    static func fromEnvironment(get: (String) -> String?) -> GitHubAppSetup {
        func raw(_ name: String) -> String? { get(name).flatMap { $0.isEmpty ? nil : $0 } }
        func value(_ name: String) -> String? { raw(name)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let names = ["GITHUB_APP_ID", "GITHUB_APP_INSTALLATION_ID", "GITHUB_APP_PRIVATE_KEY", "GITHUB_APP_REPOSITORIES"]
        guard names.contains(where: { raw($0) != nil }) || raw("GITHUB_APP_PRIVATE_KEY_FILE") != nil else { return .disabled }
        var wrong: [String] = []
        func number(_ name: String) -> String {
            let v = value(name) ?? ""
            if v.isEmpty || v.count > 20 || !v.utf8.allSatisfy({ (0x30...0x39).contains($0) }) { wrong.append(name) }
            return v
        }
        let appID = number("GITHUB_APP_ID"), installationID = number("GITHUB_APP_INSTALLATION_ID")
        let pem = (try? RuntimeEnvironment.value("GITHUB_APP_PRIVATE_KEY", get: raw)) ?? nil
        let key = pem.flatMap { try? _RSA.Signing.PrivateKey(pemRepresentation: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if key == nil { wrong.append("GITHUB_APP_PRIVATE_KEY") }
        let repositories = parseRepositories(value("GITHUB_APP_REPOSITORIES") ?? "")
        if repositories == nil { wrong.append("GITHUB_APP_REPOSITORIES") }
        let apiURL = validAPIURL(value("GITHUB_API_URL") ?? "https://api.github.com")
        if apiURL == nil { wrong.append("GITHUB_API_URL") }
        guard wrong.isEmpty, let key, let repositories, let apiURL else { return .invalid(wrong) }
        return .enabled(GitHubAppConfig(appID: appID, installationID: installationID, key: key, apiURL: apiURL, repositories: repositories))
    }

    private static func parseRepositories(_ list: String) -> [UUID: [String]]? {
        var out: [UUID: [String]] = [:]
        let owner = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let name = owner.union("._")
        for item in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !item.isEmpty {
            let pair = item.split(separator: "=", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let project = UUID(uuidString: pair[0]) else { return nil }
            let parts = pair[1].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, (1...39).contains(parts[0].count), parts[0].allSatisfy({ owner.contains($0) }),
                  (1...100).contains(parts[1].count), parts[1].allSatisfy({ name.contains($0) }), parts[1] != ".", parts[1] != ".." else { return nil }
            if !(out[project] ?? []).contains(pair[1]) { out[project, default: []].append(pair[1]) }
        }
        return out.isEmpty ? nil : out
    }

    /// HTTPS only (the app JWT goes there); plain HTTP just to the own machine, for the tests.
    private static func validAPIURL(_ s: String) -> String? {
        guard let c = URLComponents(string: s), let scheme = c.scheme, let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(host)) else { return nil }
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// The only refs Todolino may create: `server/<a-z, 0-9, ->`. Checked on bytes, so no look-alike or line break gets through.
enum GitHubBranch {
    static let prefix = "server/"
    static let maxName = 87

    static func isAllowed(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard name.utf8.starts(with: prefix.utf8), bytes.count > prefix.utf8.count, bytes.count <= maxName else { return false }
        let rest = bytes.dropFirst(prefix.utf8.count)
        return rest.first != UInt8(ascii: "-") && rest.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }
}

struct GitHubTreeEntry: Decodable, Sendable { let path: String; let mode: String; let type: String; let sha: String }

/// A new or changed file of a tree: text goes inline, other bytes as a blob created before.
struct GitHubTreeChange: Encodable, Sendable {
    let path: String
    let mode: String
    var type = "blob"
    var content: String?
    var sha: String?
}

/// One run against one repository with a fresh installation token that is limited to that repository.
struct GitHubRepoClient: Sendable {
    private let apiURL: String
    private let repository: String
    private let token: String
    private let transport: any GitHubTransport

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// RS256 JWT of the app: issued a minute in the past (clock drift), valid nine minutes (GitHub allows ten).
    private static func appToken(_ config: GitHubAppConfig, now: Date = Date()) throws -> String {
        struct Claims: Encodable { let iat: Int; let exp: Int; let iss: String }
        let iat = Int(now.timeIntervalSince1970) - 60
        let head = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let claims = base64URL(try JSONEncoder().encode(Claims(iat: iat, exp: iat + 540, iss: config.appID)))
        do {
            let signature = try config.key.signature(for: SHA256.hash(data: Data("\(head).\(claims)".utf8)), padding: .insecurePKCS1v1_5)
            return "\(head).\(claims).\(base64URL(signature.rawRepresentation))"
        } catch { throw GitHubError(code: "deploy_github_auth_failed", operation: "sign") }
    }

    private static func call<T: Decodable>(_ transport: any GitHubTransport, _ method: HTTPMethod, _ url: String, bearer: String,
                                           body: (any Encodable)? = nil, operation: String, as: T.Type) async throws -> T {
        var headers = ["Authorization": "Bearer \(bearer)", "Accept": "application/vnd.github+json",
                       "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Todolino"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let answer: GitHubHTTPResponse
        do {
            let data = try body.map { try JSONEncoder().encode($0) }
            answer = try await transport.send(GitHubHTTPRequest(method: method, url: url, headers: headers, body: data))
        } catch {
            throw GitHubError(code: "deploy_github_unavailable", operation: operation)
        }
        guard (200..<300).contains(answer.status) else {
            if operation == "ref", answer.status == 422, String(decoding: answer.body, as: UTF8.self).contains("already exists") {
                throw GitHubError(code: "deploy_github_branch_exists", status: answer.status, operation: operation)
            }
            let code: String
            switch answer.status {
            case 401: code = "deploy_github_auth_failed"
            case 403, 429: code = "deploy_github_forbidden"
            case 404: code = "deploy_github_not_found"
            case 500...599: code = "deploy_github_unavailable"
            default: code = "deploy_github_failed"
            }
            throw GitHubError(code: code, status: answer.status, operation: operation)
        }
        do { return try JSONDecoder().decode(T.self, from: answer.body) }
        catch { throw GitHubError(code: "deploy_github_failed", status: answer.status, operation: operation) }
    }

    static func open(config: GitHubAppConfig, repository: String, transport: any GitHubTransport) async throws -> GitHubRepoClient {
        struct Scope: Encodable { let repositories: [String]; let permissions: [String: String] }
        struct Token: Decodable { let token: String }
        let name = String(repository.split(separator: "/").last ?? "")
        let answer = try await call(transport, .POST, "\(config.apiURL)/app/installations/\(config.installationID)/access_tokens",
                                    bearer: try appToken(config), body: Scope(repositories: [name], permissions: ["contents": "write", "pull_requests": "write"]),
                                    operation: "token", as: Token.self)
        return GitHubRepoClient(apiURL: config.apiURL, repository: repository, token: answer.token, transport: transport)
    }

    private func request<T: Decodable>(_ method: HTTPMethod, _ path: String, body: (any Encodable)? = nil, operation: String, as type: T.Type) async throws -> T {
        try await Self.call(transport, method, "\(apiURL)/repos/\(repository)\(path)", bearer: token, body: body, operation: operation, as: type)
    }

    private struct SHA: Decodable {
        let sha: String
        /// Ids from GitHub go into later URLs: only hex.
        func checked(_ operation: String) throws -> String {
            guard GitHubRepoClient.isObjectID(sha) else { throw GitHubError(code: "deploy_github_failed", operation: operation) }
            return sha
        }
    }

    static func isObjectID(_ s: String) -> Bool {
        (s.utf8.count == 40 || s.utf8.count == 64) && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A repository that does not say it is private counts as public.
    func info() async throws -> (defaultBranch: String, isPrivate: Bool) {
        struct Repository: Decodable { let default_branch: String; let `private`: Bool? }
        let r = try await request(.GET, "", operation: "repository", as: Repository.self)
        return (r.default_branch, r.private == true)
    }

    /// True when `commit` is on `branch` (the branch is ahead of it or at it).
    func branch(_ branch: String, contains commit: String) async throws -> Bool {
        struct Comparison: Decodable { let status: String }
        guard let head = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return false }
        do {
            // Page 2: GitHub puts the changed files with their patches on the first page only.
            let c = try await request(.GET, "/compare/\(commit)...\(head)?per_page=1&page=2", operation: "compare", as: Comparison.self)
            return c.status == "ahead" || c.status == "identical"
        } catch let e as GitHubError where e.status == 404 { return false }
    }

    func tree(ofCommit commit: String) async throws -> String {
        struct Commit: Decodable { let tree: SHA }
        return try await request(.GET, "/git/commits/\(commit)", operation: "commit-read", as: Commit.self).tree.checked("commit-read")
    }

    func entries(ofTree sha: String) async throws -> [GitHubTreeEntry] {
        struct Tree: Decodable { let tree: [GitHubTreeEntry]; let truncated: Bool? }
        let t = try await request(.GET, "/git/trees/\(sha)", operation: "tree-read", as: Tree.self)
        // A cut-off listing could hide a symlink or submodule: refuse.
        guard t.truncated != true, t.tree.allSatisfy({ Self.isObjectID($0.sha) }) else { throw GitHubError(code: "deploy_github_failed", operation: "tree-read") }
        return t.tree
    }

    func createBlob(_ data: Data) async throws -> String {
        struct Blob: Encodable { let content: String; let encoding: String }
        return try await request(.POST, "/git/blobs", body: Blob(content: data.base64EncodedString(), encoding: "base64"), operation: "blob", as: SHA.self).checked("blob")
    }

    func createTree(base: String, changes: [GitHubTreeChange]) async throws -> String {
        struct Tree: Encodable { let base_tree: String; let tree: [GitHubTreeChange] }
        return try await request(.POST, "/git/trees", body: Tree(base_tree: base, tree: changes), operation: "tree", as: SHA.self).checked("tree")
    }

    func createCommit(message: String, tree: String, parent: String) async throws -> String {
        struct Commit: Encodable { let message: String; let tree: String; let parents: [String] }
        return try await request(.POST, "/git/commits", body: Commit(message: message, tree: tree, parents: [parent]), operation: "commit", as: SHA.self).checked("commit")
    }

    /// Creates a new branch, never moves one. `false`: the name is taken.
    func createBranch(_ name: String, commit: String) async throws -> Bool {
        guard GitHubBranch.isAllowed(name) else { throw GitHubError(code: "deploy_branch_forbidden", operation: "ref") }
        struct Ref: Encodable { let ref: String; let sha: String }
        struct Created: Decodable { let ref: String }
        do {
            _ = try await request(.POST, "/git/refs", body: Ref(ref: "refs/heads/\(name)", sha: commit), operation: "ref", as: Created.self)
            return true
        } catch let e as GitHubError where e.code == "deploy_github_branch_exists" { return false }
    }

    func createPullRequest(head: String, base: String, title: String, body: String) async throws -> (number: Int, url: String) {
        guard GitHubBranch.isAllowed(head) else { throw GitHubError(code: "deploy_branch_forbidden", operation: "pull") }
        struct New: Encodable { let title: String; let head: String; let base: String; let body: String }
        struct Created: Decodable { let number: Int; let html_url: String }
        let c = try await request(.POST, "/pulls", body: New(title: title, head: head, base: base, body: body), operation: "pull", as: Created.self)
        return (c.number, c.html_url)
    }
}

/// HTTPS through AsyncHTTPClient: no redirects (the token must not travel), bounded time and answer size.
struct HTTPGitHubTransport: GitHubTransport {
    static let maxAnswer = 16 * 1024 * 1024

    func send(_ r: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.timeout = .init(connect: .seconds(10), read: .seconds(60))
        let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
        do {
            var request = HTTPClientRequest(url: r.url)
            request.method = r.method
            for (name, value) in r.headers { request.headers.add(name: name, value: value) }
            if let body = r.body { request.body = .bytes(ByteBuffer(bytes: body)) }
            let response = try await client.execute(request, timeout: .seconds(60))
            let body = try await response.body.collect(upTo: Self.maxAnswer)
            try await client.shutdown()
            return GitHubHTTPResponse(status: Int(response.status.code), body: Data(body.readableBytesView))
        } catch {
            try? await client.shutdown()
            throw error
        }
    }
}

extension Application {
    private struct GitHubSetupKey: StorageKey { typealias Value = GitHubAppSetup }
    private struct GitHubTransportKey: StorageKey { typealias Value = any GitHubTransport }

    /// Set once by `configureDeploy` from the environment.
    var githubApp: GitHubAppSetup {
        get { storage[GitHubSetupKey.self] ?? .disabled }
        set { storage[GitHubSetupKey.self] = newValue }
    }
    var githubTransport: any GitHubTransport {
        get { storage[GitHubTransportKey.self] ?? HTTPGitHubTransport() }
        set { storage[GitHubTransportKey.self] = newValue }
    }
}
