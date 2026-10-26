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
    try configureDatabase(app, settings: .fromEnvironment())
    configureMigrations(app)
    try routes(app)
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
}

/// Migrations are registered but never run on `serve`; run `App migrate --yes` once per deployment.
public func configureMigrations(_ app: Application) {
    app.migrations.add(CreateInitialSchema())
}

public func configureContent() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
}
