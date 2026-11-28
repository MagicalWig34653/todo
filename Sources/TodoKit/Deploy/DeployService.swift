import Crypto
import Fluent
import Vapor

// MARK: - DTOs (persons only; no field ever carries a password, key or passphrase)

struct DeployHostKeyDTO: Content, Equatable {
    let confirmed: Bool
    let type: String?
    let fingerprint: String?
}

struct DeployTargetDTO: Content {
    let id: UUID
    let projectID: UUID
    let name: String
    let stage: String
    let `protocol`: String
    let host: String
    let port: Int
    let basePath: String
    let username: String
    /// `password` | `key`
    let authMethod: String
    let hostKey: DeployHostKeyDTO
    let tlsCertificatePinned: Bool
    let rules: DeployRulesDTO
    let effectiveExcludes: [String]
    let createdAt: Date
    let updatedAt: Date

    init(_ t: DeployTarget) throws {
        id = try t.requireID(); projectID = t.projectID; name = t.name; stage = t.stage; self.protocol = t.protocolName
        host = t.host; port = t.port; basePath = t.basePath; username = t.username; authMethod = t.authMethod
        hostKey = DeployHostKeyDTO(confirmed: t.hostKey != nil, type: t.hostKeyType, fingerprint: t.hostKey?.fingerprint)
        tlsCertificatePinned = t.tlsCertificate != nil
        rules = DeployRulesDTO.decode(t.rules)
        effectiveExcludes = (try? rules.rules().effectiveExcludes) ?? rules.excludes
        createdAt = t.createdAt; updatedAt = t.updatedAt
    }
}

struct DeployTargetsResponse: Content { let items: [DeployTargetDTO] }

/// Agents (MCP): id, name, stage, protocol and whether the host key is confirmed. Never host, port, path, user or secret.
struct DeployTargetSummary: Content, Equatable {
    let id: UUID
    let name: String
    let stage: String
    let `protocol`: String
    let hostKeyConfirmed: Bool
    init(_ t: DeployTarget) throws {
        id = try t.requireID(); name = t.name; stage = t.stage; self.protocol = t.protocolName; hostKeyConfirmed = t.hostKey != nil
    }
}

struct DeployOfferedHostKey: Content, Equatable { let type: String; let fingerprint: String }

/// Result of a connection test. `code` only when `ok` is false; `offeredHostKey` only for persons (REST) and only when the
/// host key is still unconfirmed.
struct DeployTestResult: Content {
    let ok: Bool
    let code: String?
    let files: Int?
    let offeredHostKey: DeployOfferedHostKey?
}

struct DeployCompareFile: Content, Equatable {
    /// Repo path (for `serverOnly`: where the file would live in the repo after the mappings).
    let path: String
    /// Path relative to the base path of the target.
    let serverPath: String
    /// `same` | `new` | `changed` | `serverOnly` | `unverified`
    let status: String
    let repoSize: Int?
    let serverSize: Int?
}

struct DeployCompareSummary: Content, Equatable {
    var same = 0, new = 0, changed = 0, serverOnly = 0, unverified = 0
}

struct DeployCompareResult: Content {
    let ok: Bool
    let code: String?
    let summary: DeployCompareSummary?
    let files: [DeployCompareFile]?
}

struct DeployManifestEntry: Content {
    let path: String
    let size: Int
    let sha256: String
    /// Line endings of this file in the repo (pull): `lf` (default) | `crlf` | `keep`. Ignored by compare.
    var eol: String? = nil
}

struct DeployCompareRequest: Content { let files: [DeployManifestEntry] }
struct DeployHostKeyRequest: Content { let fingerprint: String }

/// Absent = unchanged, `null` = remove, value = set (only for the optional secrets and the certificate).
enum DeployChange<T: Sendable>: Sendable { case keep, clear, set(T) }

struct DeployTargetRequest: Decodable {
    var name: String?
    var stage: String?
    var protocolName: String?
    var host: String?
    var port: Int?
    var basePath: String?
    var username: String?
    var password: DeployChange<String> = .keep
    var privateKey: DeployChange<String> = .keep
    var privateKeyPassphrase: DeployChange<String> = .keep
    var tlsCertificate: DeployChange<String> = .keep
    var rules: DeployRulesDTO?

    private enum Keys: String, CodingKey {
        case name, stage, `protocol`, host, port, basePath, username, password, privateKey, privateKeyPassphrase, tlsCertificate, rules
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func change(_ key: Keys) throws -> DeployChange<String> {
            guard c.contains(key) else { return .keep }
            if try c.decodeNil(forKey: key) { return .clear }
            return .set(try c.decode(String.self, forKey: key))
        }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocol)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        basePath = try c.decodeIfPresent(String.self, forKey: .basePath)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try change(.password); privateKey = try change(.privateKey)
        privateKeyPassphrase = try change(.privateKeyPassphrase); tlsCertificate = try change(.tlsCertificate)
        rules = try c.decodeIfPresent(DeployRulesDTO.self, forKey: .rules)
    }
}

// MARK: - Service

/// Rules shared by REST and MCP. Managing targets needs a person session and the `manage` role; the connection test and the
/// compare need `edit`; listing needs `read`. MCP additionally checks the grant (see `MCPDeployTools`).
struct DeployService: Sendable {
    let app: Application
    let user: User
    var db: any Database { app.db }

    private func access() -> ProjectAccess { ProjectAccess(user: user, db: db) }

    func target(_ id: UUID, role: ProjectRole) async throws -> DeployTarget {
        guard let t = try await DeployTarget.find(id, on: db) else { throw Abort(.notFound) }
        _ = try await access().project(t.projectID, role: role)
        return t
    }

    func list(projectID: UUID) async throws -> [DeployTarget] {
        _ = try await access().project(projectID, role: .read)
        return try await DeployTarget.query(on: db).filter(\.$projectID == projectID).sort(\.$name).sort(\.$id).all()
    }

    // MARK: Validation

    private static func validName(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= DeployLimits.maxName, !t.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw Abort(.badRequest, reason: "deploy_name_invalid")
        }
        return t
    }

    static func validHost(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard !t.isEmpty, t.utf8.count <= DeployLimits.maxHost, t.allSatisfy({ allowed.contains($0) }), !t.hasPrefix("-"), !t.hasPrefix(".")
        else { throw Abort(.badRequest, reason: "deploy_host_invalid") }
        return t
    }

    private static func validUsername(_ s: String) throws -> String {
        guard !s.isEmpty, s.utf8.count <= DeployLimits.maxUsername, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw Abort(.badRequest, reason: "deploy_username_invalid")
        }
        return s
    }

    private static func validSecret(_ s: String) throws -> String {
        guard !s.isEmpty, s.utf8.count <= DeployLimits.maxSecret else { throw Abort(.badRequest, reason: "deploy_credentials_required") }
        return s
    }

    /// Literal private or loopback addresses and names that resolve to them are refused unless the server allows them.
    /// Returns the address that passed the check (the host itself when private hosts are allowed or the host is literal).
    @discardableResult
    func checkHostAllowed(_ host: String, port: Int) async throws -> String {
        if app.deployAllowPrivateHosts { return host }
        let literal = host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." })
        if literal {
            guard !WebhookTarget.isBlocked(host) else { throw Abort(.badRequest, reason: "deploy_target_blocked") }
            return host
        }
        let address: String
        do { address = try await WebhookResolution.resolve(app.webhookResolver, host: host, port: port, timeout: app.webhookResolveTimeout) }
        catch { throw Abort(.badRequest, reason: "deploy_target_blocked") }
        guard !WebhookTarget.isBlocked(address) else { throw Abort(.badRequest, reason: "deploy_target_blocked") }
        return address
    }

    /// Where the transport connects: SFTP and plain FTP use the checked address (no second name lookup by rclone or
    /// ssh-keyscan, no DNS rebinding); FTPS keeps the name because the certificate check needs it (ADR 0039, limit).
    func connectAddress(_ t: DeployTarget) async throws -> String {
        let checked = try await checkHostAllowed(t.host, port: t.port)
        return DeployProtocol(rawValue: t.protocolName)?.usesTLS == true ? t.host : checked
    }

    // MARK: Create, change, delete

    func create(projectID: UUID, _ r: DeployTargetRequest) async throws -> DeployTarget {
        _ = try await access().project(projectID, role: .manage)
        let t = DeployTarget()
        t.id = UUID(); t.projectID = projectID; t.createdBy = try user.requireID()
        t.createdAt = Date(); t.updatedAt = t.createdAt
        guard let name = r.name, let stage = r.stage, let proto = r.protocolName, let host = r.host, let username = r.username else {
            throw Abort(.badRequest, reason: r.name == nil ? "deploy_name_invalid" : r.protocolName == nil ? "deploy_protocol_invalid"
                        : r.host == nil ? "deploy_host_invalid" : r.username == nil ? "deploy_username_invalid" : "deploy_stage_invalid")
        }
        let count = try await DeployTarget.query(on: db).filter(\.$projectID == projectID).count()
        guard count < DeployLimits.maxTargetsPerProject else { throw Abort(.badRequest, reason: "deploy_target_limit") }
        try await apply(r, to: t, name: name, stage: stage, proto: proto, host: host, username: username, creating: true)
        try await t.create(on: db)
        app.logger.info("deploy target created", metadata: ["target": .string(t.id!.uuidString), "protocol": .string(t.protocolName)])
        return t
    }

    func update(_ id: UUID, _ r: DeployTargetRequest) async throws -> DeployTarget {
        let t = try await target(id, role: .manage)
        try await apply(r, to: t, name: r.name ?? t.name, stage: r.stage ?? t.stage, proto: r.protocolName ?? t.protocolName,
                        host: r.host ?? t.host, username: r.username ?? t.username, creating: false)
        t.updatedAt = Date()
        try await t.save(on: db)
        return t
    }

    func delete(_ id: UUID) async throws {
        let t = try await target(id, role: .manage)
        try await t.delete(on: db)
    }

    /// Validates everything first, then writes the fields. Host, port, protocol and user are locked to the stored credentials:
    /// changing one of them needs a new password or key in the same request, so a stored secret can never be sent elsewhere.
    private func apply(_ r: DeployTargetRequest, to t: DeployTarget, name: String, stage: String, proto: String, host: String,
                       username: String, creating: Bool) async throws {
        let name = try Self.validName(name)
        guard ["test", "prod"].contains(stage) else { throw Abort(.badRequest, reason: "deploy_stage_invalid") }
        guard let protocolValue = DeployProtocol(rawValue: proto) else { throw Abort(.badRequest, reason: "deploy_protocol_invalid") }
        let host = try Self.validHost(host)
        let port: Int
        if let p = r.port { port = p } else if creating || proto != t.protocolName { port = protocolValue.defaultPort } else { port = t.port }
        guard (1...65_535).contains(port) else { throw Abort(.badRequest, reason: "deploy_port_invalid") }
        let basePath = r.basePath ?? (creating ? "" : t.basePath)
        guard DeployPath.isSafeBase(basePath) else { throw Abort(.badRequest, reason: "deploy_base_path_invalid") }
        let username = try Self.validUsername(username)
        var rulesDTO = r.rules ?? (creating ? DeployRulesDTO() : DeployRulesDTO.decode(t.rules))
        let rules = try rulesDTO.rules()
        rulesDTO.mappings = rules.mappings

        var certificate = creating ? nil : t.tlsCertificate
        switch r.tlsCertificate {
        case .keep: break
        case .clear: certificate = nil
        case .set(let pem): certificate = try DeployCertificate.validate(pem)
        }
        if !protocolValue.usesTLS { certificate = nil }

        // Secrets: the new state of password / key.
        var secret = DeploySecret()
        var secretChanged = false
        if case .set(let p) = r.password { secret.password = try Self.validSecret(p); secretChanged = true }
        if case .set(let k) = r.privateKey {
            guard protocolValue == .sftp, k.contains("PRIVATE KEY-----") else { throw Abort(.badRequest, reason: "deploy_private_key_invalid") }
            secret.privateKey = try Self.validSecret(k); secretChanged = true
            if case .set(let pass) = r.privateKeyPassphrase { secret.passphrase = try Self.validSecret(pass) }
        }
        if secret.password != nil, secret.privateKey != nil { throw Abort(.badRequest, reason: "deploy_credentials_ambiguous") }
        // `null` cannot leave a target without credentials: only allowed while the other kind is set in the same request.
        if case .clear = r.password, secret.privateKey == nil { throw Abort(.badRequest, reason: "deploy_credentials_required") }
        if case .clear = r.privateKey, secret.password == nil { throw Abort(.badRequest, reason: "deploy_credentials_required") }
        if case .set = r.privateKeyPassphrase, secret.privateKey == nil { throw Abort(.badRequest, reason: "deploy_private_key_invalid") }
        let endpointChanged = !creating && (host != t.host || port != t.port || proto != t.protocolName || username != t.username)
        if creating || endpointChanged {
            guard secretChanged else { throw Abort(.badRequest, reason: "deploy_credentials_required") }
        }
        try await checkHostAllowed(host, port: port)

        if secretChanged {
            let ring = try app.requireSettingsRuntime().keyRing
            let sealed = try ring.sealDeploy(secret, targetID: try t.requireID(),
                                             endpoint: SettingsKeyRing.deployEndpoint(protocolName: proto, host: host, port: port, username: username))
            t.secretCiphertext = sealed.blob; t.secretKeyID = sealed.keyID
            t.authMethod = secret.privateKey != nil ? "key" : "password"
        }
        if creating || host != t.host || port != t.port || proto != t.protocolName || protocolValue != .sftp {
            t.hostKeyType = nil; t.hostKeyBase64 = nil
        }
        t.name = name; t.stage = stage; t.protocolName = proto; t.host = host; t.port = port; t.basePath = basePath
        t.username = username; t.tlsCertificate = certificate; t.rules = try rulesDTO.encoded()
    }

    // MARK: Host key

    /// The person confirms the fingerprint they were shown; the server scans again and pins the key only if it still matches.
    func confirmHostKey(_ id: UUID, fingerprint: String) async throws -> DeployTarget {
        let t = try await target(id, role: .manage)
        guard t.protocolName == DeployProtocol.sftp.rawValue else { throw Abort(.badRequest, reason: "deploy_protocol_invalid") }
        let address = try await connectAddress(t)
        let offered: DeployHostKey
        do { offered = try await app.deployTransport.scanHostKey(host: address, port: t.port) }
        catch let e as DeployTransportError { throw Abort(.badGateway, reason: e.code) }
        guard offered.fingerprint == fingerprint else { throw Abort(.conflict, reason: "deploy_host_key_changed") }
        t.hostKeyType = offered.type; t.hostKeyBase64 = offered.base64; t.updatedAt = Date()
        try await t.save(on: db)
        app.logger.info("deploy host key confirmed", metadata: ["target": .string(id.uuidString)])
        return t
    }

    // MARK: Connection test and compare

    func connection(_ t: DeployTarget, address: String) throws -> DeployConnection {
        let endpoint = SettingsKeyRing.deployEndpoint(protocolName: t.protocolName, host: t.host, port: t.port, username: t.username)
        let secret = try app.requireSettingsRuntime().keyRing.openDeploy(t.secretCiphertext, keyID: t.secretKeyID, targetID: try t.requireID(), endpoint: endpoint)
        return DeployConnection(protocolName: t.protocolName, host: address, port: t.port, basePath: t.basePath, username: t.username,
                                password: secret.password, privateKey: secret.privateKey, passphrase: secret.passphrase,
                                hostKey: t.hostKey, tlsCertificate: t.tlsCertificate)
    }

    func failure(_ t: DeployTarget, _ code: String, _ action: String) -> String {
        app.logger.info("deploy \(action) failed", metadata: ["target": .string(t.id?.uuidString ?? "-"), "code": .string(code)])
        return code
    }

    /// Before the host key is confirmed nothing logs in: the answer carries the offered key for the person to confirm.
    func test(_ id: UUID, forPerson: Bool) async throws -> DeployTestResult {
        let t = try await target(id, role: .edit)
        do {
            let address = try await connectAddress(t)
            if t.protocolName == DeployProtocol.sftp.rawValue, t.hostKey == nil {
                let offered = try? await app.deployTransport.scanHostKey(host: address, port: t.port)
                return DeployTestResult(ok: false, code: offered == nil ? failure(t, "deploy_unreachable", "test") : "deploy_host_key_unconfirmed", files: nil,
                                        offeredHostKey: forPerson ? offered.map { DeployOfferedHostKey(type: $0.type, fingerprint: $0.fingerprint) } : nil)
            }
            let files = try await app.deployTransport.list(try connection(t, address: address))
            app.logger.info("deploy test ok", metadata: ["target": .string(id.uuidString)])
            return DeployTestResult(ok: true, code: nil, files: files.count, offeredHostKey: nil)
        } catch let e as DeployTransportError {
            return DeployTestResult(ok: false, code: failure(t, e.code, "test"), files: nil, offeredHostKey: nil)
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" {
            return DeployTestResult(ok: false, code: failure(t, "deploy_target_blocked", "test"), files: nil, offeredHostKey: nil)
        }
    }

    static func validManifest(_ files: [DeployManifestEntry]) throws -> [String: DeployManifestEntry] {
        guard files.count <= DeployLimits.maxManifest else { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
        var out: [String: DeployManifestEntry] = [:]
        let hex = Set("0123456789abcdef")
        for f in files {
            let sha = f.sha256.lowercased()
            guard DeployPath.isSafeRelative(f.path, allowEmpty: false), f.size >= 0, sha.count == 64, sha.allSatisfy({ hex.contains($0) }),
                  out[f.path] == nil, f.eol.map({ ["lf", "crlf", "keep"].contains($0) }) ?? true else { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
            out[f.path] = DeployManifestEntry(path: f.path, size: f.size, sha256: sha, eol: f.eol)
        }
        return out
    }

    func compare(_ id: UUID, manifest: [DeployManifestEntry]) async throws -> DeployCompareResult {
        let t = try await target(id, role: .edit)
        let repo = try Self.validManifest(manifest)
        let rules = try DeployRulesDTO.decode(t.rules).rules()
        guard t.protocolName != DeployProtocol.sftp.rawValue || t.hostKey != nil else {
            return DeployCompareResult(ok: false, code: "deploy_host_key_unconfirmed", summary: nil, files: nil)
        }
        do {
            let conn = try connection(t, address: try await connectAddress(t))
            let listed = try await app.deployTransport.list(conn)
            let result = try await Self.compare(repo: repo, server: listed, rules: rules) { paths in
                try await app.deployTransport.read(conn, paths: paths)
            }
            app.logger.info("deploy compare ok", metadata: ["target": .string(id.uuidString), "files": .stringConvertible(result.files?.count ?? 0)])
            return result
        } catch let e as DeployTransportError {
            return DeployCompareResult(ok: false, code: failure(t, e.code, "compare"), summary: nil, files: nil)
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" {
            return DeployCompareResult(ok: false, code: failure(t, "deploy_target_blocked", "compare"), summary: nil, files: nil)
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Without line ending differences: CRLF -> LF. Only for text (no NUL byte) up to `textCompareBytes`.
    static func normalized(_ data: Data) -> Data? {
        guard data.count <= DeployLimits.textCompareBytes, !data.contains(0) else { return nil }
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

    /// Pure compare: repo manifest against the server listing, after rules and mappings. Reads only files whose status
    /// depends on the content (equal size, or a server file that may only differ in line endings).
    static func compare(repo: [String: DeployManifestEntry], server listed: [DeployRemoteFile], rules: DeployRules,
                        read: ([String]) async throws -> [String: Data]) async throws -> DeployCompareResult {
        var wanted: [String: (repoPath: String, entry: DeployManifestEntry)] = [:]   // server path -> repo file
        for (path, entry) in repo where !rules.isExcluded(path) {
            // Overlapping mappings: only the repo file the server path maps back to counts (deterministic, ADR 0039).
            if let s = rules.serverPath(forRepo: path), rules.repoPath(forServer: s) == path { wanted[s] = (path, entry) }
        }
        var onServer: [String: Int] = [:]
        for f in listed where DeployPath.isSafeRelative(f.path, allowEmpty: false) { onServer[f.path] = f.size }

        var files: [DeployCompareFile] = []
        var toRead = Set<String>()
        var readBudget = DeployLimits.maxReadTotal
        var unverified = Set<String>()
        for (serverPath, (_, entry)) in wanted {
            guard let size = onServer[serverPath] else { continue }
            let mayBeEqual = size == entry.size || (size > entry.size && size <= DeployLimits.textCompareBytes && size <= entry.size * 2 + 2)
            guard mayBeEqual else { continue }
            if size > DeployLimits.maxReadFile || size > readBudget { unverified.insert(serverPath); continue }
            readBudget -= size
            toRead.insert(serverPath)
        }
        let contents = toRead.isEmpty ? [:] : try await read(toRead.sorted())

        var summary = DeployCompareSummary()
        for (serverPath, (repoPath, entry)) in wanted {
            guard let size = onServer[serverPath] else {
                summary.new += 1
                files.append(DeployCompareFile(path: repoPath, serverPath: serverPath, status: "new", repoSize: entry.size, serverSize: nil))
                continue
            }
            var status = "changed"
            if unverified.contains(serverPath) {
                status = "unverified"
            } else if toRead.contains(serverPath) {
                if let data = contents[serverPath] {
                    if sha256(data) == entry.sha256 || normalized(data).map(sha256) == entry.sha256 { status = "same" }
                } else { status = "unverified" }
            }
            switch status {
            case "same": summary.same += 1
            case "unverified": summary.unverified += 1
            default: summary.changed += 1
            }
            files.append(DeployCompareFile(path: repoPath, serverPath: serverPath, status: status, repoSize: entry.size, serverSize: size))
        }
        for (serverPath, size) in onServer where wanted[serverPath] == nil {
            // Only files the target would manage: inside a mapping, not excluded, and mapping back to the same server path.
            guard let repoPath = rules.repoPath(forServer: serverPath), !rules.isExcluded(repoPath),
                  rules.serverPath(forRepo: repoPath) == serverPath, repo[repoPath] == nil else { continue }
            summary.serverOnly += 1
            files.append(DeployCompareFile(path: repoPath, serverPath: serverPath, status: "serverOnly", repoSize: nil, serverSize: size))
        }
        files.sort { $0.path < $1.path }
        return DeployCompareResult(ok: true, code: nil, summary: summary, files: files)
    }
}

// MARK: - REST

struct DeployController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let p = routes.grouped("v1", "projects", ":id", "deploy-targets")
        p.get(use: list)
        p.post(use: create)
        let t = routes.grouped("v1", "deploy-targets", ":targetID")
        t.get(use: get)
        t.patch(use: update)
        t.delete(use: remove)
        t.post("host-key", use: hostKey)
        t.post("test", use: test)
        // A whole repo manifest (up to DeployLimits.maxManifest entries, ~100 bytes each) is far above the default 256 kB body
        // limit; 16 MB holds 50 000 entries with paths of up to ~250 characters on average.
        t.on(.POST, "compare", body: .collect(maxSize: "16mb"), use: compare)
        // Pull (phase 2a, ADR 0041): same manifest, the answer carries file contents (up to 16 MB).
        t.on(.POST, "pull", body: .collect(maxSize: "16mb"), use: pull)
        // Pull request through the GitHub App (phase 2b, ADR 0042): same manifest.
        t.on(.POST, "pull-request", body: .collect(maxSize: "16mb"), use: pullRequest)
    }

    // `requireUser` accepts person sessions only: OAuth access tokens (MCP connections) are 401 here.
    private func service(_ req: Request) async throws -> DeployService { DeployService(app: req.application, user: try await req.requireUser()) }
    private func id(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    @Sendable func list(_ req: Request) async throws -> DeployTargetsResponse {
        DeployTargetsResponse(items: try await service(req).list(projectID: try id(req, "id")).map(DeployTargetDTO.init))
    }
    @Sendable func create(_ req: Request) async throws -> Response {
        let s = try await service(req)
        let t = try await s.create(projectID: try id(req, "id"), try req.content.decode(DeployTargetRequest.self))
        return try await DeployTargetDTO(t).encodeResponse(status: .created, for: req)
    }
    @Sendable func get(_ req: Request) async throws -> DeployTargetDTO { try DeployTargetDTO(try await service(req).target(try id(req, "targetID"), role: .read)) }
    @Sendable func update(_ req: Request) async throws -> DeployTargetDTO {
        let s = try await service(req)
        return try DeployTargetDTO(try await s.update(try id(req, "targetID"), try req.content.decode(DeployTargetRequest.self)))
    }
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        try await service(req).delete(try id(req, "targetID"))
        return .noContent
    }
    @Sendable func hostKey(_ req: Request) async throws -> DeployTargetDTO {
        let s = try await service(req)
        return try DeployTargetDTO(try await s.confirmHostKey(try id(req, "targetID"), fingerprint: try req.content.decode(DeployHostKeyRequest.self).fingerprint))
    }
    @Sendable func test(_ req: Request) async throws -> DeployTestResult { try await service(req).test(try id(req, "targetID"), forPerson: true) }
    @Sendable func compare(_ req: Request) async throws -> DeployCompareResult {
        let s = try await service(req)
        let body: DeployCompareRequest
        do { body = try req.content.decode(DeployCompareRequest.self) } catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
        return try await s.compare(try id(req, "targetID"), manifest: body.files)
    }
}
