import Crypto
import Fluent
import Vapor
import WebAuthn

enum AuthSupport {
    static func randomToken(bytes: Int = 32) -> String {
        [UInt8]((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString().asString()
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    static let cookieName = "todo_session"
}

struct SessionResponse: Content {
    let token: String
    let expiresAt: Date
    let user: UserDTO
}

struct UserDTO: Content {
    let id: UUID
    let displayName: String
    let isAdmin: Bool
    let username: String?

    init(_ user: User) throws {
        id = try user.requireID()
        displayName = user.displayName
        isAdmin = user.isAdmin
        username = user.username
    }
}

extension Request {
    /// Issues a session; the raw token is only returned here, the database keeps its hash.
    func startSession(for user: User, on db: any Database) async throws -> Response {
        let token = AuthSupport.randomToken()
        let expires = Date().addingTimeInterval(application.settings.sessionLifetime)
        try await UserSession(userID: try user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: expires)
            .save(on: db)
        let body = SessionResponse(token: token, expiresAt: expires, user: try UserDTO(user))
        let response = try await body.encodeResponse(for: self)
        response.cookies[AuthSupport.cookieName] = sessionCookie(token, expires: expires)
        return response
    }

    fileprivate func sessionCookie(_ token: String, expires: Date) -> HTTPCookies.Value {
        HTTPCookies.Value(string: token, expires: expires, maxAge: nil, domain: nil, path: "/",
                          isSecure: application.settings.secureCookies, isHTTPOnly: true, sameSite: .strict)
    }

    /// ADR 0040: a session ends after `sessionLifetime` without use. A use moves the end, at most once a day (one write per
    /// session and day). The update goes by primary key, so a session that was ended meanwhile is never written back. A write
    /// that fails (database busy) leaves request and cookie as they are; the next request tries again.
    private func renew(_ session: UserSession, presented token: String, viaCookie: Bool) async throws {
        let lifetime = application.settings.sessionLifetime
        guard session.expiresAt.timeIntervalSinceNow < lifetime - 86_400 else { return }
        let expires = Date().addingTimeInterval(lifetime)
        do {
            try await UserSession.query(on: db).filter(\.$id == session.requireID()).set(\.$expiresAt, to: expires).update()
        } catch {
            logger.warning("session.renewal_failed", metadata: ["error": .string(String(reflecting: type(of: error)))])
            return
        }
        if viaCookie { storage[RenewedSessionCookie.self] = sessionCookie(token, expires: expires) }
    }

    private var presentedToken: (token: String, viaCookie: Bool)? {
        if let bearer = headers.bearerAuthorization { return (bearer.token, false) }
        if let cookie = cookies[AuthSupport.cookieName]?.string { return (cookie, true) }
        return nil
    }

    /// Resolves the session user or throws 401. Cookie-authenticated unsafe requests must pass the CSRF check.
    /// `renewing: false` for long polls: their late answer could put an old cookie over the one of a newer sign-in.
    func requireUser(renewing: Bool = true) async throws -> User {
        guard let presented = presentedToken else { throw Abort(.unauthorized) }
        if presented.viaCookie, ![.GET, .HEAD, .OPTIONS].contains(method) {
            try checkSameOrigin()
        }
        guard let session = try await UserSession.query(on: db)
            .filter(\.$tokenHash == AuthSupport.hash(presented.token)).first(),
            session.expiresAt > Date(),
            let user = try await User.find(session.$user.id, on: db)
        else { throw Abort(.unauthorized) }
        if user.isLocked { throw Abort(.unauthorized, reason: "account_disabled") }
        if renewing { try await renew(session, presented: presented.token, viaCookie: presented.viaCookie) }
        // Person session verified: from here on the database handles of this request may wake the outgoing webhook (ADR 0035).
        WebhookAgentContext.markPersonSession(self, userID: try user.requireID())
        return user
    }

    func requireAdmin() async throws -> User {
        let user = try await requireUser()
        guard user.isAdmin else { throw Abort(.forbidden) }
        return user
    }

    func checkSameOrigin() throws {
        guard headers.contentType == .json else { throw Abort(.unsupportedMediaType, reason: "json_required") }
        if let origin = headers.first(name: .origin), origin != application.settings.relyingPartyOrigin {
            throw Abort(.forbidden, reason: "origin_not_allowed")
        }
    }

    var sessionTokenPresented: String? { presentedToken?.token }

    /// True when the session is presented by cookie only (browser), i.e. the request needs the CSRF check.
    var sessionPresentedByCookieOnly: Bool { presentedToken?.viaCookie == true }
}

private struct RenewedSessionCookie: StorageKey { typealias Value = HTTPCookies.Value }

/// ADR 0040: the browser keeps its cookie as long as the renewed session. A response that sets the session cookie itself
/// (sign-in, sign-out) is left as it is.
struct SessionCookieRenewalMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        if let cookie = request.storage[RenewedSessionCookie.self], response.cookies[AuthSupport.cookieName] == nil {
            response.cookies[AuthSupport.cookieName] = cookie
        }
        return response
    }
}
