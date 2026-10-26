import Fluent
import FluentSQL
import SQLKit
import Foundation
import Vapor
import XCTVapor
@testable import TodoKit

struct TestApp {
    let app: Application
    let settings: AppSettings
    private let storedDatabaseSettings: DatabaseSettings

    init(app: Application, settings: AppSettings, databaseSettings: DatabaseSettings? = nil) {
        self.app = app
        self.settings = settings
        self.storedDatabaseSettings = databaseSettings ?? Self.databaseSettings
    }

    static func make(password: Bool = false) async throws -> TestApp {
        let app = try await Application.make(.testing)
        configureContent()
        var settings = AppSettings()
        settings.bootstrapToken = "bootstrap-secret"
        settings.passwordLoginEnabled = password
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
        return TestApp(app: app, settings: settings, databaseSettings: database)
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

    static var useMariaDB: Bool { ProcessInfo.processInfo.environment["TODO_TEST_MARIADB"] == "1" }

    /// A fresh application gets its own file; replica() reuses the captured database settings.
    static var sqliteFile: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("todo-\(UUID()).sqlite").path
    }

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

    func shutdown() async { try? await app.asyncShutdown() }

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
