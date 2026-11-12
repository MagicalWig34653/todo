import Fluent
import XCTVapor
@testable import TodoKit

final class SystemStatusTests: XCTestCase {
    private let sample: [String: Any] = [
        "zeit": "2026-11-12T10:18:18Z", "claude_ampel": "rot", "claude_frei_fuer_brain": 0.0,
        "claude_nutzbare_konten": [4, 7],
        "codex": ["verbraucht_pct": 5.0, "erlaubt_bis_jetzt_pct": 19.2, "ziel_pct": 75, "reset": "2026-11-17T14:16:51+00:00", "freigabe": true],
        "platte_frei_gb": 104.9, "platte_ampel": "gruen",
    ]

    private func account(_ t: TestApp) async throws -> (id: UUID, session: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID(), token)
    }

    private func pairedDevice(_ t: TestApp, session: String, label: String = "Mac") async throws -> String {
        let pairing = try await t.json(.POST, "/v1/agents/devices", ["label": label], token: session)
        let code = try XCTUnwrap(pairing.body?["code"] as? String)
        let paired = try await t.json(.POST, "/v1/runner/pair", ["code": code])
        return try XCTUnwrap(paired.body?["token"] as? String)
    }

    private func items(_ t: TestApp, _ session: String) async throws -> [[String: Any]] {
        let r = try await t.json(.GET, "/v1/system-status", token: session)
        return try XCTUnwrap(r.body?["items"] as? [[String: Any]])
    }
    private func head(_ t: TestApp, _ session: String) async throws -> String {
        let r = try await t.json(.GET, "/v1/sync/head", token: session)
        return try XCTUnwrap(r.body?["token"] as? String)
    }

    func testRequiresAuthentication() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let put = try await t.json(.PUT, "/v1/system-status", sample)
        XCTAssertEqual(put.status, .unauthorized)
        let get = try await t.json(.GET, "/v1/system-status")
        XCTAssertEqual(get.status, .unauthorized)
        let bad = try await t.json(.PUT, "/v1/system-status", sample, token: "nope")
        XCTAssertEqual(bad.status, .unauthorized)
    }

    func testDeviceTokenReportsAndOwnerReads() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let device = try await pairedDevice(t, session: a.session)
        let put = try await t.json(.PUT, "/v1/system-status", sample, token: device)
        XCTAssertEqual(put.status, .ok)
        let get = try await t.json(.GET, "/v1/system-status", token: a.session)
        XCTAssertEqual(get.status, .ok)
        let items = try XCTUnwrap(get.body?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item["source"] as? String, "default")
        XCTAssertEqual(item["label"] as? String, "Mac")
        XCTAssertNotNil(item["reportedAt"] as? String)
        XCTAssertNotNil(get.body?["now"] as? String)
        let status = try XCTUnwrap(item["status"] as? [String: Any])
        XCTAssertEqual(status["claude_ampel"] as? String, "rot")
        XCTAssertEqual(status["platte_frei_gb"] as? Double, 104.9)
        XCTAssertEqual((status["codex"] as? [String: Any])?["freigabe"] as? Bool, true)
        XCTAssertEqual(status["claude_nutzbare_konten"] as? [Int], [4, 7])
    }

    func testLatestReportReplacesAndUnknownFieldsSurvive() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t)
        _ = try await t.json(.PUT, "/v1/system-status", sample, token: a.session)
        var next = sample; next["claude_ampel"] = "gelb"; next["zukunft"] = ["x": 1]
        let put = try await t.json(.PUT, "/v1/system-status", next, token: a.session)
        XCTAssertEqual(put.status, .ok)
        let items = try await items(t, a.session)
        XCTAssertEqual(items.count, 1)
        let status = try XCTUnwrap(items[0]["status"] as? [String: Any])
        XCTAssertEqual(status["claude_ampel"] as? String, "gelb")
        XCTAssertNotNil(status["zukunft"])
    }

    func testSourcesAreSeparateAndPerUser() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t), b = try await account(t)
        _ = try await t.json(.PUT, "/v1/system-status?source=mac", sample, token: a.session)
        _ = try await t.json(.PUT, "/v1/system-status?source=server", sample, token: a.session)
        let own = try await items(t, a.session)
        XCTAssertEqual(own.compactMap { $0["source"] as? String }.sorted(), ["mac", "server"])
        let other = try await items(t, b.session)
        XCTAssertTrue(other.isEmpty)
        let badSource = try await t.json(.PUT, "/v1/system-status?source=a%20b", sample, token: a.session)
        XCTAssertEqual(badSource.status, .badRequest)
    }

    func testValidatesKnownFields() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t)
        for (key, value) in [("claude_ampel", "blau" as Any), ("platte_ampel", 3), ("platte_frei_gb", "viel"),
                             ("claude_nutzbare_konten", "4"), ("codex", "x"), ("zeit", "gestern")] {
            var body = sample; body[key] = value
            let r = try await t.json(.PUT, "/v1/system-status", body, token: a.session)
            XCTAssertEqual(r.status, .badRequest, key)
        }
        var badCodex = sample; badCodex["codex"] = ["verbraucht_pct": "5", "freigabe": true]
        let bc = try await t.json(.PUT, "/v1/system-status", badCodex, token: a.session)
        XCTAssertEqual(bc.status, .badRequest)
        let empty = try await t.json(.PUT, "/v1/system-status", [:], token: a.session)
        XCTAssertEqual(empty.status, .badRequest)
        let big = try await t.json(.PUT, "/v1/system-status", ["notiz": String(repeating: "x", count: 20_000)], token: a.session)
        XCTAssertEqual(big.status, .badRequest)
        let list = try await items(t, a.session)
        XCTAssertTrue(list.isEmpty)
    }

    func testRevokedDeviceIsRejected() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let device = try await pairedDevice(t, session: a.session)
        let row = try await RunnerDevice.query(on: t.app.db).first()
        row?.revokedAt = Date(); try await row?.save(on: t.app.db)
        let r = try await t.json(.PUT, "/v1/system-status", sample, token: device)
        XCTAssertEqual(r.status, .unauthorized)
    }

    func testReportChangesLiveToken() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let before = try await head(t, a.session)
        _ = try await t.json(.PUT, "/v1/system-status", sample, token: a.session)
        let after = try await head(t, a.session)
        XCTAssertNotEqual(before, after)
    }

    func testTooManySourcesRejected() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let a = try await account(t)
        for i in 0..<SystemStatusService.maxSources {
            let r = try await t.json(.PUT, "/v1/system-status?source=s\(i)", sample, token: a.session)
            XCTAssertEqual(r.status, .ok)
        }
        let over = try await t.json(.PUT, "/v1/system-status?source=extra", sample, token: a.session)
        XCTAssertEqual(over.status, .conflict)
        let again = try await t.json(.PUT, "/v1/system-status?source=s0", sample, token: a.session)
        XCTAssertEqual(again.status, .ok)
    }

    func testMCPToolReadsOwnStatusWithAccountReadScope() async throws {
        XCTAssertTrue(MCPController.tools.contains { $0.name == "get_system_status" && $0.scope == "account:read" })
        let f = try await OAuthFixture.make()
        do {
            let report = try await f.test.json(.PUT, "/v1/system-status", sample, token: f.session)
            XCTAssertEqual(report.status, .ok)
            let access = try await f.tokens(scope: "projects:read account:read").access
            let r = try await f.rpc("tools/call", ["name": "get_system_status", "arguments": [String: Any]()], access: access)
            let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
            let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let items = try XCTUnwrap(json["items"] as? [[String: Any]])
            XCTAssertEqual((items.first?["status"] as? [String: Any])?["platte_ampel"] as? String, "gruen")
            let denied = try await f.tokens(scope: "projects:read").access
            let d = try await f.rpc("tools/call", ["name": "get_system_status", "arguments": [String: Any]()], access: denied)
            XCTAssertEqual(((d.body?["result"] as? [String: Any])?["isError"] as? Bool), true)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
