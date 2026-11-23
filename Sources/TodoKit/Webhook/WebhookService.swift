import Fluent
import SQLKit
import Vapor

// MARK: - DTOs (no field ever carries the URL, the host path or the signing secret)

struct WebhookDeliveryDTO: Content, Equatable {
    let id: UUID
    /// `person_action` | `test`
    let event: String
    /// `pending` | `sent` | `failed`
    let state: String
    let attempts: Int
    let httpStatus: Int?
    /// Short machine code (`timeout`, `http_500`, `target_blocked`, ...); never a host, address or response text.
    let errorCode: String?
    let anzahl: Int
    let kinds: [String]
    let createdAt: Date
    let finishedAt: Date?
    /// Only while pending: when the next attempt is due.
    let nextAttemptAt: Date?

    init(_ d: WebhookDelivery) throws {
        id = try d.requireID(); event = d.event; state = d.state; attempts = d.attempts; httpStatus = d.httpStatus; errorCode = d.errorCode
        anzahl = d.anzahl; kinds = WebhookKinds.kinds(d.kindsMask); createdAt = d.createdAt; finishedAt = d.finishedAt
        nextAttemptAt = d.state == "pending" ? d.nextAttemptAt : nil
    }
}

struct WebhookDeliveriesResponse: Content { let items: [WebhookDeliveryDTO] }

struct WebhookSettingsDTO: Content {
    let configured: Bool
    /// `https://host/…`: scheme and host only, path and query never.
    let maskedURL: String?
    let enabled: Bool
    let signingConfigured: Bool
    let excludedProjectIDs: [UUID]
    /// Failed bundles in a row; at 10 the server switches the webhook off (`enabled` false).
    let consecutiveFailures: Int
    let lastDelivery: WebhookDeliveryDTO?
}

/// `url` and `signingSecret`: absent = unchanged, `null` = delete, string = set. Hence the manual decoding.
struct WebhookUpdateRequest: Decodable {
    enum Change<T: Sendable>: Sendable { case keep, clear, set(T) }
    var url: Change<String> = .keep
    var signingSecret: Change<String> = .keep
    var enabled: Bool?
    var excludedProjectIDs: [UUID]?

    private enum Keys: String, CodingKey { case url, signingSecret, enabled, excludedProjectIDs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func change(_ key: Keys) throws -> Change<String> {
            guard c.contains(key) else { return .keep }
            if try c.decodeNil(forKey: key) { return .clear }
            return .set(try c.decode(String.self, forKey: key))
        }
        url = try change(.url); signingSecret = try change(.signingSecret)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        excludedProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .excludedProjectIDs)
    }
}

// MARK: - Service

/// Settings of the webhook of one person. Only reachable with a person session (the controller uses `requireUser`); MCP has
/// no tool for it (ADR 0035, item 1).
struct WebhookService: Sendable {
    let app: Application
    let user: User
    var db: any Database { app.db }

    func settings() async throws -> WebhookSettingsDTO {
        let userID = try user.requireID()
        let endpoint = try await WebhookEndpoint.query(on: db).filter(\.$userID == userID).first()
        let excluded = try await WebhookExclusion.query(on: db).filter(\.$userID == userID).all().map(\.projectID)
            .sorted { $0.uuidString < $1.uuidString }
        let last = try await WebhookDelivery.query(on: db).filter(\.$userID == userID).sort(\.$createdAt, .descending).sort(\.$id, .descending).first()
        return WebhookSettingsDTO(
            configured: endpoint != nil, maskedURL: endpoint.map { $0.urlMask + "/…" }, enabled: endpoint?.enabled ?? false,
            signingConfigured: endpoint?.signingCiphertext != nil, excludedProjectIDs: excluded,
            consecutiveFailures: endpoint?.consecutiveFailures ?? 0, lastDelivery: try last.map(WebhookDeliveryDTO.init))
    }

    /// Checks the target at save time: https, no credentials, literal IPs and the resolved address at level strict.
    func validate(_ url: WebhookURL) async throws {
        if let literal = url.literalIP {
            guard !OutboundGuard.isBlocked(literal, .strict) else { throw Abort(.badRequest, reason: "webhook_url_blocked") }
            return
        }
        let address: String
        do { address = try await app.webhookResolver.resolve(host: url.host, port: url.port) }
        catch is OutboundBlocked { throw Abort(.badRequest, reason: "webhook_url_blocked") }
        catch { throw Abort(.badRequest, reason: "webhook_url_invalid") }
        guard !OutboundGuard.isBlocked(address, .strict) else { throw Abort(.badRequest, reason: "webhook_url_blocked") }
    }

    func update(_ request: WebhookUpdateRequest) async throws -> WebhookSettingsDTO {
        let userID = try user.requireID()
        if case .clear = request.url { try await remove(); return try await settings() }
        // Validate everything before anything is written.
        let newURL: WebhookURL?
        if case .set(let raw) = request.url {
            let parsed = try WebhookURL.parse(raw)
            try await validate(parsed)
            newURL = parsed
        } else { newURL = nil }
        let newSecret: String?
        if case .set(let secret) = request.signingSecret {
            guard (WebhookLimits.minSecret...WebhookLimits.maxSecret).contains(secret.utf8.count) else { throw Abort(.badRequest, reason: "webhook_signing_secret_invalid") }
            newSecret = secret
        } else { newSecret = nil }
        let projects: [UUID]?
        if let ids = request.excludedProjectIDs {
            let unique = Array(Set(ids))
            guard unique.count <= WebhookLimits.maxExclusions else { throw Abort(.badRequest, reason: "webhook_exclusions_invalid") }
            let access = ProjectAccess(user: user, db: db)
            // Same answer as everywhere in the project API: unknown and foreign projects are both 404.
            for id in unique { _ = try await access.project(id) }
            projects = unique
        } else { projects = nil }
        let ring = try app.requireSettingsRuntime().keyRing
        let sealedURL = try newURL.map { try ring.sealWebhook($0.absolute, userID: userID, field: .url) }
        let sealedSecret = try newSecret.map { try ring.sealWebhook($0, userID: userID, field: .signing) }

        try await db.transaction { tx in
            try await lockRow(table: User.schema, id: userID, on: tx)
            var endpoint = try await WebhookEndpoint.query(on: tx).filter(\.$userID == userID).first()
            let now = Date()
            if endpoint == nil {
                guard let sealedURL, let newURL else { throw Abort(.conflict, reason: "webhook_not_configured") }
                let e = WebhookEndpoint()
                e.userID = userID; e.urlCiphertext = sealedURL.blob; e.keyID = sealedURL.keyID; e.urlMask = newURL.mask
                e.enabled = request.enabled ?? true; e.consecutiveFailures = 0; e.createdAt = now; e.updatedAt = now
                try await e.create(on: tx)
                endpoint = e
            } else if let e = endpoint {
                if let sealedURL, let newURL { e.urlCiphertext = sealedURL.blob; e.keyID = sealedURL.keyID; e.urlMask = newURL.mask; e.consecutiveFailures = 0 }
                if let enabled = request.enabled {
                    if enabled && !e.enabled { e.consecutiveFailures = 0 }
                    e.enabled = enabled
                }
                e.updatedAt = now
                try await e.save(on: tx)
            }
            guard let e = endpoint else { return }
            switch request.signingSecret {
            case .keep: break
            case .clear: e.signingCiphertext = nil; e.signingKeyID = nil; try await e.save(on: tx)
            case .set: if let sealedSecret { e.signingCiphertext = sealedSecret.blob; e.signingKeyID = sealedSecret.keyID; try await e.save(on: tx) }
            }
            if let projects {
                try await WebhookExclusion.query(on: tx).filter(\.$userID == userID).delete()
                for id in projects.sorted(by: { $0.uuidString < $1.uuidString }) { try await WebhookExclusion(userID: userID, projectID: id).create(on: tx) }
            }
        }
        return try await settings()
    }

    /// Removes the ciphertext, the exclusions and the log of the person.
    func remove() async throws {
        let userID = try user.requireID()
        try await db.transaction { tx in
            try await lockRow(table: User.schema, id: userID, on: tx)
            try await WebhookDelivery.query(on: tx).filter(\.$userID == userID).delete()
            try await WebhookExclusion.query(on: tx).filter(\.$userID == userID).delete()
            try await WebhookEndpoint.query(on: tx).filter(\.$userID == userID).delete()
        }
    }

    func deliveries() async throws -> WebhookDeliveriesResponse {
        let userID = try user.requireID()
        let rows = try await WebhookDelivery.query(on: db).filter(\.$userID == userID)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(WebhookLimits.listLimit).all()
        return WebhookDeliveriesResponse(items: try rows.map(WebhookDeliveryDTO.init))
    }

    /// Sends the test payload once, right now (no bundle, no retries) and writes the result to the log. At most one test per
    /// ten seconds and person. A test never changes the failure counter.
    func sendTest() async throws -> WebhookDeliveryDTO {
        let userID = try user.requireID()
        guard let endpoint = try await WebhookEndpoint.query(on: db).filter(\.$userID == userID).first() else {
            throw Abort(.conflict, reason: "webhook_not_configured")
        }
        let recent = try await WebhookDelivery.query(on: db).filter(\.$userID == userID).filter(\.$event == "test")
            .filter(\.$createdAt > Date().addingTimeInterval(-Double(WebhookLimits.testInterval))).count()
        var limited = recent > 0
        if !limited {
            limited = !(try await IdentityRateLimit.take(scope: "webhook-test", subject: "user:\(userID)", limit: 1, window: WebhookLimits.testInterval, on: db))
        }
        if limited {
            var headers = HTTPHeaders()
            headers.add(name: "Retry-After", value: String(WebhookLimits.testInterval))
            throw Abort(.tooManyRequests, headers: headers, reason: "rate_limited")
        }
        let now = Date()
        let row = WebhookDelivery(userID: userID, event: "test", anzahl: 0, kindsMask: 0, due: now, open: false, now: now)
        try await row.create(on: db)
        let deliverer = WebhookDeliverer(app: app)
        let verdict = await deliverer.attempt(endpoint: endpoint, payload: .test, now: now)
        try await deliverer.record(verdict, on: row, now: Date(), single: true)
        return try WebhookDeliveryDTO(row)
    }
}

// MARK: - Controller

struct WebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let w = routes.grouped("v1", "settings", "webhook")
        w.get(use: get)
        w.put(use: put)
        w.delete(use: remove)
        w.post("test", use: test)
        w.get("deliveries", use: deliveries)
    }

    // `requireUser` accepts person sessions only: OAuth access tokens (MCP connections) are 401 here.
    private func service(_ req: Request) async throws -> WebhookService { WebhookService(app: req.application, user: try await req.requireUser()) }

    @Sendable func get(_ req: Request) async throws -> WebhookSettingsDTO { try await service(req).settings() }
    @Sendable func put(_ req: Request) async throws -> WebhookSettingsDTO {
        let service = try await service(req)
        return try await service.update(req.content.decode(WebhookUpdateRequest.self))
    }
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        try await service(req).remove()
        return .noContent
    }
    @Sendable func test(_ req: Request) async throws -> WebhookDeliveryDTO { try await service(req).sendTest() }
    @Sendable func deliveries(_ req: Request) async throws -> WebhookDeliveriesResponse { try await service(req).deliveries() }
}
