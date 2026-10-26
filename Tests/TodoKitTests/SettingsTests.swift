import Foundation
import XCTest
@testable import TodoKit

final class SettingsTests: XCTestCase {
    func testEnvironmentCompatibilityAndDefaults() throws {
        let values = ["DB_PASSWORD": "legacy", "BOOTSTRAP_TOKEN": "bootstrap", "RP_ORIGIN": "https://example.invalid"]
        XCTAssertEqual(try DatabaseSettings.fromEnvironment(get: { values[$0] }).password, "legacy")
        let app = try AppSettings.fromEnvironment(get: { values[$0] })
        XCTAssertEqual(app.bootstrapToken, "bootstrap")
        XCTAssertTrue(app.secureCookies)
        XCTAssertFalse(try AppSettings.fromEnvironment(get: { _ in nil }).passwordLoginEnabled)
        XCTAssertEqual(try DatabaseSettings.fromEnvironment(get: { _ in nil }).port, 23306)
    }

    func testFilePrecedenceAndLineEndings() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try " secret with spaces \r\n".write(to: file, atomically: true, encoding: .utf8)
        let values = ["DB_PASSWORD": "ignored", "DB_PASSWORD_FILE": file.path, "BOOTSTRAP_TOKEN_FILE": file.path]
        XCTAssertEqual(try DatabaseSettings.fromEnvironment(get: { values[$0] }).password, " secret with spaces ")
        XCTAssertEqual(try AppSettings.fromEnvironment(get: { values[$0] }).bootstrapToken, " secret with spaces ")
        try "".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(try AppSettings.fromEnvironment(get: { values[$0] }).bootstrapToken)
    }

    func testInvalidFileFailsWithoutFallback() throws {
        for path in ["", "/nonexistent/secret"] {
            let values = ["DB_PASSWORD": "legacy", "DB_PASSWORD_FILE": path, "BOOTSTRAP_TOKEN_FILE": path]
            XCTAssertThrowsError(try DatabaseSettings.fromEnvironment(get: { values[$0] }))
            XCTAssertThrowsError(try AppSettings.fromEnvironment(get: { values[$0] }))
        }
    }
}
