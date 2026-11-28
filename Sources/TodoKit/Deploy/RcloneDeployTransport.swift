import Foundation

/// Transport over the rclone binary (ADR 0039). Every run gets its own directory (0700) below `workDirectory` with the rclone
/// configuration (0600; the password only obscured by `rclone obscure` over stdin), known_hosts and the pinned certificate; the
/// directory is removed when the run ends. Secrets never appear on a command line, tool output never leaves this type: failures
/// become fixed codes.
struct RcloneDeployTransport: DeployTransport {
    let workDirectory: URL
    var timeout: TimeInterval = 120

    static func binary(_ env: String, _ name: String) -> String? {
        if let p = ProcessInfo.processInfo.environment[env], !p.isEmpty { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    struct Output { let status: Int32; let stdout: Data; let stderr: String }

    /// Runs a binary with fixed arguments, stdin from `input`, output into files of `dir`; kills it after `timeout`.
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, dir: URL, timeout: TimeInterval,
                    remoteDirectory: String? = nil) async throws -> Output {
        let id = UUID().uuidString
        let outURL = dir.appendingPathComponent("out-\(id)"), errURL = dir.appendingPathComponent("err-\(id)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        let process = Process()
        // A clean environment: no inherited RCLONE_* settings, no user configuration, no proxies.
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": dir.path, "LANG": "C", "LC_ALL": "C"]
        if let remoteDirectory {
            // The directory is the `alias` remote `d:`. Foundation on macOS rewrites arguments and environment values to decomposed
            // Unicode (another directory name), so it travels as the bytes of a file: the shell reads one line into the variable and
            // never evaluates it.
            guard !remoteDirectory.contains(where: \.isNewline) else { throw DeployTransportError(code: "deploy_failed") }
            let file = dir.appendingPathComponent("remote-\(id)")
            FileManager.default.createFile(atPath: file.path, contents: Data((remoteDirectory + "\n").utf8), attributes: [.posixPermissions: 0o600])
            environment["RCLONE_CONFIG_D_TYPE"] = "alias"
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "IFS= read -r RCLONE_CONFIG_D_REMOTE < \"$1\" || exit 90; export RCLONE_CONFIG_D_REMOTE; shift; exec \"$@\"",
                                 "sh", file.path, executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        process.environment = environment
        process.currentDirectoryURL = dir
        let outHandle = try FileHandle(forWritingTo: outURL), errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle
        let stdin = Pipe()
        process.standardInput = stdin
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: DeployTransportError(code: "deploy_transport_unavailable"))
                return
            }
            if let input { stdin.fileHandleForWriting.write(input) }
            try? stdin.fileHandleForWriting.close()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning, process.processIdentifier == pid { process.terminate() }
            }
        }
        try? outHandle.close(); try? errHandle.close()
        let stdout = (try? Data(contentsOf: outURL)) ?? Data()
        let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        return Output(status: status, stdout: stdout, stderr: stderr)
    }

    /// Maps rclone's error text to a fixed code. The text itself is dropped.
    static func classify(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("knownhosts") || s.contains("key mismatch") || s.contains("host key") { return "deploy_host_key_mismatch" }
        if s.contains("x509") || s.contains("certificate") || s.contains("tls:") { return "deploy_tls_untrusted" }
        if s.contains("unable to authenticate") || s.contains("message type 51") || s.contains("530 ") || s.contains("login incorrect") || s.contains("authentication failed")
            || s.contains("permission denied") { return "deploy_auth_failed" }
        if s.contains("directory not found") || s.contains("no such file") || s.contains("not found") { return "deploy_base_path_missing" }
        if s.contains("connection refused") || s.contains("timeout") || s.contains("no such host") || s.contains("unreachable")
            || s.contains("dial tcp") || s.contains("eof") { return "deploy_unreachable" }
        return "deploy_failed"
    }

    private func makeRunDirectory() throws -> URL {
        let dir = workDirectory.appendingPathComponent("todolino-deploy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func rclone() throws -> String {
        guard let path = Self.binary("DEPLOY_RCLONE_PATH", "rclone") else { throw DeployTransportError(code: "deploy_transport_unavailable") }
        return path
    }

    private func obscure(_ secret: String, rclone: String, dir: URL) async throws -> String {
        let out = try await Self.run(rclone, ["obscure", "-"], input: Data(secret.utf8), dir: dir, timeout: 20)
        let value = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.status == 0, !value.isEmpty, !value.contains("\n") else { throw DeployTransportError(code: "deploy_failed") }
        return value
    }

    static func knownHostsLine(host: String, port: Int, key: DeployHostKey) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        return (port == 22 ? h : "[\(host)]:\(port)") + " " + key.type + " " + key.base64 + "\n"
    }

    static func hostKeyAlgorithms(_ type: String) -> String {
        type == "ssh-rsa" ? "rsa-sha2-512 rsa-sha2-256 ssh-rsa" : type
    }

    /// Writes the configuration of remote `t` and returns the extra global arguments.
    private func configure(_ c: DeployConnection, rclone: String, dir: URL, followLinks: Bool = false) async throws -> [String] {
        guard let proto = DeployProtocol(rawValue: c.protocolName) else { throw DeployTransportError(code: "deploy_failed") }
        var lines = ["[t]", "type = \(proto == .sftp ? "sftp" : "ftp")", "host = \(c.host)", "port = \(c.port)", "user = \(c.username)"]
        var extra: [String] = []
        if let p = c.password { lines.append("pass = \(try await obscure(p, rclone: rclone, dir: dir))") }
        switch proto {
        case .sftp:
            guard let key = c.hostKey else { throw DeployTransportError(code: "deploy_host_key_unconfirmed") }
            let known = dir.appendingPathComponent("known_hosts")
            FileManager.default.createFile(atPath: known.path, contents: Data(Self.knownHostsLine(host: c.host, port: c.port, key: key).utf8),
                                           attributes: [.posixPermissions: 0o600])
            lines += ["known_hosts_file = \(known.path)", "host_key_algorithms = \(Self.hostKeyAlgorithms(key.type))",
                      "skip_links = \(!followLinks)", "shell_type = none", "disable_hashcheck = true"]
            if let pem = c.privateKey {
                lines.append(Self.keyPEMLine(pem))
                if let pass = c.passphrase { lines.append("key_file_pass = \(try await obscure(pass, rclone: rclone, dir: dir))") }
            }
        case .ftp:
            break
        case .ftps, .ftpsImplicit:
            lines.append(proto == .ftps ? "explicit_tls = true" : "tls = true")
            if let pem = c.tlsCertificate {
                let ca = dir.appendingPathComponent("ca.pem")
                FileManager.default.createFile(atPath: ca.path, contents: Data(pem.utf8), attributes: [.posixPermissions: 0o600])
                extra += ["--ca-cert", ca.path]
            }
        }
        let config = dir.appendingPathComponent(followLinks ? "rclone-follow.conf" : "rclone.conf")
        FileManager.default.createFile(atPath: config.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return ["--config", config.path, "--cache-dir", dir.appendingPathComponent("cache").path, "--low-level-retries", "1", "--retries", "1",
                "--contimeout", "15s", "--timeout", "60s", "--ask-password=false"] + extra
    }

    /// The remote argument of a directory below the base path. The directory goes through the environment as an `alias` remote:
    /// Foundation on macOS rewrites command line arguments to decomposed Unicode, which would name another directory.
    static let directoryRemote = "d:"
    static func directory(_ c: DeployConnection, _ path: String = "") -> String {
        let base = remote(basePath: c.basePath)
        return path.isEmpty ? base : (base.hasSuffix(":") || base.hasSuffix("/") ? base + path : base + "/" + path)
    }
    static func remote(basePath: String) -> String {
        basePath.hasPrefix("/") ? "t:/" + DeployPath.trimmed(String(basePath.dropFirst())) : "t:" + DeployPath.trimmed(basePath)
    }
    static func keyPEMLine(_ pem: String) -> String {
        "key_pem = " + pem.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n")
    }

    func scanHostKey(host: String, port: Int) async throws -> DeployHostKey {
        guard let keyscan = Self.binary("DEPLOY_SSH_KEYSCAN_PATH", "ssh-keyscan") else { throw DeployTransportError(code: "deploy_transport_unavailable") }
        let dir = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Self.run(keyscan, ["-T", "10", "-p", String(port), "-t", "ed25519,ecdsa,rsa", "--", host], dir: dir, timeout: 30)
        var keys: [DeployHostKey] = []
        for line in String(decoding: out.stdout, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, Data(base64Encoded: String(parts[2])) != nil else { continue }
            keys.append(DeployHostKey(type: String(parts[1]), base64: String(parts[2])))
        }
        let order = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"]
        guard let best = keys.filter({ order.contains($0.type) }).min(by: { order.firstIndex(of: $0.type)! < order.firstIndex(of: $1.type)! }) else {
            throw DeployTransportError(code: "deploy_unreachable")
        }
        return best
    }

    private struct Entry: Decodable { let Path: String; let Size: Int; let IsDir: Bool }

    func list(_ c: DeployConnection) async throws -> [DeployRemoteFile] {
        let rclone = try rclone()
        let dir = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = try await configure(c, rclone: rclone, dir: dir)
        let out = try await Self.run(rclone, args + ["lsjson", "-R", "--files-only", "--no-mimetype", "--no-modtime", Self.directoryRemote], dir: dir,
                                     timeout: timeout, remoteDirectory: Self.directory(c))
        guard out.status == 0 else { throw DeployTransportError(code: Self.classify(out.stderr)) }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: out.stdout) else { throw DeployTransportError(code: "deploy_failed") }
        return entries.filter { !$0.IsDir && $0.Size >= 0 && DeployPath.isSafeRelative($0.Path, allowEmpty: false) }
            .map { DeployRemoteFile(path: $0.Path, size: $0.Size) }
    }

    // MARK: FTP symlinks (ADR 0041)

    /// FTP and FTPS list a symlink like a file and the server follows it on download: a link to a file outside the base path
    /// would deliver that file. rclone cannot tell the two apart, so every directory on the way to a requested file is listed with
    /// `curl` (LIST, unix format: `l...`) and files below or behind a link are dropped. Credentials go in a configuration file
    /// (0600), never on the command line.
    private static func curlConfigValue(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\u{0b}", with: "\\v")
    }

    private static func urlComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }

    static func curlExitCode(_ status: Int32) -> String {
        switch status {
        case 35, 51, 53, 54, 58, 59, 60, 64, 77, 80, 82, 83, 90, 91: "deploy_tls_untrusted"
        case 67, 69: "deploy_auth_failed"
        case 9, 19, 78: "deploy_base_path_missing"
        case 6, 7, 28, 56: "deploy_unreachable"
        default: "deploy_failed"
        }
    }

    /// Names of the symlinks in a unix LIST answer. The line cannot say where the name ends (`name -> target`, and a name may hold
    /// ` -> ` itself), so every prefix before an arrow counts, with and without surrounding blanks: more than needed, never less.
    /// An `l` line that cannot be read fails the whole check (fail closed).
    static func symlinkNames(inList text: String, strict: Bool = false) throws -> Set<String> {
        var names = Set<String>()
        // "\r\n" is one Character in Swift: work on the scalars.
        for scalars in text.unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // `strict` (before writing): only the Unix format shows links, so any other line makes the listing unusable.
            if strict, !(scalars.first.map { "-dlbcps".unicodeScalars.contains($0) } == true && scalars.dropFirst().first.map { "r-".unicodeScalars.contains($0) } == true),
               !scalars.starts(with: "total ".unicodeScalars) {
                throw DeployTransportError(code: "deploy_failed")
            }
            guard scalars.first == "l" else { continue }
            let line = String(String.UnicodeScalarView(scalars))
            // Skip eight columns, then exactly one blank: the rest is `name -> target`, untrimmed.
            var rest = line[...]
            for _ in 0..<8 {
                rest = rest.drop(while: { $0 == " " })
                guard !rest.isEmpty else { throw DeployTransportError(code: "deploy_failed") }
                rest = rest.drop(while: { $0 != " " })
            }
            guard rest.first == " ", rest.contains(" -> ") || rest.dropFirst().contains(" -> ") else { throw DeployTransportError(code: "deploy_failed") }
            let tail = String(rest.dropFirst())
            var from = tail.startIndex
            while let arrow = tail.range(of: " -> ", range: from..<tail.endIndex) {
                let name = String(tail[..<arrow.lowerBound])
                names.insert(name); names.insert(name.trimmingCharacters(in: .whitespaces))
                from = arrow.upperBound
            }
        }
        return names
    }

    /// LIST URL of a directory below the base path. An absolute base path needs a second slash (`//abs`), the login directory is `/`.
    static func ftpListURL(proto: DeployProtocol, host: String, port: Int, basePath: String, directory: String) -> String {
        let absolute = basePath.hasPrefix("/")
        let base = DeployPath.trimmed(absolute ? String(basePath.dropFirst()) : basePath)
        let segments = (base.isEmpty ? [] : base.split(separator: "/").map(String.init)) + directory.split(separator: "/").map(String.init)
        let path = segments.map { urlComponent($0) }.joined(separator: "/")
        let h = host.contains(":") ? "[\(host)]" : host
        return "\(proto == .ftpsImplicit ? "ftps" : "ftp")://\(h):\(port)/" + (absolute ? "/" : "") + path + (path.isEmpty ? "" : "/")
    }

    private func linkFreePaths(_ c: DeployConnection, paths: [String], dir: URL) async throws -> [String] {
        guard let proto = DeployProtocol(rawValue: c.protocolName), proto != .sftp else { return paths }
        guard let curl = Self.binary("DEPLOY_CURL_PATH", "curl") else { throw DeployTransportError(code: "deploy_transport_unavailable") }
        var directories = Set<String>()
        for p in paths {
            let parts = DeployPath.segments(p)
            for i in 0..<parts.count { directories.insert(parts[0..<i].joined(separator: "/")) }
        }
        guard directories.count <= 5000 else { throw DeployTransportError(code: "deploy_failed") }
        let links = try await ftpLinkNames(c, proto: proto, curl: curl, directories: directories, dir: dir)
        return paths.filter { p in
            let parts = DeployPath.segments(p)
            return !parts.indices.contains { links[parts[0..<$0].joined(separator: "/")]?.contains(parts[$0]) == true }
        }
    }

    /// The symlink names of each directory (relative to the base path), from `curl` LIST runs.
    private func ftpLinkNames(_ c: DeployConnection, proto: DeployProtocol, curl: String, directories: Set<String>, dir: URL, strict: Bool = false) async throws
        -> [String: Set<String>] {
        let conf = dir.appendingPathComponent("curl.conf")
        FileManager.default.createFile(atPath: conf.path, contents: Data("user = \"\(Self.curlConfigValue(c.username)):\(Self.curlConfigValue(c.password ?? ""))\"\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        var tls: [String] = proto == .ftps ? ["--ssl-reqd"] : []
        if proto.usesTLS, let pem = c.tlsCertificate {
            let ca = dir.appendingPathComponent("curl-ca.pem")
            FileManager.default.createFile(atPath: ca.path, contents: Data(pem.utf8), attributes: [.posixPermissions: 0o600])
            tls += ["--cacert", ca.path]
        }
        // One curl run lists up to 50 directories over one connection (curl reuses it between the URLs of a run).
        var links: [String: Set<String>] = [:]
        let sorted = directories.sorted()
        for start in stride(from: 0, to: sorted.count, by: 50) {
            let batch = Array(sorted[start..<min(start + 50, sorted.count)])
            // `-a`: servers like pure-ftpd leave names starting with a dot out of a plain LIST, and a hidden link is followed too.
            var arguments = ["-q", "-sS", "--globoff", "--connect-timeout", "15", "--max-time", "300", "--ftp-skip-pasv-ip", "--request", "LIST -a",
                             "-K", conf.path] + tls
            var outFiles: [URL] = []
            for d in batch {
                let out = dir.appendingPathComponent("list-\(UUID().uuidString)")
                outFiles.append(out)
                arguments += ["-o", out.path, Self.ftpListURL(proto: proto, host: c.host, port: c.port, basePath: c.basePath, directory: d)]
            }
            defer { for f in outFiles { try? FileManager.default.removeItem(at: f) } }
            let result = try await Self.run(curl, arguments, dir: dir, timeout: 330)
            guard result.status == 0 else { throw DeployTransportError(code: Self.curlExitCode(result.status)) }
            for (d, file) in zip(batch, outFiles) {
                // A listing above 4 MB is not read (fail closed): it cannot be checked.
                guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 4 * 1024 * 1024 + 1), data.count <= 4 * 1024 * 1024 else {
                    throw DeployTransportError(code: "deploy_failed")
                }
                links[d] = try Self.symlinkNames(inList: String(decoding: data, as: UTF8.self), strict: strict)
            }
        }
        return links
    }

    func read(_ c: DeployConnection, paths: [String]) async throws -> [String: Data] {
        let wanted = paths.filter { DeployPath.isSafeRelative($0, allowEmpty: false) }
        guard !wanted.isEmpty else { return [:] }
        let rclone = try rclone()
        let dir = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let safe = try await linkFreePaths(c, paths: wanted, dir: dir)
        guard !safe.isEmpty else { return [:] }
        let args = try await configure(c, rclone: rclone, dir: dir)
        let list = dir.appendingPathComponent("files.txt"), copy = dir.appendingPathComponent("copy")
        FileManager.default.createFile(atPath: list.path, contents: Data((safe.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600])
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let out = try await Self.run(rclone, args + ["copy", "--files-from-raw", list.path,
                                                     "--no-update-modtime", Self.directoryRemote, copy.path], dir: dir, timeout: timeout,
                                     remoteDirectory: Self.directory(c))
        guard out.status == 0 else { throw DeployTransportError(code: Self.classify(out.stderr)) }
        var result: [String: Data] = [:]
        for p in safe {
            let url = copy.appendingPathComponent(p)
            // Only regular files inside the copy directory (rclone does not create links, but never follow one).
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                  let data = try? Data(contentsOf: url) else { continue }
            result[p] = data
        }
        return result
    }

    // MARK: Writing (ADR 0044)

    private static func writable(_ paths: [String]) throws {
        guard paths.allSatisfy({ DeployPath.isSafeRelative($0, allowEmpty: false) }) else { throw DeployTransportError(code: "deploy_failed") }
    }

    private struct Name: Decodable { let Name: String; let IsDir: Bool }
    private struct Level { var links = Set<String>(), files = Set<String>(), directories = Set<String>() }

    private func names(_ rclone: String, _ arguments: [String], _ directory: String, dir: URL) async throws -> [Name] {
        let out = try await Self.run(rclone, arguments + ["lsjson", "--no-mimetype", "--no-modtime", Self.directoryRemote], dir: dir,
                                     timeout: timeout, remoteDirectory: directory)
        guard out.status == 0 else { throw DeployTransportError(code: Self.classify(out.stderr)) }
        guard let entries = try? JSONDecoder().decode([Name].self, from: out.stdout) else { throw DeployTransportError(code: "deploy_failed") }
        return entries
    }

    /// Walks down the directories of every path. SFTP: what appears only when links are followed is a link. FTP: `curl` LIST.
    func linkedPaths(_ c: DeployConnection, paths: [String]) async throws -> Set<String> {
        try Self.writable(paths)
        guard !paths.isEmpty, let proto = DeployProtocol(rawValue: c.protocolName) else { return [] }
        let rclone = try rclone()
        let dir = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = try await configure(c, rclone: rclone, dir: dir)
        let follow = proto == .sftp ? try await configure(c, rclone: rclone, dir: dir, followLinks: true) : []
        var levels: [String: Level] = [:]
        func level(_ directory: String) async throws -> Level {
            if let known = levels[directory] { return known }
            guard levels.count < 2000 else { throw DeployTransportError(code: "deploy_failed") }
            let target = Self.directory(c, directory)
            var found = Level()
            let plain = try await names(rclone, args, target, dir: dir)
            for e in plain { if e.IsDir { found.directories.insert(e.Name) } else { found.files.insert(e.Name) } }
            if proto == .sftp {
                // Compared as bytes: a link may differ from a plain name only in its Unicode form.
                let seen = Set(plain.map { Data($0.Name.utf8) })
                found.links = Set(try await names(rclone, follow, target, dir: dir).map(\.Name).filter { !seen.contains(Data($0.utf8)) })
            } else {
                guard let curl = Self.binary("DEPLOY_CURL_PATH", "curl") else { throw DeployTransportError(code: "deploy_transport_unavailable") }
                found.links = try await ftpLinkNames(c, proto: proto, curl: curl, directories: [directory], dir: dir, strict: true)[directory] ?? []
            }
            levels[directory] = found
            return found
        }
        var refused = Set<String>()
        for path in paths.sorted() {
            let parts = DeployPath.segments(path)
            var directory = ""
            for (index, part) in parts.enumerated() {
                let here = try await level(directory)
                if here.links.contains(part) { refused.insert(path); break }
                if index == parts.count - 1 { if here.directories.contains(part) { refused.insert(path) }; break }
                if here.files.contains(part) { refused.insert(path); break }
                if !here.directories.contains(part) { break }   // does not exist yet: nothing below can be a link
                directory = directory.isEmpty ? part : directory + "/" + part
            }
        }
        return refused
    }

    /// A file list for rclone. File names go this way and never on the command line: Foundation on macOS rewrites arguments to
    /// decomposed Unicode, which would create or remove a different name.
    private static func fileList(_ paths: [String], dir: URL) -> URL {
        let list = dir.appendingPathComponent("write.txt")
        FileManager.default.createFile(atPath: list.path, contents: Data((paths.joined(separator: "\n") + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        return list
    }

    /// rclone uploads each file as `<name>.<random>.todolino.tmp` and renames it when complete, so nobody sees half a file.
    func upload(_ c: DeployConnection, files: [DeployUploadFile]) async throws {
        try Self.writable(files.map(\.path))
        guard !files.isEmpty else { return }
        let rclone = try rclone()
        let dir = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = try await configure(c, rclone: rclone, dir: dir)
        let staging = dir.appendingPathComponent("up")
        for file in files {
            let url = staging.appendingPathComponent(file.path)
            // Second line of defence: nothing is staged outside the staging directory.
            guard url.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw DeployTransportError(code: "deploy_failed") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: file.data) else { throw DeployTransportError(code: "deploy_failed") }
        }
        let list = Self.fileList(files.map(\.path), dir: dir)
        // --ignore-times: never take "same size, same time" as a reason to keep the old file.
        let out = try await Self.run(rclone, args + ["copy", "--files-from-raw", list.path, "--no-traverse", "--ignore-times",
                                                     "--partial-suffix", DeployPlanner.temporarySuffix, staging.path, Self.directoryRemote],
                                     dir: dir, timeout: timeout, remoteDirectory: Self.directory(c))
        guard out.status == 0 else { throw DeployTransportError(code: Self.classify(out.stderr)) }
    }

    func delete(_ c: DeployConnection, paths: [String]) async throws {
        try Self.writable(paths)
        guard !paths.isEmpty else { return }
        let rclone = try rclone()
        let dir = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = try await configure(c, rclone: rclone, dir: dir)
        let list = Self.fileList(paths, dir: dir)
        let out = try await Self.run(rclone, args + ["delete", "--files-from-raw", list.path, Self.directoryRemote], dir: dir, timeout: timeout,
                                     remoteDirectory: Self.directory(c))
        guard out.status == 0 else { throw DeployTransportError(code: Self.classify(out.stderr)) }
    }
}
