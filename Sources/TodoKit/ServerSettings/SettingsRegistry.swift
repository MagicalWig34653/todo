import Foundation

/// Central definition of every server setting that administrators can change in the PWA (ADR 0025).
/// The registry drives validation, the API metadata (GET /v1/admin/settings) and the generated PWA forms.

enum SettingType: String, Sendable, Codable {
    case bool, int, string, enumeration = "enum", text, stringList
}

struct SettingCategory: Sendable {
    let id: String
    let label: String
    let help: String
}

struct SettingDefinition: Sendable {
    let key: String
    /// Environment variable (also `<env>_FILE` for Docker secrets). A non-empty value locks the setting.
    let env: String
    let category: String
    let type: SettingType
    var defaultValue: String?
    let label: String
    let help: String
    var secret = false
    /// false: the value is read at startup only ("wirkt nach Neustart").
    var hotReload = true
    var min: Int?
    var max: Int?
    var options: [String]?
    var maxLength = 256
    /// Invalid environment values are ignored instead of failing startup (historic behaviour of LIVE_* / IDENTITY_*).
    var lenientEnv = false
    var placeholder: String?
}

/// A problem with a value, reported with the setting key and a German message.
struct SettingsProblem: Error, CustomStringConvertible, Sendable {
    let code: String
    let key: String?
    let message: String
    var description: String { message }
}

enum SettingsRegistry {
    static let categories: [SettingCategory] = [
        .init(id: "branding", label: "Darstellung", help: "Name der Instanz."),
        .init(id: "auth", label: "Anmeldung", help: "Anmeldearten dieses Servers."),
        .init(id: "mail", label: "E-Mail", help: "Ausgehende Mail für Recovery-Codes, Adressbestätigung und Test-Mail."),
        .init(id: "push", label: "Push (APNs)", help: "Push-Benachrichtigungen für die Apple-Apps."),
        .init(id: "attachments", label: "Anhänge", help: "Speicherort und Größe von Anhängen und Screenshots."),
        .init(id: "maintenance", label: "Aufräumen und Sync", help: "Periodisches Aufräumen und Aufbewahrung des Sync-Protokolls."),
        .init(id: "live", label: "Live-Aktualisierung", help: "Long-Polling, mit dem Clients Änderungen sofort sehen."),
        .init(id: "limits", label: "Limits", help: "Ratenbegrenzung der Anmeldung und Gültigkeit von Recovery-Codes."),
        .init(id: "apple", label: "Apple-Apps", help: "Eintrag für Passkeys in den nativen Apps."),
        .init(id: "security", label: "Sicherheit", help: "Schutz vor Verbindungen des Servers zu internen Zielen."),
    ]

    static let definitions: [SettingDefinition] = [
        // Branding
        .init(key: "branding.instanceName", env: "INSTANCE_NAME", category: "branding", type: .string, defaultValue: "Todolino",
              label: "Name der Instanz", help: "Wird den Clients als Servername gemeldet.", maxLength: 80),
        // Auth
        .init(key: "auth.passwordLoginEnabled", env: "PASSWORD_LOGIN_ENABLED", category: "auth", type: .bool, defaultValue: "false",
              label: "Passwort-Anmeldung erlauben", help: "Zusätzlich zu Passkeys. Wird bei jeder Passwort-Aktion serverseitig geprüft."),
        // Mail
        .init(key: "mail.enabled", env: "MAIL_ENABLED", category: "mail", type: .bool, defaultValue: "false",
              label: "E-Mail-Versand aktiv", help: "Nur mit vollständigen Angaben (Server, Absender) einschaltbar."),
        .init(key: "mail.smtpHost", env: "SMTP_HOST", category: "mail", type: .string,
              label: "SMTP-Server", help: "Host-Name oder IP-Adresse des Mailservers.", placeholder: "smtp.example.org"),
        .init(key: "mail.smtpSecurity", env: "SMTP_SECURITY", category: "mail", type: .enumeration, defaultValue: "starttls",
              label: "Verschlüsselung", help: "starttls (meist Port 587), tls (meist Port 465) oder none (nur vertrauenswürdiges Netz).",
              options: ["starttls", "tls", "none"]),
        .init(key: "mail.smtpPort", env: "SMTP_PORT", category: "mail", type: .int,
              label: "SMTP-Port", help: "Leer: Standardport der gewählten Verschlüsselung.", min: 1, max: 65535),
        .init(key: "mail.smtpUser", env: "SMTP_USER", category: "mail", type: .string,
              label: "SMTP-Benutzer", help: "Leer: ohne Anmeldung (Benutzer und Passwort nur gemeinsam).", placeholder: "todolino@example.org"),
        .init(key: "mail.smtpPassword", env: "SMTP_PASSWORD", category: "mail", type: .string,
              label: "SMTP-Passwort", help: "Wird verschlüsselt gespeichert und nie angezeigt.", secret: true),
        .init(key: "mail.from", env: "MAIL_FROM", category: "mail", type: .string,
              label: "Absenderadresse", help: "Adresse im Absenderfeld.", placeholder: "todolino@example.org"),
        .init(key: "mail.fromName", env: "MAIL_FROM_NAME", category: "mail", type: .string, defaultValue: "Todolino",
              label: "Absendername", help: "Anzeigename im Absenderfeld.", maxLength: 128),
        // Push
        .init(key: "push.enabled", env: "APNS_ENABLED", category: "push", type: .bool, defaultValue: "false",
              label: "Push aktiv", help: "Nur mit Schlüssel, Key-ID und Team-ID einschaltbar."),
        .init(key: "push.keyId", env: "APNS_KEY_ID", category: "push", type: .string,
              label: "Key-ID", help: "10 Zeichen A-Z0-9, im Apple-Entwicklerportal neben dem Schlüssel.", maxLength: 10, placeholder: "ABCDE12345"),
        .init(key: "push.teamId", env: "APNS_TEAM_ID", category: "push", type: .string,
              label: "Team-ID", help: "10 Zeichen A-Z0-9 des Apple-Entwicklerteams.", maxLength: 10, placeholder: "ABCDE12345"),
        .init(key: "push.topics", env: "APNS_TOPIC", category: "push", type: .stringList, defaultValue: "de.linolaske.todo",
              label: "Bundle-IDs", help: "Komma-getrennt; die erste ist der Standard.", maxLength: 512),
        .init(key: "push.environment", env: "APNS_ENVIRONMENT", category: "push", type: .enumeration, defaultValue: "production",
              label: "Standard-Umgebung", help: "Für Geräte ohne Angabe: production (TestFlight, App Store) oder sandbox (Xcode).",
              options: ["production", "sandbox"]),
        .init(key: "push.key", env: "APNS_KEY", category: "push", type: .text,
              label: "APNs-Schlüssel (.p8)", help: "Kompletter Inhalt der .p8-Datei. Wird verschlüsselt gespeichert und nie angezeigt.",
              secret: true, maxLength: 4096),
        // Attachments
        .init(key: "attachments.storage", env: "ATTACHMENT_STORAGE", category: "attachments", type: .enumeration, defaultValue: "database",
              label: "Speicherort für neue Anhänge", help: "database (in der Datenbank) oder s3. Vorhandene Anhänge bleiben, wo sie sind.",
              options: ["database", "s3"]),
        .init(key: "attachments.maxBytes", env: "ATTACHMENT_MAX_BYTES", category: "attachments", type: .int, defaultValue: "10485760",
              label: "Größtes Anhang in Byte", help: "Der Reverse-Proxy muss diese Größe erlauben.", hotReload: false, min: 1024, max: 134_217_728),
        .init(key: "attachments.s3Endpoint", env: "S3_ENDPOINT", category: "attachments", type: .string,
              label: "S3-Endpunkt", help: "URL des S3-kompatiblen Dienstes.", placeholder: "https://s3.example.org"),
        .init(key: "attachments.s3Bucket", env: "S3_BUCKET", category: "attachments", type: .string,
              label: "S3-Bucket", help: "Privater Bucket.", maxLength: 63),
        .init(key: "attachments.s3Region", env: "S3_REGION", category: "attachments", type: .string, defaultValue: "us-east-1",
              label: "S3-Region", help: "Region für die Signatur.", maxLength: 64),
        .init(key: "attachments.s3AccessKey", env: "S3_ACCESS_KEY", category: "attachments", type: .string,
              label: "S3-Access-Key", help: "Wird verschlüsselt gespeichert und nie angezeigt.", secret: true),
        .init(key: "attachments.s3SecretKey", env: "S3_SECRET_KEY", category: "attachments", type: .string,
              label: "S3-Secret-Key", help: "Wird verschlüsselt gespeichert und nie angezeigt.", secret: true),
        // Maintenance
        .init(key: "maintenance.cleanupIntervalMinutes", env: "CLEANUP_INTERVAL_MINUTES", category: "maintenance", type: .int, defaultValue: "360",
              label: "Aufräum-Intervall (Minuten)", help: "0 schaltet den eingebauten Aufräumer ab.", hotReload: false, min: 0, max: 10_080),
        .init(key: "maintenance.syncRetentionDays", env: "SYNC_RETENTION_DAYS", category: "maintenance", type: .int, defaultValue: "90",
              label: "Sync-Protokoll aufbewahren (Tage)", help: "Ältere Einträge werden gelöscht; Clients synchronisieren dann neu. 0 behält alles.",
              hotReload: false, min: 0, max: 3650),
        // Live
        .init(key: "live.enabled", env: "LIVE_REFRESH_ENABLED", category: "live", type: .bool, defaultValue: "true",
              label: "Live-Aktualisierung aktiv", help: "Aus: Clients fragen nur in festen Abständen ab.", lenientEnv: true),
        .init(key: "live.pollMs", env: "LIVE_POLL_MS", category: "live", type: .int, defaultValue: "1500",
              label: "Prüfabstand je Replikat (ms)", help: "Wie oft ein Replikat bei wartenden Verbindungen die Datenbank prüft.", min: 100, max: 60_000, lenientEnv: true),
        .init(key: "live.waitMaxSeconds", env: "LIVE_WAIT_MAX_SECONDS", category: "live", type: .int, defaultValue: "25",
              label: "Längste Wartezeit (Sekunden)", help: "Höchstdauer einer wartenden Verbindung.", min: 1, max: 120, lenientEnv: true),
        .init(key: "live.maxWaitersPerAccount", env: "LIVE_MAX_WAITERS_PER_ACCOUNT", category: "live", type: .int, defaultValue: "8",
              label: "Verbindungen je Konto", help: "Gleichzeitig wartende Verbindungen je Konto und Replikat.", min: 1, max: 1000, lenientEnv: true),
        .init(key: "live.maxWaitersPerReplica", env: "LIVE_MAX_WAITERS_PER_REPLICA", category: "live", type: .int, defaultValue: "500",
              label: "Verbindungen je Replikat", help: "Gleichzeitig wartende Verbindungen je Replikat.", min: 1, max: 100_000, lenientEnv: true),
        .init(key: "live.clientPollSeconds", env: "LIVE_CLIENT_POLL_SECONDS", category: "live", type: .int, defaultValue: "5",
              label: "Abfrage-Abstand der Clients (Sekunden)", help: "Empfehlung an Clients ohne Long-Polling.", min: 1, max: 3600, lenientEnv: true),
        // Limits
        .init(key: "limits.rateWindowSeconds", env: "IDENTITY_RATE_WINDOW_SECONDS", category: "limits", type: .int, defaultValue: "60",
              label: "Zeitfenster der Limits (Sekunden)", help: "Gilt für alle folgenden Anmelde-Limits.", min: 1, max: 86_400, lenientEnv: true),
        .init(key: "limits.loginLimit", env: "IDENTITY_LOGIN_LIMIT", category: "limits", type: .int, defaultValue: "60",
              label: "Passkey-Anmeldungen je Fenster", help: "Versuche je Absender und Zeitfenster.", min: 1, max: 100_000, lenientEnv: true),
        .init(key: "limits.passwordLimit", env: "IDENTITY_PASSWORD_LIMIT", category: "limits", type: .int, defaultValue: "10",
              label: "Passwort-Versuche je Fenster", help: "Versuche je Absender und Zeitfenster.", min: 1, max: 100_000, lenientEnv: true),
        .init(key: "limits.registerLimit", env: "IDENTITY_REGISTER_LIMIT", category: "limits", type: .int, defaultValue: "10",
              label: "Registrierungen je Fenster", help: "Versuche je Absender und Zeitfenster.", min: 1, max: 100_000, lenientEnv: true),
        .init(key: "limits.recoveryLimit", env: "IDENTITY_RECOVERY_LIMIT", category: "limits", type: .int, defaultValue: "5",
              label: "Recovery-Versuche je Fenster", help: "Versuche je Absender und Zeitfenster.", min: 1, max: 100_000, lenientEnv: true),
        .init(key: "limits.recoverySeconds", env: "IDENTITY_RECOVERY_SECONDS", category: "limits", type: .int, defaultValue: "3600",
              label: "Gültigkeit eines Recovery-Codes (Sekunden)", help: "Danach verfällt der Code.", min: 1, max: 2_592_000, lenientEnv: true),
        .init(key: "limits.recoverySessionSeconds", env: "IDENTITY_RECOVERY_SESSION_SECONDS", category: "limits", type: .int, defaultValue: "300",
              label: "Gültigkeit der Recovery-Sitzung (Sekunden)", help: "Zeit, um nach dem Einlösen einen neuen Passkey anzulegen.", min: 1, max: 86_400, lenientEnv: true),
        // Security
        .init(key: "security.outboundProtection", env: "OUTBOUND_TARGET_PROTECTION", category: "security", type: .enumeration, defaultValue: "standard",
              label: "Zielschutz für Mail und S3",
              help: "standard sperrt Link-Local- und Metadaten-Adressen (z. B. 169.254.169.254), lokale Mailserver und MinIO bleiben erlaubt. strict sperrt zusätzlich Loopback und private Netze. off schaltet den Schutz ab.",
              options: ["off", "standard", "strict"]),
        // Apple
        .init(key: "apple.appIds", env: "AASA_APP_IDS", category: "apple", type: .stringList,
              label: "App-IDs für Passkeys", help: "TeamID.BundleID, komma-getrennt, ausgeliefert unter /.well-known/apple-app-site-association.",
              maxLength: 1024, placeholder: "ABCDE12345.de.linolaske.todo"),
    ]

    static let byKey: [String: SettingDefinition] = Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0) })

    /// Settings that exist only as environment variables: bootstrap, trust anchors and secrets of the settings system itself.
    struct FixedSetting: Sendable {
        let name: String, label: String, help: String
        /// Public values (never secrets) may be shown.
        let showValue: Bool
    }
    static let fixed: [FixedSetting] = [
        .init(name: "DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASSWORD", label: "Datenbank-Verbindung",
              help: "Ohne Datenbank gibt es keine gespeicherten Einstellungen. Nur per Umgebung oder Docker-Secret.", showValue: false),
        .init(name: "RP_ID", label: "Passkey-Domain (RP_ID)", help: "Eine Änderung macht alle Passkeys unbrauchbar. Nur per Umgebung.", showValue: true),
        .init(name: "RP_ORIGIN", label: "Browser-Adresse (RP_ORIGIN)", help: "Muss exakt zur Adresse im Browser passen. Nur per Umgebung.", showValue: true),
        .init(name: "OAUTH_ISSUER", label: "OAuth/MCP-Adresse (OAUTH_ISSUER)", help: "Bindet ausgegebene Tokens. Nur per Umgebung.", showValue: true),
        .init(name: "SETTINGS_ENCRYPTION_KEY", label: "Schlüssel für gespeicherte Geheimnisse", help: "Verschlüsselt Geheimnisse in der Datenbank; gehört nicht ins selbe Backup wie die Datenbank. Nur per Docker-Secret.", showValue: false),
        .init(name: "BOOTSTRAP_TOKEN", label: "Bootstrap-Token", help: "Erlaubt das Anlegen des ersten Kontos. Nur per Docker-Secret.", showValue: false),
    ]
}

// MARK: - Value handling

extension SettingDefinition {
    /// Validates a typed API value and returns its canonical string form. Throws `SettingsProblem`.
    func normalize(_ raw: JSONValueLike) throws -> String {
        func bad(_ message: String) -> SettingsProblem { SettingsProblem(code: "invalid_setting", key: key, message: "\(label): \(message)") }
        switch type {
        case .bool:
            guard case .bool(let b) = raw else { throw bad("erwartet ja oder nein.") }
            return b ? "true" : "false"
        case .int:
            let n: Int
            switch raw {
            case .int(let v): n = v
            case .string(let s):
                guard let v = Int(s.trimmingCharacters(in: .whitespaces)) else { throw bad("erwartet eine ganze Zahl.") }
                n = v
            default: throw bad("erwartet eine ganze Zahl.")
            }
            if let min, n < min { throw bad("muss mindestens \(min) sein.") }
            if let max, n > max { throw bad("darf höchstens \(max) sein.") }
            return String(n)
        case .string, .text, .enumeration, .stringList:
            guard case .string(var s) = raw else { throw bad("erwartet einen Text.") }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { throw bad("darf nicht leer sein (zum Entfernen „Zurücksetzen“ verwenden).") }
            guard s.utf8.count <= maxLength else { throw bad("ist zu lang (höchstens \(maxLength) Zeichen).") }
            guard !s.unicodeScalars.contains(where: { $0.value == 0 }) else { throw bad("enthält unzulässige Zeichen.") }
            if type != .text, s.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) { throw bad("darf keine Zeilenumbrüche enthalten.") }
            if type == .enumeration, let options, !options.contains(s) { throw bad("erlaubt sind: \(options.joined(separator: ", ")).") }
            if type == .stringList {
                s = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
                guard !s.isEmpty else { throw bad("darf nicht leer sein.") }
            }
            return s
        }
    }

    /// Lenient parse of an environment/DB string (used by the resolver); nil when it does not fit the type.
    func parseStored(_ s: String) -> String? {
        switch type {
        case .bool: return s == "true" || s == "false" ? s : nil
        case .int:
            guard let n = Int(s) else { return nil }
            if let min, n < min { return nil }
            if let max, n > max { return nil }
            return String(n)
        case .enumeration: return options?.contains(s) == true ? s : nil
        default: return s
        }
    }
}

/// Minimal typed JSON value for the API (avoids Double for integers).
enum JSONValueLike: Sendable, Equatable {
    case bool(Bool), int(Int), string(String), null
}

extension JSONValueLike: Codable {
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }
    /// Typed form of a canonical string for responses.
    static func typed(_ canonical: String, _ type: SettingType) -> JSONValueLike {
        switch type {
        case .bool: return .bool(canonical == "true")
        case .int: return Int(canonical).map(JSONValueLike.int) ?? .string(canonical)
        default: return .string(canonical)
        }
    }
}
