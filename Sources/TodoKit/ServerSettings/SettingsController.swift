import Fluent
import SQLKit
import Vapor

/// Administration of server settings (ADR 0025, contracts/admin-settings.yaml). Everything here requires an admin
/// account; secrets and values of other categories never appear in an audit entry or a log line.

extension SettingsProblem {
    var status: HTTPStatus {
        switch code {
        case "invalid_setting", "setting_dependency", "setting_required", "invalid_env": return .unprocessableEntity
        case "setting_locked", "version_conflict", "encryption_key_missing", "last_admin_required", "mail_disabled", "push_disabled": return .conflict
        case "no_recipient": return .badRequest
        case "rate_limited": return .tooManyRequests
        case "mail_failed": return .badGateway
        default: return .badRequest
        }
    }
}

struct SettingsProblemBody: Content {
    var error = true
    let reason: String
    let message: String
    var key: String?
    var currentVersion: Int?
}

struct SettingsProblemMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch let p as VersionConflict {
            return try await SettingsProblemBody(reason: "version_conflict", message: "Die Einstellung wurde inzwischen von jemand anderem geändert. Bitte neu laden.", key: p.key, currentVersion: p.currentVersion)
                .encodeResponse(status: .conflict, for: request)
        } catch let p as SettingsProblem {
            return try await SettingsProblemBody(reason: p.code, message: p.message, key: p.key).encodeResponse(status: p.status, for: request)
        }
    }
}

struct VersionConflict: Error { let key: String; let currentVersion: Int }

// MARK: - DTOs

struct SettingDTO: Content {
    let key: String
    let category: String
    let label: String
    let help: String
    let type: SettingType
    let env: String
    let secret: Bool
    let hotReload: Bool
    /// true when the value is only read at startup ("wirkt nach Neustart").
    let requiresRestart: Bool
    let origin: SettingOrigin
    /// true whenever the environment variable is set: the PWA cannot change it.
    let locked: Bool
    /// Effective value; never present for secrets.
    var value: JSONValueLike?
    var defaultValue: JSONValueLike?
    /// Secrets: whether a value exists (any origin).
    var isSet: Bool
    /// A stored secret that the configured key cannot decrypt.
    var unreadable: Bool
    var fingerprint: String?
    let version: Int
    var updatedAt: Date?
    var updatedBy: String?
    var min: Int?
    var max: Int?
    var options: [String]?
    var placeholder: String?
}

struct SettingsOverview: Content {
    struct Category: Content { let id: String; let label: String; let help: String }
    struct Fixed: Content { let name: String; let label: String; let help: String; let isSet: Bool; var value: String? }
    let encryptionKeyConfigured: Bool
    let categories: [Category]
    let settings: [SettingDTO]
    let fixed: [Fixed]
    /// Problem that stopped the last hot reload on this replica (message without values).
    var lastError: String?
}

struct PutSettingBody: Content { let value: JSONValueLike; let version: Int? }
struct AuditEntryDTO: Content {
    let id: UUID, key: String, action: String
    var actorID: UUID?
    let actorName: String
    var detail: String?
    var version: Int?
    var at: Date?
}
struct MailTestBody: Content { var to: String? }
struct SettingsTestResult: Content {
    var ok: Bool
    var message: String
    var durationMs: Int?
    var details: [String: String]?
}
struct AdminUserDTO: Content { let id: UUID, displayName: String, isAdmin: Bool; var username: String? }
struct SetAdminBody: Content { let isAdmin: Bool }

// MARK: - Controller

struct SettingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("v1", "admin").grouped(SettingsProblemMiddleware())
        let s = admin.grouped("settings")
        s.get(use: overview)
        s.get("audit", use: audit)
        s.post("test", ":kind", use: test)
        s.put(":key", use: put)
        s.delete(":key", use: reset)
        admin.get("health", use: health)
        admin.get("users", use: users)
        admin.put("users", ":id", "admin", use: setAdmin)
    }

    private func runtime(_ req: Request) throws -> SettingsRuntime { try req.application.requireSettingsRuntime() }

    // MARK: Overview

    @Sendable func overview(_ req: Request) async throws -> SettingsOverview {
        _ = try await req.requireAdmin()
        let rt = try runtime(req)
        let loaded = try await rt.load(on: req.db)
        let values = try rt.resolve(loaded)
        let rows = Dictionary(uniqueKeysWithValues: loaded.rows.map { ($0.settingKey, $0) })
        let names = try await userNames(rows.values.compactMap(\.updatedBy), on: req.db)
        let locked = SettingsResolver.lockedKeys(env: rt.env)
        let settings = SettingsRegistry.definitions.map { d in
            dto(d, resolved: values.items[d.key], row: rows[d.key], locked: locked.contains(d.key),
                unreadable: loaded.unreadable.contains(d.key), names: names)
        }
        let fixed = SettingsRegistry.fixed.map { f -> SettingsOverview.Fixed in
            let first = f.name.split(separator: " ").first.map(String.init) ?? f.name
            let value = (try? RuntimeEnvironment.value(first, get: rt.env)).flatMap { $0 }
            return .init(name: f.name, label: f.label, help: f.help, isSet: !(value ?? "").isEmpty, value: f.showValue ? value : nil)
        }
        let fixedWithKey = fixed.map { f -> SettingsOverview.Fixed in
            var f = f
            if f.name == "SETTINGS_ENCRYPTION_KEY" { f = .init(name: f.name, label: f.label, help: f.help, isSet: rt.keyRing.canEncrypt, value: nil) }
            return f
        }
        return SettingsOverview(
            encryptionKeyConfigured: rt.keyRing.canEncrypt,
            categories: SettingsRegistry.categories.map { .init(id: $0.id, label: $0.label, help: $0.help) },
            settings: settings, fixed: fixedWithKey, lastError: rt.lastError.map { _ in "Die zuletzt gespeicherte Konfiguration konnte auf diesem Replikat nicht angewendet werden; die vorherige bleibt aktiv." })
    }

    private func userNames(_ ids: [UUID], on db: any Database) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let users = try await User.query(on: db).filter(\.$id ~~ Array(Set(ids))).all()
        return Dictionary(uniqueKeysWithValues: users.compactMap { u in u.id.map { ($0, u.displayName) } })
    }

    private func dto(_ d: SettingDefinition, resolved: ResolvedSetting?, row: ServerSetting?, locked: Bool, unreadable: Bool, names: [UUID: String]) -> SettingDTO {
        let value = resolved?.value
        return SettingDTO(
            key: d.key, category: d.category, label: d.label, help: d.help, type: d.type, env: d.env, secret: d.secret,
            hotReload: d.hotReload, requiresRestart: !d.hotReload, origin: resolved?.origin ?? .default, locked: locked,
            value: d.secret ? nil : value.map { JSONValueLike.typed($0, d.type) },
            defaultValue: d.defaultValue.map { JSONValueLike.typed($0, d.type) },
            isSet: value != nil || unreadable, unreadable: unreadable,
            fingerprint: d.secret && resolved?.origin == .db ? row?.fingerprint : nil,
            version: row?.version ?? 0, updatedAt: row?.updatedAt, updatedBy: row?.updatedBy.flatMap { names[$0] },
            min: d.min, max: d.max, options: d.options, placeholder: d.placeholder)
    }

    private func singleDTO(_ key: String, _ req: Request) async throws -> SettingDTO {
        let rt = try runtime(req)
        let loaded = try await rt.load(on: req.db)
        let values = try rt.resolve(loaded)
        let row = loaded.rows.first { $0.settingKey == key }
        let names = try await userNames(row?.updatedBy.map { [$0] } ?? [], on: req.db)
        return dto(SettingsRegistry.byKey[key]!, resolved: values.items[key], row: row,
                   locked: SettingsResolver.lockedKeys(env: rt.env).contains(key), unreadable: loaded.unreadable.contains(key), names: names)
    }

    // MARK: Change

    private func definition(_ req: Request) throws -> SettingDefinition {
        guard let key = req.parameters.get("key"), let d = SettingsRegistry.byKey[key] else { throw Abort(.notFound, reason: "unknown_setting") }
        return d
    }

    private func requireUnlocked(_ d: SettingDefinition, _ rt: SettingsRuntime) throws {
        if SettingsResolver.lockedKeys(env: rt.env).contains(d.key) {
            throw SettingsProblem(code: "setting_locked", key: d.key,
                                  message: "\(d.label) ist per Umgebungsvariable \(d.env) festgelegt und kann in der PWA nicht geändert werden.")
        }
    }

    /// Rejects a change that makes the effective configuration invalid, unless the same problem already existed.
    private func validate(_ rt: SettingsRuntime, current: SettingsRuntime.Loaded, changing key: String, to canonical: String?, app: Application) throws {
        func check(_ stored: [String: String]) -> SettingsProblem? {
            do {
                let values = try SettingsResolver.resolve(env: rt.env, stored: stored)
                var s = app.settings
                try s.applyHot(values, strict: true)
                return nil
            } catch let p as SettingsProblem { return p } catch { return SettingsProblem(code: "invalid_setting", key: key, message: "\(error)") }
        }
        var after = current.values
        after[key] = canonical
        if let problem = check(after) {
            let before = check(current.values)
            if before?.code != problem.code || before?.key != problem.key { throw problem }
        }
    }

    /// Stored credentials stay bound to the destination they were saved for: changing the destination requires
    /// removing the credentials first, so they cannot be sent to a host the admin picks afterwards.
    private func requireCredentialsNotRebound(_ d: SettingDefinition, current: SettingsRuntime.Loaded, to canonical: String?) throws {
        let bound: [String: [String]] = [
            "mail.smtpHost": ["mail.smtpUser", "mail.smtpPassword"], "mail.smtpPort": ["mail.smtpUser", "mail.smtpPassword"],
            "attachments.s3Endpoint": ["attachments.s3AccessKey", "attachments.s3SecretKey"],
        ]
        guard let credentials = bound[d.key], let old = current.values[d.key], old != canonical,
              credentials.contains(where: { current.values[$0] != nil || current.unreadable.contains($0) }) else { return }
        throw SettingsProblem(code: "setting_dependency", key: d.key,
                              message: "\(d.label) kann nicht geändert werden, solange gespeicherte Zugangsdaten dazu gehören. Zugangsdaten zuerst zurücksetzen, dann ändern und neu eingeben.")
    }

    @Sendable func put(_ req: Request) async throws -> SettingDTO {
        let admin = try await req.requireAdmin()
        let d = try definition(req)
        let rt = try runtime(req)
        try requireUnlocked(d, rt)
        let body = try req.content.decode(PutSettingBody.self)
        let canonical = try d.normalize(body.value)
        let sealed: (blob: String, keyID: String, fingerprint: String)? = d.secret ? try rt.keyRing.seal(canonical, settingKey: d.key) : nil
        let current = try await rt.load(on: req.db)
        try requireCredentialsNotRebound(d, current: current, to: canonical)
        try validate(rt, current: current, changing: d.key, to: canonical, app: req.application)
        let expected = body.version ?? 0
        let adminID = try admin.requireID()
        do {
            try await req.db.transaction { db in
                let existing = try await ServerSetting.query(on: db).filter(\.$settingKey == d.key).first()
                if let existing, let id = existing.id { try await lockRow(table: ServerSetting.schema, id: id, on: db) }
                let row = try await ServerSetting.query(on: db).filter(\.$settingKey == d.key).first()
                guard (row?.version ?? 0) == expected else { throw VersionConflict(key: d.key, currentVersion: row?.version ?? 0) }
                let target = row ?? ServerSetting()
                target.settingKey = d.key
                target.secret = d.secret
                target.value = sealed?.blob ?? canonical
                target.keyID = sealed?.keyID
                target.fingerprint = sealed?.fingerprint
                target.updatedBy = adminID
                target.updatedAt = Date()
                target.version = (row?.version ?? 0) + 1
                try await target.save(on: db)
                try await record(db, key: d.key, action: "set", admin: admin, version: target.version)
            }
        } catch let e as VersionConflict { throw e } catch let e as any DatabaseError where e.isConstraintFailure {
            throw VersionConflict(key: d.key, currentVersion: try await ServerSetting.query(on: req.db).filter(\.$settingKey == d.key).first()?.version ?? 0)
        }
        await rt.refresh(force: true)
        return try await singleDTO(d.key, req)
    }

    @Sendable func reset(_ req: Request) async throws -> Response {
        let admin = try await req.requireAdmin()
        let d = try definition(req)
        let rt = try runtime(req)
        try requireUnlocked(d, rt)
        let expected = req.query[Int.self, at: "version"]
        let current = try await rt.load(on: req.db)
        try requireCredentialsNotRebound(d, current: current, to: nil)
        try validate(rt, current: current, changing: d.key, to: nil, app: req.application)
        try await req.db.transaction { db in
            guard let row = try await ServerSetting.query(on: db).filter(\.$settingKey == d.key).first(), let id = row.id else {
                if let expected, expected != 0 { throw VersionConflict(key: d.key, currentVersion: 0) }
                return
            }
            try await lockRow(table: ServerSetting.schema, id: id, on: db)
            guard let locked = try await ServerSetting.find(id, on: db) else { return }
            if let expected, expected != locked.version { throw VersionConflict(key: d.key, currentVersion: locked.version) }
            guard locked.value != nil else { return }
            locked.value = nil; locked.keyID = nil; locked.fingerprint = nil
            locked.updatedBy = try admin.requireID(); locked.updatedAt = Date(); locked.version += 1
            try await locked.save(on: db)
            try await record(db, key: d.key, action: "reset", admin: admin, version: locked.version)
        }
        await rt.refresh(force: true)
        return try await singleDTO(d.key, req).encodeResponse(for: req)
    }

    private func record(_ db: any Database, key: String, action: String, admin: User, version: Int?, detail: String? = nil) async throws {
        let e = ServerSettingAudit()
        e.settingKey = key; e.action = action; e.actorID = admin.id; e.actorName = admin.displayName
        e.detail = detail; e.version = version
        try await e.save(on: db)
    }

    // MARK: Audit

    @Sendable func audit(_ req: Request) async throws -> [AuditEntryDTO] {
        _ = try await req.requireAdmin()
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 200)
        var q = ServerSettingAudit.query(on: req.db)
        if let key = req.query[String.self, at: "key"] { q = q.filter(\.$settingKey == key) }
        let rows = try await q.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit).all()
        return try rows.map { AuditEntryDTO(id: try $0.requireID(), key: $0.settingKey, action: $0.action, actorID: $0.actorID,
                                            actorName: $0.actorName, detail: $0.detail, version: $0.version, at: $0.createdAt) }
    }

    // MARK: Tests

    @Sendable func test(_ req: Request) async throws -> SettingsTestResult {
        let admin = try await req.requireAdmin()
        let adminID = try admin.requireID()
        guard let kind = req.parameters.get("kind"), ["mail", "apns", "storage"].contains(kind) else { throw Abort(.notFound, reason: "unknown_test") }
        guard try await IdentityRateLimit.take(scope: "settings-test-\(kind)", subject: "user:\(adminID)", limit: 6, window: 600, on: req.db) else {
            throw SettingsProblem(code: "rate_limited", key: nil, message: "Zu viele Tests in kurzer Zeit. Bitte etwas warten.")
        }
        let result: SettingsTestResult
        switch kind {
        case "mail": result = try await testMail(req, admin: admin)
        case "apns": result = try await testPush(req, admin: admin)
        default: result = try await testStorage(req)
        }
        try await record(req.db, key: "test.\(kind)", action: "test", admin: admin, version: nil, detail: result.ok ? "ok" : "failed")
        return result
    }

    private func testMail(_ req: Request, admin: User) async throws -> SettingsTestResult {
        guard req.application.settings.mail.enabled, let transport = req.application.mailTransport else {
            throw SettingsProblem(code: "mail_disabled", key: "mail.enabled", message: "Der E-Mail-Versand ist nicht eingeschaltet.")
        }
        let body = (try? req.content.decode(MailTestBody.self)) ?? MailTestBody()
        let recipient: String
        if let raw = body.to?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            recipient = MailAddress.normalize(raw)
            guard MailAddress.isValid(recipient) else { throw SettingsProblem(code: "invalid_setting", key: nil, message: "Die Empfängeradresse ist ungültig.") }
        } else if let own = try await MailService(db: req.db, settings: req.application.settings).confirmedEmail(of: admin.requireID()) {
            recipient = own.email
        } else {
            throw SettingsProblem(code: "no_recipient", key: nil, message: "Gib eine Empfängeradresse an oder bestätige zuerst deine eigene E-Mail-Adresse im Konto.")
        }
        let mail = MailTemplates.test()
        let started = ContinuousClock.now
        do {
            try await transport.send(MailMessage(to: recipient, subject: mail.subject, text: mail.text, html: mail.html))
        } catch let e as MailSendError {
            return SettingsTestResult(ok: false, message: Self.mailFailure(e), details: ["stage": e.stage.rawValue, "code": e.code.map(String.init) ?? ""])
        } catch {
            return SettingsTestResult(ok: false, message: "Die Test-Mail konnte nicht gesendet werden.", details: nil)
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        return SettingsTestResult(ok: true, message: "Test-Mail an \(recipient) wurde vom Mailserver angenommen.", durationMs: ms, details: nil)
    }

    static func mailFailure(_ e: MailSendError) -> String {
        switch e.stage {
        case .blocked: return "Das Ziel ist durch den Zielschutz gesperrt (Einstellung „Zielschutz für Mail und S3“ in der Kategorie Sicherheit)."
        case .connect: return "Verbindung zum Mailserver fehlgeschlagen: Host und Port prüfen."
        case .tls: return "Die verschlüsselte Verbindung zum Mailserver ist fehlgeschlagen: Verschlüsselung und Port prüfen."
        case .auth: return "Der Mailserver hat die Anmeldung abgelehnt: Benutzer und Passwort prüfen."
        case .sender: return "Der Mailserver lehnt die Absenderadresse ab."
        case .recipient: return "Der Mailserver nimmt die Empfängeradresse nicht an."
        case .timeout: return "Der Mailserver hat nicht rechtzeitig geantwortet."
        default: return "Der Mailserver hat die Nachricht nicht angenommen."
        }
    }

    private func testPush(_ req: Request, admin: User) async throws -> SettingsTestResult {
        guard req.application.settings.apns.enabled, let sender = req.application.apnsSender else {
            throw SettingsProblem(code: "push_disabled", key: "push.enabled", message: "Push ist nicht eingeschaltet.")
        }
        // Signing a token proves that key, key ID and team ID are consistent before any device is contacted.
        do { _ = try await sender.auth.token() } catch {
            return SettingsTestResult(ok: false, message: "Der APNs-Schlüssel kann kein Token signieren. Schlüssel prüfen.")
        }
        let adminID = try admin.requireID()
        let devices = try await PushDevice.query(on: req.db).filter(\.$userID == adminID).filter(\.$revokedAt == nil).sort(\.$id).all()
        guard !devices.isEmpty else {
            return SettingsTestResult(ok: true, message: "Die Konfiguration ist stimmig (Token signiert). Dein Konto hat kein registriertes Gerät, daher wurde nichts gesendet.")
        }
        var details: [String: String] = [:]
        var sent = 0
        for device in devices {
            let message = PushContent.testMessage(locale: device.locale)
            let outcome = await sender.send(to: device, payload: try message.payload(), priority: message.priority, ttl: message.ttl, collapseKey: nil)
            let label = "\(device.platform) (\(device.environment))"
            switch outcome {
            case .delivered: sent += 1; details[label] = "gesendet"
            case .revoke(let why): device.revokedAt = Date(); try await device.save(on: req.db); details[label] = "Gerät abgemeldet (\(why))"
            case .retry(let why), .permanent(let why): details[label] = "fehlgeschlagen (\(why))"
            }
        }
        return SettingsTestResult(ok: sent > 0, message: sent > 0 ? "Testbenachrichtigung an \(sent) Gerät(e) gesendet." : "Keine Testbenachrichtigung konnte zugestellt werden.", details: details)
    }

    private func testStorage(_ req: Request) async throws -> SettingsTestResult {
        var details: [String: String] = [:]
        if let sql = req.db as? any SQLDatabase {
            do { _ = try await sql.raw("SELECT 1").all(); details["Datenbank"] = "erreichbar" }
            catch { return SettingsTestResult(ok: false, message: "Die Datenbank ist nicht erreichbar.") }
        }
        let settings = req.application.settings
        guard settings.attachmentStorage == .s3 else {
            return SettingsTestResult(ok: true, message: "Neue Anhänge werden in der Datenbank gespeichert; die Datenbank ist erreichbar.", details: details)
        }
        let store: any AttachmentStore
        do { store = try AttachmentService(settings: settings).store(.s3) } catch {
            return SettingsTestResult(ok: false, message: "Der S3-Speicher ist unvollständig konfiguriert.", details: details)
        }
        let key = "healthcheck/\(UUID().uuidString)"
        let probe = Data("todolino-storage-check".utf8)
        let started = ContinuousClock.now
        do {
            try await store.put(key: key, data: probe, db: req.db)
            let back = try await store.get(key: key, db: req.db)
            try await store.delete(key: key, db: req.db)
            guard back == probe else { return SettingsTestResult(ok: false, message: "Der S3-Speicher liefert andere Daten zurück, als geschrieben wurden.", details: details) }
        } catch let e as Abort where e.reason == "outbound_target_blocked" {
            return SettingsTestResult(ok: false, message: "Das Ziel ist durch den Zielschutz gesperrt (Einstellung „Zielschutz für Mail und S3“ in der Kategorie Sicherheit).", details: details)
        } catch {
            return SettingsTestResult(ok: false, message: "Der S3-Speicher antwortet nicht wie erwartet: Endpunkt, Bucket, Region und Schlüssel prüfen.", details: details)
        }
        details["S3"] = "schreiben, lesen und löschen erfolgreich"
        return SettingsTestResult(ok: true, message: "Der S3-Speicher funktioniert.", durationMs: Int((ContinuousClock.now - started) / .milliseconds(1)), details: details)
    }

    // MARK: Health details

    /// Operational details that `/health/ready` no longer shows anonymously.
    @Sendable func health(_ req: Request) async throws -> HealthResponse {
        _ = try await req.requireAdmin()
        let settings = req.application.settings
        return HealthResponse(status: "ok", maintenance: await CleanupScheduler.status(of: req.application),
                              push: PushStatus(enabled: settings.apns.enabled, environment: settings.apns.environment.rawValue),
                              mail: MailStatus(enabled: settings.mail.enabled))
    }

    // MARK: Admins

    @Sendable func users(_ req: Request) async throws -> [AdminUserDTO] {
        _ = try await req.requireAdmin()
        return try await User.query(on: req.db).sort(\.$displayName).sort(\.$id).all().map {
            AdminUserDTO(id: try $0.requireID(), displayName: $0.displayName, isAdmin: $0.isAdmin, username: $0.username)
        }
    }

    /// At least one admin must remain: the check runs under row locks on all current admins.
    @Sendable func setAdmin(_ req: Request) async throws -> AdminUserDTO {
        let actor = try await req.requireAdmin()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let body = try req.content.decode(SetAdminBody.self)
        let updated: User = try await req.db.transaction { db in
            if let sql = db as? any SQLDatabase, sql.dialect.name != "sqlite" {
                _ = try await sql.raw("SELECT id FROM users WHERE is_admin = 1 FOR UPDATE").all()
            }
            guard let user = try await User.find(id, on: db) else { throw Abort(.notFound) }
            if user.isAdmin == body.isAdmin { return user }
            if !body.isAdmin, try await User.query(on: db).filter(\.$isAdmin == true).count() <= 1 {
                throw SettingsProblem(code: "last_admin_required", key: nil, message: "Mindestens ein Administrator muss bleiben.")
            }
            user.isAdmin = body.isAdmin
            try await user.save(on: db)
            try await record(db, key: "admin.role", action: "admin", admin: actor, version: nil, detail: body.isAdmin ? "granted" : "revoked")
            return user
        }
        return AdminUserDTO(id: try updated.requireID(), displayName: updated.displayName, isAdmin: updated.isAdmin, username: updated.username)
    }
}

// MARK: - Command

/// `todo-app settings rotate-key --yes`: re-encrypts every stored secret with `SETTINGS_ENCRYPTION_KEY`.
/// Rollout: set the new key as SETTINGS_ENCRYPTION_KEY and the old one as SETTINGS_ENCRYPTION_KEY_PREVIOUS on all
/// replicas, run this command once, then remove the previous key.
struct SettingsCommandGroup: AsyncCommandGroup {
    let help = "Server settings administration."
    let commands: [String: any AnyAsyncCommand] = ["rotate-key": RotateSettingsKeyCommand()]
    var defaultCommand: (any AnyAsyncCommand)? { nil }
}

struct RotateSettingsKeyCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "yes", help: "Confirm that all stored secrets are re-encrypted with the current key.")
        var yes: Bool
    }
    let help = "Re-encrypt stored secrets with SETTINGS_ENCRYPTION_KEY (old key in SETTINGS_ENCRYPTION_KEY_PREVIOUS)."

    func run(using context: CommandContext, signature: Signature) async throws {
        guard signature.yes else { throw Abort(.badRequest, reason: "confirmation_required: pass --yes") }
        let ring = try SettingsKeyRing.fromEnvironment(get: { Environment.get($0) })
        let n = try await Self.rotate(ring: ring, on: context.application.db)
        context.console.print("re-encrypted \(n) secret(s)")
    }

    static func rotate(ring: SettingsKeyRing, on db: any Database) async throws -> Int {
        guard let current = ring.current else { throw Abort(.badRequest, reason: "SETTINGS_ENCRYPTION_KEY is not set") }
        var count = 0
        for row in try await ServerSetting.query(on: db).filter(\.$secret == true).all() {
            guard let blob = row.value, row.keyID != current.id else { continue }
            let plain = try ring.open(blob, keyID: row.keyID, settingKey: row.settingKey)
            let sealed = try ring.seal(plain, settingKey: row.settingKey)
            row.value = sealed.blob; row.keyID = sealed.keyID; row.fingerprint = sealed.fingerprint
            try await row.save(on: db)
            count += 1
        }
        return count
    }
}
