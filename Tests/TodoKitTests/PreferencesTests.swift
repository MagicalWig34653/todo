import XCTVapor
@testable import TodoKit

final class PreferencesTests: XCTestCase {
    private func doc(scheme: String = "dark", accent: String = "teal", hex: Any = NSNull(), glow: String = "medium") -> [String: Any] {
        ["version": 1, "appearance": ["colorScheme": scheme, "accent": accent, "accentCustomHex": hex, "glow": glow] as [String: Any]]
    }

    func testDefaultsThenRoundTripWithRevision() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let first = try await t.json(.GET, "/v1/me/preferences", token: a.session)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(first.body?["revision"] as? Int, 0)
        XCTAssertNil(first.body?["updatedAt"] as? String)
        XCTAssertEqual((first.body?["appearance"] as? [String: Any])?["accent"] as? String, "blue")
        let put = try await t.json(.PUT, "/v1/me/preferences", doc(), token: a.session)
        XCTAssertEqual(put.status, .ok)
        XCTAssertEqual(put.body?["revision"] as? Int, 1)
        let again = try await t.json(.PUT, "/v1/me/preferences", doc(scheme: "light", accent: "custom", hex: "#abcdef"), token: a.session)
        XCTAssertEqual(again.body?["revision"] as? Int, 2)
        let got = try await t.json(.GET, "/v1/me/preferences", token: a.session)
        let ap = try XCTUnwrap(got.body?["appearance"] as? [String: Any])
        XCTAssertEqual(ap["colorScheme"] as? String, "light")
        XCTAssertEqual(ap["accentCustomHex"] as? String, "#ABCDEF")
        XCTAssertNotNil(got.body?["updatedAt"] as? String)
    }

    func testValidationRejectsBadDocuments() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        var bad: [[String: Any]] = [
            doc(scheme: "sepia"), doc(accent: "chartreuse"), doc(glow: "blinding"),
            doc(accent: "custom"), doc(accent: "teal", hex: "#112233"), doc(accent: "custom", hex: "red"),
            ["version": 2, "appearance": doc()["appearance"]!], ["version": 1], ["appearance": doc()["appearance"]!],
        ]
        var extra = doc(); extra["theme"] = "x"; bad.append(extra)
        var extraInner = doc(); var ap = extraInner["appearance"] as! [String: Any]; ap["density"] = "compact"; extraInner["appearance"] = ap; bad.append(extraInner)
        for (i, body) in bad.enumerated() {
            let r = try await t.json(.PUT, "/v1/me/preferences", body, token: a.session)
            XCTAssertEqual(r.status, .badRequest, "case \(i)")
        }
        let still = try await t.json(.GET, "/v1/me/preferences", token: a.session)
        XCTAssertEqual(still.body?["revision"] as? Int, 0)
    }

    func testIsolationPerAccountAndAuthRules() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let inv = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: inv.body!["token"] as! String, name: "Bob")
        _ = try await t.json(.PUT, "/v1/me/preferences", doc(), token: a.session)
        let other = try await t.json(.GET, "/v1/me/preferences", token: b.session)
        XCTAssertEqual(other.body?["revision"] as? Int, 0)
        XCTAssertEqual((other.body?["appearance"] as? [String: Any])?["colorScheme"] as? String, "system")
        let anon = try await t.json(.GET, "/v1/me/preferences")
        XCTAssertEqual(anon.status, .unauthorized)
        let anonPut = try await t.json(.PUT, "/v1/me/preferences", doc())
        XCTAssertEqual(anonPut.status, .unauthorized)
        let garbage = try await t.json(.PUT, "/v1/me/preferences", doc(), token: "nope")
        XCTAssertEqual(garbage.status, .unauthorized)
    }

    func testConcurrentWritesAcrossReplicasKeepConsistentRevision() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs row locks (MariaDB); SQLite serialises writers differently")
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let r = try await t.replica()
        defer { Task { await r.shutdown() } }
        let data = try JSONSerialization.data(withJSONObject: doc())
        let session = a.session
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<6 { let node = i % 2 == 0 ? t : r; group.addTask { try await node.rawStatus(.PUT, "/v1/me/preferences", body: data, token: session) } }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertTrue(statuses.allSatisfy { $0 == .ok }, "\(statuses)")
        let got = try await t.json(.GET, "/v1/me/preferences", token: a.session)
        XCTAssertEqual(got.body?["revision"] as? Int, 6)
    }

    func testMigrationOfStoredVersion() throws {
        let stored = #"{"version":1,"appearance":{"colorScheme":"dark","accent":"blue","glow":"off"}}"#
        let doc = try PreferencesDocument.migrated(version: 1, document: stored)
        XCTAssertEqual(doc.appearance.glow, "off")
        XCTAssertThrowsError(try PreferencesDocument.migrated(version: 99, document: stored))
    }
}
