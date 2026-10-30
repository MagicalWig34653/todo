import Fluent
import Vapor

final class User: Model, @unchecked Sendable {
    static let schema = "users"
    @ID(key: .id) var id: UUID?
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "username") var username: String?
    @OptionalField(key: "password_hash") var passwordHash: String?
    @Field(key: "is_admin") var isAdmin: Bool
    /// Set to 1 only for the first user; the unique constraint makes bootstrap atomic across replicas.
    @OptionalField(key: "bootstrap_slot") var bootstrapSlot: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(displayName: String, isAdmin: Bool) {
        self.displayName = displayName
        self.isAdmin = isAdmin
    }
}

final class PasskeyCredential: Model, @unchecked Sendable {
    static let schema = "passkey_credentials"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "credential_id") var credentialID: String
    @Field(key: "public_key") var publicKey: String // base64
    @Field(key: "sign_count") var signCount: Int
    @Field(key: "name") var name: String
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(userID: UUID, credentialID: String, publicKey: String, signCount: Int, name: String) {
        self.$user.id = userID
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signCount = signCount
        self.name = name
    }
}

/// One-time WebAuthn challenge, shared between replicas through the database.
final class AuthChallenge: Model, @unchecked Sendable {
    static let schema = "auth_challenges"
    @ID(key: .id) var id: UUID?
    @Field(key: "kind") var kind: String // "registration" | "authentication"
    @Field(key: "challenge") var challenge: String // base64
    @OptionalField(key: "user_id") var userID: UUID?
    @OptionalField(key: "display_name") var displayName: String?
    @OptionalField(key: "invitation_id") var invitationID: UUID?
    @Field(key: "expires_at") var expiresAt: Date
    init() {}
    init(kind: String, challenge: String, userID: UUID?, displayName: String?, invitationID: UUID?, expiresAt: Date) {
        self.kind = kind
        self.challenge = challenge
        self.userID = userID
        self.displayName = displayName
        self.invitationID = invitationID
        self.expiresAt = expiresAt
    }
}

final class UserSession: Model, @unchecked Sendable {
    static let schema = "sessions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(userID: UUID, tokenHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}

final class Invitation: Model, @unchecked Sendable {
    static let schema = "invitations"
    @ID(key: .id) var id: UUID?
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_by") var createdBy: UUID
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "used_at") var usedAt: Date?
    init() {}
    init(tokenHash: String, createdBy: UUID, expiresAt: Date) {
        self.tokenHash = tokenHash
        self.createdBy = createdBy
        self.expiresAt = expiresAt
    }
}

final class Project: Model, @unchecked Sendable {
    static let schema = "projects"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @OptionalField(key: "parent_id") var parentID: UUID?
    @Field(key: "name") var name: String
    /// Optional free text (TEXT column, at most 10 000 characters); `nil` = none.
    @OptionalField(key: "description") var details: String?
    /// Optional `#RRGGBB` project colour; `nil` = derived by the client.
    @OptionalField(key: "color") var color: String?
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(ownerID: UUID, parentID: UUID?, name: String) {
        self.ownerID = ownerID
        self.parentID = parentID
        self.name = name
        self.version = 1
    }
}

final class TodoTask: Model, @unchecked Sendable {
    static let schema = "tasks"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "title") var title: String
    @Field(key: "description") var details: String
    @Field(key: "status") var status: String // open | in_progress | in_review | done
    @Field(key: "version") var version: Int
    /// Board column of the task's own project (ADR 0011); nil = "Ohne Spalte" / status board.
    @OptionalField(key: "column_id") var columnID: UUID?
    /// 0-based position inside the column.
    @Field(key: "board_position") var boardPosition: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(ownerID: UUID, projectID: UUID, title: String, details: String = "", status: String = "open") {
        self.ownerID = ownerID
        self.projectID = projectID
        self.title = title
        self.details = details
        self.status = status
        self.version = 1
        self.boardPosition = 0
    }
}
