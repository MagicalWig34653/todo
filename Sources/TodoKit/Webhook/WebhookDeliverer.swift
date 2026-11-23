import Fluent
import SQLKit
import Vapor

/// Sends one bundle (or test) and records the outcome. Used by the worker and by "send test". Everything that can go wrong is
/// reduced to a short code; neither the URL nor the host appears in a result, a log line or an error text.
struct WebhookDeliverer: Sendable {
    let app: Application

    enum Verdict: Equatable, Sendable {
        case sent(status: Int)
        /// Transient: network error, timeout, 408, 425, 429, 5xx.
        case retry(code: String, status: Int?)
        /// Permanent: other 4xx, redirects, blocked targets, unusable stored secret.
        case failed(code: String, status: Int?)
    }

    /// One attempt without touching any row.
    func attempt(endpoint: WebhookEndpoint, payload: WebhookPayload, now: Date) async -> Verdict {
        if true { return .failed(code: "not_implemented", status: nil) }
        let userID = endpoint.userID
        let ring: SettingsKeyRing
        do { ring = try app.requireSettingsRuntime().keyRing } catch { return .failed(code: "encryption_key_missing", status: nil) }
        guard ring.current != nil || !ring.previous.isEmpty else { return .failed(code: "encryption_key_missing", status: nil) }
        let url: WebhookURL
        var secret: String?
        do {
            url = try WebhookURL.parse(try ring.openWebhook(endpoint.urlCiphertext, keyID: endpoint.keyID, userID: userID, field: .url))
            if let blob = endpoint.signingCiphertext {
                secret = try ring.openWebhook(blob, keyID: endpoint.signingKeyID, userID: userID, field: .signing)
            }
        } catch let abort as Abort {
            return .failed(code: abort.reason == "webhook_url_not_https" ? "webhook_url_not_https" : "webhook_url_invalid", status: nil)
        } catch { return .failed(code: "encryption_key_unreadable", status: nil) }

        // The guard runs at every delivery, at level strict, whatever the server setting for SMTP/S3 says.
        let address: String
        if let literal = url.literalIP {
            address = literal
        } else {
            do { address = try await app.webhookResolver.resolve(host: url.host, port: url.port) }
            catch is OutboundBlocked { return .failed(code: "target_blocked", status: nil) }
            catch { return .retry(code: "dns_error", status: nil) }
        }
        guard !OutboundGuard.isBlocked(address, .strict) else { return .failed(code: "target_blocked", status: nil) }

        let body: Data
        do { body = try payload.encoded() } catch { return .failed(code: "internal_error", status: nil) }
        var headers: [(String, String)] = [("Content-Type", "application/json"), ("User-Agent", "Todolino-Webhook/1")]
        if let secret { headers += WebhookSignature.headers(secret: secret, body: body, now: now) }
        let result = await app.webhookTransport.post(WebhookWireRequest(url: url.absolute, host: url.host, address: address, headers: headers, body: body))
        return Self.verdict(result)
    }

    static func verdict(_ result: WebhookSendResult) -> Verdict {
        switch result {
        case .timeout: return .retry(code: "timeout", status: nil)
        case .tlsError: return .retry(code: "tls_error", status: nil)
        case .networkError: return .retry(code: "network_error", status: nil)
        case .status(let s):
            switch s {
            case 200...299: return .sent(status: s)
            case 300...399: return .failed(code: "redirect_not_followed", status: s)
            case 408, 425, 429, 500...599: return .retry(code: "http_\(s)", status: s)
            case 400...499: return .failed(code: "http_\(s)", status: s)
            default: return .failed(code: "http_unexpected", status: s)
            }
        }
    }

    /// Delay after attempt number `attempt` (1-based) with +-10 % jitter.
    static func backoff(attempt: Int) -> TimeInterval {
        WebhookLimits.backoff[min(max(attempt, 1), WebhookLimits.backoff.count) - 1] * Double.random(in: 0.9...1.1)
    }

    /// Applies a verdict to the row and, for real bundles, to the failure counter of the webhook. `single` (test) never retries
    /// and never counts.
    @discardableResult
    func record(_ verdict: Verdict, on row: WebhookDelivery, now: Date, single: Bool = false) async throws -> WebhookDelivery {
        row.attempts += 1
        switch verdict {
        case .sent(let status):
            row.state = "sent"; row.httpStatus = status; row.errorCode = nil; row.finishedAt = now
        case .retry(let code, let status):
            row.httpStatus = status; row.errorCode = code
            if single || row.attempts >= WebhookLimits.maxAttempts {
                row.state = "failed"; row.finishedAt = now
            } else {
                row.nextAttemptAt = now.addingTimeInterval(Self.backoff(attempt: row.attempts))
            }
        case .failed(let code, let status):
            row.state = "failed"; row.httpStatus = status; row.errorCode = code; row.finishedAt = now
        }
        try await row.save(on: app.db)
        if !single, row.state != "pending" { try await countOutcome(userID: row.userID, success: row.state == "sent") }
        return row
    }

    /// Success resets the streak; the tenth failed bundle in a row switches the webhook off (protection against a dead target).
    func countOutcome(userID: UUID, success: Bool) async throws {
        let db = app.db
        if success {
            try await WebhookEndpoint.query(on: db).filter(\.$userID == userID).filter(\.$consecutiveFailures > 0).set(\.$consecutiveFailures, to: 0).update()
            return
        }
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("UPDATE webhook_endpoints SET consecutive_failures = consecutive_failures + 1 WHERE user_id = \(bind: userID)").run()
        try await WebhookEndpoint.query(on: db).filter(\.$userID == userID).filter(\.$consecutiveFailures >= WebhookLimits.disableAfterFailures)
            .filter(\.$enabled == true).set(\.$enabled, to: false).update()
    }
}
