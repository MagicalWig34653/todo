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
