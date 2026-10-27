import XCTVapor
@testable import TodoKit

final class AASATests: XCTestCase {
    private func makeApp(ids: [String]) async throws -> Application {
        let app = try await Application.make(.testing)
        try configureDatabase(app, settings: DatabaseSettings(
            driver: .sqlite, host: "", port: 0, name: "", user: "", password: ""))
        app.settings = AppSettings(appleAppIDs: ids)
        try routes(app)
        return app
    }

    func testServesWebcredentialsOnBothPaths() async throws {
        let app = try await makeApp(ids: ["T.de.x.todo", "T.de.x.todo.mac"])
        for path in [".well-known/apple-app-site-association", "apple-app-site-association"] {
            try await app.test(.GET, path) { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.contentType, .json)
                XCTAssertNil(res.headers.first(name: .location))
                XCTAssertEqual(String(buffer: res.body),
                               #"{"webcredentials":{"apps":["T.de.x.todo","T.de.x.todo.mac"]}}"#)
            }
        }
        try await app.asyncShutdown()
    }

    func testNotFoundWhenUnset() async throws {
        let app = try await makeApp(ids: [])
        try await app.test(.GET, ".well-known/apple-app-site-association") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.asyncShutdown()
    }

    func testEnvironmentParsing() throws {
        let v = ["AASA_APP_IDS": " A.b , C.d ,,"]
        XCTAssertEqual(try AppSettings.fromEnvironment(get: { v[$0] }).appleAppIDs, ["A.b", "C.d"])
        XCTAssertEqual(try AppSettings.fromEnvironment(get: { _ in nil }).appleAppIDs, [])
    }
}
