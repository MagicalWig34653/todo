import Fluent
import FluentMySQLDriver
import FluentSQLiteDriver
import Vapor

/// Database settings read from the environment. Defaults target the local dev stack.
public struct DatabaseSettings: Sendable {
    public enum Driver: String, Sendable { case mariadb, sqlite }

    public var driver: Driver
    public var host: String
    public var port: Int
    public var name: String
    public var user: String
    public var password: String

    public static func fromEnvironment(
        get: (String) -> String? = { Environment.get($0) }
    ) throws -> DatabaseSettings {
        DatabaseSettings(
            driver: Driver(rawValue: try RuntimeEnvironment.value("DATABASE_DRIVER", get: get) ?? "mariadb") ?? .mariadb,
            host: try RuntimeEnvironment.value("DB_HOST", get: get) ?? "127.0.0.1",
            port: try RuntimeEnvironment.value("DB_PORT", get: get).flatMap(Int.init) ?? 23306,
            name: try RuntimeEnvironment.value("DB_NAME", get: get) ?? "todo",
            user: try RuntimeEnvironment.value("DB_USER", get: get) ?? "todo",
            password: try RuntimeEnvironment.value("DB_PASSWORD", get: get) ?? ""
        )
    }
}

public func configure(_ app: Application) async throws {
    configureContent()
    app.settings = try .fromEnvironment()
    if app.environment == .production, app.settings.oauthIssuerIsLoopback {
        app.logger.warning("OAuth/MCP issuer is \(app.settings.oauthIssuer): MCP clients cannot connect. Set OAUTH_ISSUER (or RP_ORIGIN) to the public https URL.")
    }
    // S3 is optional: only an explicit ATTACHMENT_STORAGE=s3 makes the S3_* variables mandatory.
    if app.settings.attachmentStorage == .s3 { _ = try S3Store.fromEnvironment(maxBytes: app.settings.attachmentMaxBytes) }
    try configureDatabase(app, settings: .fromEnvironment())
    configureMigrations(app)
    try routes(app)
    configureMaintenanceScheduler(app)
    try configurePushWorker(app)
}

public func configureDatabase(_ app: Application, settings: DatabaseSettings) throws {
    switch settings.driver {
    case .sqlite:
        app.databases.use(settings.name.isEmpty ? .sqlite(.memory) : .sqlite(.file(settings.name)), as: .sqlite)
    case .mariadb:
        app.databases.use(
            .mysql(
                hostname: settings.host, port: settings.port,
                username: settings.user, password: settings.password,
                database: settings.name, tlsConfiguration: nil
            ), as: .mysql)
    }
    // Change log hooks apply to every save/delete of projects and tasks, whichever route performs it.
    app.databases.middleware.use(SyncProjectMiddleware())
    app.databases.middleware.use(SyncTaskMiddleware())
    app.databases.middleware.use(SyncColumnMiddleware())
    app.databases.middleware.use(SyncLabelMiddleware())
    app.databases.middleware.use(SyncLabelLinkMiddleware())
    registerLiveMiddleware(app)
}

/// Migrations are registered but never run on `serve`; run `App migrate --yes` once per deployment.
public func configureMigrations(_ app: Application) {
    app.migrations.add(CreateInitialSchema())
    app.migrations.add(CreateCollaborationSchema())

    app.migrations.add(CreateOAuthSchema())
    configureIdentity(app)
    configurePreferences(app)
    app.migrations.add(CreatePlanningExtension())

    app.migrations.add(CreateDiscoverySchema())
    app.migrations.add(CreateSharingSchema())
    app.migrations.add(CreateAgentSchema())
    configureAttachments(app)
    configureMaintenance(app)
    // Before the sync backfill: that migration reads tasks through the model, which now includes column_id.
    app.migrations.add(CreateProjectColumns())
    app.migrations.add(AddProjectDetails())
    app.migrations.add(CreateSyncSchema())
    app.migrations.add(AddSyncRetentionSchema())
    app.migrations.add(WidenLongTextColumns())
    configureProjectState(app)
    configureCommandCenter(app)
    configureProjectSync(app)
    configurePush(app)
    configureLive(app)
    // Last: appends label upserts to the change log (needs the sync tables and the discovery tables).
    app.migrations.add(BackfillLabelSync())
}

public func configureContent() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
}
