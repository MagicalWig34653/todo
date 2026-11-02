import Fluent
import XCTVapor
@testable import TodoKit

final class OAuthRegistrationLimitTests: XCTestCase {
    func testRegistrationIsRateLimitedAndBounded() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        var settings = IdentitySettings()
        settings.window = 3600
        settings.oauthRegisterLimit = 3
        t.app.identitySettings = settings
        let body: [String: Any] = ["client_name": "C", "redirect_uris": ["https://example.com/cb"]]
        for _ in 0..<3 {
            let r = try await t.json(.POST, "/oauth/register", body)
            XCTAssertEqual(r.status, .created)
        }
        for path in ["/oauth/register", "/oauth/register/", "//oauth//register"] {
            let blocked = try await t.json(.POST, path, body)
            XCTAssertEqual(blocked.status, .tooManyRequests, path)
        }
        let count = try await OAuthClient.query(on: t.app.db).count()
        XCTAssertEqual(count, 3)
    }

    func testOversizedMetadataRejected() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let long = "https://example.com/" + String(repeating: "a", count: 2100)
        let r1 = try await t.json(.POST, "/oauth/register", ["client_name": "C", "redirect_uris": [long]])
        XCTAssertEqual(r1.status, .badRequest)
        let r2 = try await t.json(.POST, "/oauth/register", ["client_name": String(repeating: "x", count: 201), "redirect_uris": ["https://example.com/cb"]])
        XCTAssertEqual(r2.status, .badRequest)
    }

    func testCleanupRemovesOnlyOldUnusedClients() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let user = User(displayName: "U", isAdmin: false)
        try await user.save(on: t.app.db)
        let old = Date().addingTimeInterval(-10 * 86_400)
        func client(_ name: String, created: Date) async throws -> OAuthClient {
            let c = OAuthClient(name: name, redirects: ["https://example.com/cb"])
            c.createdAt = created
            try await c.save(on: t.app.db)
            return c
        }
        let oldUnused = try await client("old-unused", created: old)
        let oldUsed = try await client("old-used", created: old)
        let fresh = try await client("fresh", created: Date())
        try await OAuthGrant(userID: user.requireID(), clientID: oldUsed.requireID(), resource: "r", scopes: [], projects: []).save(on: t.app.db)

        var cleanup = ExpiredCleanup(batchSize: 1)
        cleanup.unusedClientRetention = 7 * 86_400
        let report = try await cleanup.run(on: t.app.db)
        XCTAssertEqual(report.oauthClients, 1)
        let remaining = Set(try await OAuthClient.query(on: t.app.db).all().compactMap(\.id))
        XCTAssertFalse(remaining.contains(try oldUnused.requireID()))
        XCTAssertTrue(remaining.contains(try oldUsed.requireID()))
        XCTAssertTrue(remaining.contains(try fresh.requireID()))

        var keep = ExpiredCleanup()
        keep.unusedClientRetention = nil
        let r2 = try await keep.run(on: t.app.db)
        XCTAssertEqual(r2.oauthClients, 0)
    }
}
