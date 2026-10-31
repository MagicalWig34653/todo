import Crypto
import Foundation

/// AES-256-GCM for secrets stored in `server_settings` (ADR 0025). The key comes from `SETTINGS_ENCRYPTION_KEY`
/// (or `_FILE`): 32 random bytes as base64 or 64 hex characters. `SETTINGS_ENCRYPTION_KEY_PREVIOUS` stays readable
/// during a rotation. The setting key is bound as additional authenticated data, so a ciphertext cannot be moved
/// to another setting.
struct SettingsKeyRing: Sendable {
    struct Key: Sendable {
        let id: String
        let key: SymmetricKey
    }

    let current: Key?
    let previous: [Key]

    init(current: Key? = nil, previous: [Key] = []) { self.current = current; self.previous = previous }

    static func parse(_ text: String) -> Key? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var data: Data?
        if t.count == 64, t.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8](); var i = t.startIndex
            while i < t.endIndex { let j = t.index(i, offsetBy: 2); bytes.append(UInt8(t[i..<j], radix: 16)!); i = j }
            data = Data(bytes)
        } else {
            data = Data(base64Encoded: t)
        }
        guard let data, data.count == 32 else { return nil }
        let id = SHA256.hash(data: Data("todolino.settings.keyid".utf8) + data).prefix(4).map { String(format: "%02x", $0) }.joined()
        return Key(id: id, key: SymmetricKey(data: data))
    }

    /// Missing variables mean "no key"; a present but malformed key is a startup error (never silently ignored).
    static func fromEnvironment(get: (String) -> String?) throws -> SettingsKeyRing {
        func read(_ name: String) throws -> Key? {
            guard let raw = try RuntimeEnvironment.value(name, get: get), !raw.isEmpty else { return nil }
            guard let k = parse(raw) else {
                throw SettingsError.invalid("\(name) ist kein gültiger Schlüssel: erwartet werden 32 Zufallsbytes als Base64 oder 64 Hex-Zeichen (openssl rand -base64 32).")
            }
            return k
        }
        let previous = try read("SETTINGS_ENCRYPTION_KEY_PREVIOUS")
        return SettingsKeyRing(current: try read("SETTINGS_ENCRYPTION_KEY"), previous: previous.map { [$0] } ?? [])
    }

    var canEncrypt: Bool { current != nil }

    private func aad(_ settingKey: String) -> Data { Data("todolino.settings.v1:\(settingKey)".utf8) }

    func seal(_ plain: String, settingKey: String) throws -> (blob: String, keyID: String, fingerprint: String) {
        guard let current else { throw SettingsProblem(code: "encryption_key_missing", key: settingKey, message: "Geheimnisse können nur gespeichert werden, wenn der Server einen Verschlüsselungsschlüssel hat (SETTINGS_ENCRYPTION_KEY).") }
        let box = try AES.GCM.seal(Data(plain.utf8), using: current.key, nonce: AES.GCM.Nonce(), authenticating: aad(settingKey))
        guard let combined = box.combined else { throw SettingsError.invalid("seal failed") }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plain.utf8), using: current.key)
        return ("v1." + combined.base64EncodedString(), current.id, mac.prefix(3).map { String(format: "%02x", $0) }.joined())
    }

    func open(_ blob: String, keyID: String?, settingKey: String) throws -> String {
        guard blob.hasPrefix("v1."), let combined = Data(base64Encoded: String(blob.dropFirst(3))) else { throw SettingsError.invalid("unreadable secret") }
        let candidates = ([current].compactMap { $0 } + previous).filter { keyID == nil || $0.id == keyID }
        for k in candidates {
            if let box = try? AES.GCM.SealedBox(combined: combined), let plain = try? AES.GCM.open(box, using: k.key, authenticating: aad(settingKey)),
               let text = String(data: plain, encoding: .utf8) { return text }
        }
        throw SettingsError.invalid("secret cannot be decrypted with the configured key")
    }
}
