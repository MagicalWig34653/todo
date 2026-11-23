import AsyncHTTPClient
import Fluent
import NIOCore
import SQLKit
import XCTVapor
@testable import TodoKit

/// Findings of the security review of the outgoing webhook (card 06EB19A3): DNS pinning, address ranges, save-time limits,
/// parallel delivery, the loop guard, port, signature time and key requirements.
final class WebhookSecurityReviewTests: XCTestCase {
    private func request(_ f: WebhookFixture) throws -> WebhookWireRequest { try XCTUnwrap(f.transport.requests.last) }
    private let okResponse = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    // MARK: Finding 1: the pinned address must apply to the host that the HTTP client really looks up

    func testRequestURLIsBuiltFromTheParsedPartsWithLowercaseHostAndNoTrailingDot() throws {
        let mixed = try WebhookURL.parse("https://Example.COM/Path/X?Token=AbC#frag")
        XCTAssertEqual(mixed.host, "example.com")
        XCTAssertEqual(mixed.requestURL(), "https://example.com/Path/X?Token=AbC", "path and query keep their case, the fragment is dropped")
        let dotted = try WebhookURL.parse("https://EXAMPLE.com./x?y=1")
        XCTAssertEqual(dotted.host, "example.com", "no trailing dot")
        XCTAssertEqual(dotted.requestURL(), "https://example.com/x?y=1")
        XCTAssertEqual(dotted.mask, "https://example.com")
        XCTAssertEqual(try WebhookURL.parse("https://Example.COM:443").requestURL(), "https://example.com")
        XCTAssertEqual(try WebhookURL.parse("https://[2001:4860:4860::8888]/x").requestURL(), "https://[2001:4860:4860::8888]/x")
        XCTAssertEqual(mixed.requestURL(scheme: "http", port: 8080), "http://example.com:8080/Path/X?Token=AbC")
    }

    func testDeliveryPinsTheAddressForMixedCaseAndTrailingDotHostsAndResolvesOnce() async throws {
        try await withWebhook { f in
            let cases: [(stored: String, wire: String)] = [
                ("https://Example.COM/x", "https://example.com/x"),
                ("https://EXAMPLE.com./x?y=1", "https://example.com/x?y=1"),
                ("https://Example.COM:443/x", "https://example.com/x"),
            ]
            for (stored, wire) in cases {
                f.app.webhookResolver = FixedWebhookResolver()
                try await f.configure(url: stored)
                // The first answer is the checked one; a second lookup (what an unpinned client would do) would be internal.
                let flipping = FlippingWebhookResolver(first: "203.0.113.10", later: "10.0.0.8")
                f.app.webhookResolver = flipping
                let row = try await f.bundleAndSend()
                XCTAssertEqual(row.state, "sent", stored)
                let r = try request(f)
                XCTAssertEqual(r.url, wire, stored)
                XCTAssertEqual(r.host, "example.com", stored)
                XCTAssertEqual(r.address, "203.0.113.10", stored)
                XCTAssertEqual(flipping.calls, 1, "one resolution per delivery: \(stored)")
                XCTAssertEqual(flipping.hosts, ["example.com"], stored)
            }
        }
    }

    func testTransportConnectsExactlyOnceToThePinnedAddressForMixedCaseUrls() async throws {
        let server = LocalHTTPServer(response: okResponse)
        try await server.start()
        defer { Task { await server.stop() } }
        var expected = 0
        // "example.com" resolves in real DNS (or not at all offline): only the pinned loopback address can answer here.
        for raw in ["https://Example.COM/x", "https://EXAMPLE.com./x?y=1", "https://Example.COM:443/x"] {
            let parsed = try WebhookURL.parse(raw)
            let wire = WebhookWireRequest(url: parsed.requestURL(scheme: "http", port: server.port), host: parsed.host, address: "127.0.0.1",
                                          headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
            let result = await AsyncHTTPWebhookTransport(timeout: 5).post(wire)
            XCTAssertEqual(result, .status(200), raw)
            expected += 1
            XCTAssertEqual(server.connections, expected, "exactly one connection per delivery, to the pinned address: \(raw)")
        }
        XCTAssertTrue(server.requests.allSatisfy { $0.lowercased().contains("host: example.com:\(server.port)") }, "\(server.requests)")
    }

    func testTransportRefusesToSendWhenTheRequestHostIsNotTheOverrideKey() async throws {
        let server = LocalHTTPServer(response: okResponse)
        try await server.start()
        defer { Task { await server.stop() } }
        // What the HTTP client reads from this URL is "Pinned.Example.test": it would not find the override and would resolve again.
        let mixed = WebhookWireRequest(url: "http://Pinned.Example.test:\(server.port)/x", host: "pinned.example.test", address: "127.0.0.1",
                                       headers: [], body: Data("{}".utf8))
        let trailingDot = WebhookWireRequest(url: "http://pinned.example.test.:\(server.port)/x", host: "pinned.example.test", address: "127.0.0.1",
                                             headers: [], body: Data("{}".utf8))
        for wire in [mixed, trailingDot] {
            let result = await AsyncHTTPWebhookTransport(timeout: 5).post(wire)
            XCTAssertEqual(result, .targetBlocked, wire.url)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.connections, 0, "nothing is sent when the pinning cannot apply")
        // The matching form still works.
        let good = WebhookWireRequest(url: "http://pinned.example.test:\(server.port)/x", host: "pinned.example.test", address: "127.0.0.1",
                                      headers: [], body: Data("{}".utf8))
        let ok = await AsyncHTTPWebhookTransport(timeout: 5).post(good)
        XCTAssertEqual(ok, .status(200))
        XCTAssertEqual(server.connections, 1)
    }

    func testBlockedResultOfTheTransportIsAPermanentTargetBlockedFailure() async throws {
        XCTAssertEqual(WebhookDeliverer.verdict(.targetBlocked), .failed(code: "target_blocked", status: nil))
        try await withWebhook { f in
            try await f.configure()
            f.transport.handler = { _ in .targetBlocked }
            let row = try await f.bundleAndSend()
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.errorCode, "target_blocked")
            XCTAssertEqual(row.attempts, 1, "no retry")
        }
    }

    // MARK: Finding 2: address ranges that reach an internal address in disguise

    private static let disguised = ["::ffff:0.0.0.0", "::ffff:0:0", "::ffff:8.8.8.8", "::ffff:0:a00:1", "::ffff:0:8.8.8.8", "::ffff:0:0:0",
                                    "100::1", "100::ffff:ffff:ffff:ffff", "2001:db8::1", "2001:db8:ffff::1"]

    func testMappedZeroSiitDiscardAndDocumentationRangesAreBlocked() {
        for ip in Self.disguised { XCTAssertTrue(WebhookTarget.isBlocked(ip), ip) }
        // Neighbours stay usable: a public IPv6 address and the first address after the discard prefix.
        for ip in ["2001:4860:4860::8888", "2606:4700::1111", "100:0:0:1::1", "2001:db9::1", "203.0.113.10", "8.8.8.8"] {
            XCTAssertFalse(WebhookTarget.isBlocked(ip), ip)
        }
        // The shared guard (mail, S3) is not changed by this policy.
        XCTAssertFalse(OutboundGuard.isBlocked("::ffff:0.0.0.0", .strict))
    }

    func testDisguisedLiteralsAreRejectedAtSave() async throws {
        try await withWebhook { f in
            for ip in Self.disguised {
                let r = try await f.put(["url": "https://[\(ip)]/x"])
                XCTAssertEqual(r.status, .badRequest, ip)
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_blocked", ip)
            }
            let stored = try await f.endpoint()
            XCTAssertNil(stored)
        }
    }

    func testDisguisedAAAAAnswersAreRejectedAtSaveAndDelivery() async throws {
        try await withWebhook { f in
            f.resolver.set("aaaa.example.test", "::ffff:0.0.0.0")
            for ip in Self.disguised {
                f.resolver.set("aaaa.example.test", ip)
                let r = try await f.put(["url": "https://aaaa.example.test/x"])
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_blocked", "save: \(ip)")
            }
            try await f.configure()
            for ip in Self.disguised {
                f.resolver.set("hooks.example.test", ip)
                let attempt = await WebhookDeliverer(app: f.app).attempt(endpoint: try await f.ep(), payload: .test, now: Date())
                XCTAssertEqual(attempt, .failed(code: "target_blocked", status: nil), "delivery: \(ip)")
            }
            XCTAssertTrue(f.transport.requests.isEmpty)
        }
    }

    // MARK: Finding 3: limits and no oracle at save time

    func testPutWithAHostNameIsRateLimitedPerAccount() async throws {
        try await withWebhook { f in
            var firstLimited: Int?
            for i in 0..<30 {
                let r = try await f.put(["url": "https://h\(i).example.test/x"])
                if r.status == .tooManyRequests { firstLimited = i; XCTAssertEqual(r.body?["reason"] as? String, "rate_limited"); break }
                XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            }
            // A fixed one-minute window: the ten allowed requests may straddle a window change, so up to twenty pass.
            let limited = try XCTUnwrap(firstLimited, "no 429 within 30 PUTs")
            XCTAssertTrue((10...20).contains(limited), "limited at request \(limited)")
            let before = try await f.ep().urlMask
            let denied = try await f.put(["url": "https://another-one.example.test/x"])
            XCTAssertEqual(denied.status, .tooManyRequests)
            let after = try await f.ep().urlMask
            XCTAssertEqual(before, after, "a limited request changes nothing")
            // Other accounts have their own budget.
            let other = try await PushTests.account(f.test, "Other")
            let theirs = try await f.put(["url": "https://theirs.example.test/x"], token: other.token)
            XCTAssertEqual(theirs.status, .ok)
        }
    }

    func testUnresolvableAndBlockedHostsGiveTheSameCodeAtSave() async throws {
        try await withWebhook { f in
            f.app.webhookResolver = FixedWebhookResolver(["internal.example.test": "10.1.2.3"], fallback: nil)
            let blocked = try await f.put(["url": "https://internal.example.test/x"])
            let unknown = try await f.put(["url": "https://nowhere.example.test/x"])
            XCTAssertEqual(blocked.status, .badRequest)
            XCTAssertEqual(unknown.status, .badRequest)
            XCTAssertEqual(blocked.body?["reason"] as? String, "webhook_url_blocked")
            XCTAssertEqual(unknown.body?["reason"] as? String, "webhook_url_blocked", "an unknown name must not be distinguishable from a blocked one")
            // Syntax errors are a different matter (no lookup involved) and keep their code.
            let syntax = try await f.put(["url": "https://-bad-.test/x"])
            XCTAssertEqual(syntax.body?["reason"] as? String, "webhook_url_invalid")
            f.app.webhookResolver = SystemWebhookResolver()
            let local = try await f.put(["url": "https://localhost/x"])
            XCTAssertEqual(local.body?["reason"] as? String, "webhook_url_blocked")
        }
    }

    func testSlowResolutionAtSaveEndsAsBlockedWithinTheLimit() async throws {
        try await withWebhook { f in
            XCTAssertEqual(WebhookLimits.resolveTimeout, 5)
            XCTAssertEqual(f.app.webhookResolveTimeout, 5, "default of the setting")
            f.app.webhookResolveTimeout = 0.3
            for blocking in [false, true] {
                f.app.webhookResolver = SlowWebhookResolver(delay: blocking ? 2 : 3, blocking: blocking)
                let started = Date()
                let r = try await f.put(["url": "https://slow.example.test/x"])
                XCTAssertEqual(r.status, .badRequest, "blocking \(blocking)")
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_blocked", "blocking \(blocking)")
                XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the request ends at the limit, not when the resolver is done (blocking \(blocking))")
            }
            let stored = try await f.endpoint()
            XCTAssertNil(stored)
            // A resolver within the limit works as before.
            f.app.webhookResolver = SlowWebhookResolver(delay: 0.05)
            let ok = try await f.put(["url": "https://quick.example.test/x"])
            XCTAssertEqual(ok.status, .ok)
        }
    }

    // MARK: Finding 4: parallel delivery with limits

    /// Accounts with a webhook each and one due bundle each; `hosts[i]` is the host of account i.
    private func prepareTargets(_ f: WebhookFixture, hosts: [String]) async throws {
        for (i, host) in hosts.enumerated() {
            let account = try await PushTests.account(f.test, "Target \(i)")
            let r = try await f.put(["url": "https://\(host)/hook"], token: account.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            let row = WebhookDelivery(userID: account.id, event: "person_action", anzahl: 1, kindsMask: 1, due: Date().addingTimeInterval(-5), open: false,
                                      now: Date().addingTimeInterval(-70))
            try await row.create(on: f.app.db)
        }
    }

    func testTenSlowTargetsAreNotServedOneAfterTheOther() async throws {
        try await withWebhook { f in
            try await prepareTargets(f, hosts: (0..<10).map { "tarpit\($0).example.test" })
            f.transport.delay = 0.4
            let renewals = Counter()
            let started = Date()
            let report = try await f.worker().tick(now: Date(), keepLease: { renewals.bump(); return true })
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual(report.sent, 10, "\(report)")
            XCTAssertEqual(f.transport.requests.count, 10)
            XCTAssertLessThan(elapsed, 2.0, "serial would take 4 s; took \(elapsed)")
            XCTAssertGreaterThan(f.transport.maxInFlight, 1)
            XCTAssertLessThanOrEqual(f.transport.maxInFlight, WebhookLimits.maxConcurrentDeliveries)
            XCTAssertGreaterThanOrEqual(renewals.value, 10, "the lease is renewed before every delivery")
            let rows = try await f.rows()
            XCTAssertTrue(rows.allSatisfy { $0.state == "sent" && $0.attempts == 1 })
        }
    }

    func testOneHostIsNeverServedInParallel() async throws {
        try await withWebhook { f in
            // Four accounts on one shared host (like several people on one relay) and four on their own hosts.
            try await prepareTargets(f, hosts: Array(repeating: "shared.example.test", count: 4) + (0..<4).map { "own\($0).example.test" })
            // The same account may also have a retry and a new bundle pending at once.
            let anyEndpoint = try await WebhookEndpoint.query(on: f.app.db).first()
            let any = try XCTUnwrap(anyEndpoint)
            let second = WebhookDelivery(userID: any.userID, event: "person_action", anzahl: 2, kindsMask: 2, due: Date().addingTimeInterval(-5), open: false,
                                         now: Date().addingTimeInterval(-60))
            try await second.create(on: f.app.db)
            f.transport.delay = 0.3
            let started = Date()
            let report = try await f.worker().tick(now: Date())
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual(report.sent, 9, "\(report)")
            XCTAssertEqual(f.transport.maxInFlightPerHost, 1, "one host is served by one delivery at a time")
            XCTAssertGreaterThan(f.transport.maxInFlight, 1, "different hosts run side by side")
            XCTAssertGreaterThanOrEqual(elapsed, 0.3 * 4, "the four on the shared host are one after the other")
        }
    }

    func testConnectTimeoutIsThreeSecondsAndTheTotalStaysTen() {
        let c = AsyncHTTPWebhookTransport().configuration(host: "hooks.example.test", address: "203.0.113.10")
        XCTAssertEqual(c.timeout.connect, .seconds(3))
        XCTAssertEqual(c.timeout.read, .seconds(10))
        XCTAssertEqual(c.dnsOverride, ["hooks.example.test": "203.0.113.10"])
        XCTAssertNil(c.proxy)
        XCTAssertEqual(WebhookLimits.timeout, 10)
        XCTAssertEqual(WebhookLimits.connectTimeout, 3)
        // A shorter total limit (tests) shortens the connect limit as well, never lengthens it.
        let short = AsyncHTTPWebhookTransport(timeout: 0.5).configuration(host: "a.example.test", address: "203.0.113.10")
        XCTAssertEqual(short.timeout.connect, .milliseconds(500))
    }

    // MARK: Finding 5: only a person session wakes the webhook (fail closed)

    func testActivityWithoutAPersonSessionMarkerDoesNotWakeTheWebhook() async throws {
        try await withWebhook { f in
            let task = try await f.existingTask()
            try await f.configure()
            let top = try await ActivityEvent.query(on: f.app.db).sort(\.$sequence, .descending).first()?.sequence ?? 0
            // A write path without a request (background job) or one that forgot the mark: the event says "Person" but nobody marked a session.
            for (i, kind) in ["comment.created", "task.created", "review.accepted"].enumerated() {
                let e = ActivityEvent()
                e.taskID = UUID(uuidString: task)!; e.sequence = top + 1000 + i; e.actorType = .person; e.actorID = f.userID; e.kind = kind
                try await e.create(on: f.app.db)
            }
            let rows = try await f.rows()
            XCTAssertEqual(rows.count, 0, "no mark, no trigger")
            // Control: the same person through the app (session) does wake it.
            try await f.comment(task)
            let after = try await f.rows()
            XCTAssertEqual(after.count, 1)
        }
    }

    // MARK: Finding 7: only port 443

    func testOnlyPort443IsAccepted() async throws {
        try await withWebhook { f in
            for url in ["https://hooks.example.test:8443/x", "https://hooks.example.test:80/x", "https://hooks.example.test:444/x", "https://203.0.113.7:8080/x",
                        "https://[2001:4860:4860::8888]:444/x", "https://hooks.example.test:1/x"] {
                let r = try await f.put(["url": url])
                XCTAssertEqual(r.status, .badRequest, url)
                XCTAssertEqual(r.body?["reason"] as? String, "webhook_url_invalid", url)
            }
            let none = try await f.endpoint()
            XCTAssertNil(none)
            for url in ["https://hooks.example.test:443/x", "https://hooks.example.test/x", "https://[2001:4860:4860::8888]:443/x"] {
                let r = try await f.put(["url": url])
                XCTAssertEqual(r.status, .ok, "\(url) \(r.body ?? [:])")
            }
            XCTAssertThrowsError(try WebhookURL.parse("https://hooks.example.test:8443/x"))
            XCTAssertEqual(try WebhookURL.parse("https://hooks.example.test:443/x").port, 443)
        }
    }

    // MARK: Finding 8: the signature time is the send time

    func testSignatureTimestampIsTheTimeOfSendingNotTheStartOfTheRun() async throws {
        try await withWebhook { f in
            try await f.configure(["signingSecret": WebhookFixture.secretSigning])
            let task = try await f.existingTask()
            try await f.comment(task)
            try await f.makeDue()
            // The run "started" an hour ago (a slow run): the stamp must still be the real time of this request.
            _ = try await f.worker().tick(now: Date().addingTimeInterval(3600))
            let r = try request(f)
            let stamp = try XCTUnwrap(Double(try XCTUnwrap(f.transport.header("X-Todolino-Timestamp", in: r))))
            XCTAssertEqual(stamp, Date().timeIntervalSince1970, accuracy: 10)
            let signature = try XCTUnwrap(f.transport.header("X-Todolino-Signature", in: r))
            XCTAssertEqual(signature, "sha256=" + WebhookSignature.hex(secret: WebhookFixture.secretSigning, timestamp: String(Int(stamp)), body: r.body))
        }
    }

    // MARK: Finding 11: no key needed where nothing secret is written

    func testExclusionsAndEnabledCanBeChangedWithoutAnEncryptionKey() async throws {
        try await withWebhook { f in
            try await f.configure(["signingSecret": WebhookFixture.secretSigning])
            WebhookFixture.installRuntime(f.app, key: false)
            let off = try await f.put(["enabled": false])
            XCTAssertEqual(off.status, .ok, "\(off.body ?? [:])")
            XCTAssertEqual(off.body?["enabled"] as? Bool, false)
            let on = try await f.put(["enabled": true, "excludedProjectIDs": [f.projectID]])
            XCTAssertEqual(on.status, .ok, "\(on.body ?? [:])")
            XCTAssertEqual((on.body?["excludedProjectIDs"] as? [String])?.map { $0.lowercased() }, [f.projectID.lowercased()])
            let cleared = try await f.put(["excludedProjectIDs": [String]()])
            XCTAssertEqual(cleared.status, .ok)
            // Removing the signing secret writes nothing encrypted either.
            let noSecret = try await f.put(["signingSecret": NSNull()])
            XCTAssertEqual(noSecret.status, .ok, "\(noSecret.body ?? [:])")
            XCTAssertEqual(noSecret.body?["signingConfigured"] as? Bool, false)
            // Writing an address or a secret still needs the key.
            let url = try await f.put(["url": "https://other.example.test/x"])
            XCTAssertEqual(url.status, .conflict)
            XCTAssertEqual(url.body?["reason"] as? String, "encryption_key_missing")
            let secret = try await f.put(["signingSecret": WebhookFixture.secretSigning])
            XCTAssertEqual(secret.status, .conflict)
            XCTAssertEqual(secret.body?["reason"] as? String, "encryption_key_missing")
            let mask = try await f.get().body?["maskedURL"] as? String
            XCTAssertEqual(mask, "https://hooks.example.test/…", "the stored address is untouched")

            // A server whose key setting is unusable (runtime not built yet, malformed key in the environment) can still switch the webhook.
            f.app.settingsRuntime = nil
            setenv("SETTINGS_ENCRYPTION_KEY", "not-a-key", 1)
            defer { unsetenv("SETTINGS_ENCRYPTION_KEY") }
            let broken = try await f.put(["enabled": false])
            XCTAssertEqual(broken.status, .ok, "\(broken.body ?? [:])")
            XCTAssertEqual(broken.body?["enabled"] as? Bool, false)
            let brokenURL = try await f.put(["url": "https://other.example.test/x"])
            XCTAssertNotEqual(brokenURL.status, .ok, "an address cannot be written without a usable key")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
