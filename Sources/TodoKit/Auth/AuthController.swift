import Fluent
import Vapor
import WebAuthn

struct CapabilitiesResponse: Content {
    let passkey: Bool
    let password: Bool
    let bootstrapOpen: Bool
    /// Additive (ADR 0022); absent on older servers or when LIVE_REFRESH_ENABLED=false.
    var liveRefresh: LiveRefreshCapability? = nil
}

struct RegisterBeginRequest: Content {
    let token: String
    let displayName: String
}

/// Registration options as emitted by the WebAuthn library plus `authenticatorSelection`.
/// Login runs without a username, so new credentials must be discoverable (resident).
struct DiscoverableCreationOptions: Codable, Sendable {
    let base: PublicKeyCredentialCreationOptions

    private enum ExtraKeys: String, CodingKey { case authenticatorSelection }
    private struct Selection: Codable {
        let residentKey = "required"
        let requireResidentKey = true
        let userVerification = "preferred"
        private enum CodingKeys: String, CodingKey { case residentKey, requireResidentKey, userVerification }
        init() {}
        init(from decoder: any Decoder) throws { self.init() }
    }

    init(_ base: PublicKeyCredentialCreationOptions) { self.base = base }
    init(from decoder: any Decoder) throws { base = try PublicKeyCredentialCreationOptions(from: decoder) }
    func encode(to encoder: any Encoder) throws {
        try base.encode(to: encoder)
        var extra = encoder.container(keyedBy: ExtraKeys.self)
        try extra.encode(Selection(), forKey: .authenticatorSelection)
    }
}

struct RegisterBeginResponse: Content {
    let challengeID: UUID
    let options: DiscoverableCreationOptions
    init(challengeID: UUID, options: PublicKeyCredentialCreationOptions) {
        self.challengeID = challengeID
        self.options = DiscoverableCreationOptions(options)
    }
}

struct RegisterFinishRequest: Content {
    let challengeID: UUID
    let credential: RegistrationCredential
    let passkeyName: String?
}

struct LoginBeginResponse: Content {
    let challengeID: UUID
    let options: PublicKeyCredentialRequestOptions
}

struct LoginFinishRequest: Content {
    let challengeID: UUID
    let credential: AuthenticationCredential
}

struct PasswordLoginRequest: Content {
    let username: String
    let password: String
}

struct InvitationResponse: Content {
    let token: String
    let expiresAt: Date
}

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.get("capabilities", use: capabilities)
        let auth = v1.grouped("auth")
        auth.post("register", "begin", use: registerBegin)
        auth.post("register", "finish", use: registerFinish)
        auth.post("login", "begin", use: loginBegin)
        auth.post("login", "finish", use: loginFinish)
        auth.post("password", "login", use: passwordLogin)
        auth.post("logout", use: logout)
        v1.get("me", use: me)
        v1.post("me", "password", use: setPassword)
        v1.post("invitations", use: createInvitation)
    }

    private func webAuthn(_ req: Request) -> WebAuthnManager {
        let s = req.application.settings
        return WebAuthnManager(configuration: .init(
            relyingPartyID: s.relyingPartyID, relyingPartyName: s.relyingPartyName,
            relyingPartyOrigin: s.relyingPartyOrigin))
    }

    private func bootstrapOpen(_ db: any Database) async throws -> Bool {
        try await User.query(on: db).count() == 0
    }

    @Sendable func capabilities(_ req: Request) async throws -> CapabilitiesResponse {
        CapabilitiesResponse(
            passkey: true, password: req.application.settings.passwordLoginEnabled,
            bootstrapOpen: try await bootstrapOpen(req.db) && req.application.settings.bootstrapToken != nil,
            liveRefresh: LiveController.capability(req.application.liveSettings))
    }

    // MARK: Registration (bootstrap or invitation)

    @Sendable func registerBegin(_ req: Request) async throws -> RegisterBeginResponse {
        let body = try req.content.decode(RegisterBeginRequest.self)
        let name = body.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw Abort(.badRequest, reason: "invalid_display_name") }

        var invitationID: UUID?
        if try await bootstrapOpen(req.db) {
            guard let expected = req.application.settings.bootstrapToken,
                AuthSupport.constantTimeEquals(body.token, expected)
            else { throw Abort(.forbidden, reason: "invalid_token") }
        } else {
            guard let invitation = try await Invitation.query(on: req.db)
                .filter(\.$tokenHash == AuthSupport.hash(body.token)).first(),
                invitation.usedAt == nil, invitation.expiresAt > Date()
            else { throw Abort(.forbidden, reason: "invalid_token") }
            invitationID = invitation.id
        }

        let userID = UUID()
        let options = webAuthn(req).beginRegistration(
            user: .init(id: Array(userID.uuidString.utf8), name: name, displayName: name))
        let challenge = AuthChallenge(
            kind: "registration", challenge: options.challenge.base64URLEncodedString().asString(),
            userID: userID, displayName: name, invitationID: invitationID,
            expiresAt: Date().addingTimeInterval(req.application.settings.challengeLifetime))
        try await challenge.save(on: req.db)
        return RegisterBeginResponse(challengeID: try challenge.requireID(), options: options)
    }

    /// Loads and consumes a challenge in one transaction so it can be used exactly once, on any replica.
    private func consumeChallenge(_ id: UUID, kind: String, on db: any Database) async throws -> AuthChallenge {
        try await lockRow(table: AuthChallenge.schema, id: id, on: db)
        guard let challenge = try await AuthChallenge.find(id, on: db),
            challenge.kind == kind
        else { throw Abort(.badRequest, reason: "invalid_challenge") }
        try await challenge.delete(on: db)
        guard challenge.expiresAt > Date() else { throw Abort(.badRequest, reason: "challenge_expired") }
        return challenge
    }

    @Sendable func registerFinish(_ req: Request) async throws -> Response {
        let body = try req.content.decode(RegisterFinishRequest.self)
        let manager = webAuthn(req)
        let user = try await req.db.transaction { db -> User in
            let challenge = try await self.consumeChallenge(body.challengeID, kind: "registration", on: db)
            guard let userID = challenge.userID, let name = challenge.displayName,
                let bytes = URLEncodedBase64(challenge.challenge).decodedBytes
            else { throw Abort(.badRequest, reason: "invalid_challenge") }

            let rawID = body.credential.rawID.base64URLEncodedString().asString()
            let credential: Credential
            do {
                credential = try await manager.finishRegistration(
                    challenge: bytes, credentialCreationData: body.credential
                ) { _ in
                    try await PasskeyCredential.query(on: db).filter(\.$credentialID == rawID).count() == 0
                }
            } catch {
                throw Abort(.badRequest, reason: "registration_failed")
            }

            let first = try await User.query(on: db).count() == 0
            let user = User(displayName: name, isAdmin: first)
            user.id = userID
            if first { user.bootstrapSlot = 1 }
            if let invitationID = challenge.invitationID {
                guard let invitation = try await Invitation.find(invitationID, on: db),
                    invitation.usedAt == nil, invitation.expiresAt > Date()
                else { throw Abort(.forbidden, reason: "invalid_token") }
                invitation.usedAt = Date()
                try await invitation.save(on: db)
            } else if !first {
                throw Abort(.forbidden, reason: "invalid_token")
            }
            do { try await user.save(on: db) } catch { throw Abort(.conflict, reason: "bootstrap_closed") }
            try await PasskeyCredential(
                userID: userID, credentialID: body.credential.rawID.base64URLEncodedString().asString(),
                publicKey: credential.publicKey.base64URLEncodedString().asString(),
                signCount: Int(credential.signCount), name: body.passkeyName ?? "Passkey"
            ).save(on: db)
            return user
        }
        return try await req.startSession(for: user, on: req.db)
    }

    // MARK: Login

    @Sendable func loginBegin(_ req: Request) async throws -> LoginBeginResponse {
        let options = webAuthn(req).beginAuthentication()
        let challenge = AuthChallenge(
            kind: "authentication", challenge: options.challenge.base64URLEncodedString().asString(),
            userID: nil, displayName: nil, invitationID: nil,
            expiresAt: Date().addingTimeInterval(req.application.settings.challengeLifetime))
        try await challenge.save(on: req.db)
        return LoginBeginResponse(challengeID: try challenge.requireID(), options: options)
    }

    @Sendable func loginFinish(_ req: Request) async throws -> Response {
        let body = try req.content.decode(LoginFinishRequest.self)
        let challenge = try await req.db.transaction { db in
            try await self.consumeChallenge(body.challengeID, kind: "authentication", on: db)
        }
        guard let expected = URLEncodedBase64(challenge.challenge).decodedBytes,
            let stored = try await PasskeyCredential.query(on: req.db)
                .filter(\.$credentialID == body.credential.rawID.base64URLEncodedString().asString()).first(),
            stored.revokedAt == nil,
            let publicKey = URLEncodedBase64(stored.publicKey).decodedBytes,
            let user = try await User.find(stored.$user.id, on: req.db)
        else { throw Abort(.unauthorized, reason: "login_failed") }

        let verified: VerifiedAuthentication
        do {
            verified = try webAuthn(req).finishAuthentication(
                credential: body.credential, expectedChallenge: expected, credentialPublicKey: publicKey,
                credentialCurrentSignCount: UInt32(stored.signCount))
        } catch {
            throw Abort(.unauthorized, reason: "login_failed")
        }
        stored.signCount = Int(verified.newSignCount)
        try await stored.save(on: req.db)
        return try await req.startSession(for: user, on: req.db)
    }

    @Sendable func logout(_ req: Request) async throws -> Response {
        if let token = req.sessionTokenPresented {
            try await UserSession.query(on: req.db).filter(\.$tokenHash == AuthSupport.hash(token)).delete()
        }
        let response = Response(status: .noContent)
        response.cookies[AuthSupport.cookieName] = HTTPCookies.Value(
            string: "", expires: Date(timeIntervalSince1970: 0), maxAge: 0, path: "/",
            isSecure: req.application.settings.secureCookies, isHTTPOnly: true, sameSite: .strict)
        return response
    }

    @Sendable func me(_ req: Request) async throws -> UserDTO {
        try UserDTO(try await req.requireUser())
    }

    // MARK: Optional password login (secondary, server-controlled)

    private func requirePasswordEnabled(_ req: Request) throws {
        guard req.application.settings.passwordLoginEnabled else {
            throw Abort(.forbidden, reason: "password_login_disabled")
        }
    }

    @Sendable func passwordLogin(_ req: Request) async throws -> Response {
        try requirePasswordEnabled(req)
        let body = try req.content.decode(PasswordLoginRequest.self)
        guard let user = try await User.query(on: req.db).filter(\.$username == body.username.lowercased()).first(),
            let hash = user.passwordHash, (try? Bcrypt.verify(body.password, created: hash)) == true
        else { throw Abort(.unauthorized, reason: "login_failed") }
        return try await req.startSession(for: user, on: req.db)
    }

    @Sendable func setPassword(_ req: Request) async throws -> HTTPStatus {
        try requirePasswordEnabled(req)
        let user = try await req.requireUser()
        let body = try req.content.decode(PasswordLoginRequest.self)
        let username = body.username.lowercased()
        guard username.count >= 3, username.count <= 64, body.password.count >= 12, body.password.count <= 256 else {
            throw Abort(.badRequest, reason: "invalid_credentials_format")
        }
        if let other = try await User.query(on: req.db).filter(\.$username == username).first(), other.id != user.id {
            throw Abort(.conflict, reason: "username_taken")
        }
        user.username = username
        user.passwordHash = try Bcrypt.hash(body.password)
        try await user.save(on: req.db)
        return .noContent
    }

    // MARK: Invitations

    @Sendable func createInvitation(_ req: Request) async throws -> InvitationResponse {
        let admin = try await req.requireAdmin()
        let token = AuthSupport.randomToken()
        let expires = Date().addingTimeInterval(7 * 24 * 3600)
        try await Invitation(tokenHash: AuthSupport.hash(token), createdBy: try admin.requireID(), expiresAt: expires)
            .save(on: req.db)
        return InvitationResponse(token: token, expiresAt: expires)
    }
}
