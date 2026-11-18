import Crypto
import Fluent
import Foundation
import Vapor

/// Short-lived signed download links for agents: `/v1/attachments/{id}/download?exp=<unix>&sig=<hex>`.
/// The signature covers the attachment id and the expiry only, so a link opens exactly one attachment, until
/// `exp`, with GET. The HMAC key is derived (HKDF) from SETTINGS_ENCRYPTION_KEY when set; otherwise a random key
/// stored once in the database is shared by all replicas (a per-process key made links 404 on other replicas).
enum AttachmentLink {
    static let lifetime: TimeInterval = 300

    /// Derived from SETTINGS_ENCRYPTION_KEY when set (identical on every replica and across restarts).
    private static let environmentKey: [UInt8]? = {
        guard let ring = try? SettingsKeyRing.fromEnvironment(get: { Environment.get($0) }), let current = ring.current else { return nil }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: current.material),
                                         info: Data("todolino.attachment-link.v1".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Array($0) }
    }()

    /// Without the environment key every API replica must still agree on the key, otherwise a link issued by one
    /// replica is a 404 on the others (and after every restart). So the key is stored once in `server_settings`
    /// (random, created by the first replica that needs it) and cached per process.
    static let storedSettingKey = "internal.attachment_link_key"
    private static let cache = Locked<[UInt8]?>(nil)

    static func resolveKey(db: any Database, useCache: Bool = true) async throws -> [UInt8] {
        if let environmentKey { return environmentKey }
        if useCache, let cached = cache.value { return cached }
        func read() async throws -> [UInt8]? {
            guard let row = try await ServerSetting.query(on: db).filter(\.$settingKey == storedSettingKey).first(),
                  let text = row.value, let data = Data(base64Encoded: text), data.count == 32 else { return nil }
            return Array(data)
        }
        var key = try await read()
        if key == nil {
            let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
            let row = ServerSetting()
            row.settingKey = storedSettingKey; row.value = Data(fresh).base64EncodedString(); row.secret = false
            row.updatedAt = Date(); row.version = 1
            // A concurrent replica may win the unique index; then its key is the one to use.
            do { try await row.create(on: db); key = fresh } catch { key = try await read() }
        }
        guard let key else { throw Abort(.internalServerError, reason: "attachment_link_key_unavailable") }
        if useCache { cache.value = key }
        return key
    }

    private static func mac(_ id: UUID, _ exp: Int, key: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data("dl1|\(id.uuidString.lowercased())|\(exp)".utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Path (no host) of the link for one attachment.
    static func path(for id: UUID, key: [UInt8], now: Date = Date()) -> (path: String, expiresAt: Date) {
        let exp = Int(now.timeIntervalSince1970 + lifetime)
        return ("/v1/attachments/\(id.uuidString)/download?exp=\(exp)&sig=\(hex(mac(id, exp, key: key)))",
                Date(timeIntervalSince1970: TimeInterval(exp)))
    }

    /// True only for an unexpired link whose signature matches this attachment (constant-time comparison).
    static func verify(id: UUID, exp: String?, sig: String?, key: [UInt8], now: Date = Date()) -> Bool {
        guard let exp, let expInt = Int(exp), let sig, sig.count == 64,
              sig.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
              Double(expInt) > now.timeIntervalSince1970,
              Double(expInt) <= now.timeIntervalSince1970 + lifetime + 60 else { return false }
        return AuthSupport.constantTimeEquals(hex(mac(id, expInt, key: key)), sig)
    }
}
