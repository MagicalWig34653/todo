import Crypto
import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// ADR 0035, items 4, 8, 9, 10: sending, retries, signature, test request and log.
final class WebhookDeliveryTests: XCTestCase {
    private func request(_ f: WebhookFixture) throws -> WebhookWireRequest { try XCTUnwrap(f.transport.requests.last) }

    // MARK: Item 8: sending

    func testSuccessfulDeliveryIsSentWithNoSecretsOnTheWire() async throws {
        try await withWebhook { f in
            try await f.configure()
            let row = try await f.bundleAndSend()
            XCTAssertEqual(row.state, "sent")
            XCTAssertEqual(row.attempts, 1)
            XCTAssertEqual(row.httpStatus, 200)
            XCTAssertNil(row.errorCode)
            XCTAssertNotNil(row.finishedAt)
            XCTAssertNil(row.openMarker)
            let r = try request(f)
            XCTAssertEqual(f.transport.requests.count, 1)
            XCTAssertEqual(r.url, WebhookFixture.secretURL)
            XCTAssertEqual(r.host, "hooks.example.test")
            XCTAssertEqual(r.address, "203.0.113.10", "the connection goes to the checked address only")
            XCTAssertEqual(f.transport.header("Content-Type", in: r), "application/json")
            for name in ["Authorization", "Cookie", "Proxy-Authorization", "X-Todolino-Signature", "X-Todolino-Timestamp"] {
                XCTAssertNil(f.transport.header(name, in: r), name)
            }
            // Exactly the three fixed keys; the encoder, not string assembly, produced them.
            XCTAssertEqual(String(decoding: r.body, as: UTF8.self), #"{"anzahl":1,"event":"person_action","kinds":["comment.created"]}"#)
            // The pending bundle is not sent a second time.
            let again = try await f.worker().tick(now: Date())
            XCTAssertEqual(again.sent, 0)
            XCTAssertEqual(f.transport.requests.count, 1)
        }
    }

    func testBundleIsNotSentBeforeItIsDue() async throws {
        try await withWebhook { f in
            let task = try await f.existingTask()
            try await f.configure()
            try await f.comment(task)
            let early = try await f.worker().tick(now: Date())
            XCTAssertEqual(early.sent, 0)
            XCTAssertTrue(f.transport.requests.isEmpty)
            let later = try await f.worker().tick(now: Date().addingTimeInterval(61))
            XCTAssertEqual(later.sent, 1)
            XCTAssertEqual(f.transport.requests.count, 1)
        }
    }

    func testRedirectIsAnErrorAndNeverFollowed() async throws {
        try await withWebhook { f in
            try await f.configure()
            f.transport.handler = { _ in .status(302) }
            let row = try await f.bundleAndSend()
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.httpStatus, 302)
            XCTAssertEqual(row.errorCode, "redirect_not_followed")
            XCTAssertEqual(row.attempts, 1, "no retry, no second request")
            XCTAssertEqual(f.transport.requests.count, 1)
            for code in [301, 303, 307, 308] {
                XCTAssertEqual(WebhookDeliverer.verdict(.status(code)), .failed(code: "redirect_not_followed", status: code))
            }
        }
    }

    func testClientErrorsFailAtOnceTransientOnesRetry() async throws {
        for code in [400, 401, 403, 404, 410, 422] {
            XCTAssertEqual(WebhookDeliverer.verdict(.status(code)), .failed(code: "http_\(code)", status: code), "\(code)")
        }
        for code in [408, 425, 429, 500, 502, 503, 504, 599] {
            XCTAssertEqual(WebhookDeliverer.verdict(.status(code)), .retry(code: "http_\(code)", status: code), "\(code)")
        }
        for code in [200, 201, 202, 204, 299] { XCTAssertEqual(WebhookDeliverer.verdict(.status(code)), .sent(status: code)) }
        XCTAssertEqual(WebhookDeliverer.verdict(.timeout), .retry(code: "timeout", status: nil))
        XCTAssertEqual(WebhookDeliverer.verdict(.networkError), .retry(code: "network_error", status: nil))
        XCTAssertEqual(WebhookDeliverer.verdict(.tlsError), .retry(code: "tls_error", status: nil))
        XCTAssertEqual(WebhookDeliverer.verdict(.status(100)), .failed(code: "http_unexpected", status: 100))
        try await withWebhook { f in
            try await f.configure()
            f.transport.handler = { _ in .status(400) }
            let row = try await f.bundleAndSend()
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.attempts, 1)
            XCTAssertEqual(row.errorCode, "http_400")
            XCTAssertEqual(f.transport.requests.count, 1)
            let retried = try await f.worker().tick(now: Date().addingTimeInterval(86_400))
            XCTAssertEqual(retried.retried + retried.sent + retried.failed, 0)
            XCTAssertEqual(f.transport.requests.count, 1, "a permanent failure is not tried again")
        }
    }

    // MARK: Item 9: backoff

    func testServerErrorRetriesWithBackoffAndStopsAfterSixAttempts() async throws {
        try await withWebhook { f in
            try await f.configure()
            f.transport.handler = { _ in .status(500) }
            var row = try await f.bundleAndSend()
            let base = Date()
            let expected: [TimeInterval] = [30, 120, 600, 1800, 7200]
            var now = base
            for (index, seconds) in expected.enumerated() {
                XCTAssertEqual(row.state, "pending", "attempt \(index + 1)")
                XCTAssertEqual(row.attempts, index + 1)
                XCTAssertEqual(row.httpStatus, 500)
                XCTAssertEqual(row.errorCode, "http_500")
                let wait = row.nextAttemptAt.timeIntervalSince(now)
                XCTAssertGreaterThanOrEqual(wait, seconds * 0.9 - 1, "attempt \(index + 1)")
                XCTAssertLessThanOrEqual(wait, seconds * 1.1 + 1, "attempt \(index + 1)")
                // Not yet due: nothing is sent.
                let sentBefore = f.transport.requests.count
                _ = try await f.worker().tick(now: now.addingTimeInterval(seconds * 0.8))
                XCTAssertEqual(f.transport.requests.count, sentBefore)
                now = row.nextAttemptAt.addingTimeInterval(1)
                _ = try await f.worker().tick(now: now)
                row = try await f.last()
            }
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.attempts, 6)
            XCTAssertEqual(f.transport.requests.count, 6)
            XCTAssertEqual(row.errorCode, "http_500")
            let more = try await f.worker().tick(now: now.addingTimeInterval(10 * 86_400))
            XCTAssertEqual(more.sent + more.retried, 0)
            XCTAssertEqual(f.transport.requests.count, 6, "no seventh attempt")
            let streak = try await f.ep().consecutiveFailures
            XCTAssertEqual(streak, 1, "one failed bundle, not six")
        }
    }

    func testTimeoutAndNetworkErrorRetryThenSucceed() async throws {
        try await withWebhook { f in
            try await f.configure()
            let results = LockedResults([.timeout, .networkError, .status(204)])
            f.transport.handler = { _ in results.next() }
            var row = try await f.bundleAndSend()
            XCTAssertEqual(row.state, "pending")
            XCTAssertEqual(row.errorCode, "timeout")
            XCTAssertNil(row.httpStatus)
            _ = try await f.worker().tick(now: row.nextAttemptAt.addingTimeInterval(1))
            row = try await f.last()
            XCTAssertEqual(row.errorCode, "network_error")
            XCTAssertEqual(row.state, "pending")
            _ = try await f.worker().tick(now: row.nextAttemptAt.addingTimeInterval(1))
            row = try await f.last()
            XCTAssertEqual(row.state, "sent")
            XCTAssertEqual(row.attempts, 3)
            XCTAssertEqual(row.httpStatus, 204)
            XCTAssertNil(row.errorCode, "the last result replaces the earlier error")
        }
    }

    func testTenFailedBundlesInARowSwitchTheWebhookOff() async throws {
        try await withWebhook { f in
            try await f.configure()
            f.transport.handler = { _ in .status(403) }
            let task = try await f.existingTask()
            for i in 1...10 {
                try await f.comment(task)
                try await f.makeDue()
                _ = try await f.worker().tick(now: Date())
                let e = try await f.ep()
                XCTAssertEqual(e.consecutiveFailures, i)
                XCTAssertEqual(e.enabled, i < 10, "after \(i) failed bundles")
            }
            XCTAssertEqual(f.transport.requests.count, 10)
        }
    }

    func testSuccessResetsTheFailureStreak() async throws {
        try await withWebhook { f in
            try await f.configure()
            let task = try await f.existingTask()
            func round(_ status: Int) async throws {
                f.transport.handler = { _ in .status(status) }
                try await f.comment(task); try await f.makeDue()
                _ = try await f.worker().tick(now: Date())
            }
            // Only final failures count; 403 is final at once.
            for _ in 0..<3 { try await round(403) }
            try await assertEqual(try await f.ep().consecutiveFailures, 3)
            try await round(200)
            try await assertEqual(try await f.ep().consecutiveFailures, 0)
            for _ in 0..<3 { try await round(403) }
            let e = try await f.ep()
            XCTAssertEqual(e.consecutiveFailures, 3)
            XCTAssertTrue(e.enabled)
        }
    }

    func testAutomaticShutOffIsVisibleAndStopsCollectingUntilSwitchedOn() async throws {
        try await withWebhook { f in
            let task = try await f.existingTask()
            try await f.configure()
            f.transport.handler = { _ in .status(404) }
            for _ in 0..<10 {
                try await f.comment(task); try await f.makeDue()
                _ = try await f.worker().tick(now: Date())
            }
            let state = try await f.get()
            XCTAssertEqual(state.body?["enabled"] as? Bool, false)
            XCTAssertEqual(state.body?["configured"] as? Bool, true)
            XCTAssertEqual(state.body?["consecutiveFailures"] as? Int, 10)
            let sent = f.transport.requests.count
            XCTAssertEqual(sent, 10)
            try await f.comment(task)
            let rows = try await f.rows()
            XCTAssertEqual(rows.filter { $0.state == "pending" }.count, 0, "a switched off webhook collects nothing")
            // The person switches it on again: the streak starts over.
            let on = try await f.put(["enabled": true])
            XCTAssertEqual(on.body?["enabled"] as? Bool, true)
            XCTAssertEqual(on.body?["consecutiveFailures"] as? Int, 0)
            f.transport.handler = { _ in .status(200) }
            try await f.comment(task); try await f.makeDue()
            let report = try await f.worker().tick(now: Date())
            XCTAssertEqual(report.sent, 1)
        }
    }

    func testPendingBundlesOfADisabledWebhookAreNotSent() async throws {
        try await withWebhook { f in
            let task = try await f.existingTask()
            try await f.configure()
            try await f.comment(task)
            let off = try await f.put(["enabled": false])
            XCTAssertEqual(off.status, .ok)
            try await f.makeDue()
            let report = try await f.worker().tick(now: Date())
            XCTAssertEqual(report.sent, 0)
            XCTAssertTrue(f.transport.requests.isEmpty)
            let row = try await f.last()
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.errorCode, "webhook_disabled")
        }
    }

    // MARK: Item 8: target checks at delivery time

    func testNameResolvingToAPrivateAddressAtDeliveryFailsWithoutRetry() async throws {
        try await withWebhook { f in
            try await f.configure()
            // DNS rebinding: the name was fine when saved and points inside now.
            f.resolver.set("hooks.example.test", "10.0.0.8")
            let row = try await f.bundleAndSend()
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.errorCode, "target_blocked")
            XCTAssertEqual(row.attempts, 1)
            XCTAssertTrue(f.transport.requests.isEmpty, "nothing is sent to a blocked address")
            let again = try await f.worker().tick(now: Date().addingTimeInterval(86_400))
            XCTAssertEqual(again.retried, 0)
            // A resolver that wrongly hands out a blocked address is caught by the service as well.
            for blocked in ["127.0.0.1", "169.254.169.254", "::1", "fd00::1", "::ffff:10.0.0.1", "100.64.1.1"] {
                f.resolver.set("hooks.example.test", blocked)
                let attempt = await WebhookDeliverer(app: f.app).attempt(endpoint: try await f.ep(), payload: .test, now: Date())
                XCTAssertEqual(attempt, .failed(code: "target_blocked", status: nil), blocked)
            }
            XCTAssertTrue(f.transport.requests.isEmpty)
        }
    }

    func testLocalhostIsRefusedByTheRealResolverAtDelivery() async throws {
        try await withWebhook { f in
            // Seal a URL for "localhost" directly (the API would refuse to store it).
            let ring = try XCTUnwrap(f.app.settingsRuntime?.keyRing)
            let sealed = try ring.sealWebhook("https://localhost/hook", userID: f.userID, field: .url)
            let e = WebhookEndpoint()
            e.userID = f.userID; e.urlCiphertext = sealed.blob; e.keyID = sealed.keyID; e.urlMask = "https://localhost"
            e.enabled = true; e.consecutiveFailures = 0; e.createdAt = Date(); e.updatedAt = Date()
            try await e.create(on: f.app.db)
            f.app.webhookResolver = SystemWebhookResolver()
            let task = try await f.existingTask()
            try await f.comment(task)
            try await f.makeDue()
            _ = try await f.worker().tick(now: Date())
            let row = try await f.last()
            XCTAssertEqual(row.state, "failed")
            XCTAssertEqual(row.errorCode, "target_blocked")
            XCTAssertEqual(row.attempts, 1)
            XCTAssertTrue(f.transport.requests.isEmpty)
        }
    }

    func testStoredHttpUrlIsNeverSent() async throws {
        try await withWebhook { f in
            let ring = try XCTUnwrap(f.app.settingsRuntime?.keyRing)
            let sealed = try ring.sealWebhook("http://hooks.example.test/hook", userID: f.userID, field: .url)
            let e = WebhookEndpoint()
            e.userID = f.userID; e.urlCiphertext = sealed.blob; e.keyID = sealed.keyID; e.urlMask = "https://hooks.example.test"
            e.enabled = true; e.consecutiveFailures = 0; e.createdAt = Date(); e.updatedAt = Date()
            try await e.create(on: f.app.db)
            let task = try await f.existingTask()
            try await f.comment(task); try await f.makeDue()
            _ = try await f.worker().tick(now: Date())
            let row = try await f.last()
            XCTAssertEqual(row.errorCode, "webhook_url_not_https")
            XCTAssertEqual(row.state, "failed")
            XCTAssertTrue(f.transport.requests.isEmpty)
        }
    }

    func testUnreadableCiphertextFailsWithoutExposingAnything() async throws {
        try await withWebhook { f in
            try await f.configure()
            // The key was replaced: the stored secret cannot be opened any more.
            WebhookFixture.installRuntime(f.app, key: false)
            var row = try await f.bundleAndSend()
            XCTAssertEqual(row.errorCode, "encryption_key_missing")
            let other = Data(repeating: 9, count: 32).base64EncodedString()
            let env = ["SETTINGS_ENCRYPTION_KEY": other]
            f.app.settingsRuntime = SettingsRuntime(app: f.app, env: { env[$0] }, keyRing: try .fromEnvironment(get: { env[$0] }), pollInterval: 1)
            let task = try await f.existingTask()
            try await f.comment(task); try await f.makeDue()
            _ = try await f.worker().tick(now: Date())
            row = try await f.last()
            XCTAssertEqual(row.errorCode, "encryption_key_unreadable")
            XCTAssertTrue(f.transport.requests.isEmpty)
            // Rotation: the old key as PREVIOUS keeps it readable.
            let both = ["SETTINGS_ENCRYPTION_KEY": other, "SETTINGS_ENCRYPTION_KEY_PREVIOUS": WebhookFixture.keyBase64]
            f.app.settingsRuntime = SettingsRuntime(app: f.app, env: { both[$0] }, keyRing: try .fromEnvironment(get: { both[$0] }), pollInterval: 1)
            let attempt = await WebhookDeliverer(app: f.app).attempt(endpoint: try await f.ep(), payload: .test, now: Date())
            XCTAssertEqual(attempt, .sent(status: 200))
        }
    }

    // MARK: Item 4: signature

    func testSignatureHeadersMatchHmacOfTimestampAndBody() async throws {
        try await withWebhook { f in
            try await f.configure(["signingSecret": WebhookFixture.secretSigning])
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let row = try await f.bundleAndSend(at: now)
            XCTAssertEqual(row.state, "sent")
            let r = try request(f)
            let timestamp = try XCTUnwrap(f.transport.header("X-Todolino-Timestamp", in: r))
            XCTAssertEqual(timestamp, String(Int(now.timeIntervalSince1970)))
            let signature = try XCTUnwrap(f.transport.header("X-Todolino-Signature", in: r))
            let mac = HMAC<SHA256>.authenticationCode(for: Data("\(timestamp).".utf8) + r.body, using: SymmetricKey(data: Data(WebhookFixture.secretSigning.utf8)))
            XCTAssertEqual(signature, "sha256=" + mac.map { String(format: "%02x", $0) }.joined())
            XCTAssertTrue(signature.hasPrefix("sha256="))
            XCTAssertEqual(signature.count, 7 + 64)
            // A different secret does not produce this value.
            let wrong = HMAC<SHA256>.authenticationCode(for: Data("\(timestamp).".utf8) + r.body, using: SymmetricKey(data: Data("another-secret-0123456789".utf8)))
            XCTAssertNotEqual(signature, "sha256=" + wrong.map { String(format: "%02x", $0) }.joined())
            // The secret itself never goes out.
            XCTAssertFalse(r.headers.contains { $0.1.contains(WebhookFixture.secretSigning) })
            XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains(WebhookFixture.secretSigning))
        }
    }

    // MARK: Item 10: test request and log

    func testSendTestDeliversAtOnceAndIsRateLimited() async throws {
        try await withWebhook { f in
            try await f.configure(["signingSecret": WebhookFixture.secretSigning])
            let first = try await f.sendTest()
            XCTAssertEqual(first.status, .ok, "\(first.body ?? [:])")
            XCTAssertEqual(first.body?["state"] as? String, "sent")
            XCTAssertEqual(first.body?["event"] as? String, "test")
            XCTAssertEqual(first.body?["httpStatus"] as? Int, 200)
            XCTAssertEqual(first.body?["anzahl"] as? Int, 0)
            XCTAssertEqual(first.body?["kinds"] as? [String], [])
            let r = try request(f)
            XCTAssertEqual(String(decoding: r.body, as: UTF8.self), #"{"anzahl":0,"event":"test","kinds":[]}"#)
            XCTAssertNotNil(f.transport.header("X-Todolino-Signature", in: r))
            // At most one per ten seconds.
            let second = try await f.sendTest()
            XCTAssertEqual(second.status, .tooManyRequests)
            XCTAssertEqual(second.body?["reason"] as? String, "rate_limited")
            XCTAssertEqual(f.transport.requests.count, 1)
            // The result is in the log; the streak counter is untouched.
            let log = try await f.deliveries()
            XCTAssertEqual((log.body?["items"] as? [[String: Any]])?.count, 1)
            // Other accounts have their own limit.
            let other = try await PushTests.account(f.test, "Other")
            let theirs = try await f.put(["url": "https://another.example.test/y"], token: other.token)
            XCTAssertEqual(theirs.status, .ok)
            let otherTest = try await f.sendTest(token: other.token)
            XCTAssertEqual(otherTest.status, .ok)
        }
    }

    func testFailedTestIsLoggedWithoutRetryAndWithoutCountingAsFailedBundle() async throws {
        try await withWebhook { f in
            try await f.configure()
            f.transport.handler = { _ in .status(500) }
            let r = try await f.sendTest()
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.body?["state"] as? String, "failed")
            XCTAssertEqual(r.body?["errorCode"] as? String, "http_500")
            XCTAssertEqual(r.body?["attempts"] as? Int, 1)
            XCTAssertEqual(f.transport.requests.count, 1)
            let e = try await f.ep()
            XCTAssertEqual(e.consecutiveFailures, 0)
            XCTAssertTrue(e.enabled)
            let tick = try await f.worker().tick(now: Date().addingTimeInterval(86_400))
            XCTAssertEqual(tick.retried, 0)
            XCTAssertEqual(f.transport.requests.count, 1)
            let settings = try await f.get()
            XCTAssertEqual((settings.body?["lastDelivery"] as? [String: Any])?["errorCode"] as? String, "http_500")
        }
    }

    func testSendTestNeedsAConfiguredWebhook() async throws {
        try await withWebhook { f in
            let r = try await f.sendTest()
            XCTAssertEqual(r.status, .conflict)
            XCTAssertEqual(r.body?["reason"] as? String, "webhook_not_configured")
        }
    }

    func testDeliveryLogHasNoUrlAndOnlyTheLastFiftyOfTheOwnAccount() async throws {
        try await withWebhook { f in
            try await f.configure()
            let other = try await PushTests.account(f.test, "Other")
            _ = try await f.put(["url": "https://another.example.test/y"], token: other.token)
            for i in 0..<60 {
                let row = WebhookDelivery(userID: f.userID, event: "person_action", anzahl: i + 1, kindsMask: 1, due: Date(), open: false,
                                          now: Date().addingTimeInterval(Double(i)))
                row.state = i.isMultiple(of: 2) ? "sent" : "failed"; row.attempts = 1; row.httpStatus = i.isMultiple(of: 2) ? 200 : 500
                row.errorCode = i.isMultiple(of: 2) ? nil : "http_500"; row.finishedAt = row.createdAt
                try await row.create(on: f.app.db)
            }
            let foreign = WebhookDelivery(userID: other.id, event: "person_action", anzahl: 99, kindsMask: 1, due: Date(), open: false)
            try await foreign.create(on: f.app.db)
            let log = try await f.deliveries()
            let items = try XCTUnwrap(log.body?["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 50)
            XCTAssertEqual(items.first?["anzahl"] as? Int, 60, "newest first")
            XCTAssertEqual(items.last?["anzahl"] as? Int, 11)
            XCTAssertFalse(items.contains { $0["anzahl"] as? Int == 99 })
            let text = jsonString(log.body)
            for needle in ["example.test", "https", "url", "URL", "SECRET"] { XCTAssertFalse(text.contains(needle), needle) }
            for key in ["id", "event", "state", "attempts", "anzahl", "kinds", "createdAt"] { XCTAssertNotNil(items.first?[key], key) }
            XCTAssertEqual(Set(items.compactMap { $0["state"] as? String }), ["sent", "failed"])
            XCTAssertEqual(items.first(where: { $0["state"] as? String == "failed" })?["errorCode"] as? String, "http_500")
            // The other account sees its own log only.
            let theirs = try await f.deliveries(token: other.token)
            XCTAssertEqual((theirs.body?["items"] as? [[String: Any]])?.count, 1)
            // Anonymous: no.
            let anonymous = try await f.test.json(.GET, "/v1/settings/webhook/deliveries")
            XCTAssertEqual(anonymous.status, .unauthorized)
        }
    }

    func testLogIsKeptForFourteenDays() async throws {
        try await withWebhook { f in
            try await f.configure()
            let now = Date()
            func add(_ daysAgo: Double, state: String) async throws -> UUID {
                let row = WebhookDelivery(userID: f.userID, event: "person_action", anzahl: 1, kindsMask: 1, due: now.addingTimeInterval(-daysAgo * 86_400), open: false,
                                          now: now.addingTimeInterval(-daysAgo * 86_400))
                row.state = state; row.finishedAt = row.createdAt
                try await row.create(on: f.app.db)
                return try row.requireID()
            }
            let old = try await add(15, state: "sent"), oldFailed = try await add(20, state: "failed"), young = try await add(13, state: "sent")
            let report = try await f.worker().tick(now: now)
            XCTAssertEqual(report.purged, 2)
            let kept = Set(try await f.rows().map { $0.id! })
            XCTAssertEqual(kept, [young])
            XCTAssertFalse(kept.contains(old) || kept.contains(oldFailed))
        }
    }

    // MARK: Item 8: several replicas, one lease

    func testWorkerLeaseLetsOnlyOneReplicaSend() async throws {
        try await withWebhook { f in
            let replica = try await f.replica()
            defer { Task { await replica.shutdown() } }
            let task = try await f.existingTask()
            try await f.configure()
            try await f.comment(task)
            try await f.makeDue()
            let a = f.worker(), b = f.worker(replica.app)
            async let first = a.runIfDue(), second = b.runIfDue()
            let outcomes = await [first, second]
            let ran = outcomes.compactMap { outcome -> WebhookWorker.Report? in if case .ran(let r) = outcome { return r } else { return nil } }
            XCTAssertGreaterThanOrEqual(ran.count, 1, "\(outcomes)")
            XCTAssertEqual(ran.reduce(0) { $0 + $1.sent }, 1)
            XCTAssertEqual(f.transport.requests.count, 1, "exactly one request for one bundle")
            let row = try await f.last()
            XCTAssertEqual(row.state, "sent")
            XCTAssertEqual(row.attempts, 1)
        }
    }

    func testWorkerLeaseIsHeldWhileARunIsInProgress() async throws {
        try await withWebhook { f in
            let replica = try await f.replica()
            defer { Task { await replica.shutdown() } }
            let sql = try XCTUnwrap(f.app.db as? any SQLDatabase)
            let first = f.worker()
            // Another replica holds the lease: this one skips and does not send.
            let task = try await f.existingTask()
            try await f.configure()
            try await f.comment(task)
            try await f.makeDue()
            _ = try await first.runIfDue()  // creates the lease row
            try await sql.raw("UPDATE maintenance_leases SET holder = 'other', expires_at = 9999999999 WHERE name = \(bind: WebhookWorker.jobName)").run()
            f.transport.handler = { _ in .status(200) }
            try await WebhookDelivery.query(on: f.app.db).set(\.$state, to: "pending").set(\.$nextAttemptAt, to: Date().addingTimeInterval(-1)).update()
            let before = f.transport.requests.count
            let outcome = await f.worker(replica.app).runIfDue()
            XCTAssertEqual(outcome, .skipped)
            XCTAssertEqual(f.transport.requests.count, before)
        }
    }
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [WebhookSendResult]
    init(_ queue: [WebhookSendResult]) { self.queue = queue }
    func next() -> WebhookSendResult { lock.lock(); defer { lock.unlock() }; return queue.isEmpty ? .status(200) : queue.removeFirst() }
}
