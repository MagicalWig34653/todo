import Foundation

// Stub so the red tests compile.
enum DeploySecretGuard {
    static func pathReason(_ path: String) -> String? { nil }
    static func containsSecret(path: String, data: Data) -> Bool { false }
}
