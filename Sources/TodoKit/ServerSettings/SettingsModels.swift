import Fluent
import Vapor

/// One stored setting. A reset keeps the row (value nil) and bumps `version`, so replicas detect every change
/// by comparing `(setting_key, version)` pairs. Secret values are AES-GCM blobs; plaintext never touches the table.
final class ServerSetting: Model, @unchecked Sendable {
    static let schema = "server_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "setting_key") var settingKey: String
    /// Canonical string (JSON typed text is not needed: the registry knows the type); secrets: `v1.<base64>` blob.
    @OptionalField(key: "value") var value: String?
    @Field(key: "secret") var secret: Bool
    @OptionalField(key: "key_id") var keyID: String?
    @OptionalField(key: "fingerprint") var fingerprint: String?
    @OptionalField(key: "updated_by") var updatedBy: UUID?
    @Field(key: "updated_at") var updatedAt: Date
    @Field(key: "version") var version: Int
    init() {}
}

/// Who changed which setting when. Never contains values.
final class ServerSettingAudit: Model, @unchecked Sendable {
    static let schema = "server_settings_audit"
    @ID(key: .id) var id: UUID?
    @Field(key: "setting_key") var settingKey: String
    /// set | reset | test | admin
    @Field(key: "action") var action: String
    @OptionalField(key: "actor_id") var actorID: UUID?
    @Field(key: "actor_name") var actorName: String
    @OptionalField(key: "detail") var detail: String?
    @OptionalField(key: "version") var version: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

struct CreateServerSettings: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ServerSetting.schema).id()
            .field("setting_key", .string, .required).field("value", .sql(.text))
            .field("secret", .bool, .required).field("key_id", .string).field("fingerprint", .string)
            .field("updated_by", .uuid).field("updated_at", .datetime, .required).field("version", .int, .required)
            .unique(on: "setting_key").create()
        try await db.schema(ServerSettingAudit.schema).id()
            .field("setting_key", .string, .required).field("action", .string, .required)
            .field("actor_id", .uuid).field("actor_name", .string, .required)
            .field("detail", .string).field("version", .int).field("created_at", .datetime).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ServerSettingAudit.schema).delete()
        try await db.schema(ServerSetting.schema).delete()
    }
}

func configureServerSettings(_ app: Application) {
    app.migrations.add(CreateServerSettings())
    app.asyncCommands.use(SettingsCommandGroup(), as: "settings")
}
