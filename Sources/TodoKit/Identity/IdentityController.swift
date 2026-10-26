import Fluent
import Vapor
import WebAuthn

struct IdentityName: Content { let name: String }
struct RecoveryCodeRequest: Content { let code: String }
struct RecoveryTokenResponse: Content { let token: String; let expiresAt: Date }
struct PasskeyInfo: Content {
    let id: UUID
    let name: String
    let createdAt: Date?
    let revokedAt: Date?
    init(_ key: PasskeyCredential) throws {
        id = try key.requireID(); name = key.name; createdAt = key.createdAt; revokedAt = key.revokedAt
    }
}
struct SessionInfo: Content {
    let id: UUID
    let createdAt: Date?
    let expiresAt: Date
    let current: Bool
}

struct IdentityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let me = routes.grouped("v1", "me")
        me.get("passkeys", use: passkeys)
        me.post("passkeys", "begin", use: begin)
        me.post("passkeys", "finish", use: finish)
        me.patch("passkeys", ":id", use: rename)
        me.delete("passkeys", ":id", use: revoke)
        me.get("sessions", use: sessions)
        me.delete("sessions", ":id", use: revokeSession)
        me.post("sessions", "revoke-others", use: revokeOthers)
        routes.post("v1", "identity", "accounts", ":id", "recovery", use: issueRecovery)
        let recovery = routes.grouped("v1", "identity", "recovery")
        recovery.post("redeem", use: redeemRecovery)
        recovery.post("passkeys", "begin", use: recoveryBegin)
        recovery.post("passkeys", "finish", use: recoveryFinish)
    }

    private func manager(_ req: Request) -> WebAuthnManager {
        let s = req.application.settings
        return WebAuthnManager(configuration: .init(relyingPartyID: s.relyingPartyID,
            relyingPartyName: s.relyingPartyName, relyingPartyOrigin: s.relyingPartyOrigin))
    }
    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }
    private func name(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 100 else { throw Abort(.badRequest, reason: "invalid_passkey_name") }
        return value
    }
    private func ownedKey(_ id: UUID, userID: UUID, db: any Database) async throws -> PasskeyCredential {
        guard let key = try await PasskeyCredential.find(id, on: db), key.$user.id == userID else { throw Abort(.notFound) }
        return key
    }

    @Sendable func passkeys(_ req: Request) async throws -> [PasskeyInfo] {
        let userID = try await req.requireUser().requireID()
        return try await PasskeyCredential.query(on: req.db).filter(\.$user.$id == userID)
            .all().map { try PasskeyInfo($0) }
    }
    @Sendable func rename(_ req: Request) async throws -> HTTPStatus {
        let userID = try await req.requireUser().requireID()
        let keyID = try id(req)
        let newName = try name(req.content.decode(IdentityName.self).name)
        try await req.db.transaction { db in
            try await lockRow(table: User.schema, id: userID, on: db)
            let key = try await ownedKey(keyID, userID: userID, db: db)
            key.name = newName
            try await key.save(on: db)
        }
        return .noContent
    }
    @Sendable func revoke(_ req: Request) async throws -> HTTPStatus {
        let userID = try await req.requireUser().requireID()
        let keyID = try id(req)
        try await req.db.transaction { db in
            try await lockRow(table: User.schema, id: userID, on: db)
            let key = try await ownedKey(keyID, userID: userID, db: db)
            if key.revokedAt != nil { return }
            let count = try await PasskeyCredential.query(on: db).filter(\.$user.$id == userID).filter(\.$revokedAt == nil).count()
            let user = try await User.find(userID, on: db)!
            let recovery = try await RecoveryGrant.query(on: db).filter(\.$userID == userID).all()
            let hasRecovery = recovery.contains {
                ($0.sessionHash == nil && $0.expiresAt > Date()) || ($0.sessionExpiresAt ?? .distantPast) > Date()
            }
            let hasPassword = req.application.settings.passwordLoginEnabled && user.passwordHash != nil && user.username != nil
            guard count > 1 || hasRecovery || hasPassword else { throw Abort(.conflict, reason: "last_passkey_requires_recovery") }
            key.revokedAt = Date()
            try await key.save(on: db)
        }
        return .noContent
    }

    @Sendable func sessions(_ req: Request) async throws -> [SessionInfo] {
        let userID = try await req.requireUser().requireID()
        let hash = AuthSupport.hash(req.sessionTokenPresented ?? "")
        return try await UserSession.query(on: req.db).filter(\.$user.$id == userID).filter(\.$expiresAt > Date()).all().map {
            SessionInfo(id: try $0.requireID(), createdAt: $0.createdAt, expiresAt: $0.expiresAt, current: $0.tokenHash == hash)
        }
    }
    @Sendable func revokeSession(_ req: Request) async throws -> HTTPStatus {
        let userID = try await req.requireUser().requireID()
        guard let session = try await UserSession.find(id(req), on: req.db), session.$user.id == userID else { throw Abort(.notFound) }
        try await session.delete(on: req.db)
        return .noContent
    }
    @Sendable func revokeOthers(_ req: Request) async throws -> HTTPStatus {
        let userID = try await req.requireUser().requireID()
        try await UserSession.query(on: req.db).filter(\.$user.$id == userID)
            .filter(\.$tokenHash != AuthSupport.hash(req.sessionTokenPresented ?? "")).delete()
        return .noContent
    }

    private func beginRegistration(_ req: Request, user: User, binding: String) async throws -> RegisterBeginResponse {
        let userID = try user.requireID()
        let options = manager(req).beginRegistration(user: .init(id: Array(userID.uuidString.utf8), name: user.displayName, displayName: user.displayName))
        let challenge = AuthChallenge(kind: binding, challenge: options.challenge.base64URLEncodedString().asString(),
            userID: userID, displayName: nil, invitationID: nil,
            expiresAt: Date().addingTimeInterval(req.application.settings.challengeLifetime))
        try await challenge.save(on: req.db)
        return RegisterBeginResponse(challengeID: try challenge.requireID(), options: options)
    }
    @Sendable func begin(_ req: Request) async throws -> RegisterBeginResponse {
        let user = try await req.requireUser()
        return try await beginRegistration(req, user: user, binding: "key:" + AuthSupport.hash(req.sessionTokenPresented!))
    }
    private func saveRegistration(_ req: Request, body: RegisterFinishRequest, userID: UUID, binding: String, db: any Database) async throws {
        try await lockRow(table: AuthChallenge.schema, id: body.challengeID, on: db)
        guard let challenge = try await AuthChallenge.find(body.challengeID, on: db), challenge.kind == binding,
              challenge.userID == userID, challenge.expiresAt > Date(),
              let bytes = URLEncodedBase64(challenge.challenge).decodedBytes else { throw Abort(.badRequest, reason: "invalid_challenge") }
        let keyName = try name(body.passkeyName ?? "Passkey")
        let rawID = body.credential.rawID.base64URLEncodedString().asString()
        let credential: Credential
        do {
            credential = try await manager(req).finishRegistration(challenge: bytes, credentialCreationData: body.credential) { _ in
                try await PasskeyCredential.query(on: db).filter(\.$credentialID == rawID).count() == 0
            }
        } catch { throw Abort(.badRequest, reason: "registration_failed") }
        try await PasskeyCredential(userID: userID, credentialID: rawID,
            publicKey: credential.publicKey.base64URLEncodedString().asString(), signCount: Int(credential.signCount), name: keyName).save(on: db)
        try await challenge.delete(on: db)
    }
    @Sendable func finish(_ req: Request) async throws -> HTTPStatus {
        let userID = try await req.requireUser().requireID()
        let body = try req.content.decode(RegisterFinishRequest.self)
        let binding = "key:" + AuthSupport.hash(req.sessionTokenPresented!)
        try await req.db.transaction { db in
            try await lockRow(table: User.schema, id: userID, on: db)
            // Recheck revocation after acquiring the account lock.
            guard try await UserSession.query(on: db).filter(\.$tokenHash == AuthSupport.hash(req.sessionTokenPresented!))
                .filter(\.$expiresAt > Date()).count() == 1 else { throw Abort(.unauthorized) }
            try await saveRegistration(req, body: body, userID: userID, binding: binding, db: db)
        }
        return .noContent
    }

    @Sendable func issueRecovery(_ req: Request) async throws -> RecoveryTokenResponse {
        _ = try await req.requireAdmin()
        let userID = try id(req)
        let code = AuthSupport.randomToken()
        let expires = Date().addingTimeInterval(req.application.identitySettings.recoveryLifetime)
        try await req.db.transaction { db in
            try await lockRow(table: User.schema, id: userID, on: db)
            guard try await User.find(userID, on: db) != nil else { throw Abort(.notFound) }
            // Reissue invalidates every previous code and restricted session for this account.
            try await RecoveryGrant.query(on: db).filter(\.$userID == userID).delete()
            try await RecoveryGrant(userID: userID, code: code, expiresAt: expires).save(on: db)
        }
        return RecoveryTokenResponse(token: code, expiresAt: expires)
    }
    @Sendable func redeemRecovery(_ req: Request) async throws -> RecoveryTokenResponse {
        let body = try req.content.decode(RecoveryCodeRequest.self)
        let hash = AuthSupport.hash(body.code)
        guard let found = try await RecoveryGrant.query(on: req.db).filter(\.$codeHash == hash).first() else { throw Abort(.unauthorized, reason: "recovery_failed") }
        let token = AuthSupport.randomToken()
        let expires = Date().addingTimeInterval(req.application.identitySettings.recoverySessionLifetime)
        try await req.db.transaction { db in
            try await lockRow(table: User.schema, id: found.userID, on: db)
            guard let grant = try await RecoveryGrant.find(found.id, on: db), grant.sessionHash == nil,
                  grant.expiresAt > Date() else { throw Abort(.unauthorized, reason: "recovery_failed") }
            grant.sessionHash = AuthSupport.hash(token)
            grant.sessionExpiresAt = expires
            try await grant.save(on: db)
        }
        return RecoveryTokenResponse(token: token, expiresAt: expires)
    }
    private func recoveryGrant(_ req: Request, db: any Database) async throws -> RecoveryGrant {
        // Recovery accepts only Bearer, never the ordinary session cookie.
        guard let token = req.headers.bearerAuthorization?.token,
              let grant = try await RecoveryGrant.query(on: db).filter(\.$sessionHash == AuthSupport.hash(token)).first(),
              let expires = grant.sessionExpiresAt, expires > Date() else { throw Abort(.unauthorized) }
        return grant
    }
    @Sendable func recoveryBegin(_ req: Request) async throws -> RegisterBeginResponse {
        let grant = try await recoveryGrant(req, db: req.db)
        guard let user = try await User.find(grant.userID, on: req.db) else { throw Abort(.unauthorized) }
        return try await beginRegistration(req, user: user, binding: "recovery:" + grant.sessionHash!)
    }
    @Sendable func recoveryFinish(_ req: Request) async throws -> HTTPStatus {
        let found = try await recoveryGrant(req, db: req.db)
        let body = try req.content.decode(RegisterFinishRequest.self)
        try await req.db.transaction { db in
            try await lockRow(table: User.schema, id: found.userID, on: db)
            let grant = try await recoveryGrant(req, db: db)
            try await saveRegistration(req, body: body, userID: grant.userID, binding: "recovery:" + grant.sessionHash!, db: db)
            try await grant.delete(on: db)
            // A recovered account must log in with the new key; existing sessions are revoked.
            try await UserSession.query(on: db).filter(\.$user.$id == grant.userID).delete()
        }
        return .noContent
    }
}
