import Fluent
import Vapor

final class RecoveryGrant: Model, @unchecked Sendable {
    static let schema = "identity_recovery"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "session_hash") var sessionHash: String?
    @OptionalField(key: "session_expires_at") var sessionExpiresAt: Date?
    init() {}
    init(userID: UUID, code: String, expiresAt: Date) {
        self.userID = userID
        self.codeHash = AuthSupport.hash(code)
        self.expiresAt = expiresAt
    }
}

struct IdentityMigration: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(RecoveryGrant.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code_hash", .string, .required).unique(on: "code_hash")
            .field("expires_at", .datetime, .required)
            .field("session_hash", .string).unique(on: "session_hash")
            .field("session_expires_at", .datetime).create()
        try await db.schema("identity_rate_limits")
            .field("id", .string, .identifier(auto: false))
            .field("attempts", .int, .required)
            .field("expires_at", .int64, .required).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("identity_rate_limits").delete()
        try await db.schema(RecoveryGrant.schema).delete()
    }
}

struct IdentitySettings: Sendable {
    var window: Int = 60
    var loginLimit: Int = 60
    var passwordLimit: Int = 10
    var registerLimit: Int = 10
    var recoveryLimit: Int = 5
    var recoveryLifetime: TimeInterval = 3600
    var recoverySessionLifetime: TimeInterval = 300

    static func fromEnvironment() -> Self {
        func positive(_ key: String, _ fallback: Int) -> Int {
            max(1, Environment.get(key).flatMap(Int.init) ?? fallback)
        }
        var s = Self()
        s.window = positive("IDENTITY_RATE_WINDOW_SECONDS", s.window)
        s.loginLimit = positive("IDENTITY_LOGIN_LIMIT", s.loginLimit)
        s.passwordLimit = positive("IDENTITY_PASSWORD_LIMIT", s.passwordLimit)
        s.registerLimit = positive("IDENTITY_REGISTER_LIMIT", s.registerLimit)
        s.recoveryLimit = positive("IDENTITY_RECOVERY_LIMIT", s.recoveryLimit)
        s.recoveryLifetime = TimeInterval(positive("IDENTITY_RECOVERY_SECONDS", Int(s.recoveryLifetime)))
        s.recoverySessionLifetime = TimeInterval(positive("IDENTITY_RECOVERY_SESSION_SECONDS", Int(s.recoverySessionLifetime)))
        return s
    }
}

extension Application {
    private struct IdentityKey: StorageKey { typealias Value = IdentitySettings }
    var identitySettings: IdentitySettings {
        get { storage[IdentityKey.self] ?? .fromEnvironment() }
        set { storage[IdentityKey.self] = newValue }
    }
}

func configureIdentity(_ app: Application) {
    app.migrations.add(IdentityMigration())

}

func registerIdentity(_ app: Application) throws {
    app.middleware.use(IdentityRateMiddleware())
    try app.register(collection: IdentityController())
}
