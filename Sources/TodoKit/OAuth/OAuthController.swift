import Crypto
import Fluent
import Vapor

struct OAuthController: RouteCollection {
    static let scopes = ["projects:read", "projects:write", "tasks:read", "tasks:write", "comments:write", "attachments:read", "attachments:write", "agents:read", "labels:read", "labels:write", "filters:read", "filters:write", "sharing:read", "sharing:write", "teams:read", "teams:write", "account:read", "account:write", "admin:read", "runs:read", "runs:write"]
    // The issuer comes from AppSettings.oauthIssuer (OAUTH_ISSUER, else RP_ORIGIN); never from an untrusted Host or forwarded header.

    func boot(routes: any RoutesBuilder) throws {
        let routes = routes.grouped(OAuthResponseMiddleware())
        routes.get(".well-known", "oauth-authorization-server", use: metadata)
        routes.get(".well-known", "oauth-protected-resource", "mcp", use: resourceMetadata)
        routes.get(".well-known", "oauth-protected-resource", use: resourceMetadata)
        routes.post("oauth", "register", use: register)
        routes.get("oauth", "authorize", use: authorize)
        routes.post("oauth", "consent", use: consent)
        routes.post("oauth", "token", use: token)
        routes.get("oauth", "grants", use: grants)
        routes.delete("oauth", "grants", ":id", use: revoke)
        routes.put("oauth", "grants", ":id", "projects", use: setGrantProjects)
        try routes.register(collection: MCPController())
    }

    @Sendable func metadata(_ req: Request) -> [String: JSONValue] {
        ["issuer": .string(req.application.settings.oauthIssuer), "authorization_endpoint": .string(req.application.settings.oauthIssuer + "/oauth/authorize"),
         "token_endpoint": .string(req.application.settings.oauthIssuer + "/oauth/token"), "registration_endpoint": .string(req.application.settings.oauthIssuer + "/oauth/register"),
         "response_types_supported": .strings(["code"]), "grant_types_supported": .strings(["authorization_code", "refresh_token"]),
         "token_endpoint_auth_methods_supported": .strings(["none"]), "code_challenge_methods_supported": .strings(["S256"]),
         "scopes_supported": .strings(Self.scopes), "authorization_response_iss_parameter_supported": .bool(true),
         "client_id_metadata_document_supported": .bool(false)]
    }
    @Sendable func resourceMetadata(_ req: Request) -> [String: JSONValue] {
        ["resource": .string(req.application.settings.oauthResource), "authorization_servers": .strings([req.application.settings.oauthIssuer]),
         "scopes_supported": .strings(Self.scopes), "bearer_methods_supported": .strings(["header"])]
    }
    struct Registration: Content {
        var client_name: String?
        var redirect_uris: [String]
        var token_endpoint_auth_method: String?
        var grant_types: [String]?
        var response_types: [String]?
    }
    @Sendable func register(_ req: Request) async throws -> Response {
        let b = try req.content.decode(Registration.self)
        guard !b.redirect_uris.isEmpty, b.redirect_uris.count <= 10,
              b.redirect_uris.allSatisfy({ $0.count <= 2000 && Self.validRedirect($0) }), (b.client_name?.count ?? 0) <= 200,
              b.token_endpoint_auth_method == nil || b.token_endpoint_auth_method == "none",
              Set(b.grant_types ?? ["authorization_code", "refresh_token"]).isSubset(of: ["authorization_code", "refresh_token"]),
              b.response_types == nil || b.response_types == ["code"] else { throw Abort(.badRequest, reason: "invalid_client_metadata") }
        let c = OAuthClient(name: b.client_name ?? "MCP Client", redirects: b.redirect_uris)
        try await c.save(on: req.db)
        return try await JSONValue.object(["client_id": .string(try c.requireID().uuidString),
            "client_name": .string(c.name), "redirect_uris": .strings(c.redirects), "token_endpoint_auth_method": .string("none"),
            "grant_types": .strings(["authorization_code", "refresh_token"]), "response_types": .strings(["code"])])
            .encodeResponse(status: .created, for: req)
    }
    static func validRedirect(_ raw: String) -> Bool {
        guard let u = URLComponents(string: raw), u.fragment == nil, u.user == nil, u.password == nil, let host = u.host else { return false }
        return u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host))
    }
    struct Authorization: Content {
        var response_type: String
        var client_id: UUID
        var redirect_uri: String
        var scope: String?
        var state: String?
        var resource: String?
        var code_challenge: String
        var code_challenge_method: String
    }
    /// Only the authorization endpoint of this origin may be a post-login return target (no open redirect).
    /// `next` must be `/oauth/authorize` or `/oauth/authorize?<query>` in printable ASCII without backslashes.
    static func isSafeAuthorizeNext(_ next: String) -> Bool {
        guard next.utf8.count <= 4000, next.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f && $0 != UInt8(ascii: "\\") }) else { return false }
        return next == "/oauth/authorize" || next.hasPrefix("/oauth/authorize?")
    }
    /// `/login?next=<percent-encoded authorize URL>`; the query is kept byte for byte. Nil if the target is not acceptable.
    static func loginRedirect(forAuthorizeQuery query: String) -> String? {
        let next = "/oauth/authorize" + query
        guard isSafeAuthorizeNext(next) else { return nil }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        guard let encoded = next.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "/login?next=" + encoded
    }
    /// Query item with a strictly percent-encoded value: URLComponents leaves "+" and "&" alone, which clients would decode as space.
    static func encodedItem(_ name: String, _ value: String) -> URLQueryItem {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }
    struct Pending: Codable { var userID: UUID; var request: Authorization }
    static func pack<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    /// Browsers (Accept: text/html) get the consent page; it talks to the JSON contract below.
    @Sendable func authorize(_ req: Request) async throws -> Response {
        if req.headers.first(name: .accept)?.contains("text/html") == true {
            // Not signed in: send the browser to the PWA login and come back to exactly this request afterwards.
            if (try? await req.requireUser()) == nil {
                let query = req.url.query.map { "?" + $0 } ?? ""
                if let location = Self.loginRedirect(forAuthorizeQuery: query) { return req.redirect(to: location, redirectType: .normal) }
            }
            let response = Response(status: .ok, body: .init(string: ConsentPage.html))
            response.headers.contentType = .html
            response.headers.replaceOrAdd(name: "Content-Security-Policy", value: ConsentPage.csp)
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
            return response
        }
        return try await authorizeJSON(req).encodeResponse(for: req)
    }
    func authorizeJSON(_ req: Request) async throws -> JSONValue {
        let user = try await req.requireUser()
        var b = try req.query.decode(Authorization.self)
        // RFC 8707: clients should send `resource`; an absent value can only mean this server's single resource.
        if b.resource == nil { b.resource = req.application.settings.oauthResource }
        // No scope requested: offer everything this server supports; the user still decides in the consent step.
        let scope = (b.scope?.isEmpty == false ? b.scope! : Self.scopes.joined(separator: " "))
        b.scope = scope
        guard b.response_type == "code", b.resource == req.application.settings.oauthResource, b.code_challenge_method == "S256",
              b.code_challenge.count == 43, b.code_challenge.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              Set(scope.split(separator: " ").map(String.init)).isSubset(of: Set(Self.scopes)),
              let c = try await OAuthClient.find(b.client_id, on: req.db), c.redirects.contains(b.redirect_uri)
        else { throw Abort(.badRequest, reason: "invalid_request") }
        let raw = AuthSupport.randomToken()
        try await OAuthSecret(raw: raw, kind: "consent", payload: Self.pack(Pending(userID: try user.requireID(), request: b)), lifetime: 300).save(on: req.db)
        let projects = try await Project.query(on: req.db).filter(\.$ownerID == user.requireID()).all()
        return .object(["consent_token": .string(raw), "client_name": .string(c.name), "client_id": .string(b.client_id.uuidString),
            "redirect_uri": .string(b.redirect_uri), "scopes": .strings(scope.split(separator: " ").map(String.init)),
            "projects": try .encoded(projects.map(ProjectDTO.init))])
    }
    struct Consent: Content { var consent_token: String; var project_ids: [UUID]; var approve: Bool }
    @Sendable func consent(_ req: Request) async throws -> JSONValue {
        let user = try await req.requireUser()
        let b = try req.content.decode(Consent.self)
        // Look the row up before the transaction: MariaDB's snapshot isolation fails a locking read that follows
        // a plain read in the same transaction when the row changed in between ("Record has changed since last read").
        guard let found = try await OAuthSecret.query(on: req.db).filter(\.$hash == AuthSupport.hash(b.consent_token)).first() else { throw Abort(.badRequest) }
        return try await req.db.transaction { db in
            try await lockRow(table: OAuthSecret.schema, id: found.requireID(), on: db)
            guard let s = try await OAuthSecret.find(found.id, on: db), s.kind == "consent", !s.consumed, s.expiresAt > Date() else { throw Abort(.badRequest) }
            let pending = try JSONDecoder().decode(Pending.self, from: Data(s.payload.utf8))
            guard pending.userID == user.id else { throw Abort(.notFound) }
            let a = pending.request
            var url = URLComponents(string: a.redirect_uri)!
            var items = url.percentEncodedQueryItems ?? []
            if let state = a.state { items.append(Self.encodedItem("state", state)) }
            items.append(Self.encodedItem("iss", req.application.settings.oauthIssuer)) // RFC 9207
            if b.approve {
                // A grant that may create projects (projects:write) can start without existing projects: create_project extends it.
                let mayCreateProjects = (a.scope ?? "").split(separator: " ").contains("projects:write")
                guard !b.project_ids.isEmpty || mayCreateProjects else { throw Abort(.badRequest, reason: "projects_required") }
                for id in b.project_ids { _ = try await ProjectAccess(user: user, db: db).project(id) }
                let g = OAuthGrant(userID: try user.requireID(), clientID: a.client_id, resource: req.application.settings.oauthResource,
                                   scopes: (a.scope ?? "").split(separator: " ").map(String.init), projects: Array(Set(b.project_ids)))
                try await g.save(on: db)
                let code = AuthSupport.randomToken()
                try await OAuthSecret(raw: code, kind: "code", grantID: g.requireID(), payload: Self.pack(a), lifetime: 120).save(on: db)
                items.append(Self.encodedItem("code", code))
            } else { items.append(Self.encodedItem("error", "access_denied")) }
            s.consumed = true; try await s.save(on: db)
            url.percentEncodedQueryItems = items
            return .object(["redirect_uri": .string(url.string!)])
        }
    }
    struct TokenRequest: Content {
        var grant_type: String; var client_id: UUID; var resource: String?
        var code: String?; var redirect_uri: String?; var code_verifier: String?; var refresh_token: String?; var scope: String?
    }
    @Sendable func token(_ req: Request) async throws -> Response {
        var decoded = try req.content.decode(TokenRequest.self)
        if decoded.resource == nil { decoded.resource = req.application.settings.oauthResource }
        let b = decoded
        guard ["authorization_code", "refresh_token"].contains(b.grant_type), b.resource == req.application.settings.oauthResource,
              let raw = b.grant_type == "authorization_code" ? b.code : b.refresh_token else { return try await tokenError(req) }
        // Return errors after committing: throwing inside this transaction would undo reuse revocation.
        // Plain lookup first, then lock before the transaction's first read (see consent()).
        guard let found = try await OAuthSecret.query(on: req.db).filter(\.$hash == AuthSupport.hash(raw)).first(),
              let gid = found.grantID else { return try await tokenError(req) }
        let result: JSONValue? = try await req.db.transaction { db in
            try await lockRow(table: OAuthGrant.schema, id: gid, on: db)
            guard let s = try await OAuthSecret.find(found.id, on: db),
                  let g = try await OAuthGrant.find(gid, on: db), !g.revoked,
                  g.clientID == b.client_id, g.resource == b.resource,
                  s.kind == (b.grant_type == "authorization_code" ? "code" : "refresh") else { return nil }
            if s.consumed {
                g.revoked = true; try await g.save(on: db); return nil
            }
            guard s.expiresAt > Date() else { return nil }
            if s.kind == "code" {
                let a = try JSONDecoder().decode(Authorization.self, from: Data(s.payload.utf8))
                guard let v = b.code_verifier, (43...128).contains(v.count),
                      v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }),
                      b.redirect_uri == a.redirect_uri,
                      AuthSupport.constantTimeEquals(Data(SHA256.hash(data: Data(v.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""), a.code_challenge)
                else { return nil }
            }
            if let scope = b.scope, Set(scope.split(separator: " ").map(String.init)) != Set(g.scopes) { return nil }
            s.consumed = true; try await s.save(on: db)
            let access = AuthSupport.randomToken(), refresh = AuthSupport.randomToken()
            try await OAuthSecret(raw: access, kind: "access", grantID: gid, lifetime: 900).save(on: db)
            try await OAuthSecret(raw: refresh, kind: "refresh", grantID: gid, lifetime: 30 * 86400).save(on: db)
            return .object(["access_token": .string(access), "refresh_token": .string(refresh), "token_type": .string("Bearer"),
                            "expires_in": .number(900), "scope": .string(g.scopes.joined(separator: " "))])
        }
        guard let result else { return try await tokenError(req) }
        let response = try await result.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: .pragma, value: "no-cache")
        return response
    }
    private func tokenError(_ req: Request) async throws -> Response {
        let r = try await JSONValue.object(["error": .string("invalid_grant")]).encodeResponse(status: .badRequest, for: req)
        r.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return r
    }
    private static func grantJSON(_ g: OAuthGrant, clientName: String? = nil) throws -> JSONValue {
        .object(["id": .string(try g.requireID().uuidString), "client_id": .string(g.clientID.uuidString), "client_name": .string(clientName ?? ""),
                 "scopes": .strings(g.scopes), "project_ids": .strings(g.projects.map(\.uuidString)), "revoked": .bool(g.revoked)])
    }
    @Sendable func grants(_ req: Request) async throws -> JSONValue {
        let user = try await req.requireUser()
        let grants = try await OAuthGrant.query(on: req.db).filter(\.$userID == user.requireID()).all()
        let names = Dictionary(uniqueKeysWithValues: try await OAuthClient.query(on: req.db).filter(\.$id ~~ Set(grants.map(\.clientID))).all().compactMap { c in c.id.map { ($0, c.name) } })
        return .array(try grants.map { try Self.grantJSON($0, clientName: names[$0.clientID]) })
    }
    struct GrantProjects: Content { var project_ids: [UUID] }
    /// Replaces the projects an existing connection may reach. MCP requests read the grant on every call, so the change is immediate.
    @Sendable func setGrantProjects(_ req: Request) async throws -> JSONValue {
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.notFound) }
        let b = try req.content.decode(GrantProjects.self)
        let ids = Array(Set(b.project_ids))
        return try await req.db.transaction { db in
            try await lockRow(table: OAuthGrant.schema, id: id, on: db)
            guard let g = try await OAuthGrant.find(id, on: db), g.userID == user.id else { throw Abort(.notFound) }
            guard !g.revoked else { throw Abort(.conflict, reason: "grant_revoked") }
            guard !ids.isEmpty || g.scopes.contains("projects:write") else { throw Abort(.badRequest, reason: "projects_required") }
            // Only projects added now need the user's current access; removing one the user lost access to must stay possible.
            for pid in ids where !g.projects.contains(pid) { _ = try await ProjectAccess(user: user, db: db).project(pid) }
            g.projects = ids; try await g.save(on: db)
            return try Self.grantJSON(g, clientName: try await OAuthClient.find(g.clientID, on: db)?.name)
        }
    }
    @Sendable func revoke(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.notFound) }
        try await req.db.transaction { db in
            try await lockRow(table: OAuthGrant.schema, id: id, on: db)
            guard let g = try await OAuthGrant.find(id, on: db), g.userID == user.id else { throw Abort(.notFound) }
            g.revoked = true; try await g.save(on: db)
        }
        return .noContent
    }
}
