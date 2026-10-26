import Fluent
import Vapor

final class OAuthClient: Model, @unchecked Sendable {
    static let schema = "oauth_clients"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "redirects") var redirects: [String]
    init() {}
    init(name: String, redirects: [String]) { self.name = name; self.redirects = redirects }
}

final class OAuthGrant: Model, @unchecked Sendable {
    static let schema = "oauth_grants"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "client_id") var clientID: UUID
    @Field(key: "resource") var resource: String
    @Field(key: "scopes") var scopes: [String]
    @Field(key: "projects") var projects: [UUID]
    @Field(key: "revoked") var revoked: Bool
    init() {}
    init(userID: UUID, clientID: UUID, resource: String, scopes: [String], projects: [UUID]) {
        self.userID = userID; self.clientID = clientID; self.resource = resource
        self.scopes = scopes; self.projects = projects; revoked = false
    }
}

/// Codes and refresh tokens remain as consumed tombstones for replay detection.
final class OAuthSecret: Model, @unchecked Sendable {
    static let schema = "oauth_secrets"
    @ID(key: .id) var id: UUID?
    @Field(key: "hash") var hash: String
    @Field(key: "kind") var kind: String
    @OptionalField(key: "grant_id") var grantID: UUID?
    @Field(key: "payload") var payload: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "consumed") var consumed: Bool
    init() {}
    init(raw: String, kind: String, grantID: UUID? = nil, payload: String = "", lifetime: Double) {
        hash = AuthSupport.hash(raw); self.kind = kind; self.grantID = grantID; self.payload = payload
        expiresAt = Date().addingTimeInterval(lifetime); consumed = false
    }
}
