import Fluent
import FluentSQL
import SQLKit
import Foundation
import Vapor
import XCTVapor
@testable import TodoKit

/// One scratch directory per test process (`todo-tests-<pid>-<UUID>` in TMPDIR). It is removed when the process
/// exits, and directories left behind by crashed or killed runs (owner pid gone) are swept on first use, so
/// scratch SQLite files never pile up in TMPDIR (card F49E0207).
enum TestTemp {
    private static let prefix = "todo-tests-"
    private static let memoryPrefix = "sqlite-kit_memorydb-"
    nonisolated(unsafe) private static var created: String?

    static let directory: URL = {
        let tmp = FileManager.default.temporaryDirectory
        sweepStale(in: tmp)
        let dir = tmp.appendingPathComponent("\(prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        created = dir.path
        atexit {
            if let path = TestTemp.created { try? FileManager.default.removeItem(atPath: path) }
            TestTemp.sweepOwnMemoryDatabases()
        }
        return dir
    }()

    static func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    /// Removes a SQLite file together with its -wal and -shm companions.
    static func removeSQLite(atPath path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    static func sweepStale(in tmp: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names {
            let stem = name.hasPrefix(prefix) ? prefix : name.hasPrefix(memoryPrefix) ? memoryPrefix : nil
            guard let stem else { continue }
            let pidText = name.dropFirst(stem.count).prefix { $0 != "-" }
            guard let pid = pid_t(pidText), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// sqlite-kit fakes `.sqlite(.memory)` with `sqlite-kit_memorydb-<pid>-<id>.sqlite3` in TMPDIR and never removes it.
    static func sweepOwnMemoryDatabases(in tmp: URL = FileManager.default.temporaryDirectory) {
        let own = "\(memoryPrefix)\(getpid())-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(own) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}

extension DatabaseSettings {
    /// Replaces `.sqlite(.memory)` in tests: a file in the per-process scratch directory that is removed at exit.
    static var testScratch: DatabaseSettings {
        DatabaseSettings(driver: .sqlite, host: "", port: 0, name: TestTemp.path("scratch-\(UUID()).sqlite"), user: "", password: "")
    }
}

struct TestApp {
    let app: Application
    let settings: AppSettings
    private let storedDatabaseSettings: DatabaseSettings
    /// SQLite file this instance created and must delete on shutdown; replicas share the file and own nothing.
    private let ownedSQLiteFile: String?

    init(app: Application, settings: AppSettings, databaseSettings: DatabaseSettings? = nil, ownedSQLiteFile: String? = nil) {
        self.app = app
        self.settings = settings
        self.storedDatabaseSettings = databaseSettings ?? Self.databaseSettings
        self.ownedSQLiteFile = ownedSQLiteFile
    }

    static func make(password: Bool = false, issuer: String? = nil) async throws -> TestApp {
        let app = try await Application.make(.testing)
        configureContent()
        var settings = AppSettings()
        settings.bootstrapToken = "bootstrap-secret"
        settings.passwordLoginEnabled = password
        if let issuer { settings.oauthIssuer = issuer }
        app.settings = settings
        let database = databaseSettings
        try configureDatabase(app, settings: database)
        configureMigrations(app)
        try routes(app)
        if useMariaDB {
            // Fresh schema per test; tests run serially against the dev database `todo_test`.
            try await resetMariaDB(app)
        }
        try await app.autoMigrate()
        return TestApp(app: app, settings: settings, databaseSettings: database,
                       ownedSQLiteFile: database.driver == .sqlite && !database.name.isEmpty ? database.name : nil)
    }

    /// Drops every table (and migration bookkeeping) so each test starts from an empty schema, independent of
    /// the order in which modules registered their migrations.
    static func resetMariaDB(_ app: Application) async throws {
        guard let sql = app.db as? any SQLDatabase else { return }
        _ = try await sql.raw("SET FOREIGN_KEY_CHECKS=0").run()
        let rows = try await sql.raw("SELECT table_name AS t FROM information_schema.tables WHERE table_schema = DATABASE()").all()
        for row in rows {
            let name = try row.decode(column: "t", as: String.self)
            _ = try await sql.raw("DROP TABLE IF EXISTS `\(unsafeRaw: name)`").run()
        }
        _ = try await sql.raw("SET FOREIGN_KEY_CHECKS=1").run()
    }

    /// Second application instance on the same database, like another swarm replica.
    func replica() async throws -> TestApp {
        let other = try await Application.make(.testing)
        other.settings = settings
        try configureDatabase(other, settings: storedDatabaseSettings)
        try routes(other)
        return TestApp(app: other, settings: settings, databaseSettings: storedDatabaseSettings)
    }

    static var useMariaDB: Bool { ProcessInfo.processInfo.environment["TODO_TEST_MARIADB"] == "1" || ProcessInfo.processInfo.environment["TODO_TEST_DB"] != nil }

    /// A fresh application gets its own file in the per-process scratch directory; replica() reuses the captured
    /// database settings.
    static var sqliteFile: String { TestTemp.path("todo-\(UUID()).sqlite") }

    static var databaseSettings: DatabaseSettings {
        if useMariaDB {
            return DatabaseSettings(
                driver: .mariadb, host: "127.0.0.1",
                port: Int(ProcessInfo.processInfo.environment["DB_PORT"] ?? "") ?? 23306,
                name: ProcessInfo.processInfo.environment["TODO_TEST_DB"] ?? "todo_test", user: "root", password: "dev-root-only")
        }
        return DatabaseSettings(driver: .sqlite, host: "", port: 0, name: sqliteFile, user: "", password: "")
    }

    /// Sends a pre-serialised JSON body; usable from concurrent tasks (Data is Sendable).
    func rawStatus(_ method: HTTPMethod, _ path: String, body: Data, token: String? = nil) async throws -> HTTPStatus {
        var status = HTTPStatus.ok
        try await app.test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            req.headers.contentType = .json
            req.body = ByteBuffer(data: body)
        }, afterResponse: { res async in status = res.status })
        return status
    }

    /// Path of the SQLite file this instance (or its primary) runs on; nil for MariaDB or an in-memory database.
    var sqliteFilePath: String? {
        storedDatabaseSettings.driver == .sqlite && !storedDatabaseSettings.name.isEmpty ? storedDatabaseSettings.name : nil
    }

    func shutdown() async {
        try? await app.asyncShutdown()
        if let ownedSQLiteFile { TestTemp.removeSQLite(atPath: ownedSQLiteFile) }
    }

    func json(
        _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, token: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        var out: (HTTPStatus, [String: Any]?, [[String: Any]]?, String?) = (.ok, nil, nil, nil)
        try await app.test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if let body {
                req.headers.contentType = .json
                req.body = ByteBuffer(data: try JSONSerialization.data(withJSONObject: body))
            }
        }, afterResponse: { res async in
            let data = Data(res.body.readableBytesView)
            let parsed = try? JSONSerialization.jsonObject(with: data)
            out = (res.status, parsed as? [String: Any], parsed as? [[String: Any]],
                   res.headers.setCookie?[AuthSupport.cookieName]?.string)
        })
        return out
    }

    /// Full passkey registration; returns the session token and the authenticator.
    func register(token: String, name: String, bearer: String? = nil) async throws -> (session: String, key: VirtualAuthenticator, userID: String) {
        let begin = try await json(.POST, "/v1/auth/register/begin", ["token": token, "displayName": name])
        guard begin.status == .ok, let b = begin.body, let opts = b["options"] as? [String: Any],
            let challenge = opts["challenge"] as? String
        else { throw Abort(begin.status, reason: "register/begin failed: \(begin.body ?? [:])") }
        let key = VirtualAuthenticator()
        let finish = try await json(.POST, "/v1/auth/register/finish", [
            "challengeID": b["challengeID"]!, "credential": key.registrationResponse(challenge: challenge),
        ])
        guard finish.status == .ok, let f = finish.body, let session = f["token"] as? String,
            let user = f["user"] as? [String: Any]
        else { throw Abort(finish.status, reason: "register/finish failed: \(finish.body ?? [:])") }
        return (session, key, user["id"] as! String)
    }

    func login(_ key: VirtualAuthenticator, tamper: Bool = false) async throws -> (status: HTTPStatus, token: String?) {
        let begin = try await json(.POST, "/v1/auth/login/begin")
        let b = begin.body!
        let challenge = (b["options"] as! [String: Any])["challenge"] as! String
        let finish = try await json(.POST, "/v1/auth/login/finish", [
            "challengeID": b["challengeID"]!, "credential": try key.assertion(challenge: challenge, tamper: tamper),
        ])
        return (finish.status, finish.body?["token"] as? String)
    }
}
