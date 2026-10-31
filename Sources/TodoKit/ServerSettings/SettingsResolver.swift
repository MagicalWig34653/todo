import Crypto
import Foundation
import Vapor

enum SettingOrigin: String, Codable, Sendable { case env, db, `default` }

struct ResolvedSetting: Sendable {
    var value: String?
    var origin: SettingOrigin
    /// Set when an environment value does not fit the type of a mail/push setting; reported only when the feature is on.
    var problem: String?
}

/// S3 connection for attachments. Built from `attachments.s3*`.
struct S3Config: Sendable, Equatable {
    var endpoint: URL
    var bucket: String
    var region: String
    var accessKey: String?
    var secretKey: String?
}

/// Effective value of every registry entry: environment (non-empty) > database > default (ADR 0025).
struct SettingValues: Sendable {
    var items: [String: ResolvedSetting] = [:]

    func string(_ key: String) -> String? { items[key]?.value }
    func flag(_ key: String) -> Bool { items[key]?.value == "true" }
    func int(_ key: String) -> Int? { items[key]?.value.flatMap(Int.init) }

    /// Value, or the recorded problem as an error.
    func valid(_ key: String) throws -> String? {
        if let p = items[key]?.problem { throw SettingsProblem(code: "invalid_setting", key: key, message: p) }
        return items[key]?.value
    }

    static func ref(_ key: String) -> String {
        guard let d = SettingsRegistry.byKey[key] else { return key }
        return "\(d.label) (\(d.env))"
    }

    func missing(_ key: String, _ why: String) -> SettingsProblem {
        SettingsProblem(code: "setting_required", key: key, message: "\(why) Es fehlt: \(Self.ref(key)).")
    }
}

enum SettingsResolver {
    /// - Parameters:
    ///   - env: environment lookup (also resolves `<NAME>_FILE`).
    ///   - stored: decrypted database values by setting key.
    static func resolve(env get: (String) -> String?, stored: [String: String]) throws -> SettingValues {
        var out = SettingValues()
        for d in SettingsRegistry.definitions {
            var item = ResolvedSetting(value: d.defaultValue, origin: .default, problem: nil)
            let raw = try RuntimeEnvironment.value(d.env, get: get).flatMap { $0.isEmpty ? nil : $0 }
            if let raw {
                let bareBool = d.key == "auth.passwordLoginEnabled"
                if bareBool {
                    item = .init(value: raw == "true" ? "true" : "false", origin: .env, problem: nil)
                } else if let parsed = d.parseStored(raw) {
                    item = .init(value: parsed, origin: .env, problem: nil)
                } else if d.lenientEnv {
                    // Historic behaviour: invalid LIVE_* / IDENTITY_* values fall back to the default.
                } else if d.category == "mail" || d.category == "push", d.key != "mail.enabled", d.key != "push.enabled" {
                    item = .init(value: nil, origin: .env, problem: "\(d.label) (\(d.env)) hat einen ungültigen Wert.")
                } else {
                    throw SettingsProblem(code: "invalid_env", key: d.key, message: "\(d.label) (\(d.env)) hat einen ungültigen Wert.")
                }
            } else if let s = stored[d.key], let parsed = d.parseStored(s) {
                item = .init(value: parsed, origin: .db, problem: nil)
            }
            out.items[d.key] = item
        }
        return out
    }

    /// Names of the keys whose environment value is set (non-empty), i.e. locked in the PWA.
    static func lockedKeys(env get: (String) -> String?) -> Set<String> {
        Set(SettingsRegistry.definitions.filter { d in
            (try? RuntimeEnvironment.value(d.env, get: get)).flatMap { $0 }.map { !$0.isEmpty } ?? false
        }.map(\.key))
    }
}

// MARK: - Builders

extension SettingValues {
    func mailConfig() throws -> MailConfig {
        var c = MailConfig()
        guard flag("mail.enabled") else { return c }
        c.enabled = true
        guard let host = try valid("mail.smtpHost"), !host.isEmpty else {
            throw missing("mail.smtpHost", "Der E-Mail-Versand ist eingeschaltet, aber der Mailserver ist nicht angegeben.")
        }
        guard host.utf8.allSatisfy({ (33...126).contains($0) }), !host.contains("/"), !host.contains("@") else {
            throw SettingsProblem(code: "invalid_setting", key: "mail.smtpHost", message: "\(Self.ref("mail.smtpHost")) muss ein einfacher Host-Name oder eine IP-Adresse sein.")
        }
        c.host = host
        if let raw = try valid("mail.smtpSecurity"), let s = SMTPSecurity(rawValue: raw) { c.security = s }
        c.port = c.security.defaultPort
        if let raw = try valid("mail.smtpPort"), let p = Int(raw), (1...65535).contains(p) { c.port = p }
        let user = try valid("mail.smtpUser").flatMap { $0.isEmpty ? nil : $0 }
        let password = try valid("mail.smtpPassword").flatMap { $0.isEmpty ? nil : $0 }
        guard (user == nil) == (password == nil) else {
            throw SettingsProblem(code: "setting_dependency", key: user == nil ? "mail.smtpUser" : "mail.smtpPassword",
                                  message: "SMTP-Benutzer und SMTP-Passwort gehören zusammen: entweder beide angeben oder keines von beiden.")
        }
        if let user, let password {
            guard user.utf8.count <= 256, password.utf8.count <= 256, !user.utf8.contains(0), !password.utf8.contains(0),
                  !user.utf8.contains(13), !user.utf8.contains(10) else {
                throw SettingsProblem(code: "invalid_setting", key: "mail.smtpUser", message: "SMTP-Benutzer oder -Passwort enthalten unzulässige Zeichen oder sind zu lang.")
            }
            if c.security == .none, !MailConfig.isLoopback(host) {
                throw SettingsProblem(code: "setting_dependency", key: "mail.smtpSecurity",
                                      message: "Ohne Verschlüsselung (none) sind Zugangsdaten nur für einen lokalen Server erlaubt. Wähle starttls oder tls.")
            }
        }
        c.user = user; c.password = password
        guard let from = try valid("mail.from"), MailAddress.isValid(from) else {
            throw SettingsProblem(code: "invalid_setting", key: "mail.from", message: "\(Self.ref("mail.from")) muss eine gültige Absenderadresse sein, z. B. todolino@example.org.")
        }
        c.from = from
        if let name = try valid("mail.fromName"), !name.isEmpty {
            guard name.utf8.count <= 128, !name.utf8.contains(13), !name.utf8.contains(10), !name.utf8.contains(0) else {
                throw SettingsProblem(code: "invalid_setting", key: "mail.fromName", message: "Der Absendername ist zu lang oder enthält Steuerzeichen.")
            }
            c.fromName = name
        }
        return c
    }

    func apnsConfig() throws -> APNsConfig {
        var c = APNsConfig()
        if let raw = try valid("push.environment"), let e = APNsEnvironment(rawValue: raw) { c.environment = e }
        if let raw = try valid("push.topics"), !raw.isEmpty {
            c.topics = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard flag("push.enabled") else { return c }
        c.enabled = true
        guard !c.topics.isEmpty, c.topics.allSatisfy({ $0.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil }) else {
            throw SettingsProblem(code: "invalid_setting", key: "push.topics", message: "\(Self.ref("push.topics")) muss Bundle-IDs wie de.example.app enthalten (komma-getrennt).")
        }
        let id = "^[A-Z0-9]{10}$"
        guard let keyID = try valid("push.keyId"), keyID.range(of: id, options: .regularExpression) != nil else {
            throw missing("push.keyId", "Push ist eingeschaltet, aber die Key-ID fehlt oder ist ungültig (10 Zeichen A-Z0-9).")
        }
        guard let teamID = try valid("push.teamId"), teamID.range(of: id, options: .regularExpression) != nil else {
            throw missing("push.teamId", "Push ist eingeschaltet, aber die Team-ID fehlt oder ist ungültig (10 Zeichen A-Z0-9).")
        }
        guard let pem = try valid("push.key"), !pem.isEmpty else {
            throw missing("push.key", "Push ist eingeschaltet, aber der APNs-Schlüssel (.p8) fehlt.")
        }
        do { _ = try P256.Signing.PrivateKey(pemRepresentation: pem) }
        catch { throw SettingsProblem(code: "invalid_setting", key: "push.key", message: "\(Self.ref("push.key")) ist kein gültiger APNs-Schlüssel (PEM, EC P-256).") }
        c.keyID = keyID; c.teamID = teamID; c.keyPEM = pem
        return c
    }

    /// nil when no endpoint/bucket is configured.
    func s3Config() throws -> S3Config? {
        guard let raw = string("attachments.s3Endpoint"), let bucket = string("attachments.s3Bucket") else { return nil }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SettingsProblem(code: "invalid_setting", key: "attachments.s3Endpoint", message: "\(Self.ref("attachments.s3Endpoint")) muss eine http(s)-Adresse ohne Zugangsdaten sein.")
        }
        guard bucket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
            throw SettingsProblem(code: "invalid_setting", key: "attachments.s3Bucket", message: "\(Self.ref("attachments.s3Bucket")) enthält unzulässige Zeichen.")
        }
        let access = string("attachments.s3AccessKey"), secret = string("attachments.s3SecretKey")
        guard (access == nil) == (secret == nil) else {
            throw SettingsProblem(code: "setting_dependency", key: "attachments.s3SecretKey", message: "S3-Access-Key und S3-Secret-Key gehören zusammen.")
        }
        return S3Config(endpoint: url, bucket: bucket, region: string("attachments.s3Region") ?? "us-east-1", accessKey: access, secretKey: secret)
    }

    func liveSettings() -> LiveSettings {
        var s = LiveSettings()
        if let v = int("live.pollMs") { s.pollInterval = Double(v) / 1000 }
        if let v = int("live.waitMaxSeconds") { s.maxWaitSeconds = min(v, 120); s.defaultWaitSeconds = min(25, s.maxWaitSeconds) }
        if let v = int("live.maxWaitersPerAccount") { s.maxWaitersPerAccount = v }
        if let v = int("live.maxWaitersPerReplica") { s.maxWaitersPerReplica = v }
        if let v = int("live.clientPollSeconds") { s.clientPollSeconds = v }
        s.enabled = string("live.enabled") != "false"
        return s
    }

    func identitySettings() -> IdentitySettings {
        var s = IdentitySettings()
        if let v = int("limits.rateWindowSeconds") { s.window = v }
        if let v = int("limits.loginLimit") { s.loginLimit = v }
        if let v = int("limits.passwordLimit") { s.passwordLimit = v }
        if let v = int("limits.registerLimit") { s.registerLimit = v }
        if let v = int("limits.recoveryLimit") { s.recoveryLimit = v }
        if let v = int("limits.recoverySeconds") { s.recoveryLifetime = TimeInterval(v) }
        if let v = int("limits.recoverySessionSeconds") { s.recoverySessionLifetime = TimeInterval(v) }
        return s
    }
}

extension AppSettings {
    /// Values that change at runtime without a restart (`hotReload`).
    mutating func applyHot(_ v: SettingValues, strict: Bool = false) throws {
        passwordLoginEnabled = v.flag("auth.passwordLoginEnabled")
        instanceName = v.string("branding.instanceName") ?? "Todolino"
        appleAppIDs = (v.string("apple.appIds") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        mail = try v.mailConfig()
        apns = try v.apnsConfig()
        s3 = try v.s3Config()
        if let raw = v.string("attachments.storage"), let kind = AttachmentStorageKind(rawValue: raw) { attachmentStorage = kind }
        if strict, attachmentStorage == .s3, s3 == nil {
            throw SettingsProblem(code: "setting_dependency", key: "attachments.storage",
                                  message: "Für S3 fehlen Endpunkt und Bucket (\(SettingValues.ref("attachments.s3Endpoint")), \(SettingValues.ref("attachments.s3Bucket"))).")
        }
    }

    /// Values read once at startup ("wirkt nach Neustart").
    mutating func applyStartup(_ v: SettingValues) {
        if let n = v.int("attachments.maxBytes") { attachmentMaxBytes = n }
        if let n = v.int("maintenance.cleanupIntervalMinutes") { cleanupIntervalMinutes = n }
        if let n = v.int("maintenance.syncRetentionDays") { syncRetentionDays = n }
    }
}
