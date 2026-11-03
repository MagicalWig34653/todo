import XCTest
@testable import TodoKit

final class ConsentPageTests: XCTestCase {
    func testEveryScopeHasLabelAndGroup() {
        let groups = Set(ConsentPage.groups.map(\.id))
        for scope in OAuthController.scopes {
            let entry = ConsentPage.catalog.first { $0.scope == scope }
            XCTAssertNotNil(entry, "missing label for \(scope)")
            XCTAssertFalse(entry?.label.isEmpty ?? true, scope)
            XCTAssertTrue(groups.contains(entry?.group ?? ""), "missing group for \(scope)")
        }
        XCTAssertEqual(Set(ConsentPage.catalog.map(\.scope)).count, ConsentPage.catalog.count, "duplicate catalog entries")
        XCTAssertTrue(ConsentPage.catalog.allSatisfy { OAuthController.scopes.contains($0.scope) }, "catalog has unknown scope")
    }

    func testCriticalScopesAreFlagged() {
        for scope in ["sharing:write", "teams:write", "runs:write", "admin:read"] {
            XCTAssertEqual(ConsentPage.catalog.first { $0.scope == scope }?.critical, true, scope)
        }
    }

    func testPageKeepsSecurityProperties() {
        XCTAssertTrue(ConsentPage.csp.contains("frame-ancestors 'none'"))
        XCTAssertTrue(ConsentPage.csp.contains("default-src 'none'"))
        XCTAssertTrue(ConsentPage.csp.contains("script-src 'sha256-"))
        XCTAssertFalse(ConsentPage.csp.contains("script-src 'unsafe"))
        XCTAssertFalse(ConsentPage.html.contains("http://") || ConsentPage.html.contains("https://"), "no external resources")
        XCTAssertFalse(ConsentPage.script.contains("innerHTML"))
        XCTAssertTrue(ConsentPage.html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(ConsentPage.script.contains("consent_token"))
        XCTAssertFalse(ConsentPage.script.contains("__CATALOG__"))
    }

    func testLoginReturnTargetOnlyAcceptsAuthorizeEndpoint() {
        let good = ["/oauth/authorize", "/oauth/authorize?client_id=1&scope=a%20b&state=x%2By&code_challenge=abc-_"]
        for g in good { XCTAssertTrue(OAuthController.isSafeAuthorizeNext(g), g) }
        let hostile = ["//evil.com", "//evil.com/oauth/authorize", "https://evil", "https://evil/oauth/authorize?x=1", "http://localhost/oauth/authorize",
                       "/\\evil.com", "/oauth/authorize?x=\\evil", "/oauth/authorize\r\nSet-Cookie: a=b", "/oauth/authorize?x=1\r\nLocation: //evil",
                       "/oauth/authorize?x=\n", "/oauth/authorizeevil", "/oauth/authorize/../x", "/oauth/token", "/v1/me", "javascript:alert(1)",
                       "", "oauth/authorize", " /oauth/authorize", "/oauth/authorize?x=ä", "/oauth/authorize?x=\0",
                       "/oauth/authorize?" + String(repeating: "a", count: 4100)]
        for h in hostile { XCTAssertFalse(OAuthController.isSafeAuthorizeNext(h), h) }
    }

    func testLoginRedirectKeepsQueryExactly() throws {
        let query = "?response_type=code&client_id=ABC&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcb&scope=tasks%3Aread%20projects%3Aread&state=a+b%26c&code_challenge=x"
        let loc = try XCTUnwrap(OAuthController.loginRedirect(forAuthorizeQuery: query))
        XCTAssertTrue(loc.hasPrefix("/login?next=%2Foauth%2Fauthorize%3F"))
        let next = try XCTUnwrap(URLComponents(string: loc)?.queryItems?.first { $0.name == "next" }?.value)
        XCTAssertEqual(next, "/oauth/authorize" + query)
        XCTAssertNil(OAuthController.loginRedirect(forAuthorizeQuery: "?x=\\evil"))
        XCTAssertNil(OAuthController.loginRedirect(forAuthorizeQuery: "/../x"))
    }

    func testConsentPageSendsLoggedOutUsersToLogin() {
        XCTAssertTrue(ConsentPage.script.contains("/login?next="))
        XCTAssertFalse(ConsentPage.script.contains("Bitte zuerst in der Todo-App anmelden"))
    }

    func testPageOffersConnectionNameWithoutBreakingSecurity() {
        // Name field prefilled from the server's default, limited to 80 characters, written via value/textContent only.
        XCTAssertTrue(ConsentPage.script.contains("conname"))
        XCTAssertTrue(ConsentPage.script.contains("d.default_name"))
        XCTAssertTrue(ConsentPage.script.contains("maxLength = 80"))
        XCTAssertTrue(ConsentPage.script.contains("connection_name"))
        XCTAssertFalse(ConsentPage.script.contains("innerHTML"))
        XCTAssertTrue(ConsentPage.csp.contains("script-src 'sha256-"))
    }
}
