import Crypto
import Foundation
import Vapor

// ADR 0039, 0044: the transport behind deploy targets. Only an approved run (phase 3) calls `upload` and `delete`.

/// A pinned or offered SSH host key: key type (`ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`) and the base64 key blob.
struct DeployHostKey: Sendable, Equatable {
    let type: String
    let base64: String
    /// OpenSSH style: `SHA256:` + base64 of the SHA-256 of the key blob, without padding.
    var fingerprint: String {
        guard let blob = Data(base64Encoded: base64) else { return "SHA256:invalid" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Everything one transport run needs. Holds the decrypted secret only for the duration of the run; never logged or encoded.
struct DeployConnection: Sendable {
    let protocolName: String
    let host: String
    let port: Int
    let basePath: String
    let username: String
    let password: String?
    let privateKey: String?
    let passphrase: String?
    let hostKey: DeployHostKey?
    let tlsCertificate: String?
}

struct DeployRemoteFile: Sendable, Equatable {
    /// Relative to the base path, `/`-separated, never with `..`.
    let path: String
    let size: Int
}

/// One file a run writes: path relative to the base path of the target and its exact bytes.
struct DeployUploadFile: Sendable, Equatable { let path: String; let data: Data }

/// A failed transport run as a fixed machine code (`deploy_auth_failed`, ...); never host, path or tool output.
struct DeployTransportError: Error, Sendable, Equatable { let code: String }

protocol DeployTransport: Sendable {
    /// SFTP only: the host key the server offers now (first connection, confirmation by a person).
    func scanHostKey(host: String, port: Int) async throws -> DeployHostKey
    /// All regular files below the base path, recursively. Symlinks are neither listed nor followed.
    func list(_ connection: DeployConnection) async throws -> [DeployRemoteFile]
    /// The content of the given files (relative to the base path).
    func read(_ connection: DeployConnection, paths: [String]) async throws -> [String: Data]
    /// Those of `paths` that must not be written: a symlink on the way (or as the file), or a file where a directory is needed.
    func linkedPaths(_ connection: DeployConnection, paths: [String]) async throws -> Set<String>
    /// Writes the files, each under a temporary name first and then renamed, creating directories as needed.
    func upload(_ connection: DeployConnection, files: [DeployUploadFile]) async throws
    /// Removes exactly these files.
    func delete(_ connection: DeployConnection, paths: [String]) async throws
}

extension Application {
    private struct DeployTransportKey: StorageKey { typealias Value = any DeployTransport }
    private struct DeployPrivateKey: StorageKey { typealias Value = Bool }
    private struct DeployWorkKey: StorageKey { typealias Value = URL }

    var deployTransport: any DeployTransport {
        get { storage[DeployTransportKey.self] ?? RcloneDeployTransport(workDirectory: deployWorkDirectory) }
        set { storage[DeployTransportKey.self] = newValue }
    }

    /// `DEPLOY_ALLOW_PRIVATE_HOSTS=1`: loopback and private targets allowed (tests, own network). Default: refused.
    var deployAllowPrivateHosts: Bool {
        get { storage[DeployPrivateKey.self] ?? (Environment.get("DEPLOY_ALLOW_PRIVATE_HOSTS") == "1") }
        set { storage[DeployPrivateKey.self] = newValue }
    }

    /// Parent of the per-run temporary directories (rclone configuration, known_hosts, certificate, copies).
    var deployWorkDirectory: URL {
        get { storage[DeployWorkKey.self] ?? FileManager.default.temporaryDirectory }
        set { storage[DeployWorkKey.self] = newValue }
    }
}
