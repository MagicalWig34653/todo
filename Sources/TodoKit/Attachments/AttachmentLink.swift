import Crypto
import Foundation
import Vapor

/// Short-lived signed download links for agents: `/v1/attachments/{id}/download?exp=<unix>&sig=<hex>`.
/// The signature covers the attachment id and the expiry only, so a link opens exactly one attachment, until
/// `exp`, with GET. The HMAC key is derived (HKDF) from SETTINGS_ENCRYPTION_KEY when set; otherwise a random
/// per-process key is used (links then die on restart and do not work across replicas).
enum AttachmentLink {
    static let lifetime: TimeInterval = 300

    /// Process-wide, derived from the environment key or random. Never stored, never logged.
    /// Raw bytes: `SymmetricKey` is not `Sendable` on Linux (static properties must be).
    private static let keyBytes: [UInt8] = {
        let key: SymmetricKey
        if let ring = try? SettingsKeyRing.fromEnvironment(get: { Environment.get($0) }), let current = ring.current {
            key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: current.material),
                                         info: Data("todolino.attachment-link.v1".utf8), outputByteCount: 32)
        } else {
            key = SymmetricKey(size: .bits256)
        }
        return key.withUnsafeBytes { Array($0) }
    }()

    private static func mac(_ id: UUID, _ exp: Int) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data("dl1|\(id.uuidString.lowercased())|\(exp)".utf8), using: SymmetricKey(data: keyBytes)))
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Path (no host) of the link for one attachment.
    static func path(for id: UUID, now: Date = Date()) -> (path: String, expiresAt: Date) {
        let exp = Int(now.timeIntervalSince1970 + lifetime)
        return ("/v1/attachments/\(id.uuidString)/download?exp=\(exp)&sig=\(hex(mac(id, exp)))",
                Date(timeIntervalSince1970: TimeInterval(exp)))
    }

    /// True only for an unexpired link whose signature matches this attachment (constant-time comparison).
    static func verify(id: UUID, exp: String?, sig: String?, now: Date = Date()) -> Bool {
        guard let exp, let expInt = Int(exp), let sig, sig.count == 64,
              sig.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
              Double(expInt) > now.timeIntervalSince1970,
              Double(expInt) <= now.timeIntervalSince1970 + lifetime + 60 else { return false }
        return AuthSupport.constantTimeEquals(hex(mac(id, expInt)), sig)
    }
}
