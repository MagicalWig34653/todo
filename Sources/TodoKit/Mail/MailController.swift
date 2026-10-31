import Fluent
import Vapor

/// Account e-mail address (double opt-in) and the mail test. Contract: contracts/mail.yaml, ADR 0024.
struct MailController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let me = routes.grouped("v1", "me", "email")
        me.get(use: status)
        me.post(use: set)
        me.put(use: set)
        me.delete(use: remove)
        me.post("test", use: test)
        // Public: possession of the mailed single-use token is the credential.
        routes.post("v1", "email", "confirm", use: confirm)
    }

    private func service(_ req: Request) -> MailService { MailService(db: req.db, settings: req.application.settings) }

    private func limited(_ req: Request, scope: String, subject: String, limit: Int, window: Int) async throws {
        guard try await IdentityRateLimit.take(scope: scope, subject: subject, limit: limit, window: window, on: req.db) else {
            var headers = HTTPHeaders()
            headers.add(name: "Retry-After", value: String(window))
            throw Abort(.tooManyRequests, headers: headers, reason: "mail_rate_limited")
        }
    }

    @Sendable func status(_ req: Request) async throws -> EmailStatusDTO {
        try await service(req).status(for: req.requireUser().requireID())
    }

    @Sendable func set(_ req: Request) async throws -> Response {
        let userID = try await req.requireUser().requireID()
        guard req.application.settings.mail.enabled else { throw Abort(.conflict, reason: "mail_disabled") }
        let address = MailAddress.normalize(try req.content.decode(SetEmailRequest.self).email)
        guard MailAddress.isValid(address) else { throw Abort(.badRequest, reason: "invalid_email") }
        try await limited(req, scope: "mail-verify", subject: "user:\(userID)", limit: 3, window: 600)
        try await limited(req, scope: "mail-verify", subject: "ip:\(req.remoteAddress?.ipAddress ?? "unknown")", limit: 20, window: 600)
        let result = try await service(req).requestVerification(userID: userID, address: address)
        return try await result.encodeResponse(status: .accepted, for: req)
    }

    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        try await service(req).remove(userID: req.requireUser().requireID())
        return .noContent
    }

    @Sendable func test(_ req: Request) async throws -> Response {
        let userID = try await req.requireUser().requireID()
        guard req.application.settings.mail.enabled else { throw Abort(.conflict, reason: "mail_disabled") }
        let service = service(req)
        guard let address = try await service.confirmedEmail(of: userID) else { throw Abort(.conflict, reason: "no_verified_email") }
        try await limited(req, scope: "mail-test", subject: "user:\(userID)", limit: 1, window: 60)
        let now = Date()
        try await service.enqueue(kind: MailKind.test, to: address.email, userID: userID, payload: MailPayload(),
                                  dedupeKey: "test:\(UUID().uuidString)", expiresAt: now.addingTimeInterval(3600), now: now)
        return try await EmailTestDTO(status: "queued").encodeResponse(status: .accepted, for: req)
    }

    @Sendable func confirm(_ req: Request) async throws -> HTTPStatus {
        try await limited(req, scope: "mail-confirm", subject: "ip:\(req.remoteAddress?.ipAddress ?? "unknown")", limit: 10, window: 60)
        let body = try req.content.decode(ConfirmEmailRequest.self)
        try await service(req).confirm(token: body.token.trimmingCharacters(in: .whitespacesAndNewlines))
        return .noContent
    }
}
