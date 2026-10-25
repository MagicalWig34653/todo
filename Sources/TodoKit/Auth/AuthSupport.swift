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
        response.cookies[AuthSupport.cookieName] = HTTPCookies.Value(
            string: token, expires: expires, maxAge: nil, domain: nil, path: "/",
            isSecure: application.settings.secureCookies, isHTTPOnly: true, sameSite: .strict)
        return response
    }

    private var presentedToken: (token: String, viaCookie: Bool)? {
        if let bearer = headers.bearerAuthorization { return (bearer.token, false) }
        if let cookie = cookies[AuthSupport.cookieName]?.string { return (cookie, true) }
        return nil
    }

    /// Resolves the session user or throws 401. Cookie-authenticated unsafe requests must pass the CSRF check.
    func requireUser() async throws -> User {
        guard let presented = presentedToken else { throw Abort(.unauthorized) }
        if presented.viaCookie, ![.GET, .HEAD, .OPTIONS].contains(method) {
            try checkSameOrigin()
        }
        guard let session = try await UserSession.query(on: db)
            .filter(\.$tokenHash == AuthSupport.hash(presented.token)).first(),
            session.expiresAt > Date(),
            let user = try await User.find(session.$user.id, on: db)
        else { throw Abort(.unauthorized) }
        return user
    }

    func requireAdmin() async throws -> User {
        let user = try await requireUser()
        guard user.isAdmin else { throw Abort(.forbidden) }
        return user
    }

    private func checkSameOrigin() throws {
        guard headers.contentType == .json else { throw Abort(.unsupportedMediaType, reason: "json_required") }
        if let origin = headers.first(name: .origin), origin != application.settings.relyingPartyOrigin {
            throw Abort(.forbidden, reason: "origin_not_allowed")
        }
    }

    var sessionTokenPresented: String? { presentedToken?.token }
}
