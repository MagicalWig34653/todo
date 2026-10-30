import XCTVapor
@testable import TodoKit

final class OAuthIssuerTests: XCTestCase {
    private func settings(_ env: [String: String]) throws -> AppSettings { try AppSettings.fromEnvironment(get: { env[$0] }) }

    func testDerivation() throws {
        // Dev default is unchanged without variables, and with a loopback RP_ORIGIN (compose dev stack).
        XCTAssertEqual(try settings([:]).oauthIssuer, "http://localhost:28080")
        XCTAssertEqual(try settings(["RP_ORIGIN": "http://localhost:25173"]).oauthIssuer, "http://localhost:28080")
        XCTAssertTrue(try settings([:]).oauthIssuerIsLoopback)
        // Existing production env files only carry RP_ORIGIN.
        let prod = try settings(["RP_ORIGIN": "https://todo.example.test"])
        XCTAssertEqual(prod.oauthIssuer, "https://todo.example.test")
        XCTAssertEqual(prod.oauthResource, "https://todo.example.test/mcp")
        XCTAssertFalse(prod.oauthIssuerIsLoopback)
        // OAUTH_ISSUER wins; trailing slashes and blanks are normalised.
        XCTAssertEqual(try settings(["OAUTH_ISSUER": "https://mcp.example.test/", "RP_ORIGIN": "https://todo.example.test"]).oauthIssuer, "https://mcp.example.test")
        XCTAssertEqual(try settings(["OAUTH_ISSUER": " ", "RP_ORIGIN": "https://todo.example.test"]).oauthIssuer, "https://todo.example.test")
    }

    func testDiscoveryUsesConfiguredIssuerAndNoLocalhost() async throws {
        let base = "https://todo.example.test"
        let t = try await TestApp.make(issuer: base)
        do {
            let rs = try await t.json(.GET, "/.well-known/oauth-protected-resource/mcp")
            XCTAssertEqual(rs.body?["resource"] as? String, base + "/mcp")
            XCTAssertEqual(rs.body?["authorization_servers"] as? [String], [base])
            let `as` = try await t.json(.GET, "/.well-known/oauth-authorization-server")
            XCTAssertEqual(`as`.body?["issuer"] as? String, base)
            XCTAssertEqual(`as`.body?["authorization_endpoint"] as? String, base + "/oauth/authorize")
            XCTAssertEqual(`as`.body?["token_endpoint"] as? String, base + "/oauth/token")
            XCTAssertEqual(`as`.body?["registration_endpoint"] as? String, base + "/oauth/register")
            var challenge = ""
            try await t.app.test(.POST, "/mcp") { res async in
                XCTAssertEqual(res.status, .unauthorized)
                challenge = res.headers.first(name: "WWW-Authenticate") ?? ""
            }
            XCTAssertTrue(challenge.contains("resource_metadata=\"\(base)/.well-known/oauth-protected-resource/mcp\""), challenge)
            for text in [String(describing: rs.body ?? [:]), String(describing: `as`.body ?? [:]), challenge] {
                XCTAssertFalse(text.contains("localhost"), text)
            }
        }
        try await t.app.asyncShutdown()
    }

    func testDefaultDiscoveryUnchanged() async throws {
        let t = try await TestApp.make()
        let rs = try await t.json(.GET, "/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(rs.body?["resource"] as? String, "http://localhost:28080/mcp")
        try await t.app.asyncShutdown()
    }

    func testFullFlowBindsGrantToConfiguredIssuer() async throws {
        let base = "https://todo.example.test"
        let f = try await OAuthFixture.make(issuer: base)
        let tokens = try await f.tokens()
        let list = try await f.rpc("tools/list", access: tokens.access)
        XCTAssertEqual(list.status, .ok)
        // A grant for the old localhost resource is refused at the token endpoint.
        let wrong = try await f.exchange(try await f.code(), resource: "http://localhost:28080/mcp")
        XCTAssertEqual(wrong.status, .badRequest)
        try await f.test.app.asyncShutdown()
    }
}
