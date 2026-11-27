import Fluent
import Foundation
import Vapor

/// Repo path -> server path, both relative and `/`-separated (`""` = root of the repo or of the base path).
struct DeployMapping: Codable, Sendable, Equatable { let local: String; let remote: String }

/// Placeholder rules (red phase).
struct DeployRules: Sendable {
    init(includes: [String], excludes: [String], mappings: [DeployMapping], defaultExcludes: Bool) throws {}
    func isExcluded(_ repoPath: String) -> Bool { false }
    func serverPath(forRepo path: String) -> String? { nil }
    func repoPath(forServer path: String) -> String? { nil }
}

final class DeployTarget: Model, @unchecked Sendable {
    static let schema = "deploy_targets"
    @ID(key: .id) var id: UUID?
    @OptionalField(key: "host_key_base64") var hostKeyBase64: String?
    init() {}
}
