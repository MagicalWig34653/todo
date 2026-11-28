import _CryptoExtras
import Vapor

// Red stage: types only, no behaviour yet.

struct GitHubHTTPRequest: Sendable { let method: HTTPMethod; let url: String; let headers: [String: String]; let body: Data? }
struct GitHubHTTPResponse: Sendable { let status: Int; let body: Data }
protocol GitHubTransport: Sendable { func send(_ r: GitHubHTTPRequest) async throws -> GitHubHTTPResponse }
struct GitHubError: Error, Sendable, Equatable { let code: String }

struct GitHubAppConfig: Sendable {
    let appID: String
    let installationID: String
    let key: _RSA.Signing.PrivateKey
    let apiURL: String
    let repositories: [UUID: [String]]
}

enum GitHubAppSetup: Sendable {
    case disabled
    case invalid([String])
    case enabled(GitHubAppConfig)
    static func fromEnvironment(get: (String) -> String?) -> GitHubAppSetup { .disabled }
}

struct GitHubRepoClient: Sendable {
    static func open(config: GitHubAppConfig, repository: String, transport: any GitHubTransport) async throws -> GitHubRepoClient { throw GitHubError(code: "deploy_github_not_configured") }
    func createBranch(_ name: String, commit: String) async throws -> Bool { false }
    func createPullRequest(head: String, base: String, title: String, body: String) async throws -> (number: Int, url: String) { (0, "") }
}

extension Application {
    private struct GitHubSetupKey: StorageKey { typealias Value = GitHubAppSetup }
    private struct GitHubTransportKey: StorageKey { typealias Value = any GitHubTransport }
    var githubApp: GitHubAppSetup {
        get { storage[GitHubSetupKey.self] ?? .disabled }
        set { storage[GitHubSetupKey.self] = newValue }
    }
    var githubTransport: (any GitHubTransport)? {
        get { storage[GitHubTransportKey.self] }
        set { storage[GitHubTransportKey.self] = newValue }
    }
}
