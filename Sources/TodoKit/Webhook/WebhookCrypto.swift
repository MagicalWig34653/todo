import Crypto
import Foundation
import Vapor

/// AES-256-GCM of the webhook secrets with the existing settings key ring (ADR 0025). The additional authenticated data names
/// the purpose, the account and the field, so a ciphertext cannot be moved to another account or from the URL to the secret.
enum WebhookField: String, Sendable { case url, signing }

extension SettingsKeyRing {
    private func webhookAAD(_ userID: UUID, _ field: WebhookField) -> Data {
        Data("todolino.webhook.v1:\(userID.uuidString):\(field.rawValue)".utf8)
    }

    /// Fails with `encryption_key_missing` when the server has no key; the plain text is never part of the error.
    func sealWebhook(_ plain: String, userID: UUID, field: WebhookField) throws -> (blob: String, keyID: String) {
        guard let current else { throw Abort(.conflict, reason: "encryption_key_missing") }
        let box = try AES.GCM.seal(Data(plain.utf8), using: current.key, nonce: AES.GCM.Nonce(), authenticating: webhookAAD(userID, field))
        guard let combined = box.combined else { throw Abort(.internalServerError, reason: "seal_failed") }
        return ("v1." + combined.base64EncodedString(), current.id)
    }

    func openWebhook(_ blob: String, keyID: String?, userID: UUID, field: WebhookField) throws -> String {
        guard blob.hasPrefix("v1."), let combined = Data(base64Encoded: String(blob.dropFirst(3))) else { throw WebhookCryptoError.unreadable }
        let candidates = ([current].compactMap { $0 } + previous).filter { keyID == nil || $0.id == keyID }
        for k in candidates {
            if let box = try? AES.GCM.SealedBox(combined: combined),
               let plain = try? AES.GCM.open(box, using: k.key, authenticating: webhookAAD(userID, field)),
               let text = String(data: plain, encoding: .utf8) { return text }
        }
        throw WebhookCryptoError.unreadable
    }
}

/// The stored secret cannot be decrypted with the configured keys (key removed or rotated away). Carries no data.
enum WebhookCryptoError: Error, Sendable { case unreadable }

enum WebhookSignature {
    /// `X-Todolino-Timestamp` and `X-Todolino-Signature: sha256=<hex>`; HMAC-SHA256 over `"<timestamp>.<body>"`.
    static func headers(secret: String, body: Data, now: Date) -> [(String, String)] {
        let timestamp = String(Int(now.timeIntervalSince1970))
        return [("X-Todolino-Timestamp", timestamp), ("X-Todolino-Signature", "sha256=" + hex(secret: secret, timestamp: timestamp, body: body))]
    }

    static func hex(secret: String, timestamp: String, body: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data((timestamp + ".").utf8) + body, using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
