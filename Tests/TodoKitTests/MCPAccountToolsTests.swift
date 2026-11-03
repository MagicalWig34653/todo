import Fluent
import XCTVapor
@testable import TodoKit

final class MCPAccountToolsTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private let all = "projects:read account:read account:write admin:read"
    private func fixture(scope: String? = nil, admin: Bool = false, _ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            if admin { f.user.isAdmin = true; try await f.user.save(on: f.test.app.db) }
            let t = try await f.tokens(scope: scope ?? all); try await run(f, t.access)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRegistrationAndScopes() {
        for n in ["get_settings", "update_settings", "get_notification_prefs", "update_notification_prefs", "get_connection", "list_users", "list_invitations"] {
            XCTAssertTrue(MCPController.tools.contains { $0.name == n }, n)
        }
        for s in ["account:read", "account:write", "admin:read"] { XCTAssertTrue(OAuthController.scopes.contains(s), s) }
    }

    func testSettingsReadUpdateAndConflict() async throws {
        try await fixture { f, access in
            let first = try await self.call(f, "get_settings", [:], access)
            XCTAssertEqual((first.json as? [String: Any])?["revision"] as? Int, 0)
            let u1 = try await self.call(f, "update_settings", ["revision": 0, "colorScheme": "dark", "accent": "custom", "accentCustomHex": "#aabbcc"], access)
            XCTAssertFalse(u1.isError, u1.text)
            let appearance = (u1.json as? [String: Any])?["appearance"] as? [String: Any]
            XCTAssertEqual(appearance?["colorScheme"] as? String, "dark"); XCTAssertEqual(appearance?["accentCustomHex"] as? String, "#AABBCC")
            XCTAssertEqual((u1.json as? [String: Any])?["revision"] as? Int, 1)
            // Partial: glow only keeps the rest.
            let u2 = try await self.call(f, "update_settings", ["revision": 1, "glow": "off"], access)
            XCTAssertEqual(((u2.json as? [String: Any])?["appearance"] as? [String: Any])?["colorScheme"] as? String, "dark")
            // Stale revision.
            let stale = try await self.call(f, "update_settings", ["revision": 1, "glow": "strong"], access)
            XCTAssertTrue(stale.isError); XCTAssertEqual(stale.text, "version_conflict")
            // Invalid input.
            for bad: [String: Any] in [["revision": 2, "colorScheme": "pink"], ["revision": 2, "accent": "blue", "accentCustomHex": "#112233"], ["revision": 2, "accent": 7],
                                       ["revision": -1], ["revision": 1.5], ["revision": "x"], ["colorScheme": "dark"]] {
                let r = try await self.call(f, "update_settings", bad, access)
                XCTAssertTrue(r.isError, "\(bad)"); XCTAssertNotEqual(r.text, "")
            }
            let again = try await self.call(f, "get_settings", [:], access)
            XCTAssertEqual((again.json as? [String: Any])?["revision"] as? Int, 2)
        }
    }

    func testNotificationPrefs() async throws {
        try await fixture { f, access in
            let read = try await self.call(f, "get_notification_prefs", [:], access)
            XCTAssertEqual(((read.json as? [String: Any])?["categories"] as? [String: Bool])?["comments"], false)
            let w = try await self.call(f, "update_notification_prefs", ["categories": ["comments": true], "badge": false], access)
            XCTAssertFalse(w.isError, w.text)
            XCTAssertEqual(((w.json as? [String: Any])?["categories"] as? [String: Bool])?["comments"], true)
            XCTAssertEqual((w.json as? [String: Any])?["badge"] as? Bool, false)
            let h1 = try await self.call(f, "update_notification_prefs", ["categories": ["nope": true]], access)
            XCTAssertEqual(h1.text, "invalid_category")
            let h2 = try await self.call(f, "update_notification_prefs", ["categories": ["comments": "yes"]], access)
            XCTAssertEqual(h2.text, "invalid_categories")
            let h3 = try await self.call(f, "update_notification_prefs", ["categories": [String: Bool]()], access)
            XCTAssertEqual(h3.isError, false)
            let h4 = try await self.call(f, "update_notification_prefs", [:], access)
            XCTAssertTrue(h4.isError)
            let h5 = try await self.call(f, "update_notification_prefs", ["badge": 3], access)
            XCTAssertTrue(h5.isError)
        }
    }

    func testMissingScopeHidesAndBlocksTools() async throws {
        try await fixture(scope: "projects:read", admin: true) { f, access in
            for n in ["get_settings", "update_settings", "get_notification_prefs", "update_notification_prefs", "list_users", "list_invitations"] {
                let r = try await self.call(f, n, n == "update_settings" ? ["revision": 0] : [:], access)
                XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "insufficient_scope", n)
            }
            let list = try await f.rpc("tools/list", access: access)
            let names = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertFalse(names.contains("list_users")); XCTAssertTrue(names.contains("get_connection"))
        }
        try await fixture(scope: "projects:read account:read") { f, access in
            let r = try await self.call(f, "update_notification_prefs", ["badge": false], access)
            XCTAssertEqual(r.text, "insufficient_scope")
        }
    }

    func testConnectionShowsGrantOnlyWithoutSecrets() async throws {
        try await fixture { f, access in
            let r = try await self.call(f, "get_connection", [:], access)
            XCTAssertFalse(r.isError, r.text)
            let json = try XCTUnwrap(r.json as? [String: Any])
            XCTAssertEqual(json["client"] as? String, "Test Client")
            XCTAssertEqual((json["scopes"] as? [String])?.sorted(), self.all.split(separator: " ").map(String.init).sorted())
            let projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
            XCTAssertEqual(projects.map { $0["id"] as? String }, [try f.project.requireID().uuidString])
            XCTAssertFalse(r.text.contains(access))
            XCTAssertNotNil(json["refreshExpiresAt"] as? String)
        }
    }

    func testAdminReadsOnlyForAdmins() async throws {
        try await fixture { f, access in   // not an admin
            let h6 = try await self.call(f, "list_users", [:], access)
            XCTAssertEqual(h6.text, "forbidden")
            let h7 = try await self.call(f, "list_invitations", [:], access)
            XCTAssertEqual(h7.text, "forbidden")
        }
        try await fixture(admin: true) { f, access in
            let other = User(displayName: "Zed", isAdmin: false); try await other.save(on: f.test.app.db)
            try await Invitation(tokenHash: "h", createdBy: f.user.requireID(), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
            let users = try await self.call(f, "list_users", [:], access)
            XCTAssertFalse(users.isError, users.text)
            let list = try XCTUnwrap(users.json as? [[String: Any]])
            XCTAssertTrue(list.contains { $0["displayName"] as? String == "Zed" && $0["status"] as? String == "active" })
            for forbidden in ["passwordHash", "email", "token", "secret"] { XCTAssertFalse(users.text.lowercased().contains(forbidden.lowercased()), forbidden) }
            let h8 = try await self.call(f, "list_users", ["limit": 1], access)
            XCTAssertEqual(h8.json.flatMap { $0 as? [Any] }?.count, 1)
            let h9 = try await self.call(f, "list_users", ["limit": 0], access)
            XCTAssertTrue(h9.isError)
            let h10 = try await self.call(f, "list_users", ["limit": 1e300], access)
            XCTAssertTrue(h10.isError)
            let inv = try await self.call(f, "list_invitations", [:], access)
            let rows = try XCTUnwrap(inv.json as? [[String: Any]])
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["status"] as? String, "open")
            XCTAssertFalse(inv.text.contains("tokenHash"))
        }
    }
}
