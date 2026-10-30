import XCTVapor
@testable import TodoKit

final class WebRootTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "webroot-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/_app/immutable/chunks", withIntermediateDirectories: true)
        try "<!doctype html><title>PWA</title>".write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
        try "console.log(1)".write(toFile: dir + "/_app/immutable/chunks/a.js", atomically: true, encoding: .utf8)
        try "sw".write(toFile: dir + "/service-worker.js", atomically: true, encoding: .utf8)
        try "{}".write(toFile: dir + "/manifest.webmanifest", atomically: true, encoding: .utf8)
        try "secret".write(toFile: dir + "/../\((dir as NSString).lastPathComponent)-secret.txt", atomically: true, encoding: .utf8)
        try ".hidden".write(toFile: dir + "/.env", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: dir + "-secret.txt")
    }

    private func makeApp(webRoot: String?, ids: [String] = ["T.de.x.todo"]) async throws -> Application {
        let app = try await Application.make(.testing)
        try configureDatabase(app, settings: DatabaseSettings(
            driver: .sqlite, host: "", port: 0, name: "", user: "", password: ""))
        app.settings = AppSettings(appleAppIDs: ids, webRoot: webRoot)
        try routes(app)
        return app
    }

    private let html: HTTPHeaders = ["Accept": "text/html,application/xhtml+xml"]

    func testIndexAtRootWithNoCache() async throws {
        let app = try await makeApp(webRoot: dir)
        try await app.test(.GET, "/") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .contentType), "text/html; charset=utf-8")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
            XCTAssertTrue(String(buffer: res.body).contains("<title>PWA</title>"))
        }
        try await app.test(.HEAD, "/", headers: html) { res async in XCTAssertEqual(res.status, .ok) }
        try await app.asyncShutdown()
    }

    func testImmutableAssetAndNoCacheFiles() async throws {
        let app = try await makeApp(webRoot: dir)
        try await app.test(.GET, "/_app/immutable/chunks/a.js") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .contentType), "text/javascript; charset=utf-8")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "public, max-age=31536000, immutable")
            XCTAssertEqual(String(buffer: res.body), "console.log(1)")
        }
        try await app.test(.GET, "/service-worker.js") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
        }
        try await app.test(.GET, "/manifest.webmanifest") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .contentType), "application/manifest+json; charset=utf-8")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
        }
        try await app.test(.GET, "/_app/immutable/missing.js", headers: html) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.asyncShutdown()
    }

    func testSPAFallbackOnlyForHTMLNavigation() async throws {
        let app = try await makeApp(webRoot: dir)
        try await app.test(.GET, "/inbox", headers: html) { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(String(buffer: res.body).contains("<title>PWA</title>"))
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
        }
        try await app.test(.GET, "/projects/abc/tasks/1", headers: html) { res async in XCTAssertEqual(res.status, .ok) }
        try await app.test(.GET, "/inbox", headers: ["Accept": "application/json"]) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.test(.POST, "/inbox", headers: html) { res async in XCTAssertEqual(res.status, .notFound) }
        try await app.asyncShutdown()
    }

    func testAPIPathsKeepJSONNotFound() async throws {
        let app = try await makeApp(webRoot: dir)
        for path in ["/v1/nope", "/oauth/nope", "/mcp", "/.well-known/nope", "/health/nope", "/docs/x", "/v1"] {
            try await app.test(.GET, path, headers: html) { res async in
                XCTAssertTrue([.notFound, .methodNotAllowed].contains(res.status), "\(path) \(res.status)")
                XCTAssertNotEqual(res.headers.first(name: .contentType), "text/html; charset=utf-8", path)
            }
        }
        try await app.test(.GET, "/v1/nope", headers: html) { res async in
            XCTAssertEqual(res.headers.contentType, .json)
            XCTAssertTrue(String(buffer: res.body).contains("\"error\":true"))
        }
        try await app.asyncShutdown()
    }

    func testTraversalAndDotFilesAreRefused() async throws {
        let app = try await makeApp(webRoot: dir)
        let name = (dir as NSString).lastPathComponent
        for path in ["/..%2f\(name)-secret.txt", "/%2e%2e/\(name)-secret.txt", "/_app/%2e%2e/%2e%2e/\(name)-secret.txt",
                     "/..%5c..%5cetc", "/a%00b", "/.env", "/%2eenv"] {
            try await app.test(.GET, path) { res async in
                XCTAssertTrue([.notFound, .badRequest].contains(res.status), "\(path) \(res.status)")
                XCTAssertFalse(String(buffer: res.body).contains("secret"), path)
            }
        }
        try await app.asyncShutdown()
    }

    func testAASAAndWellKnownNotShadowed() async throws {
        let app = try await makeApp(webRoot: dir)
        for path in ["/.well-known/apple-app-site-association", "/apple-app-site-association"] {
            try await app.test(.GET, path, headers: html) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.contentType, .json)
                XCTAssertEqual(String(buffer: res.body), #"{"webcredentials":{"apps":["T.de.x.todo"]}}"#)
            }
        }
        try await app.test(.GET, "/health/live") { res async in XCTAssertEqual(res.status, .ok) }
        try await app.asyncShutdown()
        // AASA unset: stays a 404, not the SPA shell.
        let bare = try await makeApp(webRoot: dir, ids: [])
        try await bare.test(.GET, "/.well-known/apple-app-site-association", headers: html) { res async in
            XCTAssertEqual(res.status, .notFound)
            XCTAssertNotEqual(res.headers.first(name: .contentType), "text/html; charset=utf-8")
        }
        try await bare.asyncShutdown()
    }

    func testWithoutWebRootBehavesAsAPIOnly() async throws {
        for root in [nil, "/nonexistent-\(UUID().uuidString)"] {
            let app = try await makeApp(webRoot: root)
            try await app.test(.GET, "/", headers: html) { res async in XCTAssertEqual(res.status, .notFound) }
            try await app.test(.GET, "/inbox", headers: html) { res async in XCTAssertEqual(res.status, .notFound) }
            try await app.asyncShutdown()
        }
    }

    func testWebRootEnvironment() throws {
        XCTAssertEqual(try AppSettings.fromEnvironment(get: { _ in nil }).webRoot, "/srv/web")
        XCTAssertEqual(try AppSettings.fromEnvironment(get: { $0 == "WEB_ROOT" ? "/x" : nil }).webRoot, "/x")
    }
}
