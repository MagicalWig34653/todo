import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0035, items 1, 2, 6, 11: settings only with a person session, the URL stays secret, validation at save time.
final class WebhookSettingsTests: XCTestCase {
    // MARK: Item 1: session only

    func testSettingsNeedAPersonSessionNotAnOAuthToken() async throws {
        try await withWebhook { f in
            try await f.configure()
            let anonymous = try await f.test.json(.GET, "/v1/settings/webhook")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let access = try await f.mcpToken()
            for (method, path) in [(HTTPMethod.GET, "/v1/settings/webhook"), (.PUT, "/v1/settings/webhook"), (.DELETE, "/v1/settings/webhook"),
                                   (.POST, "/v1/settings/webhook/test"), (.GET, "/v1/settings/webhook/deliveries")] {
                let r = try await f.test.json(method, path, method == .PUT ? ["enabled": false] : nil, token: access)
                XCTAssertTrue([.unauthorized, .forbidden].contains(r.status), "\(method) \(path) -> \(r.status)")
            }
            let after = try await f.get()
            XCTAssertEqual(after.body?["enabled"] as? Bool, true, "an OAuth token must not change the webhook")
            // No MCP tool reads or writes the webhook.
            let tools = try await f.o.rpc("tools/list", access: access)
            let names = ((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            XCTAssertFalse(names.isEmpty)
            XCTAssertFalse(names.contains { $0.lowercased().contains("webhook") })
        }
    }

    // MARK: Item 2: URL secrecy

    func testUrlAndSecretAreNeverReturnedLoggedOrStoredInPlainText() async throws {
        try await withWebhook { f in
            var responses: [String] = []
            let put = try await f.configure(["signingSecret": WebhookFixture.secretSigning])
            responses.append(jsonString(put.body))
            responses.append(jsonString(try await f.get().body))
            let test = try await f.sendTest()
            responses.append(jsonString(test.body))
            responses.append(jsonString(try await f.deliveries().body))
            // Error answers do not repeat the URL either.
            for bad in ["http://hooks.example.test/SECRETPATH-9f8e7d", "https://user:SECRETPASS@hooks.example.test/SECRETPATH-9f8e7d", "https://127.0.0.1/SECRETPATH-9f8e7d"] {
                let r = try await f.put(["url": bad])
                XCTAssertEqual(r.status, .badRequest)
                responses.append(jsonString(r.body))
            }
            let tooShort = try await f.put(["signingSecret": "SECRETSHORT"])
            responses.append(jsonString(tooShort.body))
            for text in responses {
                for needle in ["SECRETPATH", "SECRETQUERY", "SECRETPASS", "SIGNING-SECRET", "SECRETSHORT"] { XCTAssertFalse(text.contains(needle), "\(needle) in \(text)") }
            }
            XCTAssertEqual(put.body?["maskedURL"] as? String, "https://hooks.example.test/…")
            XCTAssertEqual(put.body?["configured"] as? Bool, true)
            XCTAssertEqual(put.body?["signingConfigured"] as? Bool, true)
            XCTAssertNil(put.body?["url"])
            XCTAssertNil(put.body?["signingSecret"])

            // The database has ciphertext only.
            let stored = try await f.storedText()
            XCTAssertFalse(stored.isEmpty)
            for needle in ["SECRETPATH", "SECRETQUERY", "SIGNING-SECRET", "token="] { XCTAssertFalse(stored.contains(needle), "\(needle) stored in plain text") }
            let row = try await f.ep()
            XCTAssertTrue(row.urlCiphertext.hasPrefix("v1."))
            XCTAssertEqual(row.urlMask, "https://hooks.example.test")
            XCTAssertEqual(row.keyID, f.app.settingsRuntime?.keyRing.current?.id)

            // Nothing in the server log (settings, test delivery, rejected URLs, worker run).
            _ = try await f.bundleAndSend()
            let logged = f.capture.lines.joined(separator: "\n")
            for needle in ["SECRETPATH", "SECRETQUERY", "SECRETPASS", "SIGNING-SECRET", "hooks.example.test"] { XCTAssertFalse(logged.contains(needle), "\(needle) in the log") }
        }
    }

    func testMaskShowsSchemeAndHostOnly() async throws {
        try await withWebhook { f in
            for (url, mask) in [("https://hooks.example.test/a/b?c=d#e", "https://hooks.example.test/…"),
                                ("HTTPS://Hooks.Example.Test:8443/x", "https://hooks.example.test/…"),
                                ("https://203.0.113.7/secret", "https://203.0.113.7/…"),
                                ("https://[2001:db8::7]/secret", "https://[2001:db8::7]/…")] {
                let r = try await f.configure(url: url)
                XCTAssertEqual(r.body?["maskedURL"] as? String, mask, url)
            }
        }
    }

    func testPutWithoutKeyOnServerIsRejected() async throws {
        try await withWebhook(key: false) { f in
            let r = try await f.put(["url": WebhookFixture.secretURL])
            XCTAssertEqual(r.status, .conflict)
            XCTAssertEqual(r.body?["reason"] as? String, "encryption_key_missing")
            let secret = try await f.put(["url": WebhookFixture.secretURL, "signingSecret": WebhookFixture.secretSigning])
            XCTAssertEqual(secret.body?["reason"] as? String, "encryption_key_missing")
            let none = try await f.endpoint()
            XCTAssertNil(none)
            let state = try await f.get()
            XCTAssertEqual(state.body?["configured"] as? Bool, false)
        }
    }

    // MARK: Item 8: URL rules at save time

    func testHttpCredentialsAndMalformedUrlsAreRejected() async throws {
        try await withWebhook { f in
            let notHTTPS = ["http://hooks.example.test/x", "HTTP://hooks.example.test/x", "ftp://hooks.example.test/x", "ws://hooks.example.test/x"]
            for url in notHTTPS {
                let r = try await f.put(["url": url])
                XCTAssertEqual(r.status, .badRequest, url)
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_not_https", url)
            }
            let invalid = ["https://user:pass@hooks.example.test/x", "https://user@hooks.example.test/x", "https://:@hooks.example.test/", "hooks.example.test/x", "not a url",
                           "", "https://", "https:///path", "https://hooks.example.test:99999/x", "https://hooks.example.test:0/x", "https://hooks.example.test:abc/x",
                           "https://hooks example.test/x", "https://hooks.example.test\\@evil.test/", "https://hooks.example.test/\u{00e4}",
                           "https://2130706433/x", "https://[::1/x", "https://[not-an-ip]/x", "https://-bad-.test/x", "https://a..b/x",
                           "https://hooks.example.test/" + String(repeating: "a", count: 2100)]
            for url in invalid {
                let r = try await f.put(["url": url])
                XCTAssertEqual(r.status, .badRequest, "\(url.prefix(60))")
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_invalid", "\(url.prefix(60))")
            }
            let stored = try await f.endpoint()
            XCTAssertNil(stored, "a rejected URL leaves nothing behind")
            // An explicit port is fine.
            let ok = try await f.put(["url": "https://hooks.example.test:8443/x"])
            XCTAssertEqual(ok.status, .ok)
        }
    }

    func testLiteralPrivateAndLocalAddressesAreRejectedAtSave() async throws {
        try await withWebhook { f in
            let blocked = ["https://127.0.0.1/x", "https://127.1.2.3:8443/x", "https://10.0.0.5/x", "https://192.168.1.10/x", "https://172.16.0.1/x",
                           "https://169.254.169.254/latest/meta-data", "https://100.64.0.1/x", "https://0.0.0.0/x",
                           "https://[::1]/x", "https://[fd00::1]/x", "https://[fe80::1]/x", "https://[::ffff:10.0.0.1]/x", "https://[::ffff:127.0.0.1]/x", "https://[fd00:ec2::254]/x"]
            for url in blocked {
                let r = try await f.put(["url": url])
                XCTAssertEqual(r.status, .badRequest, url)
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_blocked", url)
            }
            let stored = try await f.endpoint()
            XCTAssertNil(stored)
            // The same check holds even if the server setting for SMTP/S3 is relaxed: the level is fixed.
            f.app.settings.mail.protection = .off
            let relaxed = try await f.put(["url": "https://10.0.0.5/x"])
            XCTAssertEqual(relaxed.body?["reason"] as? String, "webhook_url_blocked")
            let publicIP = try await f.put(["url": "https://203.0.113.7/x"])
            XCTAssertEqual(publicIP.status, .ok)
        }
    }

    func testHostnameResolvingToAPrivateAddressIsRejectedAtSave() async throws {
        try await withWebhook { f in
            f.resolver.set("internal.example.test", "10.1.2.3")
            f.resolver.set("meta.example.test", "169.254.169.254")
            f.resolver.set("mapped.example.test", "::ffff:192.168.0.9")
            for host in ["internal", "meta", "mapped"] {
                let r = try await f.put(["url": "https://\(host).example.test/x"])
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_blocked", host)
            }
            // Real resolver: "localhost" is never allowed.
            f.app.webhookResolver = SystemWebhookResolver()
            let local = try await f.put(["url": "https://localhost/x"])
            XCTAssertEqual(local.body?["reason"] as? String, "webhook_url_blocked")
            // A name that does not resolve at all is invalid.
            f.app.webhookResolver = FixedWebhookResolver(fallback: nil)
            let unknown = try await f.put(["url": "https://nowhere.example.test/x"])
            XCTAssertEqual(unknown.body?["reason"] as? String, "webhook_url_invalid")
        }
    }

    // MARK: Item 11: partial updates and deletion

    func testPutKeepsMissingFieldsAndNullDeletes() async throws {
        try await withWebhook { f in
            let first = try await f.configure()
            XCTAssertEqual(first.body?["enabled"] as? Bool, true)
            XCTAssertEqual(first.body?["signingConfigured"] as? Bool, false)
            let before = try await f.ep().urlCiphertext
            // Only `enabled`: URL stays.
            let off = try await f.put(["enabled": false])
            XCTAssertEqual(off.body?["enabled"] as? Bool, false)
            XCTAssertEqual(off.body?["configured"] as? Bool, true)
            try await assertEqual(try await f.ep().urlCiphertext, before)
            // Signing secret set and cleared (null), URL untouched.
            let signed = try await f.put(["signingSecret": WebhookFixture.secretSigning])
            XCTAssertEqual(signed.body?["signingConfigured"] as? Bool, true)
            let cleared = try await f.put(["signingSecret": NSNull()])
            XCTAssertEqual(cleared.body?["signingConfigured"] as? Bool, false)
            let cleared2 = try await f.ep()
            XCTAssertNil(cleared2.signingCiphertext)
            XCTAssertEqual(cleared2.urlCiphertext, before)
            // A new URL replaces the ciphertext (new nonce) and the mask.
            let moved = try await f.put(["url": "https://other.example.test/p"])
            XCTAssertEqual(moved.body?["maskedURL"] as? String, "https://other.example.test/…")
            let replaced = try await f.ep().urlCiphertext
            XCTAssertNotEqual(replaced, before)
            // Invalid secrets.
            let weak = try await f.put(["signingSecret": "short"])
            XCTAssertEqual(weak.body?["reason"] as? String, "webhook_signing_secret_invalid")
            // url: null removes the webhook.
            let removed = try await f.put(["url": NSNull()])
            XCTAssertEqual(removed.body?["configured"] as? Bool, false)
            XCTAssertNil(removed.body?["maskedURL"])
            let none = try await f.endpoint()
            XCTAssertNil(none)
            // Without a stored URL a partial update has nothing to change.
            let orphan = try await f.put(["enabled": true])
            XCTAssertEqual(orphan.status, .conflict)
            XCTAssertEqual(orphan.body?["reason"] as? String, "webhook_not_configured")
        }
    }

    func testDeleteRemovesCiphertextExclusionsAndLog() async throws {
        try await withWebhook { f in
            try await f.configure(["signingSecret": WebhookFixture.secretSigning, "excludedProjectIDs": [f.o.other.id!.uuidString]])
            _ = try await f.sendTest()
            let task = try await f.existingTask()
            try await f.comment(task)
            let rowsBefore = try await f.rows()
            XCTAssertGreaterThanOrEqual(rowsBefore.count, 1)
            let del = try await f.test.json(.DELETE, "/v1/settings/webhook", token: f.session)
            XCTAssertEqual(del.status, .noContent)
            let endpoint = try await f.endpoint()
            XCTAssertNil(endpoint)
            let remaining = try await WebhookDelivery.query(on: f.app.db).count()
            XCTAssertEqual(remaining, 0)
            let exclusions = try await WebhookExclusion.query(on: f.app.db).count()
            XCTAssertEqual(exclusions, 0)
            let again = try await f.test.json(.DELETE, "/v1/settings/webhook", token: f.session)
            XCTAssertEqual(again.status, .noContent, "idempotent")
            let state = try await f.get()
            XCTAssertEqual(state.body?["configured"] as? Bool, false)
        }
    }

    func testAccountDeletionRemovesWebhookRows() async throws {
        try await withWebhook { f in
            try await f.configure(["excludedProjectIDs": [f.o.other.id!.uuidString]])
            _ = try await f.sendTest()
            try await AccountDeletion.delete(userID: f.userID, on: f.app.db)
            let endpoints = try await WebhookEndpoint.query(on: f.app.db).count()
            let exclusions = try await WebhookExclusion.query(on: f.app.db).count()
            let deliveries = try await WebhookDelivery.query(on: f.app.db).count()
            XCTAssertEqual([endpoints, exclusions, deliveries], [0, 0, 0])
        }
    }

    func testCiphertextCannotBeMovedToAnotherAccount() async throws {
        try await withWebhook { f in
            try await f.configure()
            let stolen = try await f.ep()
            let other = try await PushTests.account(f.test, "Other")
            let copy = WebhookEndpoint()
            copy.userID = other.id; copy.urlCiphertext = stolen.urlCiphertext; copy.keyID = stolen.keyID; copy.urlMask = stolen.urlMask
            copy.enabled = true; copy.consecutiveFailures = 0; copy.createdAt = Date(); copy.updatedAt = Date()
            try await copy.create(on: f.app.db)
            let attempt = await WebhookDeliverer(app: f.app).attempt(endpoint: copy, payload: .test, now: Date())
            XCTAssertEqual(attempt, .failed(code: "encryption_key_unreadable", status: nil))
            XCTAssertTrue(f.transport.requests.isEmpty)
            // The owner's own row still decrypts.
            let own = await WebhookDeliverer(app: f.app).attempt(endpoint: stolen, payload: .test, now: Date())
            XCTAssertEqual(own, .sent(status: 200))
        }
    }

    // MARK: Item 6: exclusions

    func testExclusionsAcceptOnlyOwnReadableProjects() async throws {
        try await withWebhook { f in
            let stranger = try await PushTests.account(f.test, "Stranger")
            let foreign = try await f.test.json(.POST, "/v1/projects", ["name": "Foreign"], token: stranger.token)
            let foreignID = try XCTUnwrap(foreign.body?["id"] as? String)
            try await f.configure()
            for id in [foreignID, UUID().uuidString] {
                let r = try await f.put(["excludedProjectIDs": [f.projectID, id]])
                XCTAssertEqual(r.status, .notFound, "unknown and foreign projects look the same")
            }
            let unchanged = try await f.get()
            XCTAssertEqual(unchanged.body?["excludedProjectIDs"] as? [String], [])
            // Own projects, also a read-only shared one.
            let shared = try await f.test.json(.POST, "/v1/projects", ["name": "Shared"], token: stranger.token)
            let sharedID = try XCTUnwrap(shared.body?["id"] as? String)
            let grant = try await f.test.json(.PUT, "/v1/projects/\(sharedID)/grants", ["principalType": "person", "principalID": f.userID.uuidString, "role": "read"], token: stranger.token)
            XCTAssertEqual(grant.status, .ok, "\(grant.body ?? [:])")
            let ok = try await f.put(["excludedProjectIDs": [f.projectID, sharedID, f.projectID]])
            XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
            XCTAssertEqual(Set(ok.body?["excludedProjectIDs"] as? [String] ?? []), [f.projectID, sharedID])
            // Other accounts never see them.
            let strangerView = try await f.get(token: stranger.token)
            XCTAssertEqual(strangerView.body?["configured"] as? Bool, false)
            XCTAssertEqual(strangerView.body?["excludedProjectIDs"] as? [String], [])
            // Deleting a project removes its exclusion (cascade).
            let deleted = try await f.test.json(.DELETE, "/v1/projects/\(f.projectID)", token: f.session)
            XCTAssertTrue([.noContent, .ok].contains(deleted.status), "\(deleted.status)")
            let after = try await f.get()
            XCTAssertEqual(after.body?["excludedProjectIDs"] as? [String], [sharedID])
            let empty = try await f.put(["excludedProjectIDs": [String]()])
            XCTAssertEqual(empty.body?["excludedProjectIDs"] as? [String], [])
        }
    }

    func testEachAccountHasItsOwnWebhook() async throws {
        try await withWebhook { f in
            try await f.configure()
            let other = try await PushTests.account(f.test, "Other")
            let theirs = try await f.put(["url": "https://another.example.test/y"], token: other.token)
            XCTAssertEqual(theirs.status, .ok)
            let mine = try await f.get()
            XCTAssertEqual(mine.body?["maskedURL"] as? String, "https://hooks.example.test/…")
            let count = try await WebhookEndpoint.query(on: f.app.db).count()
            XCTAssertEqual(count, 2)
        }
    }
}
