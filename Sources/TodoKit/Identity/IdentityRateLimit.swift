import Fluent
import SQLKit
import Vapor

/// Fixed windows, serialized only per hashed subject and window by the unique row key.
/// Counts attempts, including successful and malformed requests. No forwarded headers are trusted.
enum IdentityRateLimit {
    static func take(scope: String, subject: String, limit: Int, window: Int, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { throw Abort(.serviceUnavailable) }
        let now: Int64
        if sql.dialect.name == "sqlite" {
            now = try await sql.raw("SELECT CAST(strftime('%s', 'now') AS INTEGER) AS t").first()!.decode(column: "t", as: Int64.self)
        } else {
            now = try await sql.raw("SELECT UNIX_TIMESTAMP() AS t").first()!.decode(column: "t", as: Int64.self)
        }
        let width = Int64(max(1, window))
        let end = (now / width + 1) * width
        let key = AuthSupport.hash("\(scope):\(subject):\(now / width)")
        return try await db.transaction { tx in
            let sql = tx as! any SQLDatabase
            if sql.dialect.name == "sqlite" {
                try await sql.raw("INSERT INTO identity_rate_limits (id, attempts, expires_at) VALUES (\(bind: key), 1, \(bind: end)) ON CONFLICT(id) DO UPDATE SET attempts = attempts + 1").run()
            } else {
                try await sql.raw("INSERT INTO identity_rate_limits (id, attempts, expires_at) VALUES (\(bind: key), 1, \(bind: end)) ON DUPLICATE KEY UPDATE attempts = attempts + 1").run()
            }
            let count = try await sql.raw("SELECT attempts FROM identity_rate_limits WHERE id = \(bind: key)").first()!.decode(column: "attempts", as: Int.self)
            return count <= limit
        }
    }
}

struct IdentityRateMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let s = req.application.identitySettings
        let scope: String
        let limit: Int
        switch req.url.path {
        case "/v1/auth/login/begin", "/v1/auth/login/finish": scope = "login"; limit = s.loginLimit
        case "/v1/auth/password/login": scope = "password"; limit = s.passwordLimit
        case "/v1/auth/register/begin": scope = "register"; limit = s.registerLimit
        case "/v1/identity/recovery/redeem", "/v1/identity/recovery/passkeys/begin", "/v1/identity/recovery/passkeys/finish": scope = "recovery"; limit = s.recoveryLimit
        default: return try await next.respond(to: req)
        }
        guard req.method == .POST else { return try await next.respond(to: req) }
        let peer = req.remoteAddress?.ipAddress ?? "unknown"
        var allowed = try await IdentityRateLimit.take(scope: scope, subject: "ip:\(peer)", limit: limit, window: s.window, on: req.db)
        // A second bucket prevents distributing guesses for one account/code across replicas and IPs.
        let field = scope == "password" ? "username" : "code"
        if allowed, ["password", "recovery"].contains(scope),
           let body = try? req.content.decode([String: String].self), let value = body[field] {
            let accountAllowed = try await IdentityRateLimit.take(scope: scope, subject: "subject:\(scope == "password" ? value.lowercased() : value)", limit: limit, window: s.window, on: req.db)
            allowed = allowed && accountAllowed
        }
        guard allowed else {
            var headers = HTTPHeaders()
            headers.add(name: "Retry-After", value: String(s.window))
            throw Abort(.tooManyRequests, headers: headers, reason: "identity_rate_limited")
        }
        return try await next.respond(to: req)
    }
}
