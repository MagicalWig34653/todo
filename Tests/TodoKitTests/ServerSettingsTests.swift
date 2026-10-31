import Crypto
import Fluent
import Foundation
import XCTest
import XCTVapor
@testable import TodoKit

/// ADR 0025: server settings in the database, environment first. SQLite only; MariaDB is not covered here.
final class ServerSettingsTests: XCTestCase {
    static let keyA = Data(repeating: 1, count: 32).base64EncodedString()
    static let keyB = Data(repeating: 2, count: 32).base64EncodedString()

    struct Fixture {
        let t: TestApp
        let admin: MailTests.Account
        let user: MailTests.Account
        let runtime: SettingsRuntime
    }

    func runtime(_ t: TestApp, env: [String: String] = [:], key: String? = keyA, previous: String? = nil) throws -> SettingsRuntime {
        var all = env
        if let key { all["SETTINGS_ENCRYPTION_KEY"] = key }
        if let previous { all["SETTINGS_ENCRYPTION_KEY_PREVIOUS"] = previous }
        let snapshot = all
        let rt = SettingsRuntime(app: t.app, env: { snapshot[$0] }, keyRing: try .fromEnvironment(get: { snapshot[$0] }), pollInterval: 1)
        t.app.settingsRuntime = rt
        return rt
    }

    func fixture(env: [String: String] = [:], key: String? = keyA) async throws -> Fixture {
        let t = try await TestApp.make()
        let rt = try runtime(t, env: env, key: key)
        try await rt.bootstrap()
        return Fixture(t: t, admin: try await MailTests.account(t, "Root", admin: true), user: try await MailTests.account(t, "Anna"), runtime: rt)
    }

    func get(_ f: Fixture, token: String? = nil) async throws -> [String: Any] {
        let r = try await f.t.json(.GET, "/v1/admin/settings", token: token ?? f.admin.token)
        XCTAssertEqual(r.status, .ok)
        return r.body ?? [:]
    }

    func setting(_ overview: [String: Any], _ key: String) -> [String: Any] {
        ((overview["settings"] as? [[String: Any]]) ?? []).first { $0["key"] as? String == key } ?? [:]
    }

    func put(_ f: Fixture, _ key: String, _ value: Any, version: Int = 0, token: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.t.json(.PUT, "/v1/admin/settings/\(key)", ["value": value, "version": version], token: token ?? f.admin.token)
        return (r.status, r.body)
    }

    // MARK: Resolution

    func testEnvironmentBeatsDatabaseBeatsDefault() async throws {
        let f = try await fixture(env: ["IDENTITY_LOGIN_LIMIT": "7"]); defer { Task { await f.t.shutdown() } }
        var o = try await get(f)
        XCTAssertEqual(setting(o, "limits.loginLimit")["origin"] as? String, "env")
        XCTAssertEqual(setting(o, "limits.loginLimit")["locked"] as? Bool, true)
        XCTAssertEqual(setting(o, "limits.loginLimit")["value"] as? Int, 7)
        XCTAssertEqual(setting(o, "limits.registerLimit")["origin"] as? String, "default")
        XCTAssertEqual(setting(o, "limits.registerLimit")["value"] as? Int, 10)
        // Locked by the environment: the PWA cannot change or reset it.
        let locked = try await put(f, "limits.loginLimit", 9)
        XCTAssertEqual(locked.status, .conflict); XCTAssertEqual(locked.body?["reason"] as? String, "setting_locked")
        let lockedReset = try await f.t.json(.DELETE, "/v1/admin/settings/limits.loginLimit", token: f.admin.token)
        XCTAssertEqual(lockedReset.status, .conflict)
        // Free setting: the database value applies.
        let ok = try await put(f, "limits.registerLimit", 3)
        XCTAssertEqual(ok.status, .ok); XCTAssertEqual(ok.body?["origin"] as? String, "db"); XCTAssertEqual(ok.body?["version"] as? Int, 1)
        XCTAssertEqual(f.t.app.identitySettings.registerLimit, 3)
        XCTAssertEqual(f.t.app.identitySettings.loginLimit, 7)
        // A stored value for a locked key is ignored while the variable is set ...
        let row = ServerSetting()
        row.settingKey = "limits.loginLimit"; row.value = "9"; row.secret = false; row.updatedAt = Date(); row.version = 1
        try await row.save(on: f.t.app.db)
        await f.runtime.refresh(force: true)
        o = try await get(f)
        XCTAssertEqual(setting(o, "limits.loginLimit")["value"] as? Int, 7)
        // ... and takes effect once the variable is removed.
        let rt2 = try runtime(f.t, env: [:])
        await rt2.refresh(force: true)
        o = try await get(f)
        XCTAssertEqual(setting(o, "limits.loginLimit")["value"] as? Int, 9)
        XCTAssertEqual(setting(o, "limits.loginLimit")["origin"] as? String, "db")
        XCTAssertEqual(setting(o, "limits.loginLimit")["locked"] as? Bool, false)
        XCTAssertEqual(f.t.app.identitySettings.loginLimit, 9)
        // Reset returns to the default.
        let reset = try await f.t.json(.DELETE, "/v1/admin/settings/limits.registerLimit?version=1", token: f.admin.token)
        XCTAssertEqual(reset.status, .ok); XCTAssertEqual(reset.body?["origin"] as? String, "default")
        XCTAssertEqual(f.t.app.identitySettings.registerLimit, 10)
    }

    func testEmptyEnvironmentValueDoesNotLock() async throws {
        let f = try await fixture(env: ["IDENTITY_LOGIN_LIMIT": "", "ATTACHMENT_STORAGE": ""]); defer { Task { await f.t.shutdown() } }
        let o = try await get(f)
        XCTAssertEqual(setting(o, "limits.loginLimit")["locked"] as? Bool, false)
        XCTAssertEqual(setting(o, "attachments.storage")["locked"] as? Bool, false)
    }

    func testFixedSettingsAreReadOnlyAndNeverLeakSecrets() async throws {
        let f = try await fixture(env: ["RP_ID": "todo.example.org", "DB_PASSWORD": "hunter2", "BOOTSTRAP_TOKEN": "tok"]); defer { Task { await f.t.shutdown() } }
        let o = try await get(f)
        let fixed = (o["fixed"] as? [[String: Any]]) ?? []
        XCTAssertTrue(fixed.contains { $0["name"] as? String == "RP_ID" && $0["value"] as? String == "todo.example.org" })
        let text = String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        XCTAssertFalse(text.contains("hunter2")); XCTAssertFalse(text.contains("\"tok\""))
        let r = try await f.t.json(.PUT, "/v1/admin/settings/rp.id", ["value": "x", "version": 0], token: f.admin.token)
        XCTAssertEqual(r.status, .notFound)
    }

    // MARK: Rights

    func testOnlyAdminsHaveAccess() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for (m, p) in [(HTTPMethod.GET, "/v1/admin/settings"), (.GET, "/v1/admin/settings/audit"), (.PUT, "/v1/admin/settings/limits.loginLimit"),
                       (.DELETE, "/v1/admin/settings/limits.loginLimit"), (.POST, "/v1/admin/settings/test/mail"), (.GET, "/v1/admin/users")] {
            let anon = try await f.t.json(m, p, ["value": 1, "version": 0])
            XCTAssertEqual(anon.status, .unauthorized, "\(m) \(p)")
            let user = try await f.t.json(m, p, ["value": 1, "version": 0], token: f.user.token)
            XCTAssertEqual(user.status, .forbidden, "\(m) \(p)")
        }
        let rows = try await ServerSetting.query(on: f.t.app.db).count()
        XCTAssertEqual(rows, 0)
    }

    // MARK: Secrets

    func testSecretsAreEncryptedNeverDeliveredAndAudited() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let r = try await put(f, "mail.smtpPassword", "p4ss-w0rd-unique")
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.body?["value"]); XCTAssertEqual(r.body?["isSet"] as? Bool, true)
        let fp = try XCTUnwrap(r.body?["fingerprint"] as? String); XCTAssertEqual(fp.count, 6)
        let row = try await ServerSetting.query(on: f.t.app.db).filter(\.$settingKey == "mail.smtpPassword").first()
        let blob = try XCTUnwrap(row?.value)
        XCTAssertTrue(blob.hasPrefix("v1.")); XCTAssertFalse(blob.contains("p4ss"))
        XCTAssertEqual(row?.secret, true)
        let all = String(decoding: try JSONSerialization.data(withJSONObject: try await get(f)), as: UTF8.self)
        XCTAssertFalse(all.contains("p4ss-w0rd-unique"))
        let audit = try await f.t.json(.GET, "/v1/admin/settings/audit", token: f.admin.token)
        let auditText = String(decoding: try JSONSerialization.data(withJSONObject: audit.list ?? []), as: UTF8.self)
        XCTAssertFalse(auditText.contains("p4ss")); XCTAssertTrue(auditText.contains("mail.smtpPassword"))
        // A ciphertext is bound to its setting key.
        let ring = f.runtime.keyRing
        let sealed = try ring.seal("x", settingKey: "a")
        XCTAssertThrowsError(try ring.open(sealed.blob, keyID: sealed.keyID, settingKey: "b"))
        XCTAssertEqual(try ring.open(sealed.blob, keyID: sealed.keyID, settingKey: "a"), "x")
    }

    func testWithoutEncryptionKeyNoSecretCanBeStored() async throws {
        let f = try await fixture(key: nil); defer { Task { await f.t.shutdown() } }
        let r = try await put(f, "mail.smtpPassword", "secret")
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.body?["reason"] as? String, "encryption_key_missing")
        let v1 = try await get(f)["encryptionKeyConfigured"] as? Bool
        XCTAssertEqual(v1, false)
        let plain = try await put(f, "limits.loginLimit", 5)
        XCTAssertEqual(plain.status, .ok)
        let v2 = try await ServerSetting.query(on: f.t.app.db).filter(\.$secret == true).count()
        XCTAssertEqual(v2, 0)
    }

    func testMalformedEncryptionKeyIsAStartupError() {
        XCTAssertThrowsError(try SettingsKeyRing.fromEnvironment(get: { $0 == "SETTINGS_ENCRYPTION_KEY" ? "too-short" : nil }))
        XCTAssertNotNil(SettingsKeyRing.parse(String(repeating: "ab", count: 32)))
        XCTAssertNil(SettingsKeyRing.parse(Data(repeating: 1, count: 16).base64EncodedString()))
    }

    func testKeyRotationReencryptsSecrets() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        _ = try await put(f, "attachments.s3SecretKey", "s3-secret-value")
        let before = try await ServerSetting.query(on: f.t.app.db).filter(\.$settingKey == "attachments.s3SecretKey").first()
        // Rolled out: new key plus the old one as previous - still readable.
        let ring = try SettingsKeyRing.fromEnvironment(get: { ["SETTINGS_ENCRYPTION_KEY": Self.keyB, "SETTINGS_ENCRYPTION_KEY_PREVIOUS": Self.keyA][$0] })
        let rt = SettingsRuntime(app: f.t.app, env: { _ in nil }, keyRing: ring)
        let v3 = try await rt.load(on: f.t.app.db).values["attachments.s3SecretKey"]
        XCTAssertEqual(v3, "s3-secret-value")
        let n = try await RotateSettingsKeyCommand.rotate(ring: ring, on: f.t.app.db)
        XCTAssertEqual(n, 1)
        let after = try await ServerSetting.query(on: f.t.app.db).filter(\.$settingKey == "attachments.s3SecretKey").first()
        XCTAssertNotEqual(before?.keyID, after?.keyID); XCTAssertNotEqual(before?.value, after?.value)
        // Previous key removed: readable with the new key alone, unreadable with the old one.
        let onlyB = SettingsRuntime(app: f.t.app, env: { _ in nil }, keyRing: try .fromEnvironment(get: { ["SETTINGS_ENCRYPTION_KEY": Self.keyB][$0] }))
        let v4 = try await onlyB.load(on: f.t.app.db).values["attachments.s3SecretKey"]
        XCTAssertEqual(v4, "s3-secret-value")
        let onlyA = SettingsRuntime(app: f.t.app, env: { _ in nil }, keyRing: try .fromEnvironment(get: { ["SETTINGS_ENCRYPTION_KEY": Self.keyA][$0] }))
        let loaded = try await onlyA.load(on: f.t.app.db)
        XCTAssertNil(loaded.values["attachments.s3SecretKey"]); XCTAssertTrue(loaded.unreadable.contains("attachments.s3SecretKey"))
        let again = try await RotateSettingsKeyCommand.rotate(ring: ring, on: f.t.app.db)
        XCTAssertEqual(again, 0)
    }

    // MARK: Versions, validation, audit

    func testVersionConflictAndAudit() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let first = try await put(f, "limits.passwordLimit", 4)
        XCTAssertEqual(first.body?["version"] as? Int, 1)
        let stale = try await put(f, "limits.passwordLimit", 5, version: 0)
        XCTAssertEqual(stale.status, .conflict); XCTAssertEqual(stale.body?["reason"] as? String, "version_conflict")
        XCTAssertEqual(stale.body?["currentVersion"] as? Int, 1)
        let second = try await put(f, "limits.passwordLimit", 5, version: 1)
        XCTAssertEqual(second.body?["version"] as? Int, 2)
        let staleReset = try await f.t.json(.DELETE, "/v1/admin/settings/limits.passwordLimit?version=1", token: f.admin.token)
        XCTAssertEqual(staleReset.status, .conflict)
        let reset = try await f.t.json(.DELETE, "/v1/admin/settings/limits.passwordLimit?version=2", token: f.admin.token)
        XCTAssertEqual(reset.status, .ok); XCTAssertEqual(reset.body?["version"] as? Int, 3)
        let audit = try await f.t.json(.GET, "/v1/admin/settings/audit?key=limits.passwordLimit", token: f.admin.token)
        let actions = (audit.list ?? []).compactMap { $0["action"] as? String }
        XCTAssertEqual(actions, ["reset", "set", "set"])
        XCTAssertEqual((audit.list ?? []).first?["actorName"] as? String, "Root")
    }

    func testValidation() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for (key, value) in [("limits.loginLimit", "abc" as Any), ("limits.loginLimit", 0), ("limits.loginLimit", 999_999_999), ("mail.smtpSecurity", "ssl"),
                             ("auth.passwordLoginEnabled", "yes"), ("branding.instanceName", ""), ("branding.instanceName", String(repeating: "x", count: 200))] {
            let r = try await put(f, key, value)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(key)=\(value)")
            XCTAssertEqual(r.body?["reason"] as? String, "invalid_setting"); XCTAssertEqual(r.body?["key"] as? String, key)
            XCTAssertNotNil(r.body?["message"] as? String)
        }
        let unknown = try await put(f, "nope.nothing", 1)
        XCTAssertEqual(unknown.status, .notFound)
        // Dependencies: enabling mail needs a server and a sender.
        let noHost = try await put(f, "mail.enabled", true)
        XCTAssertEqual(noHost.status, .unprocessableEntity); XCTAssertEqual(noHost.body?["key"] as? String, "mail.smtpHost")
        let v5 = try await put(f, "mail.smtpHost", "smtp.example.org").status
        XCTAssertEqual(v5, .ok)
        let noFrom = try await put(f, "mail.enabled", true)
        XCTAssertEqual(noFrom.body?["key"] as? String, "mail.from")
        let v6 = try await put(f, "mail.from", "not-an-address").status
        XCTAssertEqual(v6, .ok, "single fields are checked together when the feature is switched on")
        let badFrom = try await put(f, "mail.enabled", true)
        XCTAssertEqual(badFrom.status, .unprocessableEntity)
        let v7 = try await put(f, "mail.from", "todolino@example.org", version: 1).status
        XCTAssertEqual(v7, .ok)
        let v8 = try await put(f, "mail.enabled", true).status
        XCTAssertEqual(v8, .ok)
        // User without password is rejected while mail is on.
        let userOnly = try await put(f, "mail.smtpUser", "u")
        XCTAssertEqual(userOnly.status, .unprocessableEntity); XCTAssertEqual(userOnly.body?["reason"] as? String, "setting_dependency")
        let v9 = try await ServerSetting.query(on: f.t.app.db).filter(\.$settingKey == "mail.smtpUser").count()
        XCTAssertEqual(v9, 0)
        // APNs key must parse.
        let v10 = try await put(f, "push.keyId", "ABCDE12345").status
        XCTAssertEqual(v10, .ok)
        let v11 = try await put(f, "push.teamId", "ABCDE12345").status
        XCTAssertEqual(v11, .ok)
        let v12 = try await put(f, "push.key", "not a key").status
        XCTAssertEqual(v12, .ok)
        let pushOn = try await put(f, "push.enabled", true)
        XCTAssertEqual(pushOn.status, .unprocessableEntity); XCTAssertEqual(pushOn.body?["key"] as? String, "push.key")
    }

    // MARK: Hot reload across replicas

    func testHotReloadReachesAnotherInstanceWithoutRestart() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let other = try await f.t.replica(); defer { Task { await other.shutdown() } }
        let rtB = try runtime(other, env: [:])
        try await rtB.bootstrap()
        XCTAssertFalse(other.app.settings.mail.enabled); XCTAssertNil(other.app.mailTransport); XCTAssertNil(other.app.apnsSender)
        for (k, v) in [("mail.smtpHost", "smtp.example.org" as Any), ("mail.from", "todolino@example.org"), ("mail.fromName", "Test-Instanz"),
                       ("mail.smtpPassword", "pw"), ("mail.smtpUser", "u"), ("mail.enabled", true)] {
            let r = try await put(f, k, v)
            XCTAssertEqual(r.status, .ok, "\(k): \(String(describing: r.body))")
        }
        XCTAssertTrue(f.t.app.settings.mail.enabled); XCTAssertNotNil(f.t.app.mailTransport)
        XCTAssertEqual(f.t.app.settings.mail.password, "pw")
        // Instance B has not polled yet.
        XCTAssertFalse(other.app.settings.mail.enabled)
        let applied = await rtB.refresh()
        XCTAssertTrue(applied)
        XCTAssertTrue(other.app.settings.mail.enabled); XCTAssertEqual(other.app.settings.mail.fromName, "Test-Instanz")
        XCTAssertEqual(other.app.settings.mail.password, "pw")
        XCTAssertNotNil(other.app.mailTransport)
        let unchanged = await rtB.refresh()
        XCTAssertFalse(unchanged, "no change, nothing applied")
        // APNs: key, IDs and the switch.
        let pem = P256.Signing.PrivateKey().pemRepresentation
        for (k, v) in [("push.keyId", "ABCDE12345" as Any), ("push.teamId", "TEAMID1234"), ("push.key", pem), ("push.environment", "sandbox"), ("push.enabled", true)] {
            let v13 = try await put(f, k, v).status
            XCTAssertEqual(v13, .ok, k)
        }
        XCTAssertNotNil(f.t.app.apnsSender)
        await rtB.refresh()
        XCTAssertNotNil(other.app.apnsSender); XCTAssertEqual(other.app.settings.apns.environment, .sandbox)
        // Switching off again.
        let v14 = try await put(f, "push.enabled", false, version: 1).status
        XCTAssertEqual(v14, .ok)
        let v15 = try await put(f, "mail.enabled", false, version: 1).status
        XCTAssertEqual(v15, .ok)
        await rtB.refresh()
        XCTAssertNil(other.app.apnsSender); XCTAssertNil(other.app.mailTransport); XCTAssertFalse(other.app.settings.mail.enabled)
        // Settings that need a restart are stored but not applied while running.
        let v16 = try await put(f, "maintenance.syncRetentionDays", 30).body?["requiresRestart"] as? Bool
        XCTAssertEqual(v16, true)
        XCTAssertEqual(f.t.app.settings.syncRetentionDays, 90)
        let fresh = try await f.t.replica(); defer { Task { await fresh.shutdown() } }
        let rtC = try runtime(fresh, env: [:])
        try await rtC.bootstrap()
        XCTAssertEqual(fresh.app.settings.syncRetentionDays, 30, "applied at the next start")
    }

    func testBrandingAppearsInCapabilitiesAndPasswordSwitchIsHot() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let v17 = try await put(f, "branding.instanceName", "Büro-Todo").status
        XCTAssertEqual(v17, .ok)
        let v18 = try await put(f, "auth.passwordLoginEnabled", true).status
        XCTAssertEqual(v18, .ok)
        let caps = try await f.t.json(.GET, "/v1/capabilities")
        XCTAssertEqual(caps.body?["instanceName"] as? String, "Büro-Todo")
        XCTAssertEqual(caps.body?["password"] as? Bool, true)
    }

    func testInvalidStoredConfigurationDoesNotBreakStartup() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        // A row that violates a dependency (written directly, e.g. by an older version).
        for (k, v) in [("mail.enabled", "true")] {
            let row = ServerSetting(); row.settingKey = k; row.value = v; row.secret = false; row.updatedAt = Date(); row.version = 1
            try await row.save(on: f.t.app.db)
        }
        let fresh = try await f.t.replica(); defer { Task { await fresh.shutdown() } }
        let rt = try runtime(fresh, env: [:])
        try await rt.bootstrap()
        XCTAssertFalse(fresh.app.settings.mail.enabled)
        XCTAssertNotNil(rt.lastError)
    }

    // MARK: Test actions

    func testMailTestUsesTheCurrentTransport() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let off = try await f.t.json(.POST, "/v1/admin/settings/test/mail", ["to": "a@example.org"], token: f.admin.token)
        XCTAssertEqual(off.status, .conflict); XCTAssertEqual(off.body?["reason"] as? String, "mail_disabled")
        let mock = MockMail()
        f.t.app.settings.mail = MailTests.mailConfig(); f.t.app.mailTransport = mock
        let noTarget = try await f.t.json(.POST, "/v1/admin/settings/test/mail", [:], token: f.admin.token)
        XCTAssertEqual(noTarget.status, .badRequest)
        let ok = try await f.t.json(.POST, "/v1/admin/settings/test/mail", ["to": " Anna@Example.org "], token: f.admin.token)
        XCTAssertEqual(ok.status, .ok); XCTAssertEqual(ok.body?["ok"] as? Bool, true)
        XCTAssertEqual(mock.sent.first?.to, "anna@example.org")
        mock.failNext(MailSendError(stage: .auth, code: 535))
        let fail = try await f.t.json(.POST, "/v1/admin/settings/test/mail", ["to": "a@example.org"], token: f.admin.token)
        XCTAssertEqual(fail.body?["ok"] as? Bool, false)
        XCTAssertTrue((fail.body?["message"] as? String ?? "").contains("Anmeldung"))
        let audit = try await f.t.json(.GET, "/v1/admin/settings/audit?key=test.mail", token: f.admin.token)
        XCTAssertEqual((audit.list ?? []).count, 2)
    }

    func testStorageAndPushTests() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let storage = try await f.t.json(.POST, "/v1/admin/settings/test/storage", [:], token: f.admin.token)
        XCTAssertEqual(storage.status, .ok); XCTAssertEqual(storage.body?["ok"] as? Bool, true)
        let push = try await f.t.json(.POST, "/v1/admin/settings/test/apns", [:], token: f.admin.token)
        XCTAssertEqual(push.status, .conflict); XCTAssertEqual(push.body?["reason"] as? String, "push_disabled")
        let unknown = try await f.t.json(.POST, "/v1/admin/settings/test/fax", [:], token: f.admin.token)
        XCTAssertEqual(unknown.status, .notFound)
    }

    // MARK: Admin protection

    func testLastAdminCannotBeRemoved() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let list = try await f.t.json(.GET, "/v1/admin/users", token: f.admin.token)
        XCTAssertEqual((list.list ?? []).count, 2)
        let denied = try await f.t.json(.PUT, "/v1/admin/users/\(f.admin.id)/admin", ["isAdmin": false], token: f.admin.token)
        XCTAssertEqual(denied.status, .conflict); XCTAssertEqual(denied.body?["reason"] as? String, "last_admin_required")
        let promote = try await f.t.json(.PUT, "/v1/admin/users/\(f.user.id)/admin", ["isAdmin": true], token: f.admin.token)
        XCTAssertEqual(promote.status, .ok)
        let demote = try await f.t.json(.PUT, "/v1/admin/users/\(f.admin.id)/admin", ["isAdmin": false], token: f.user.token)
        XCTAssertEqual(demote.status, .ok)
        // Now Anna is the only one left.
        let again = try await f.t.json(.PUT, "/v1/admin/users/\(f.user.id)/admin", ["isAdmin": false], token: f.user.token)
        XCTAssertEqual(again.status, .conflict)
        // The former admin has lost access.
        let lost = try await f.t.json(.GET, "/v1/admin/settings", token: f.admin.token)
        XCTAssertEqual(lost.status, .forbidden)
    }
}
